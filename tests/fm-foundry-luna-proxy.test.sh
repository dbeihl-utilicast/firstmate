#!/usr/bin/env bash
# Behavior tests for bin/fm-foundry-luna-proxy.py: the local AAD-token-
# refreshing gateway that gates every request bound for the gpt-5.6-luna
# Azure AI Foundry deployment.
#
# Every case here runs against a fake `az` on PATH and a fake local upstream
# HTTP server; no real credential and no real network call to Azure is ever
# made or needed. The refusal case proves an unauthorized deployment name
# never reaches the fake upstream at all. The refresh case proves an expired
# cached token makes the proxy obtain a genuinely new token on the next
# request rather than reusing the stale value, by having the fake az CLI mint
# a distinct nonsecret fake token string on every invocation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROXY="$ROOT/bin/fm-foundry-luna-proxy.py"
TMP_ROOT=$(fm_test_tmproot fm-foundry-luna-proxy)

# The real code path resolves the Foundry host and subscription id from
# FM_FOUNDRY_LUNA_CONFIG rather than a built-in default, so every case in this
# suite needs a fixture config present - exported once here rather than
# per-test, since it is ordinary environment inheritance, not launch-command
# text. Values are obviously fake; only tests that specifically exercise
# config resolution itself override this.
FOUNDRY_LUNA_FIXTURE_CONFIG="$TMP_ROOT/fixture-foundry-luna.json"
printf '{"host":"fixture-account.services.ai.azure.com","subscription_id":"00000000-0000-0000-0000-000000000000"}\n' \
  > "$FOUNDRY_LUNA_FIXTURE_CONFIG"
export FM_FOUNDRY_LUNA_CONFIG="$FOUNDRY_LUNA_FIXTURE_CONFIG"

# The secret a foreground `serve` gateway admits, for the cases that drive it
# with curl rather than through a wrapped child. A nonsecret fixture string that
# resembles no real credential; `run` mints its own and hands it to its child.
GATEWAY_SECRET=fm-test-gateway-fixture-not-a-credential
AUTH_HEADER="Authorization: Bearer $GATEWAY_SECRET"

# fm_start_fake_upstream <log-file> -> prints "<pid> <port>"
# The fake upstream always answers 200 and records the path and Authorization
# header it received for each forwarded request.
fm_start_fake_upstream() {
  local log=$1 script="$TMP_ROOT/fake_upstream_$$_$RANDOM.py" portfile
  portfile=$(mktemp "$TMP_ROOT/upstream-port.XXXXXX")
  cat > "$script" <<'PY'
import http.server
import sys

log_path = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        req_body = self.rfile.read(n)
        with open(log_path, "a") as fh:
            fh.write(
                self.path + "\t" + self.headers.get("Authorization", "") + "\t"
                + req_body.decode("utf-8", "replace").replace("\n", " ") + "\n"
            )
        if self.path != "/openai/v1/responses":
            body = b'{"error":{"message":"unserved route"}}'
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if b'"stream": true' in req_body or b'"stream":true' in req_body:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                event = b'data: {"seq":%d}\n\n' % i
                self.wfile.write(b"%x\r\n" % len(event) + event + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            return
        body = b'{"ok":true}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PY
  python3 "$script" "$log" > "$portfile" 2>"$TMP_ROOT/upstream-err-$$" &
  local pid=$!
  local port=
  for _ in $(seq 1 50); do
    [ -s "$portfile" ] && { port=$(cat "$portfile"); break; }
    sleep 0.1
  done
  [ -n "$port" ] || fail "fake upstream never printed a listening port"
  printf '%s %s\n' "$pid" "$port"
}

# fm_start_proxy <fake-az-dir> <upstream-port> -> prints "<pid> <port>"
fm_start_proxy() {
  local az_dir=$1 upstream_port=$2 portfile
  portfile=$(mktemp "$TMP_ROOT/proxy-port.XXXXXX")
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    FM_FOUNDRY_LUNA_TEST_SECRET="$GATEWAY_SECRET" \
    python3 "$PROXY" serve 0 > "$portfile" 2>"$TMP_ROOT/proxy-err-$$" &
  local pid=$!
  local port=
  for _ in $(seq 1 50); do
    [ -s "$portfile" ] && { port=$(cat "$portfile"); break; }
    sleep 0.1
  done
  [ -n "$port" ] || fail "proxy never printed a listening port"
  printf '%s %s\n' "$pid" "$port"
}

# fm_start_fake_upstream_reply <status> <body-file> -> prints "<pid> <port>"
# Serves one fixed JSON body at the given status for every POST, so a test can
# force Foundry's 401/404/500 shapes without a live account.
fm_start_fake_upstream_reply() {
  local status=$1 body_file=$2 script="$TMP_ROOT/fake_upstream_reply_$$_$RANDOM.py" portfile
  portfile=$(mktemp "$TMP_ROOT/upstream-reply-port.XXXXXX")
  cat > "$script" <<'PY'
import http.server
import pathlib
import sys

status = int(sys.argv[1])
body = pathlib.Path(sys.argv[2]).read_bytes()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(n)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(srv.server_address[1])
sys.stdout.flush()
srv.serve_forever()
PY
  python3 "$script" "$status" "$body_file" > "$portfile" 2>"$TMP_ROOT/upstream-reply-err-$$" &
  local pid=$!
  local port=
  for _ in $(seq 1 50); do
    [ -s "$portfile" ] && { port=$(cat "$portfile"); break; }
    sleep 0.1
  done
  [ -n "$port" ] || fail "classified-reply upstream never printed a listening port"
  printf '%s %s\n' "$pid" "$port"
}

# fm_write_fake_az <dir> <calls-file>
# Mints "FAKE-TOKEN-<n>" on the n'th invocation, reporting an expiry 30
# seconds in the future - comfortably not-yet-expired at fetch time (the
# proxy now refuses an already-expired token outright) but still deep inside
# REFRESH_MARGIN_SECONDS (300s), so callers always take the refresh path on
# their NEXT request with no need to fake wall-clock time. Never touches a
# real credential.
fm_write_fake_az() {
  local dir=$1 calls_file=$2
  mkdir -p "$dir"
  : > "$calls_file"
  cat > "$dir/az" <<SH
#!/usr/bin/env bash
set -u
n=\$(( \$(cat "$calls_file") + 1 ))
echo "\$n" > "$calls_file"
printf '{"accessToken":"FAKE-TOKEN-%s","expires_on":%s}\n' "\$n" "\$(( \$(date +%s) + 30 ))"
SH
  chmod +x "$dir/az"
}

# fm_write_fake_az_fails_after_one <dir> <calls-file>
# Same first response, but any second invocation exits nonzero loudly instead
# of minting another token, so a test using it fails hard if the proxy calls
# az more than once for a still-valid cached token.
fm_write_fake_az_fails_after_one() {
  local dir=$1 calls_file=$2
  mkdir -p "$dir"
  : > "$calls_file"
  cat > "$dir/az" <<SH
#!/usr/bin/env bash
set -u
n=\$(( \$(cat "$calls_file") + 1 ))
echo "\$n" > "$calls_file"
if [ "\$n" -gt 1 ]; then
  echo "fake az: unexpected second call; a cached non-expired token must not be refetched" >&2
  exit 7
fi
printf '{"accessToken":"FAKE-TOKEN-ONLY","expires_on":9999999999}\n'
SH
  chmod +x "$dir/az"
}

# fm_write_relaying_child <path> [exit-status] -> prints <path>
# A stand-in "codex" for run mode: it learns its gateway's port only from its
# own argv (where the gateway substitutes __FOUNDRYLUNAPORT__) and its secret
# only from the environment the gateway handed it, exactly as codex does with
# base_url and env_key. $1 port, $2 status file, $3 optional port-echo file.
# Stays quiet on stdio so a run-mode silence assertion measures the gateway.
fm_write_relaying_child() {
  local path=$1 exit_status=${2:-0}
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
port=\$1
[ -z "\${3:-}" ] || printf '%s\n' "\$port" > "\$3"
curl -s -o /dev/null -w '%{http_code}' \\
  -X POST "http://127.0.0.1:\$port/openai/v1/responses" \\
  -H 'Content-Type: application/json' \\
  -H "Authorization: Bearer \$FM_FOUNDRY_LUNA_SECRET" \\
  -d '{"model":"gpt-5.6-luna","input":[]}' 2>/dev/null > "\$2"
exit $exit_status
SH
  chmod +x "$path"
  printf '%s\n' "$path"
}

test_refuses_every_unauthorized_deployment_name() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port name status body baseline

  az_dir="$TMP_ROOT/az-refuse"
  calls="$TMP_ROOT/az-refuse-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-refuse.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }
  baseline=$(cat "$calls")

  for name in gpt-5.6-terra gpt-5.6-sol claude-sonnet-5 claude-opus-5; do
    body=$(curl -sS -o "$TMP_ROOT/refuse-body" -w '%{http_code}' \
      -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
      -H 'Content-Type: application/json' \
      -H "$AUTH_HEADER" \
      -d "{\"model\":\"$name\",\"messages\":[]}")
    status=$body
    if [ "$status" -lt 400 ]; then
      kill "$proxy_pid" "$upstream_pid" 2>/dev/null
      fail "refusal did not fail red for deployment '$name': got HTTP $status $(cat "$TMP_ROOT/refuse-body")"
    fi
    assert_contains "$(cat "$TMP_ROOT/refuse-body")" "not authorized" \
      "refusal body for '$name' names the reason"
  done

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  [ ! -s "$upstream_log" ] || fail "an unauthorized deployment name reached the fake upstream: $(cat "$upstream_log")"
  assert_equals "$baseline" "$(cat "$calls")" \
    "an unauthorized deployment name must trigger no token fetch beyond the gateway's startup one"
  pass "fm-foundry-luna-proxy: refuses every unauthorized deployment name before reaching Azure"
}

