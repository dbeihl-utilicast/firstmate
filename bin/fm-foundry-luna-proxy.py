#!/usr/bin/env python3
# fm-foundry-luna-proxy.py - local token-refreshing gateway for the Azure AI
# Foundry `gpt-5.6-luna` deployment, the only deployment the captain has
# authorized for fleet dispatch (aih-utilicast-ftiek / rg-utilicast-convert /
# subscription 201f9be2-2f49-47d4-9f16-f2ab8a9cd1a2).
#
# Why this exists: an AAD access token expires in about an hour and an
# overnight worker outlives it, but the OpenAI-compatible CLI this proxy sits
# behind reads its bearer token once from its process environment at launch
# and has no per-request refresh hook for a generic (non-AWS) provider. This
# proxy is the worker's own token refresh: it listens on loopback only, fetches
# a fresh AAD token via `az account get-access-token` on demand, caches it only
# in memory until shortly before expiry, and forwards to Foundry with that
# token attached. No credential value is ever read from argv, written to a
# file, or logged; only HTTP status codes are logged.
#
# It also carries the deployment allowlist: any request naming a model other
# than `gpt-5.6-luna` is refused locally and never reaches Azure, so an
# unauthorized deployment on this account cannot rack up cost.
import datetime
import http.client
import http.server
import json
import os
import subprocess
import sys
import threading
import time

ALLOWED_MODEL = "gpt-5.6-luna"
FOUNDRY_HOST = "aih-utilicast-ftiek.services.ai.azure.com"
SUBSCRIPTION_ID = "201f9be2-2f49-47d4-9f16-f2ab8a9cd1a2"
TOKEN_RESOURCE = "https://cognitiveservices.azure.com"
REFRESH_MARGIN_SECONDS = 300

# Test-only escape hatch: redirect forwarding away from the real Foundry host
# so tests can point this proxy at a local fake upstream. Unset in every real
# launch, so production traffic always goes to FOUNDRY_HOST over https.
UPSTREAM_HOST = os.environ.get("FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST", FOUNDRY_HOST)
UPSTREAM_SCHEME = os.environ.get("FM_FOUNDRY_LUNA_TEST_UPSTREAM_SCHEME", "https")


class TokenCache:
    """Holds the current AAD token only in memory; never persisted to disk."""

    def __init__(self, fetch):
        self._fetch = fetch
        self._token = None
        self._expires_at = 0.0

    def get(self):
        if self._token is None or time.time() >= self._expires_at - REFRESH_MARGIN_SECONDS:
            self._token, self._expires_at = self._fetch()
        return self._token


def fetch_az_token(subscription=SUBSCRIPTION_ID, resource=TOKEN_RESOURCE):
    """Runs `az account get-access-token` and returns (token, epoch_expiry).

    Never logs or returns anything but the two values the caller needs; the
    token itself is handed straight to the caller and never printed here.
    """
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
    if "expires_on" in data:
        expires_at = float(data["expires_on"])
    else:
        expires_at = datetime.datetime.strptime(
            data["expiresOn"], "%Y-%m-%d %H:%M:%S.%f"
        ).timestamp()
    return data["accessToken"], expires_at


def make_handler(token_cache, upstream_host=UPSTREAM_HOST, upstream_scheme=UPSTREAM_SCHEME):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            sys.stderr.write("fm-foundry-luna-proxy: " + (fmt % args) + "\n")

        def do_POST(self):
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
            # gpt-5.6-luna rejects the legacy `max_tokens` field with a 400
            # ("Use 'max_completion_tokens' instead"), confirmed live against
            # the account; most OpenAI-compatible clients still send the
            # legacy name, so translate it here rather than pushing that
            # quirk onto every caller.
            if "max_tokens" in parsed and "max_completion_tokens" not in parsed:
                parsed["max_completion_tokens"] = parsed.pop("max_tokens")
                body = json.dumps(parsed).encode()
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
                data = upstream.read()
                self.send_response(upstream.status)
                for k, v in upstream.getheaders():
                    if k.lower() in ("transfer-encoding", "connection"):
                        continue
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(data)
            finally:
                conn.close()

    return Handler


def start_server(port):
    token_cache = TokenCache(fetch_az_token)
    server = http.server.HTTPServer(("127.0.0.1", port), make_handler(token_cache))
    return server


def cmd_serve(argv):
    """serve <port>: run the gateway in the foreground; prints its port, then blocks."""
    port = int(argv[0]) if argv else 0
    server = start_server(port)
    sys.stdout.write("%d\n" % server.server_address[1])
    sys.stdout.flush()
    server.serve_forever()


def cmd_run(argv):
    """run --port <port> -- <command> [args...]: run the gateway in the
    background and the given command in the foreground, inheriting its
    stdio (so an interactive CLI's TUI still renders normally); exits with
    the command's exit status and stops the gateway either way.
    """
    if len(argv) < 3 or argv[0] != "--port" or "--" not in argv:
        sys.exit("usage: fm-foundry-luna-proxy.py run --port <port> -- <command> [args...]")
    port = int(argv[1])
    command = argv[argv.index("--") + 1:]
    if not command:
        sys.exit("usage: fm-foundry-luna-proxy.py run --port <port> -- <command> [args...]")
    server = start_server(port)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        return subprocess.run(command).returncode
    finally:
        server.shutdown()


def main(argv):
    if len(argv) >= 2 and argv[1] == "run":
        sys.exit(cmd_run(argv[2:]))
    if len(argv) >= 2 and argv[1] == "serve":
        cmd_serve(argv[2:])
        return
    sys.exit("usage: fm-foundry-luna-proxy.py serve <port> | run --port <port> -- <command> [args...]")


if __name__ == "__main__":
    main(sys.argv)
