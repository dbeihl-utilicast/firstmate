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

# The per-task secret the gateway admits, standing in for the value
# bin/fm-spawn.sh mints per spawn. A nonsecret fixture string that resembles no
# real credential.
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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

# fm_write_fake_az <dir> <calls-file>
# Mints "FAKE-TOKEN-<n>" on the n'th invocation and always reports it as
# already expired, so callers always take the refresh path with no need to
# fake wall-clock time. Never touches a real credential.
fm_write_fake_az() {
  local dir=$1 calls_file=$2
  mkdir -p "$dir"
  : > "$calls_file"
  cat > "$dir/az" <<SH
#!/usr/bin/env bash
set -u
n=\$(( \$(cat "$calls_file") + 1 ))
echo "\$n" > "$calls_file"
printf '{"accessToken":"FAKE-TOKEN-%s","expires_on":1}\n' "\$n"
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
    python3 "$PROXY" run -- "$child_script" __FOUNDRYLUNAPORT__ \
      "$TMP_ROOT/status-a" "$TMP_ROOT/port-a" "$TMP_ROOT/port-b" \
    > /dev/null 2>"$TMP_ROOT/ports-a-stderr" &
  local a_pid=$!
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
  printf '#!/usr/bin/env bash\ntouch "$1"\n' > "$child_script"
  chmod +x "$child_script"

  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
    python3 "$PROXY" run -- "$child_script" "$ran" \
    > "$TMP_ROOT/broken-stdout" 2>"$TMP_ROOT/broken-stderr"
  status=$?

  [ "$status" -ne 0 ] \
    || fail "the gateway must exit non-zero when it cannot obtain a token, instead of serving"
  [ ! -e "$ran" ] \
    || fail "the wrapped command must never start when the gateway could not obtain a token"
  [ ! -s "$TMP_ROOT/broken-stderr" ] \
    || fail "a failed startup token fetch must not write to the pane's stderr, got: $(cat "$TMP_ROOT/broken-stderr")"
  [ ! -s "$TMP_ROOT/broken-stdout" ] \
    || fail "a failed startup token fetch must not write to the pane's stdout, got: $(cat "$TMP_ROOT/broken-stdout")"
  assert_equals "1" "$(cat "$calls")" \
    "the gateway must take exactly one token at launch, not one per turn"

  log="$TMP_ROOT/broken-access.log"
  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
    FM_FOUNDRY_LUNA_LOG="$log" \
    python3 "$PROXY" run -- "$child_script" "$ran" \
    > /dev/null 2>"$TMP_ROOT/broken-loud-stderr"
  status=$?
  [ "$status" -ne 0 ] || fail "a named access log must not turn a failed startup fetch into a success"
  [ ! -s "$TMP_ROOT/broken-loud-stderr" ] \
    || fail "a named access log must replace stderr on the startup path too, got: $(cat "$TMP_ROOT/broken-loud-stderr")"
  [ -s "$log" ] \
    || fail "a named access log must record why the gateway refused to serve, and nothing was written"

  out=$(PATH="$az_dir:$PATH" FM_FOUNDRY_LUNA_SECRET="$GATEWAY_SECRET" \
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
  out=$(env -u FM_FOUNDRY_LUNA_SECRET timeout 5 python3 "$PROXY" serve 0 2>&1)
  status=$?

  [ "$status" -ne 0 ] \
    || fail "the proxy must refuse to start rather than broker an AAD token with no caller check at all"
  assert_contains "$out" "FM_FOUNDRY_LUNA_SECRET" "the refusal names the missing secret"
  pass "fm-foundry-luna-proxy: refuses to start without this task's gateway secret"
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
test_refuses_a_caller_without_this_tasks_secret
test_refuses_to_serve_without_a_gateway_secret
test_refuses_to_serve_when_the_first_token_fetch_fails
