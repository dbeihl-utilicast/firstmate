#!/usr/bin/env bash
# tests/fm-secondmate-lane.test.sh - bin/fm-secondmate-lane.sh stop and reopen:
# the marker the session-start liveness sweep honors, written before the agent
# is stopped and cleared only by reopen. Control-plane and spawn calls are
# stubbed in a copy of bin/ so the test drives the real verb script.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-lane)

new_lane_world() {  # <name> [remote-host] -> prints world dir
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/bin" "$w/home/state"
  cp "$ROOT"/bin/*.sh "$w/bin/"
  local s
  for s in fm-control fm-spawn fm-on; do
    cat > "$w/bin/$s.sh" <<STUB
#!/usr/bin/env bash
echo "$s \$*" >> "$w/calls.log"
[ -z "\${STUB_FAIL:-}" ] || exit 1
STUB
    chmod +x "$w/bin/$s.sh"
  done
  {
    printf 'window=firstmate:fm-sm1\nkind=secondmate\nharness=claude\n'
    [ -z "${2:-}" ] || printf 'remote_host=%s\n' "$2"
  } > "$w/home/state/sm1.meta"
  printf '%s\n' "$w"
}

lane() {  # <world> <args...>
  local w=$1; shift
  FM_HOME="$w/home" "$w/bin/fm-secondmate-lane.sh" "$@" 2>&1
}

test_stop_local_records_marker_and_exits_agent() {
  local w
  w=$(new_lane_world stop-local)
  lane "$w" stop sm1 >/dev/null || fail "stop should succeed"
  assert_present "$w/home/state/sm1.stopped" "stop must record the marker"
  assert_contains "$(cat "$w/calls.log")" "fm-control sm1 exit" "a local mate stops through the control plane"
  pass "lane: stop on a local mate records the marker and exits the agent"
}

test_stop_remote_uses_host_stop_verb() {
  local w
  w=$(new_lane_world stop-remote host1)
  lane "$w" stop sm1 >/dev/null || fail "remote stop should succeed"
  assert_present "$w/home/state/sm1.stopped" "remote stop must record the marker"
  assert_contains "$(cat "$w/calls.log")" "fm-on sm1 fm-remote-secondmate-control.sh stop sm1" "a remote mate stops through its host's stop verb"
  pass "lane: stop on a remote mate routes to the host stop verb"
}

test_marker_survives_failed_stop() {
  local w
  w=$(new_lane_world stop-fails)
  STUB_FAIL=1 lane "$w" stop sm1 >/dev/null && fail "a failed agent exit must be reported"
  assert_present "$w/home/state/sm1.stopped" "the marker must hold even when the agent exit fails"
  pass "lane: the marker is written before, and survives, a failed agent exit"
}

test_stop_waits_for_delivery_metadata_lock() {
  local w holder rc=0
  w=$(new_lane_world stop-lock)
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$w/bin/fm-wake-lib.sh" "$w/home/state/.meta-sm1.lock" "$w/held" "$w/release" &
  holder=$!
  while [ ! -e "$w/held" ]; do sleep 0.05; done
  lane "$w" stop sm1 >"$w/stop.out" &
  local stopper=$!
  sleep 0.1
  assert_absent "$w/home/state/sm1.stopped" "stop must not publish its marker while delivery owns metadata"
  touch "$w/release"
  wait "$holder"
  wait "$stopper" || rc=$?
  [ "$rc" -eq 0 ] || fail "stop should complete after the metadata lock releases: $(cat "$w/stop.out")"
  assert_present "$w/home/state/sm1.stopped" "stop must publish the marker after metadata delivery releases"
  pass "lane: stop serializes marker publication with delivery metadata"
}

# The marker is written first, so a gone endpoint is already the state stop
# wants. Other exit failures stay errors (test_marker_survives_failed_stop).
test_stop_missing_endpoint_is_already_complete() {
  local w out rc
  w=$(new_lane_world stop-gone)
  cat > "$w/bin/fm-control.sh" <<'STUB'
#!/usr/bin/env bash
echo "error: task sm1's recorded endpoint is gone, so there is no agent to stop; reconcile the task before any further control action" >&2
exit 1
STUB
  chmod +x "$w/bin/fm-control.sh"
  out=$(lane "$w" stop sm1); rc=$?
  [ "$rc" -eq 0 ] || fail "stop should succeed when the recorded endpoint is already gone: $out"
  assert_present "$w/home/state/sm1.stopped" "stop must still record the marker"
  pass "lane: stop treats a missing endpoint as already complete"
}

test_reopen_clears_marker_and_relaunches() {
  local w
  w=$(new_lane_world reopen)
  : > "$w/home/state/sm1.stopped"
  lane "$w" reopen sm1 >/dev/null || fail "reopen should succeed"
  assert_absent "$w/home/state/sm1.stopped" "reopen must clear the marker"
  assert_contains "$(cat "$w/calls.log")" "fm-spawn sm1 --secondmate" "reopen relaunches the mate"
  pass "lane: reopen clears the marker and relaunches"
}

test_refuses_unregistered_and_bad_verb() {
  local w
  w=$(new_lane_world refuse)
  lane "$w" stop nope >/dev/null && fail "an unregistered id must be refused"
  lane "$w" pause sm1 >/dev/null && fail "an unknown verb must be refused"
  assert_absent "$w/home/state/sm1.stopped" "a refused verb must not write a marker"
  pass "lane: unregistered ids and unknown verbs are refused"
}

test_stop_local_records_marker_and_exits_agent
test_stop_remote_uses_host_stop_verb
test_marker_survives_failed_stop
test_stop_waits_for_delivery_metadata_lock
test_stop_missing_endpoint_is_already_complete
test_reopen_clears_marker_and_relaunches
test_refuses_unregistered_and_bad_verb
echo "# all fm-secondmate-lane tests passed"
