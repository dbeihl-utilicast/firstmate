#!/usr/bin/env bash
set -u

TARGET_ROOT=${1:?target root required}
BASE_COMMIT=${2:?base commit required}
EVIDENCE=$(cd "$(dirname "$0")" && pwd)
WATCHER_PID=

stop_watcher() {
  if [ -n "$WATCHER_PID" ] && kill -0 "$WATCHER_PID" 2>/dev/null; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  WATCHER_PID=
}
trap stop_watcher EXIT HUP INT TERM

mtime() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %m "$1"; else stat -c %Y "$1"; fi
}

run_one() {
  local label=$1 root=$2 home=$3 expected=$4 source_mode=$5 events out age i=0
  events="$home/events.log"
  out="$home/guard.out"
  : > "$events"
  : > "$home/watcher.out"
  chmod 700 "$home/state/stage-a.check.sh" "$home/state/stage-b.check.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$root/bin/fm-check-register.sh" stage-a >/dev/null
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$root/bin/fm-check-register.sh" stage-b >/dev/null
  if [ "$source_mode" = base ]; then
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" FM_EVIDENCE_EVENT_LOG="$events" \
      FM_BASE_SCRIPT_DIR="$root/bin" FM_POLL=15 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=40 \
      FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
      bash <(git -C "$root" show "$BASE_COMMIT:bin/fm-watch.sh" \
        | sed 's|^SCRIPT_DIR=.*$|SCRIPT_DIR="${FM_BASE_SCRIPT_DIR:?}"|') > "$home/watcher.out" 2>&1 &
  else
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
      FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" FM_EVIDENCE_EVENT_LOG="$events" \
      FM_POLL=15 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=40 FM_HEARTBEAT=999999 \
      FM_HOME_SUMMARY_INTERVAL=999999 "$root/bin/fm-watch.sh" > "$home/watcher.out" 2>&1 &
  fi
  WATCHER_PID=$!
  while ! grep -F stage-b-start "$events" >/dev/null 2>&1; do
    kill -0 "$WATCHER_PID" 2>/dev/null || { printf 'FAIL: %s watcher exited early\n' "$label"; return 1; }
    [ "$i" -lt 20 ] || { printf 'FAIL: %s stage B did not start\n' "$label"; return 1; }
    sleep 1
    i=$((i + 1))
  done
  : > "$out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_GUARD_GRACE=2 FM_GUARD_READ_ONLY=1 \
    "$root/bin/fm-guard.sh" >/dev/null 2> "$out"
  age=$(( $(date +%s) - $(mtime "$home/state/.last-watcher-beat") ))
  if grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$out" >/dev/null; then result=DOWN; else result=healthy; fi
  printf '%s after stage A returned: beat_age=%ss guard=%s expected=%s\n' "$label" "$age" "$result" "$expected"
  [ "$result" = "$expected" ] || { printf 'FAIL: %s produced the wrong guard result\n' "$label"; return 1; }
  stop_watcher
}

printf 'NEGATIVE CONTROL: same real product flow, compressed to a 2s grace\n'
run_one target "$TARGET_ROOT" "$EVIDENCE/negative-target/home" healthy target || exit 1
run_one base "$TARGET_ROOT" "$EVIDENCE/negative-base/home" DOWN base || exit 1
printf 'NEGATIVE CONTROL RESULT: PASS (the base reproduces the false alarm; the target removes it)\n'
