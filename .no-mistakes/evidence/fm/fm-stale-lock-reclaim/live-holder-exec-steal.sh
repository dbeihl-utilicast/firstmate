#!/usr/bin/env bash
# A LIVE lock holder that exec()s is treated as abandoned and loses its lock.
# Same pid, same start time, new argv -> fm_pid_identity mismatch.
set -u
LIB=${FM_DEMO_WORKTREE:?}/bin/fm-wake-lib.sh
D=$(mktemp -d "${TMPDIR:-/tmp}/exec-steal.XXXXXX"); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/state"
FM_STATE_OVERRIDE="$D/state" bash -c '
  . "$1"
  fm_lock_acquire_wait "$STATE/.probe.lock" || exit 7
  printf ready > "$2"
  exec sleep 30
' _ "$LIB" "$D/ready" &
holder=$!
i=0; while [ "$i" -lt 100 ] && [ ! -s "$D/ready" ]; do sleep 0.05; i=$((i + 1)); done
printf 'holder pid %s acquired .probe.lock; lock records pid=%s; holder is alive: %s\n' \
  "$holder" "$(cat "$D/state/.probe.lock/pid")" "$(kill -0 "$holder" 2>/dev/null && echo yes || echo no)"
printf 'identity recorded at acquire : %s\n' "$(head -1 "$D/state/.probe.lock/pid-identity")"
printf 'identity now, after its exec : %s\n' \
  "$(FM_STATE_OVERRIDE=$D/state bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$holder" | head -1)"
FM_STATE_OVERRIDE="$D/state" bash -c '
  . "$1"
  if fm_lock_try_acquire "$STATE/.probe.lock"; then
    printf "second acquirer  : RECLAIMED the live holder'\''s lock, new owner pid=%s\n" "$(cat "$STATE/.probe.lock/pid")"
  else
    printf "second acquirer  : refused (rc=%s, held by %s)\n" "$?" "$FM_LOCK_HELD_PID"
  fi
' _ "$LIB"
printf 'original holder %s still running inside its critical section: %s\n' \
  "$holder" "$(kill -0 "$holder" 2>/dev/null && echo 'yes - two owners now' || echo no)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