test_refresh_path_obtains_a_new_token_per_request_when_expired() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status body line1 line2 baseline

  az_dir="$TMP_ROOT/az-refresh"
  calls="$TMP_ROOT/az-refresh-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-refresh.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }
  baseline=$(cat "$calls")

  status=$(curl -sS -o "$TMP_ROOT/req1-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "first authorized request must be forwarded"

  status=$(curl -sS -o "$TMP_ROOT/req2-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "second authorized request must be forwarded"

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  assert_equals "$((baseline + 2))" "$(cat "$calls")" \
    "an already-expired cached token must be refreshed on every request, never reused"

  line1=$(sed -n '1p' "$upstream_log")
  line2=$(sed -n '2p' "$upstream_log")
  assert_contains "$line1" "Bearer FAKE-TOKEN-$((baseline + 1))" "first forwarded request carries the first fresh token"
  assert_contains "$line2" "Bearer FAKE-TOKEN-$((baseline + 2))" "second forwarded request carries a newly refreshed token, not the first one"
  assert_not_equals "$line1" "$line2" "the proxy must not forward the same stale token twice after it expired"
  pass "fm-foundry-luna-proxy: an expired cached token is refreshed, never reused stale, on every request"
}

test_caches_a_still_valid_token_across_requests() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status

  az_dir="$TMP_ROOT/az-cache"
  calls="$TMP_ROOT/az-cache-calls"
  fm_write_fake_az_fails_after_one "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-cache.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "first authorized request must be forwarded"

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "second authorized request must be forwarded"

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  assert_equals "1" "$(cat "$calls")" \
    "a still-valid cached token must not be refetched on every request"
  pass "fm-foundry-luna-proxy: a still-valid cached token is reused instead of refetched"
}

test_refuses_a_deployment_scoped_route_for_an_unauthorized_deployment() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status route baseline

  az_dir="$TMP_ROOT/az-route"
  calls="$TMP_ROOT/az-route-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-route.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }
  baseline=$(cat "$calls")

  # Foundry names the deployment in the URL as well as the body, so an
  # authorized body model on a deployment-scoped route must still be refused.
  for route in \
    "/openai/deployments/gpt-5.6-terra/chat/completions?api-version=2025-04-01-preview" \
    "/openai/v1/chat/completions" \
    "/openai/v1/models" \
    "/openai/deployments/gpt-5.6-luna/responses"; do
    status=$(curl -sS -o "$TMP_ROOT/route-body" -w '%{http_code}' \
      -X POST "http://127.0.0.1:$proxy_port$route" \
      -H 'Content-Type: application/json' \
      -H "$AUTH_HEADER" \
      -d '{"model":"gpt-5.6-luna","input":[]}')
    if [ "$status" -lt 400 ]; then
      kill "$proxy_pid" "$upstream_pid" 2>/dev/null
      fail "route '$route' was relayed instead of refused: got HTTP $status"
    fi
    assert_contains "$(cat "$TMP_ROOT/route-body")" "is not authorized" \
      "refusal body for route '$route' names the reason"
  done

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  [ ! -s "$upstream_log" ] || fail "an unauthorized route reached the fake upstream: $(cat "$upstream_log")"
  assert_equals "$baseline" "$(cat "$calls")" \
    "an unauthorized route must trigger no token fetch beyond the gateway's startup one"
  pass "fm-foundry-luna-proxy: refuses a deployment-scoped route before any token is fetched"
}

