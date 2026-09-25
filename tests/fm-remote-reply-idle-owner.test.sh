#!/usr/bin/env bash
# A live primary session keeps remote reply sources owned between turns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-reply-idle-owner)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$CLAIMS"

cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  [ -z "${FAKE_CLAUDE_PID:-}" ] || {
    kill "$FAKE_CLAUDE_PID" 2>/dev/null || true
    wait "$FAKE_CLAUDE_PID" 2>/dev/null || true
  }
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
: > "$REMOTE/state/parent-replies.status"
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=1 \
  "$@"
}

wait_for() {
  local path=$1
  for ((i = 0; i < 200; i++)); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_owner_state() {
  local desired=$1 owner
  for ((i = 0; i < 200; i++)); do
    owner=$(remote_env "$ROOT/bin/fm-procevent.sh" list | awk -v id="$SID" '$1 == id { print $3 }')
    [ "$owner" = "$desired" ] && return 0
    sleep 0.05
  done
  return 1
}

SID=$(remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" source-id ios)
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null \
  || fail "remote reply source could not be armed"
ln -s /bin/bash "$FAKEBIN/claude"
# shellcheck disable=SC2016 # $FM_HOME and $$ expand in the fake Claude process.
FM_HOME="$PARENT" "$FAKEBIN/claude" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/.lock"
  while :; do sleep 1; done
' &
FAKE_CLAUDE_PID=$!
wait_for "$PARENT/state/.lock" || fail "idle primary session did not publish its lock"
assert_contains "$(FM_HOME="$PARENT" "$ROOT/bin/fm-lock.sh" status)" 'held by live harness' \
  "idle primary session was not recognized as live"

FM_PROCEVENT_OWNER_LEASE_SECONDS=2 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "remote reply source could not be started"
wait_for_owner_state live || fail "remote reply source had no initial owner"
sleep 5
wait_for_owner_state live || fail "quiet remote reply source lost its owner without a firstmate turn"
first_pid=$(awk -F= '$1 == "pid" { print $2 }' "$CLAIMS/$SID.claim")
remote_env "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null \
  || fail "reconcile could not inspect an already-owned source"
second_pid=$(awk -F= '$1 == "pid" { print $2 }' "$CLAIMS/$SID.claim")
[ "$first_pid" = "$second_pid" ] || fail "reconcile replaced a live remote reply owner"

printf 'working [key=one]: first idle reply\n' >> "$REMOTE/state/parent-replies.status"
wait_for "$PARENT/state/procevent-inbox/$SID.1.handled" \
  || fail "first idle reply was not captured and applied"
wait_for_owner_state live || fail "captured reply had no successor listener without a watcher"
printf 'done [key=two]: second idle reply\n' >> "$REMOTE/state/parent-replies.status"
wait_for "$PARENT/state/procevent-inbox/$SID.2.handled" \
  || fail "second idle reply was not captured and applied"
assert_grep 'working [key=one]: first idle reply' "$PARENT/state/ios.status" \
  "first idle reply was not mirrored"
assert_grep 'done [key=two]: second idle reply' "$PARENT/state/ios.status" \
  "second idle reply was not mirrored"
[ "$(grep -c 'first idle reply' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "first idle reply was mirrored more than once"
[ "$(grep -c 'second idle reply' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "second idle reply was mirrored more than once"
wait_for_owner_state live || fail "second captured reply had no successor listener"
kill "$FAKE_CLAUDE_PID" 2>/dev/null || true
wait "$FAKE_CLAUDE_PID" 2>/dev/null || true
FAKE_CLAUDE_PID=
wait_for_owner_state none || fail "source owner survived the end of its primary session"
pass "remote reply owners persist and succeed one another while the primary session is idle"
