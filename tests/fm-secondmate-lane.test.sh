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
    printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls.log"\n[ -z "${STUB_FAIL:-}" ] || exit 1\n' "$s" "$w" > "$w/bin/$s.sh"
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
test_reopen_clears_marker_and_relaunches
test_refuses_unregistered_and_bad_verb
echo "# all fm-secondmate-lane tests passed"