test_streams_a_chunked_reply_through_with_usable_framing() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status headers server_lines

  az_dir="$TMP_ROOT/az-stream"
  calls="$TMP_ROOT/az-stream-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-stream.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  headers="$TMP_ROOT/stream-headers"
  if ! status=$(curl -sS --max-time 8 -D "$headers" -o "$TMP_ROOT/stream-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","stream":true,"input":[]}'); then
    kill "$proxy_pid" "$upstream_pid" 2>/dev/null
    fail "a streamed reply must terminate for the client instead of hanging until the socket times out"
  fi

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  expect_code 200 "$status" "a streamed authorized request must be forwarded"
  assert_contains "$(cat "$TMP_ROOT/stream-body")" 'data: {"seq":2}' \
    "the whole streamed body must reach the client"
  server_lines=$(grep -ci '^server:' "$headers")
  [ "$server_lines" -le 1 ] \
    || fail "the relayed response must not carry a duplicated Server header (got $server_lines)"
  pass "fm-foundry-luna-proxy: a chunked streamed reply is relayed with framing the client can end on"
}

test_refuses_a_non_loopback_upstream_override() {
  local out status

  out=$(FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="foundry-luna.invalid:443" \
    python3 "$PROXY" serve 0 2>&1)
  status=$?

  [ "$status" -ne 0 ] \
    || fail "the proxy must refuse to start rather than attach an AAD token for a non-loopback host"
  assert_contains "$out" "must be 127.0.0.1" "the refusal names the constraint it enforced"
  pass "fm-foundry-luna-proxy: refuses a non-loopback upstream override instead of forwarding a token to it"
}

test_run_mode_is_silent_unless_an_access_log_file_is_named() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local child_script quiet_err loud_err access_log probe

  az_dir="$TMP_ROOT/az-quiet"
  calls="$TMP_ROOT/az-quiet-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-quiet.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  child_script=$(fm_write_relaying_child "$TMP_ROOT/quiet-child.sh")

  probe="$TMP_ROOT/quiet-probe"
  quiet_err="$TMP_ROOT/quiet-stderr"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ "$probe" \
    > "$TMP_ROOT/quiet-stdout" 2>"$quiet_err"
  expect_code 200 "$(cat "$probe")" "the wrapped command's request must still be relayed"
  [ ! -s "$quiet_err" ] \
    || fail "run mode must write nothing to the pane's stderr by default, got: $(cat "$quiet_err")"
  [ ! -s "$TMP_ROOT/quiet-stdout" ] \
    || fail "run mode must write nothing to the pane's stdout by default, got: $(cat "$TMP_ROOT/quiet-stdout")"

  access_log="$TMP_ROOT/quiet-access.log"
  loud_err="$TMP_ROOT/loud-stderr"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    FM_FOUNDRY_LUNA_LOG="$access_log" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ "$probe" \
    > /dev/null 2>"$loud_err"
  expect_code 200 "$(cat "$probe")" "the wrapped command's request must still be relayed with logging on"

  kill "$upstream_pid" 2>/dev/null
  wait "$upstream_pid" 2>/dev/null

  assert_contains "$(cat "$access_log")" 'POST /openai/v1/responses HTTP/1.1" 200' \
    "a named access log must receive the relayed request's status line"
  [ ! -s "$loud_err" ] \
    || fail "a named access log must replace stderr, not add to it, got: $(cat "$loud_err")"

  # The error path (an exception escaping the handler, e.g. an upstream
  # connection failure) must be silenced the same way, not just the ordinary
  # access log: point at a loopback port nothing listens on so conn.request()
  # in _forward raises ConnectionRefusedError before any response is sent.
  local error_quiet_err error_loud_err error_log error_probe
  error_probe="$TMP_ROOT/error-probe"
  error_quiet_err="$TMP_ROOT/error-quiet-stderr"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:1" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ "$error_probe" \
    > "$TMP_ROOT/error-quiet-stdout" 2>"$error_quiet_err"
  [ ! -s "$error_quiet_err" ] \
    || fail "an error escaping the handler must not write to the pane's stderr by default, got: $(cat "$error_quiet_err")"
  [ ! -s "$TMP_ROOT/error-quiet-stdout" ] \
    || fail "an error escaping the handler must not write to the pane's stdout by default, got: $(cat "$TMP_ROOT/error-quiet-stdout")"

  error_log="$TMP_ROOT/error-access.log"
  error_loud_err="$TMP_ROOT/error-loud-stderr"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:1" \
    FM_FOUNDRY_LUNA_LOG="$error_log" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ "$error_probe" \
    > /dev/null 2>"$error_loud_err"
  [ ! -s "$error_loud_err" ] \
    || fail "a named access log must catch an escaping error too, not just leave it on stderr, got: $(cat "$error_loud_err")"
  [ -s "$error_log" ] \
    || fail "a named access log must record the error path when the handler raises, and nothing was written"
  pass "fm-foundry-luna-proxy: run mode is silent on the error path too, unless FM_FOUNDRY_LUNA_LOG names a file"
}

test_run_subcommand_serves_while_the_child_runs_then_stops() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local child_script status port_probe run_status served_port

  az_dir="$TMP_ROOT/az-run"
  calls="$TMP_ROOT/az-run-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-run.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  # A stand-in "codex": it curls the gateway's own port - handed to it by the
  # gateway itself, through the __FOUNDRYLUNAPORT__ placeholder in its argv -
  # to prove the gateway is already listening while the wrapped command runs,
  # then exits with a distinctive status so the test can prove `run` forwards
  # a real child exit code rather than always exiting 0.
  child_script=$(fm_write_relaying_child "$TMP_ROOT/fake-child.sh" 42)

  port_probe="$TMP_ROOT/run-port-probe"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ "$port_probe" "$TMP_ROOT/run-port-seen"
  run_status=$?

  kill "$upstream_pid" 2>/dev/null
  wait "$upstream_pid" 2>/dev/null

  assert_equals "42" "$run_status" "run must exit with the wrapped command's own exit status"
  status=$(cat "$port_probe")
  expect_code 200 "$status" "the wrapped command could reach the gateway while it ran"
  served_port=$(cat "$TMP_ROOT/run-port-seen")
  [ "$served_port" != "__FOUNDRYLUNAPORT__" ] \
    || fail "run must replace __FOUNDRYLUNAPORT__ in the wrapped command's argv with the port it bound"
  assert_contains "$(cat "$upstream_log")" "Bearer FAKE-TOKEN-" "the request the child made was really forwarded with a fetched token"
  ! curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:$served_port/openai/v1/responses" 2>/dev/null \
    || fail "the gateway must stop listening once the wrapped command exits"
  pass "fm-foundry-luna-proxy: 'run' serves the wrapped command on the port it resolves for it, and stops when the command exits"
}

