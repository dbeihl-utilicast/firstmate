#!/usr/bin/env bash
set -u

ROOT=${1:?repository root required}
EVIDENCE=$(cd "$(dirname "$0")" && pwd)
SLOW_HOME="$EVIDENCE/live-slow/home"
HUNG_HOME="$EVIDENCE/live-hung/home"
WATCH="$ROOT/bin/fm-watch.sh"
GUARD="$ROOT/bin/fm-guard.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
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
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}

beat_age() {
  local beat=$1
  printf '%s\n' "$(( $(date +%s) - $(mtime "$beat") ))"
}

wait_for_event() {
  local log=$1 marker=$2 limit=$3 elapsed=0
  while ! grep -F "$marker" "$log" >/dev/null 2>&1; do
    kill -0 "$WATCHER_PID" 2>/dev/null || {
      printf 'FAIL: watcher exited before %s\n' "$marker"
      return 1
    }
    [ "$elapsed" -lt "$limit" ] || {
      printf 'FAIL: timed out waiting for %s\n' "$marker"
      return 1
    }
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

guard_probe() {
  local home=$1 label=$2 out="$home/guard-probe.out" age
  : > "$out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_GUARD_READ_ONLY=1 "$GUARD" >/dev/null 2> "$out"
  age=$(beat_age "$home/state/.last-watcher-beat")
  if grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$out" >/dev/null; then
    printf '%s beat_age=%ss guard=DOWN\n' "$label" "$age"
    return 1
  fi
  printf '%s beat_age=%ss guard=healthy\n' "$label" "$age"
  return 0
}

register_check() {
  local home=$1 id=$2
  chmod 700 "$home/state/$id.check.sh"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REGISTER" "$id"
}

run_slow_progress_scenario() {
  local home=$SLOW_HOME events="$SLOW_HOME/events.log" beat="$SLOW_HOME/state/.last-watcher-beat"
  local first_start fourth_start elapsed sample=0
  : > "$events"
  : > "$home/watcher.out"
  register_check "$home" stage-1
  register_check "$home" stage-2
  register_check "$home" stage-3
  register_check "$home" stage-4
  printf 'SCENARIO slow-progress: real watcher begins one cycle with four 101s registered checks; guard grace is its default 300s\n'
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_EVIDENCE_EVENT_LOG="$events" FM_POLL=15 FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=120 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$WATCH" > "$home/watcher.out" 2>&1 &
  WATCHER_PID=$!
  wait_for_event "$events" stage-1-start 60 || return 1
  first_start=$(awk -F '\t' '$2 == "stage-1-start" { print $1; exit }' "$events")
  while ! grep -F 'stage-4-start' "$events" >/dev/null 2>&1; do
    sleep 30
    sample=$((sample + 1))
    guard_probe "$home" "slow-progress sample-$sample" || {
      printf 'FAIL: the real guard reported a live progressing cycle down before stage 4\n'
      return 1
    }
  done
  fourth_start=$(awk -F '\t' '$2 == "stage-4-start" { print $1; exit }' "$events")
  elapsed=$((fourth_start - first_start))
  [ "$elapsed" -ge 300 ] || {
    printf 'FAIL: cycle had not crossed 300s when stage 4 began (elapsed=%ss)\n' "$elapsed"
    return 1
  }
  guard_probe "$home" "slow-progress after-${elapsed}s-in-one-cycle" || {
    printf 'FAIL: the real guard called a progressing cycle down after 300s\n'
    return 1
  }
  kill -0 "$WATCHER_PID" 2>/dev/null || {
    printf 'FAIL: watcher was not running during stage 4\n'
    return 1
  }
  printf 'events:\n'
  sed 's/^/  /' "$events"
  printf 'PASS: a single poll cycle remained distinguishable from a dead watcher after %ss because completed work refreshed the mtime-only beacon\n' "$elapsed"
  stop_watcher
}

run_hung_scenario() {
  local home=$HUNG_HOME events="$HUNG_HOME/events.log" age=0 sample=0 out="$HUNG_HOME/guard-final.out"
  : > "$events"
  : > "$home/watcher.out"
  register_check "$home" hung
  printf 'SCENARIO hung-step: real watcher enters one non-returning registered check; guard grace is its default 300s\n'
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_EVIDENCE_EVENT_LOG="$events" FM_POLL=15 FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=400 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$WATCH" > "$home/watcher.out" 2>&1 &
  WATCHER_PID=$!
  wait_for_event "$events" hung-start 60 || return 1
  while [ "$age" -lt 300 ]; do
    sleep 30
    sample=$((sample + 1))
    age=$(beat_age "$home/state/.last-watcher-beat")
    kill -0 "$WATCHER_PID" 2>/dev/null || {
      printf 'FAIL: watcher exited before its hung step reached 300s\n'
      return 1
    }
    if [ "$age" -lt 300 ]; then
      guard_probe "$home" "hung-step sample-$sample" || {
        printf 'FAIL: guard alarmed before the unchanged beat reached 300s\n'
        return 1
      }
    fi
  done
  : > "$out"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_GUARD_READ_ONLY=1 "$GUARD" >/dev/null 2> "$out"
  printf 'hung-step after-no-progress beat_age=%ss watcher_process=alive\n' "$age"
  sed -n '/WATCHER DOWN - SUPERVISION IS OFF/,+3p' "$out" | sed 's/^/  /'
  grep -F 'WATCHER DOWN - SUPERVISION IS OFF' "$out" >/dev/null || {
    printf 'FAIL: guard did not report the non-returning step down after 300s\n'
    return 1
  }
  grep -F 'grace 300s' "$out" >/dev/null || {
    printf 'FAIL: guard alarm did not preserve the 300s threshold\n'
    return 1
  }
  kill -0 "$WATCHER_PID" 2>/dev/null || {
    printf 'FAIL: watcher process was not alive when the stale-beacon alarm fired\n'
    return 1
  }
  printf 'PASS: a live process stuck inside one step stopped refreshing the beacon and the unchanged 300s guard reported it down\n'
  stop_watcher
}

run_slow_progress_scenario || exit 1
run_hung_scenario || exit 1
printf 'LIVE PRODUCT RESULT: PASS\n'
