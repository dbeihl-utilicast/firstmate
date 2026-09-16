#!/usr/bin/env python3
# fm-foundry-luna-proxy.py - local token-refreshing gateway for the Azure AI
# Foundry `gpt-5.6-luna` deployment, the only deployment the captain has
# authorized for fleet dispatch. The Foundry account host and subscription id
# are private operational data (this fork is public), so neither is
# hard-coded here: both are read from the local, gitignored config file named
# by FM_FOUNDRY_LUNA_CONFIG, which bin/fm-spawn.sh resolves from the
# launching home's own config/foundry-luna.json (inherited into secondmate
# homes by bin/fm-config-inherit-lib.sh so a secondmate's own crewmates can
# reach it too). Absent, unreadable, malformed, or non-Azure config refuses
# to start rather than falling back to any built-in host.
#
# Why this exists: an AAD access token expires in about an hour and an
# overnight worker outlives it, but the OpenAI-compatible CLI this proxy sits
# behind reads its bearer token once from its process environment at launch
# and has no per-request refresh hook for a generic (non-AWS) provider. This
# proxy is the worker's own token refresh: it listens on loopback only, mints
# its own per-launch secret and admits only the child it handed that secret to,
# fetches a fresh AAD token via `az account get-access-token` on demand, caches
# it only in memory until shortly before expiry, and forwards to Foundry with
# that token attached. Neither value is ever read from argv, written to a file,
# or logged. The gateway is silent on stdout and stderr - including its
# error path (a client disconnect mid-relay, an upstream network failure) -
# because in a dispatched pane it shares a tty with the worker's TUI; naming a
# file in FM_FOUNDRY_LUNA_LOG appends each request's status line there instead.
#
# It also carries the deployment allowlist. Foundry names the deployment in two
# places - the JSON body's `model` and the deployment-scoped URL - so both are
# pinned: only the single route the configured base_url produces is relayed, and
# only `gpt-5.6-luna` in the body. Anything else is refused locally before a
# token is fetched, so an unauthorized deployment cannot rack up Azure cost.
import hmac
import http.client
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import traceback

ALLOWED_MODEL = "gpt-5.6-luna"
ALLOWED_PATH = "/openai/v1/responses"
FOUNDRY_HOST_SUFFIX = ".services.ai.azure.com"
# Exactly one DNS label (RFC 1123: alnum, interior hyphens, 1-63 chars) plus
# the literal Foundry suffix - no extra subdomain labels, no path, no port,
# and no placeholder-shaped value such as docs/examples/foundry-luna.json's
# own "<foundry-account>..." (angle brackets are not a valid label character).
FOUNDRY_HOST_RE = re.compile(
    r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" + re.escape(FOUNDRY_HOST_SUFFIX) + r"$",
    re.IGNORECASE,
)
SUBSCRIPTION_ID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)
TOKEN_RESOURCE = "https://cognitiveservices.azure.com"
REFRESH_MARGIN_SECONDS = 300

ACCESS_LOG_PATH = os.environ.get("FM_FOUNDRY_LUNA_LOG", "")
CLIENT_SECRET_ENV = "FM_FOUNDRY_LUNA_SECRET"
CONFIG_PATH_ENV = "FM_FOUNDRY_LUNA_CONFIG"
PORT_PLACEHOLDER = "__FOUNDRYLUNAPORT__"
HOP_BY_HOP_HEADERS = (
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade",
)

_foundry_config = None


def resolve_foundry_config():
    """Reads and validates (host, subscription_id) from FM_FOUNDRY_LUNA_CONFIG.

    Never falls back to a built-in host: absent, unreadable, malformed JSON,
    a missing field, or a host that is not a genuine Foundry hostname all
    refuse to start with a message naming the concrete problem, so a
    misconfigured or malicious config file cannot redirect the real AAD
    bearer token to an arbitrary host. Memoized because it is consulted from
    more than one call site in a single process lifetime.
    """
    global _foundry_config
    if _foundry_config is not None:
        return _foundry_config
    path = os.environ.get(CONFIG_PATH_ENV, "")
    if not path:
        sys.exit(
            "fm-foundry-luna-proxy: %s is not set; the launching home's "
            "config/foundry-luna.json path is required to resolve the "
            "Foundry endpoint" % CONFIG_PATH_ENV
        )
    try:
        with open(path, "r") as fh:
            raw = fh.read()
    except OSError as exc:
        sys.exit(
            "fm-foundry-luna-proxy: config file named by %s is missing or "
            "unreadable at %r: %s" % (CONFIG_PATH_ENV, path, exc)
        )
    try:
        data = json.loads(raw)
    except ValueError as exc:
        sys.exit(
            "fm-foundry-luna-proxy: config file at %r is not valid JSON: %s"
            % (path, exc)
        )
    host = data.get("host") if isinstance(data, dict) else None
    subscription = data.get("subscription_id") if isinstance(data, dict) else None
    if not isinstance(host, str) or not FOUNDRY_HOST_RE.match(host):
        sys.exit(
            "fm-foundry-luna-proxy: config file at %r has an invalid or "
            "missing 'host'; it must be exactly one DNS label plus %r "
            "(docs/examples/foundry-luna.json's own placeholder value is "
            "deliberately invalid until filled in)"
            % (path, FOUNDRY_HOST_SUFFIX)
        )
    if not isinstance(subscription, str) or not SUBSCRIPTION_ID_RE.match(subscription):
        sys.exit(
            "fm-foundry-luna-proxy: config file at %r has an invalid or "
            "missing 'subscription_id'; it must be a GUID" % path
        )
    _foundry_config = (host, subscription)
    return _foundry_config