test_run_mints_the_admission_secret_into_its_child_environment_only() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local child_script len_a len_b digest_a digest_b

  az_dir="$TMP_ROOT/az-mint"
  calls="$TMP_ROOT/az-mint-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-mint.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  # Reports its secret's LENGTH and DIGEST, never the value, plus whether that
  # value is visible in its own or the gateway's command line - the /proc
  # exposure any local uid can read when a secret rides a launch command.
  child_script="$TMP_ROOT/mint-child.sh"
  cat > "$child_script" <<'SH'
#!/usr/bin/env bash
set -u
port=$1
printf '%s\n' "${#FM_FOUNDRY_LUNA_SECRET}" > "$3"
printf '%s' "$FM_FOUNDRY_LUNA_SECRET" | sha256sum | cut -d' ' -f1 > "$4"
if ps -ww -o args= -p $$ -p "$PPID" 2>/dev/null | grep -qF -- "$FM_FOUNDRY_LUNA_SECRET"; then
  printf 'leaked\n' > "$5"
else
  printf 'clean\n' > "$5"
fi
curl -s -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$port/openai/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $FM_FOUNDRY_LUNA_SECRET" \
  -d '{"model":"gpt-5.6-luna","input":[]}' 2>/dev/null > "$2"
SH
  chmod +x "$child_script"

  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ \
      "$TMP_ROOT/mint-status-a" "$TMP_ROOT/mint-len-a" "$TMP_ROOT/mint-digest-a" "$TMP_ROOT/mint-argv-a" \
    > "$TMP_ROOT/mint-stdout" 2>"$TMP_ROOT/mint-stderr"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ \
      "$TMP_ROOT/mint-status-b" "$TMP_ROOT/mint-len-b" "$TMP_ROOT/mint-digest-b" "$TMP_ROOT/mint-argv-b" \
    > /dev/null 2>>"$TMP_ROOT/mint-stderr"

  kill "$upstream_pid" 2>/dev/null
  wait "$upstream_pid" 2>/dev/null

  expect_code 200 "$(cat "$TMP_ROOT/mint-status-a")" \
    "the child must be admitted by the secret the gateway put in its environment"
  assert_equals "clean" "$(cat "$TMP_ROOT/mint-argv-a")" \
    "the admission secret must never appear in the child's or the gateway's command line"
  assert_equals "clean" "$(cat "$TMP_ROOT/mint-argv-b")" \
    "the admission secret must never appear in the child's or the gateway's command line"
  len_a=$(cat "$TMP_ROOT/mint-len-a")
  len_b=$(cat "$TMP_ROOT/mint-len-b")
  assert_equals "64" "$len_a" "the gateway must mint a full-length secret, not inherit a placeholder"
  assert_equals "64" "$len_b" "the gateway must mint a full-length secret, not inherit a placeholder"
  digest_a=$(cat "$TMP_ROOT/mint-digest-a")
  digest_b=$(cat "$TMP_ROOT/mint-digest-b")
  assert_not_equals "$digest_a" "$digest_b" \
    "each launch must mint its own admission secret, never reuse one across launches"
  [ ! -s "$TMP_ROOT/mint-stderr" ] && [ ! -s "$TMP_ROOT/mint-stdout" ] \
    || fail "minting must stay silent on the pane's stdio: $(cat "$TMP_ROOT/mint-stderr" "$TMP_ROOT/mint-stdout")"
  pass "fm-foundry-luna-proxy: 'run' mints its own admission secret and hands it only to its child's environment"
}

test_run_reports_a_wrapped_command_it_cannot_start_without_a_traceback() {
  local az_dir calls status log

  az_dir="$TMP_ROOT/az-nochild"
  calls="$TMP_ROOT/az-nochild-calls"
  fm_write_fake_az "$az_dir" "$calls"

  PATH="$az_dir:$PATH" \
    python3 "$PROXY" run -- "$TMP_ROOT/no-such-command-here" \
    > "$TMP_ROOT/nochild-stdout" 2>"$TMP_ROOT/nochild-stderr"
  status=$?

  [ "$status" -ne 0 ] || fail "run must not report success when the wrapped command never started"
  [ ! -s "$TMP_ROOT/nochild-stderr" ] \
    || fail "an unstartable wrapped command must not print a traceback to the pane, got: $(cat "$TMP_ROOT/nochild-stderr")"
  [ ! -s "$TMP_ROOT/nochild-stdout" ] \
    || fail "an unstartable wrapped command must not print to the pane's stdout, got: $(cat "$TMP_ROOT/nochild-stdout")"

  log="$TMP_ROOT/nochild-access.log"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_LOG="$log" \
    python3 "$PROXY" run -- "$TMP_ROOT/no-such-command-here" \
    > /dev/null 2>"$TMP_ROOT/nochild-loud-stderr"
  [ ! -s "$TMP_ROOT/nochild-loud-stderr" ] \
    || fail "a named access log must catch the unstartable command too, got: $(cat "$TMP_ROOT/nochild-loud-stderr")"
  [ -s "$log" ] \
    || fail "a named access log must record that the wrapped command could not be started"
  pass "fm-foundry-luna-proxy: a wrapped command that cannot start is reported, never as a pane traceback"
}

test_two_live_gateways_never_share_a_port() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local child_script a_status b_status port_a port_b

  az_dir="$TMP_ROOT/az-ports"
  calls="$TMP_ROOT/az-ports-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-ports.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  # Each child publishes its gateway's port, then waits for the OTHER child to
  # publish before relaying, so both gateways are provably listening at once -
  # the window in which a port handed out before it was bound could collide.
  child_script="$TMP_ROOT/rendezvous-child.sh"
  cat > "$child_script" <<'SH'
#!/usr/bin/env bash
set -u
port=$1
printf '%s\n' "$port" > "$3"
for _ in $(seq 1 100); do
  [ -s "$4" ] && break
  sleep 0.1
done
curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$port/openai/v1/responses" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $FM_FOUNDRY_LUNA_SECRET" \
  -d '{"model":"gpt-5.6-luna","input":[]}' > "$2"
