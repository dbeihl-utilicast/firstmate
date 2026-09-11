#!/usr/bin/env bash
# Manual end-to-end demo of identity-based lock reclaim using the real lock library.
set -u
ROOT=${1:?repo root}
LIB="$ROOT/bin/fm-wake-lib.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-demo.XXXXXX")
trap 'kill ${live:-} ${holder:-} 2>/dev/null; rm -rf "$work"' EXIT
mkdir -p "$work/state"

echo "== 1. fresh acquire records starttime identity =="
FM_STATE_OVERRIDE="$work/state" bash -c '
  . "$1"; fm_lock_try_acquire "$2" || exit 7
  echo "pid=$(cat "$2/pid")  pid-identity=$(cat "$2/pid-identity")"
  echo "live fm_lock_pid_identity=$(fm_lock_pid_identity "$(cat "$2/pid")")"
  fm_lock_release "$2"
' _ "$LIB" "$work/state/.a.lock"

echo
echo "== 2. live pid whose recorded identity no longer matches (recycled pid) =="
sleep 30 & live=$!
mkdir "$work/state/.b.lock"
printf '%s\n' "$live" > "$work/state/.b.lock/pid"
printf '%s\n' "Thu Jan  1 00:00:00 1970" > "$work/state/.b.lock/pid-identity"
echo "lock pid=$live (alive: $(kill -0 $live && echo yes)), recorded identity=$(cat "$work/state/.b.lock/pid-identity")"
FM_STATE_OVERRIDE="$work/state" bash -c '
  . "$1"
  if fm_lock_try_acquire "$2"; then echo "contender ACQUIRED; new pid=$(cat "$2/pid")"; fm_lock_release "$2"; else echo "contender REFUSED held_pid=$FM_LOCK_HELD_PID"; fi
' _ "$LIB" "$work/state/.b.lock"
kill "$live"; wait "$live" 2>/dev/null; live=

echo
echo "== 3. live pid whose identity matches stays held =="
sleep 30 & live=$!
mkdir "$work/state/.c.lock"
printf '%s\n' "$live" > "$work/state/.c.lock/pid"
FM_STATE_OVERRIDE="$work/state" bash -c '. "$1"; fm_lock_pid_identity "$2"' _ "$LIB" "$live" > "$work/state/.c.lock/pid-identity"
FM_STATE_OVERRIDE="$work/state" bash -c '
  . "$1"
  if fm_lock_try_acquire "$2"; then echo "contender ACQUIRED (BAD)"; else echo "contender REFUSED held_pid=$FM_LOCK_HELD_PID (expected $3)"; fi
' _ "$LIB" "$work/state/.c.lock" "$live"
kill "$live"; wait "$live" 2>/dev/null; live=

echo
echo "== 4. holder acquires then execs sleep; lock stays held =="
FM_STATE_OVERRIDE="$work/state" bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 7; exec sleep 30' _ "$LIB" "$work/state/.d.lock" &
holder=$!
for _ in $(seq 1 100); do
  [ "$(ps -p "$holder" -o comm= 2>/dev/null | sed 's#.*/##')" = sleep ] && break
  sleep 0.05
done
echo "holder pid=$holder program=$(ps -p "$holder" -o comm=) lockpid=$(cat "$work/state/.d.lock/pid")"
FM_STATE_OVERRIDE="$work/state" bash -c '
  . "$1"
  if fm_lock_try_acquire "$2"; then echo "contender ACQUIRED (BAD)"; else echo "contender REFUSED held_pid=$FM_LOCK_HELD_PID"; fi
' _ "$LIB" "$work/state/.d.lock"
kill "$holder"; wait "$holder" 2>/dev/null; holder=

echo
echo "== 5. dead holder pid is still reclaimed =="
dead=999999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
mkdir "$work/state/.e.lock"; printf '%s\n' "$dead" > "$work/state/.e.lock/pid"
FM_STATE_OVERRIDE="$work/state" bash -c '
  . "$1"
  if fm_lock_try_acquire "$2"; then echo "contender ACQUIRED dead pid $3 lock; new pid=$(cat "$2/pid")"; fm_lock_release "$2"; else echo "contender REFUSED (BAD)"; fi
' _ "$LIB" "$work/state/.e.lock" "$dead"