def resolve_upstream(override):
    """Test-only escape hatch: point forwarding at a LOOPBACK fake upstream.

    A non-loopback override would send this proxy's real AAD bearer token to
    an arbitrary host, so it is refused loudly rather than honored or ignored.
    """
    if not override:
        host, _ = resolve_foundry_config()
        return host, "https"
    if override.split(":", 1)[0] != "127.0.0.1":
        sys.exit(
            "fm-foundry-luna-proxy: FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST must be "
            "127.0.0.1 or 127.0.0.1:<port>; refusing to attach an AAD token for "
            "a request to %r" % override
        )
    return override, "http"


UPSTREAM_HOST, UPSTREAM_SCHEME = resolve_upstream(
    os.environ.get("FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST", "")
)


class TokenCache:
    """Holds the current AAD token only in memory; never persisted to disk."""

    def __init__(self, fetch):
        self._fetch = fetch
        self._token = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def get(self):
        with self._lock:
            if self._token is None or time.time() >= self._expires_at - REFRESH_MARGIN_SECONDS:
                self._token, self._expires_at = self._fetch()
            return self._token


def fetch_az_token(subscription=None, resource=TOKEN_RESOURCE):
    """Runs `az account get-access-token` and returns (token, epoch_expiry).

    Never logs or returns anything but the two values the caller needs; the
    token itself is handed straight to the caller and never printed here.
    An `expires_on` that is missing, cannot be read as a number, or is
    already at or before now is never guessed at or used: that is a failed
    refresh, raised as ValueError/KeyError so every caller's existing
    refusal path handles it the same way a broken `az` invocation already
    does, and the caller never caches or forwards a token with no real
    remaining expiry attached.
    """
    if subscription is None:
        _, subscription = resolve_foundry_config()
    proc = subprocess.run(
        [
            "az", "account", "get-access-token",
            "--subscription", subscription,
            "--resource", resource,
            "-o", "json",
        ],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(proc.stdout)
    try:
        expires_at = float(data["expires_on"])
    except (TypeError, ValueError) as exc:
        raise ValueError(
            "az reported a token with an unreadable expires_on value"
        ) from exc
    if expires_at <= time.time():
        raise ValueError("az reported a token that is already expired")
    return data["accessToken"], expires_at


def make_handler(token_cache, client_secret, upstream_host=UPSTREAM_HOST, upstream_scheme=UPSTREAM_SCHEME):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            if not ACCESS_LOG_PATH:
                return
            with open(ACCESS_LOG_PATH, "a") as fh:
                fh.write("fm-foundry-luna-proxy: " + (fmt % args) + "\n")

        def do_POST(self):
            offered = self.headers.get("Authorization", "").encode("latin-1", "replace")
            expected = ("Bearer " + client_secret).encode("latin-1", "replace")
            if not hmac.compare_digest(offered, expected):
                self._reject(401, "caller is not authorized to use this gateway")
                return
            if self.path != ALLOWED_PATH:
                self._reject(
                    403,
                    "route %r is not authorized; only %r may be relayed"
                    % (self.path, ALLOWED_PATH),
                )
                return
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length) if length else b""
            try:
                parsed = json.loads(body) if body else {}
            except ValueError:
                self._reject(400, "request body is not valid JSON")
                return
            model = parsed.get("model")
            if model != ALLOWED_MODEL:
                self._reject(
                    403,
                    "deployment %r is not authorized; only %r may be dispatched"
                    % (model, ALLOWED_MODEL),
                )
                return
            self._forward(body)

        def _reject(self, status, message):
            payload = json.dumps({"error": {"message": message}}).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _forward(self, body):
            try:
                token = token_cache.get()
            except (subprocess.CalledProcessError, OSError, ValueError, KeyError):
                self._reject(502, "token refresh failed")
                return
            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in ("host", "content-length", "authorization")
            }
            headers["Authorization"] = "Bearer " + token
            headers["Content-Length"] = str(len(body))
            conn_cls = http.client.HTTPSConnection if upstream_scheme == "https" else http.client.HTTPConnection
            conn = conn_cls(upstream_host, timeout=120)
            try:
                conn.request("POST", self.path, body=body, headers=headers)
                upstream = conn.getresponse()
                self._relay(upstream)
            finally:
                conn.close()

        def _relay(self, upstream):
            """Re-frames the upstream reply for this connection.

            A streamed Foundry reply arrives chunked with no Content-Length, so
            its framing cannot be copied through: it is re-chunked here, flushed
            per read so a streaming client renders as the turn arrives.
            """
            declared = upstream.getheader("Content-Length")
            self.log_request(upstream.status)
            self.send_response_only(upstream.status)
            for k, v in upstream.getheaders():
                if k.lower() in HOP_BY_HOP_HEADERS or k.lower() == "content-length":
                    continue
                self.send_header(k, v)
            if declared is not None:
                self.send_header("Content-Length", declared)
                self.end_headers()
                self.wfile.write(upstream.read())
                return
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while True:
                chunk = upstream.read1(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")

    return Handler


def log_silently(message):
    if not ACCESS_LOG_PATH:
        return
    with open(ACCESS_LOG_PATH, "a") as fh:
        fh.write("fm-foundry-luna-proxy: " + message + "\n")
        traceback.print_exc(file=fh)


class Gateway(http.server.ThreadingHTTPServer):
    """Silent by default on the error path too: an exception escaping a
    request handler (a client disconnect mid-relay, an upstream network
    error) must never print a traceback to the pane's tty, the same
    invariant Handler.log_message already holds for the ordinary access log.
    """

    def handle_error(self, request, client_address):
        log_silently("error handling request from %s" % (client_address,))


def start_server(port, client_secret):
    """Binds the listening socket. The bound port is the ONE the gateway serves.

    Takes the first token BEFORE binding, so an unusable credential is a launch
    that fails instead of a live pane that 502s silently on every turn.
    """
    token_cache = TokenCache(fetch_az_token)
    try:
        token_cache.get()
    except (subprocess.CalledProcessError, OSError, ValueError, KeyError):
        log_silently("initial AAD token fetch failed; refusing to serve")
        raise SystemExit(70)
    server = Gateway(("127.0.0.1", port), make_handler(token_cache, client_secret))
    return server


def cmd_serve(argv):
    """serve <port>: foreground gateway for tests; prints its port, then blocks.

    Test-only, like FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST: it admits the caller
    holding FM_FOUNDRY_LUNA_TEST_SECRET, because a test client has no child
    environment to read one from. The dispatched path is `run`, which mints its
    own secret so no admission value ever exists outside this process and the
    child it starts.
    """
    client_secret = os.environ.get("FM_FOUNDRY_LUNA_TEST_SECRET", "")
    if not client_secret:
        sys.exit(
            "fm-foundry-luna-proxy: serve needs FM_FOUNDRY_LUNA_TEST_SECRET to name "
            "the secret it admits; refusing to serve an unauthenticated AAD token broker"
        )
    port = int(argv[0]) if argv else 0
    server = start_server(port, client_secret)
    sys.stdout.write("%d\n" % server.server_address[1])
    sys.stdout.flush()
    server.serve_forever()


def cmd_run(argv):
    """run -- <command> [args...]: bind a free loopback port, run the gateway on
    it in the background and the given command in the foreground with every
    __FOUNDRYLUNAPORT__ in its argv replaced by that port, inheriting its stdio
    (so an interactive CLI's TUI still renders normally); exits with the
    command's exit status and stops the gateway either way.

    The port is chosen here, at the one moment it can be held: the socket that
    is probed is the socket that serves, so nothing can take it in between.

    The admission secret is minted here too and reaches the child only through
    its environment, so it never appears in a launch command, an argv any local
    user can read out of /proc, or anything on disk.
    """
    if len(argv) < 2 or argv[0] != "--":
        sys.exit("usage: fm-foundry-luna-proxy.py run -- <command> [args...]")
    command = argv[1:]
    client_secret = secrets.token_hex(32)
    try:
        server = start_server(0, client_secret)
    except OSError:
        log_silently("gateway could not bind a loopback port")
        return 70
    port = str(server.server_address[1])
    command = [arg.replace(PORT_PLACEHOLDER, port) for arg in command]
    child_env = dict(os.environ, **{CLIENT_SECRET_ENV: client_secret})

    def serve():
        try:
            server.serve_forever()
        except Exception:
            log_silently("gateway stopped serving")

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    try:
        return subprocess.run(command, env=child_env).returncode
    except OSError:
        log_silently("the wrapped command could not be started")
        return 70
    finally:
        server.shutdown()


def main(argv):
    if len(argv) >= 2 and argv[1] == "run":
        sys.exit(cmd_run(argv[2:]))
    if len(argv) >= 2 and argv[1] == "serve":
        cmd_serve(argv[2:])
        return
    sys.exit("usage: fm-foundry-luna-proxy.py serve <port> | run -- <command> [args...]")


if __name__ == "__main__":
    main(sys.argv)