SH
  chmod +x "$child_script"

  rm -f "$TMP_ROOT/port-a" "$TMP_ROOT/port-b"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ \
      "$TMP_ROOT/status-a" "$TMP_ROOT/port-a" "$TMP_ROOT/port-b" \
    > /dev/null 2>"$TMP_ROOT/ports-a-stderr" &
  local a_pid=$!
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ \
      "$TMP_ROOT/status-b" "$TMP_ROOT/port-b" "$TMP_ROOT/port-a" \
    > /dev/null 2>"$TMP_ROOT/ports-b-stderr" &
  local b_pid=$!
  wait "$a_pid"
  wait "$b_pid"

  kill "$upstream_pid" 2>/dev/null
  wait "$upstream_pid" 2>/dev/null

  port_a=$(cat "$TMP_ROOT/port-a" 2>/dev/null)
  port_b=$(cat "$TMP_ROOT/port-b" 2>/dev/null)
  a_status=$(cat "$TMP_ROOT/status-a" 2>/dev/null)
  b_status=$(cat "$TMP_ROOT/status-b" 2>/dev/null)

  [ -n "$port_a" ] && [ -n "$port_b" ] \
    || fail "both gateways must hand their wrapped command a port (got '$port_a' and '$port_b')"
  assert_not_equals "$port_a" "$port_b" \
    "two gateways listening at the same time must never be handed the same port"
  expect_code 200 "$a_status" "the first of two concurrent gateways must relay its request"
  expect_code 200 "$b_status" "the second of two concurrent gateways must relay its request"
  [ ! -s "$TMP_ROOT/ports-a-stderr" ] && [ ! -s "$TMP_ROOT/ports-b-stderr" ] \
    || fail "a second concurrent gateway must not print a bind failure to the pane: $(cat "$TMP_ROOT/ports-a-stderr" "$TMP_ROOT/ports-b-stderr")"
  pass "fm-foundry-luna-proxy: two gateways alive at once each serve the port they bound themselves"
}

