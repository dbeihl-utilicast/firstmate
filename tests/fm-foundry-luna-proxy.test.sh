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

test_refuses_every_unauthorized_deployment_name() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port name status body

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

  for name in gpt-5.6-terra gpt-5.6-sol claude-sonnet-5 claude-opus-5; do
    body=$(curl -sS -o "$TMP_ROOT/refuse-body" -w '%{http_code}' \
      -X POST "http://127.0.0.1:$proxy_port/openai/v1/chat/completions" \
      -H 'Content-Type: application/json' \
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
  [ ! -s "$calls" ] || fail "an unauthorized deployment name triggered a token fetch"
  pass "fm-foundry-luna-proxy: refuses every unauthorized deployment name before reaching Azure"
}

test_refresh_path_obtains_a_new_token_per_request_when_expired() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local proxy_info proxy_pid proxy_port status body line1 line2

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

  status=$(curl -sS -o "$TMP_ROOT/req1-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "first authorized request must be forwarded"

  status=$(curl -sS -o "$TMP_ROOT/req2-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "second authorized request must be forwarded"

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  assert_equals "2" "$(cat "$calls")" \
    "an already-expired cached token must be refreshed on every request, never reused"

  line1=$(sed -n '1p' "$upstream_log")
  line2=$(sed -n '2p' "$upstream_log")
  assert_contains "$line1" "Bearer FAKE-TOKEN-1" "first forwarded request carries the first fresh token"
  assert_contains "$line2" "Bearer FAKE-TOKEN-2" "second forwarded request carries a newly refreshed token, not the first one"
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
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "first authorized request must be forwarded"

  status=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","messages":[]}')
  expect_code 200 "$status" "second authorized request must be forwarded"

  kill "$proxy_pid" "$upstream_pid" 2>/dev/null
  wait "$proxy_pid" "$upstream_pid" 2>/dev/null

  assert_equals "1" "$(cat "$calls")" \
    "a still-valid cached token must not be refetched on every request"
  pass "fm-foundry-luna-proxy: a still-valid cached token is reused instead of refetched"
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
  status=$(curl -sS --max-time 8 -D "$headers" -o "$TMP_ROOT/stream-body" -w '%{http_code}' \
    -X POST "http://127.0.0.1:$proxy_port/openai/v1/responses" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-5.6-luna","stream":true,"input":[]}')
  if [ $? -ne 0 ]; then
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
  assert_contains "$out" "loopback address" "the refusal names the constraint it enforced"
  pass "fm-foundry-luna-proxy: refuses a non-loopback upstream override instead of forwarding a token to it"
}

test_run_subcommand_serves_while_the_child_runs_then_stops() {
  local az_dir calls upstream_info upstream_pid upstream_port upstream_log
  local child_script status port_probe run_status

  az_dir="$TMP_ROOT/az-run"
  calls="$TMP_ROOT/az-run-calls"
  fm_write_fake_az "$az_dir" "$calls"

  upstream_log="$TMP_ROOT/upstream-run.log"
  : > "$upstream_log"
  upstream_info=$(fm_start_fake_upstream "$upstream_log")
  upstream_pid=${upstream_info%% *}
  upstream_port=${upstream_info##* }

  # A stand-in "codex": it curls the gateway's own port (passed to it as $1)
  # to prove the gateway is already listening while the wrapped command runs,
  # then exits with a distinctive status so the test can prove `run` forwards
  # a real child exit code rather than always exiting 0.
  child_script="$TMP_ROOT/fake-child.sh"
  cat > "$child_script" <<'SH'
#!/usr/bin/env bash
set -u
port=$1
curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$port/openai/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.6-luna","messages":[]}' > "$2"
exit 42
SH
  chmod +x "$child_script"

  port_probe="$TMP_ROOT/run-port-probe"
  # bin/fm-spawn.sh's launch template must pick a concrete port itself (it
  # appears twice in one launch command: once for `run --port` and once inside
  # codex's base_url), so this picks one the same way rather than asking `run`
  # to self-assign one as `serve 0` does.
  port_probe_val=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

  PATH="$az_dir:$PATH" \
    FM_FOUNDRY_LUNA_TEST_UPSTREAM_HOST="127.0.0.1:$upstream_port" \
    python3 "$PROXY" run --port "$port_probe_val" -- "$child_script" "$port_probe_val" "$port_probe"
  run_status=$?

  kill "$upstream_pid" 2>/dev/null
  wait "$upstream_pid" 2>/dev/null

  assert_equals "42" "$run_status" "run must exit with the wrapped command's own exit status"
  status=$(cat "$port_probe")
  expect_code 200 "$status" "the wrapped command could reach the gateway while it ran"
  assert_contains "$(cat "$upstream_log")" "Bearer FAKE-TOKEN-1" "the request the child made was really forwarded with a fetched token"
  ! curl -sS -o /dev/null --max-time 1 "http://127.0.0.1:$port_probe_val/openai/v1/chat/completions" 2>/dev/null \
    || fail "the gateway must stop listening once the wrapped command exits"
  pass "fm-foundry-luna-proxy: 'run' serves the wrapped command and stops the gateway when it exits"
}

test_refuses_every_unauthorized_deployment_name
test_refresh_path_obtains_a_new_token_per_request_when_expired
test_caches_a_still_valid_token_across_requests
test_streams_a_chunked_reply_through_with_usable_framing
test_refuses_a_non_loopback_upstream_override
test_run_subcommand_serves_while_the_child_runs_then_stops