test_refuses_a_caller_without_this_tasks_secret() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status baseline

  az_dir="$TMP_ROOT/az-secret"
  calls="$TMP_ROOT/az-secret-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-secret.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }
  baseline=$(cat "$calls")

  status=$(curl -sS -o "$TMP_ROOT/secret-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  expect_code 401 "$status" "a local caller with no Authorization header must be refused"

  status=$(curl -sS -o "$TMP_ROOT/secret-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer not-this-tasks-secret" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  expect_code 401 "$status" "a local caller offering the wrong secret must be refused"
  assert_not_contains "$(cat "$TMP_ROOT/secret-body")" "not-this-tasks-secret" \
    "the refusal must never echo the value it was offered"

  [ ! -s "$upstream_log" ] || fail "an unauthenticated caller reached the fake upstream: $(cat "$upstream_log")"
  assert_equals "$baseline" "$(cat "$calls")" \
    "an unauthenticated caller must trigger no token fetch beyond the gateway's startup one"

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  expect_code 200 "$status" "the caller holding this task's secret must still be relayed"

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  assert_contains "$(cat "$upstream_log")" "Bearer FAKE-TOKEN-" \
    "the relayed request carries the gateway's own fetched token, not the caller's secret"
  assert_not_contains "$(cat "$upstream_log")" "$GATEWAY_SECRET" \
    "the caller's gateway secret must never be forwarded upstream"
  pass "fm-foundry-luna-proxy: refuses a local caller that does not hold this task's gateway secret"
}

test_refuses_to_serve_when_the_first_token_fetch_fails() {
  local az_dir calls child_script ran out status log

  # az on PATH but unusable, the aged-out-login shape: without a token taken at
  # startup this becomes a live pane that answers 502 on every turn instead of a
  # launch that fails, which supervision reads as a wedged worker.
  az_dir="$TMP_ROOT/az-broken"
  calls="$TMP_ROOT/az-broken-calls"
  mkdir -p "$az_dir"
  : > "$calls"
  cat > "$az_dir/az" <<SH
#!/usr/bin/env bash
echo "\$(( \$(cat "$calls") + 1 ))" > "$calls"
echo "fake az: please run 'az login' to setup account" >&2
exit 1
SH
  chmod +x "$az_dir/az"

  ran="$TMP_ROOT/broken-child-ran"
  rm -f "$ran"
  child_script="$TMP_ROOT/broken-child.sh"
  cat > "$child_script" <<'SH'
#!/usr/bin/env bash
touch "$1"
SH
  chmod +x "$child_script"

  PATH="$az_dir:$PATH" \
    python3 "$PROXY" run -- "$child_script" "$ran" \
    > "$TMP_ROOT/broken-stdout" 2>"$TMP_ROOT/broken-stderr"
  status=$?

  [ "$status" -ne 0 ] \
    || fail "the gateway must exit non-zero when it cannot obtain a token, instead of serving"
  [ ! -e "$ran" ] \
    || fail "the wrapped command must never start when the gateway could not obtain a token"
  assert_contains "$(cat "$TMP_ROOT/broken-stderr")" "az could not produce a token" \
    "a failed startup token fetch must name az as the failing stage"
  assert_contains "$(cat "$TMP_ROOT/broken-stderr")" "please run 'az login'" \
    "a failed startup token fetch must surface az's own stderr, not swallow it"
  assert_not_contains "$(cat "$TMP_ROOT/broken-stderr")" "Traceback" \
    "a failed startup token fetch must not print a raw traceback"
  assert_not_contains "$(cat "$TMP_ROOT/broken-stderr")" "invalid subscription key" \
    "an az failure must not be described as a subscription-key failure"
  [ ! -s "$TMP_ROOT/broken-stdout" ] \
    || fail "a failed startup token fetch must not write to the pane's stdout, got: $(cat "$TMP_ROOT/broken-stdout")"
  assert_equals "1" "$(cat "$calls")" \
    "the gateway must take exactly one token at launch, not one per turn"

  log="$TMP_ROOT/broken-access.log"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_LOG="$log" \
    python3 "$PROXY" run -- "$child_script" "$ran" \
    > /dev/null 2>"$TMP_ROOT/broken-loud-stderr"
  status=$?
  [ "$status" -ne 0 ] || fail "a named access log must not turn a failed startup fetch into a success"
  assert_contains "$(cat "$TMP_ROOT/broken-loud-stderr")" "az could not produce a token" \
    "startup still names az on stderr when a log file is also named, because the wrapped command never starts"
  assert_contains "$(cat "$log")" "az could not produce a token" \
    "a named access log must record the classified az failure"

  out=$(PATH="$az_dir:$PATH" FM_FOUNDRY_LUNA_TEST_SECRET="$GATEWAY_SECRET" \
    timeout 10 python3 "$PROXY" serve 0 2>"$TMP_ROOT/broken-serve-stderr")
  status=$?
  [ "$status" -ne 0 ] || fail "serve must exit non-zero rather than listen without a usable credential"
  [ -z "$out" ] \
    || fail "serve must never announce a port it cannot serve requests on, got: $out"
  pass "fm-foundry-luna-proxy: refuses to serve at all when the first token fetch fails"
}

test_refuses_to_serve_without_a_gateway_secret() {
  local out status

  # Bounded: a gateway that wrongly starts would otherwise block here forever
  # instead of failing, and a guard that can only hang is not a guard.
  out=$(env -u FM_FOUNDRY_LUNA_TEST_SECRET timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?

  [ "$status" -ne 0 ] \
    || fail "the proxy must refuse to start rather than broker an AAD token with no caller check at all"
  assert_contains "$out" "FM_FOUNDRY_LUNA_TEST_SECRET" "the refusal names the missing secret"
  pass "fm-foundry-luna-proxy: refuses to start without this task's gateway secret"
}

test_refuses_to_start_when_the_foundry_config_is_missing_or_invalid() {
  local out status bad_dir host

  out=$(env -u FM_FOUNDRY_LUNA_CONFIG timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the proxy must refuse to start with no Foundry config path set"
  assert_contains "$out" "FM_FOUNDRY_LUNA_CONFIG" "the refusal names the missing config variable"

  out=$(FM_FOUNDRY_LUNA_CONFIG="$TMP_ROOT/does-not-exist.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the proxy must refuse to start when the named config file is missing"
  assert_contains "$out" "missing or unreadable" "the refusal names the missing config file"

  bad_dir="$TMP_ROOT/bad-foundry-config"
  mkdir -p "$bad_dir"

  printf 'not json at all' > "$bad_dir/malformed.json"
  out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/malformed.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the proxy must refuse to start when the config file is not valid JSON"
  assert_contains "$out" "not valid JSON" "the refusal names the malformed JSON"

  printf '{"subscription_id":"00000000-0000-0000-0000-000000000000"}' > "$bad_dir/no-host.json"
  out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/no-host.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the proxy must refuse to start when the config file has no 'host'"
  assert_contains "$out" "'host'" "the refusal names the missing host field"

  printf '{"host":"fixture-account.services.ai.azure.com"}' > "$bad_dir/no-subscription.json"
  out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/no-subscription.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the proxy must refuse to start when the config file has no 'subscription_id'"
  assert_contains "$out" "'subscription_id'" "the refusal names the missing subscription id field"

  for host in \
    "evil.example.com" \
    "fixture-account.services.ai.azure.com.evil.example.com" \
    ".services.ai.azure.com" \
    "evil.example/.services.ai.azure.com" \
    "a.b.services.ai.azure.com" \
    "fixture-account.services.ai.azure.com:443" \
    "<foundry-account>.services.ai.azure.com"; do
    printf '{"host":"%s","subscription_id":"00000000-0000-0000-0000-000000000000"}' "$host" \
      > "$bad_dir/non-azure-host.json"
    out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/non-azure-host.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
    status=$?
    [ "$status" -ne 0 ] \
      || fail "the proxy must refuse a non-Azure-Foundry host '$host' instead of attaching an AAD token for it"
    assert_contains "$out" "'host'" "the refusal for host '$host' names the invalid field"
  done

  # Python's $ in a regex matches just before a trailing newline even under
  # .match, so a value carrying one must be checked with a real end-anchored
  # match (fullmatch), not just a leading-anchored one.
  printf '{"host":"fixture-account.services.ai.azure.com\\n","subscription_id":"00000000-0000-0000-0000-000000000000"}' \
    > "$bad_dir/trailing-newline-host.json"
  out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/trailing-newline-host.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "the proxy must refuse a host carrying a trailing newline instead of accepting it as the bare hostname"
  assert_contains "$out" "'host'" "the refusal for a trailing-newline host names the invalid field"

  for subscription in "not-a-guid" "00000000-0000-0000-0000-00000000000" "00000000-0000-0000-0000-0000000000gg"; do
    printf '{"host":"fixture-account.services.ai.azure.com","subscription_id":"%s"}' "$subscription" \
      > "$bad_dir/non-guid-subscription.json"
    out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/non-guid-subscription.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
    status=$?
    [ "$status" -ne 0 ] \
      || fail "the proxy must refuse a non-GUID subscription_id '$subscription'"
    assert_contains "$out" "'subscription_id'" "the refusal for subscription_id '$subscription' names the invalid field"
  done

  printf '{"host":"fixture-account.services.ai.azure.com","subscription_id":"00000000-0000-0000-0000-000000000000\\n"}' \
    > "$bad_dir/trailing-newline-subscription.json"
  out=$(FM_FOUNDRY_LUNA_CONFIG="$bad_dir/trailing-newline-subscription.json" timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?
  [ "$status" -ne 0 ] \
    || fail "the proxy must refuse a subscription_id carrying a trailing newline instead of accepting it as the bare GUID"
  assert_contains "$out" "'subscription_id'" "the refusal for a trailing-newline subscription_id names the invalid field"

  pass "fm-foundry-luna-proxy: refuses to start when the Foundry config is missing, malformed, names a non-Azure host, or names a non-GUID subscription id"
}

test_refuses_to_serve_when_the_token_expiry_is_unreadable() {
  local scenario az_dir body out_file err_file status log loud_err

  for scenario in missing non-numeric past; do
    az_dir="$TMP_ROOT/az-unreadable-expiry-$scenario"
    mkdir -p "$az_dir"
    case "$scenario" in
      missing) body='{"accessToken":"FAKE-TOKEN-NO-EXPIRY"}' ;;
      non-numeric) body='{"accessToken":"FAKE-TOKEN-NULL-EXPIRY","expires_on":null}' ;;
      # A real, parseable, already-elapsed epoch - what az would report for a
      # token that is dead on arrival. This must never be cached or forwarded
      # either: the earlier fm_write_fake_az fixture used exactly this shape
      # (expires_on=1) purely as a "force the next refresh" trick, which is
      # why that fixture now mints a near-future expiry instead.
      past) body='{"accessToken":"FAKE-TOKEN-PAST-EXPIRY","expires_on":1}' ;;
    esac
    cat > "$az_dir/az" <<SH
#!/usr/bin/env bash
printf '%s\n' '$body'
SH
    chmod +x "$az_dir/az"

    out_file="$TMP_ROOT/expiry-$scenario-stdout"
    err_file="$TMP_ROOT/expiry-$scenario-stderr"
    PATH="$az_dir:$PATH" FM_FOUNDRY_LUNA_TEST_SECRET="$GATEWAY_SECRET" \
      timeout 5 python3 "$PROXY" serve 0 > "$out_file" 2>"$err_file"
    status=$?

    [ "$status" -ne 0 ] \
      || fail "the proxy must refuse to serve when az reports an expires_on that is $scenario"
    [ ! -s "$out_file" ] \
      || fail "an unreadable expires_on ($scenario) must not print to the pane's stdout, got: $(cat "$out_file")"
    assert_contains "$(cat "$err_file")" "az could not produce a token" \
      "an unreadable expires_on ($scenario) must name az as the failing stage"
    assert_not_contains "$(cat "$err_file")" "Traceback" \
      "an unreadable expires_on ($scenario) must not print a raw traceback to the pane's stderr"

    log="$TMP_ROOT/expiry-$scenario-access.log"
    loud_err="$TMP_ROOT/expiry-$scenario-loud-stderr"
    PATH="$az_dir:$PATH" FM_FOUNDRY_LUNA_TEST_SECRET="$GATEWAY_SECRET" FM_FOUNDRY_LUNA_LOG="$log" \
      timeout 5 python3 "$PROXY" serve 0 > /dev/null 2>"$loud_err"
    assert_contains "$(cat "$loud_err")" "az could not produce a token" \
      "an unreadable expiry ($scenario) still names az on stderr when a log file is also named"
    assert_contains "$(cat "$log")" "az could not produce a token" \
      "a named access log must record the classified az failure for an unreadable expiry ($scenario)"
    assert_not_contains "$(cat "$log")" "FAKE-TOKEN" \
      "the refusal log for an unreadable expiry ($scenario) must never record the token value"
  done
  pass "fm-foundry-luna-proxy: refuses to serve when az reports a token with an unreadable expires_on, never crashing with a raw traceback"
}

test_az_failure_on_refresh_names_az_and_surfaces_stderr() {
  local az_dir calls upstream_info upstream_pid upstream_port
  local proxy_info proxy_pid proxy_port status body

  az_dir="$TMP_ROOT/az-refresh-fail"
  calls="$TMP_ROOT/az-refresh-fail-calls"
  mkdir -p "$az_dir"
  : > "$calls"
  # First call (startup) succeeds with a near-future expiry so the next
  # request must refresh; the second call fails with distinctive stderr.
  cat > "$az_dir/az" <<SH
#!/usr/bin/env bash
set -u
n=\$(( \$(cat "$calls") + 1 ))
echo "\$n" > "$calls"
if [ "\$n" -gt 1 ]; then
  echo "AADSTS700082: The refresh token has expired due to inactivity." >&2
  echo "Please run 'az login' to setup account." >&2
  exit 1
fi
printf '{"accessToken":"FAKE-TOKEN-FIRST","expires_on":%s}\n' "\$(( \$(date +%s) + 30 ))"
SH
  chmod +x "$az_dir/az"

  printf '{"ok":true}\n' > "$TMP_ROOT/upstream-ok-body"
  upstream_info=$(fm_start_fake_upstream_reply 200 "$TMP_ROOT/upstream-ok-body")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o "$TMP_ROOT/az-refresh-fail-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  body=$(cat "$TMP_ROOT/az-refresh-fail-body")

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  expect_code 502 "$status" "az failing to mint a token on refresh must be HTTP 502, not a Foundry 401"
  assert_contains "$body" '"stage": "az-token"' "the body names the az-token stage"
  assert_contains "$body" "az could not produce a token" "the body names az as the failing stage"
  assert_contains "$body" "AADSTS700082" "the body surfaces az's own stderr rather than swallowing it"
  assert_not_contains "$body" "invalid subscription key" \
    "an az failure must not be described as a subscription-key failure"
  assert_not_contains "$body" "FAKE-TOKEN" "the body must never include the token value"
  assert_equals "2" "$(cat "$calls")" \
    "a single az failure must not be retried; startup plus one refresh is exactly two calls"
  pass "fm-foundry-luna-proxy: an az refresh failure names az, surfaces stderr, and is not retried"
}

test_foundry_401_is_classified_as_token_rejection_not_subscription_key() {
  local az_dir calls upstream_info upstream_pid upstream_port
  local proxy_info proxy_pid proxy_port status body

  az_dir="$TMP_ROOT/az-reject"
  calls="$TMP_ROOT/az-reject-calls"
  fm_write_fake_az "$az_dir" "$calls"

  printf '%s\n' '{"error":{"code":"401","message":"Access denied due to invalid subscription key or wrong API endpoint. Make sure to provide a valid key for an active subscription and use a correct regional API endpoint for your resource."}}' \
    > "$TMP_ROOT/upstream-401-body"
  upstream_info=$(fm_start_fake_upstream_reply 401 "$TMP_ROOT/upstream-401-body")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o "$TMP_ROOT/foundry-401-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  body=$(cat "$TMP_ROOT/foundry-401-body")

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  expect_code 401 "$status" "Foundry rejecting the az token keeps HTTP 401"
  assert_contains "$body" '"stage": "foundry-rejected-token"' "the body names the token-rejection stage"
  assert_contains "$body" "az produced a token and Foundry rejected it" \
    "the body says az produced a token and Foundry rejected it"
  assert_not_contains "$body" "invalid subscription key" \
    "Foundry's subscription-key sentence must not be the diagnosis on this AAD route"
  assert_not_contains "$body" "token refresh failed" \
    "a Foundry 401 after a successful az fetch is not a token-refresh failure"
  pass "fm-foundry-luna-proxy: Foundry 401 after an az token is classified as token rejection, not a subscription key"
}

test_foundry_404_is_classified_as_wrong_deployment_or_host() {
  local az_dir calls upstream_info upstream_pid upstream_port
  local proxy_info proxy_pid proxy_port status body

  az_dir="$TMP_ROOT/az-404"
  calls="$TMP_ROOT/az-404-calls"
  fm_write_fake_az "$az_dir" "$calls"

  printf '%s\n' '{"error":{"type":"invalid_request_error","code":"DeploymentNotFound","message":"The API deployment for this resource does not exist."}}' \
    > "$TMP_ROOT/upstream-404-body"
  upstream_info=$(fm_start_fake_upstream_reply 404 "$TMP_ROOT/upstream-404-body")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o "$TMP_ROOT/foundry-404-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  body=$(cat "$TMP_ROOT/foundry-404-body")

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  expect_code 404 "$status" "a missing deployment keeps HTTP 404"
  assert_contains "$body" '"stage": "deployment-or-host"' "the body names the deployment-or-host stage"
  assert_contains "$body" "the Foundry deployment or host is wrong" \
    "the body says the deployment or host is wrong"
  assert_contains "$body" "DeploymentNotFound" "the body still carries Foundry's deployment-not-found detail"
  assert_not_contains "$body" "invalid subscription key" \
    "a missing deployment must not be described as a subscription-key failure"
  pass "fm-foundry-luna-proxy: Foundry 404 is classified as a wrong deployment or host"
}

test_unreachable_host_is_classified_as_wrong_deployment_or_host() {
  local az_dir calls proxy_info proxy_pid proxy_port status body

  az_dir="$TMP_ROOT/az-unreach"
  calls="$TMP_ROOT/az-unreach-calls"
  fm_write_fake_az "$az_dir" "$calls"

  # Port 1 on loopback refuses connections: the configured host cannot be reached.
  proxy_info=$(fm_start_proxy "$az_dir" 1)
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o "$TMP_ROOT/unreach-body" -w '%{http_code}' --max-time 5 \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  body=$(cat "$TMP_ROOT/unreach-body")

  kill "$proxy_pid" 2>/dev/null
  wait "$proxy_pid" 2>/dev/null

  expect_code 502 "$status" "an unreachable host must be an HTTP error, not an empty reply"
  assert_contains "$body" '"stage": "deployment-or-host"' "the body names the deployment-or-host stage"
  assert_contains "$body" "the Foundry deployment or host is wrong" \
    "the body says the deployment or host is wrong"
  assert_not_contains "$body" "token refresh failed" \
    "an unreachable host is not a token-refresh failure"
  pass "fm-foundry-luna-proxy: an unreachable Foundry host is classified as a wrong deployment or host"
}

test_unknown_upstream_5xx_is_explicitly_unknown() {
  local az_dir calls upstream_info upstream_pid upstream_port
  local proxy_info proxy_pid proxy_port status body

  az_dir="$TMP_ROOT/az-500"
  calls="$TMP_ROOT/az-500-calls"
  fm_write_fake_az "$az_dir" "$calls"

  printf '%s\n' '{"error":{"message":"internal server error"}}' > "$TMP_ROOT/upstream-500-body"
  upstream_info=$(fm_start_fake_upstream_reply 500 "$TMP_ROOT/upstream-500-body")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  proxy_info=$(fm_start_proxy "$az_dir" "$upstream_port")
  proxy_pid=${proxy_info%% *}
  proxy_port=${proxy_info##* }

  status=$(curl -sS -o "$TMP_ROOT/foundry-500-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -H "$AUTH_HEADER" \
    -d '{"model":"gpt-5.6-luna","input":[]}')
  body=$(cat "$TMP_ROOT/foundry-500-body")

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  expect_code 500 "$status" "an unclassified Foundry 500 keeps HTTP 500"
  assert_contains "$body" '"stage": "unknown"' "the body names the unknown stage"
  assert_contains "$body" "unknown reason" "the body says the failure is unknown"
  assert_not_contains "$body" "az could not produce a token" \
    "an unknown 500 must not be blamed on az"
  assert_not_contains "$body" "invalid subscription key" \
    "an unknown 500 must not be described as a subscription-key failure"
  pass "fm-foundry-luna-proxy: an unclassified Foundry 500 is an explicit unknown, not one of the three stages"
}

test_classify_api_key_401_is_not_a_token_refresh_failure() {
  local body_file out

  body_file="$TMP_ROOT/classify-apikey-401.json"
  printf '%s\n' '{"error":{"code":"401","message":"Access denied due to invalid subscription key or wrong API endpoint. Make sure to provide a valid key for an active subscription and use a correct regional API endpoint for your resource."}}' \
    > "$body_file"

  out=$(python3 "$PROXY" classify --credential api-key --status 401 --body "$body_file")
  assert_contains "$out" '"stage": "api-key"' "a key 401 names the api-key stage"
  assert_contains "$out" "Foundry rejected the API key" "a key 401 says Foundry rejected the API key"
  assert_contains "$out" "not an az token-refresh failure" \
    "a key 401 says this is not an az token-refresh failure"
  assert_contains "$out" "models.json" "a key 401 names Pi's provider config as the credential source"
  assert_not_contains "$out" "invalid subscription key" \
    "the classified key 401 must not repeat Foundry's subscription-key sentence as the diagnosis"

  out=$(python3 "$PROXY" classify --credential az-token --status 401 --body "$body_file")
  assert_contains "$out" '"stage": "foundry-rejected-token"' \
    "the same Foundry 401 with an az token is token rejection, not a key failure"
  assert_contains "$out" "az produced a token and Foundry rejected it" \
    "the az-token classification of that 401 names the az token stage"

  printf 'AADSTS700082: The refresh token has expired due to inactivity.\n' > "$TMP_ROOT/classify-az-stderr"
  out=$(python3 "$PROXY" classify --az-stderr "$TMP_ROOT/classify-az-stderr")
  assert_contains "$out" '"stage": "az-token"' "classify --az-stderr names the az-token stage"
  assert_contains "$out" "AADSTS700082" "classify --az-stderr keeps az's own words"

  out=$(python3 "$PROXY" classify --connect-error "Connection refused")
  assert_contains "$out" '"stage": "deployment-or-host"' "classify --connect-error names deployment-or-host"
  assert_contains "$out" "the Foundry deployment or host is wrong" \
    "classify --connect-error says the host is wrong"
  pass "fm-foundry-luna-proxy: classify reprints a key 401 as a key rejection, never as a token refresh"
}

test_refuses_every_unauthorized_deployment_name
test_refresh_path_obtains_a_new_token_per_request_when_expired
test_caches_a_still_valid_token_across_requests
test_refuses_a_deployment_scoped_route_for_an_unauthorized_deployment
test_streams_a_chunked_reply_through_with_usable_framing
test_refuses_a_non_loopback_upstream_override
test_run_mode_is_silent_unless_an_access_log_file_is_named
test_run_subcommand_serves_while_the_child_runs_then_stops
test_two_live_gateways_never_share_a_port
test_run_mints_the_admission_secret_into_its_child_environment_only
test_run_reports_a_wrapped_command_it_cannot_start_without_a_traceback
test_refuses_a_caller_without_this_tasks_secret
test_refuses_to_serve_without_a_gateway_secret
test_refuses_to_serve_when_the_first_token_fetch_fails
test_refuses_to_start_when_the_foundry_config_is_missing_or_invalid
test_refuses_to_serve_when_the_token_expiry_is_unreadable
test_az_failure_on_refresh_names_az_and_surfaces_stderr
test_foundry_401_is_classified_as_token_rejection_not_subscription_key
test_foundry_404_is_classified_as_wrong_deployment_or_host
test_unreachable_host_is_classified_as_wrong_deployment_or_host
test_unknown_upstream_5xx_is_explicitly_unknown
test_classify_api_key_401_is_not_a_token_refresh_failure
