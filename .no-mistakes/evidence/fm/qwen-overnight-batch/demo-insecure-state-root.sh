#!/usr/bin/env bash
# Walk the exact scenario issue #3929 reports, as an operator would:
# arm a process-event source while the state root is private, relax the root
# afterwards, run the reconcile call whose exit the caller swallows, and see
# whether the failure reaches anyone. FM_ROOT points at the tree under test.
set -u
FM_TREE=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-3929-demo.XXXXXX")
mkdir -p "$H/state"

say() { printf '\n=== %s\n' "$*"; }

say "1. arm a condition->action watch while state/ is private (700)"
chmod 700 "$H/state"
FM_HOME="$H" "$FM_TREE/bin/fm-procevent-when.sh" arm demo-watch --interval 0.1 \
  --condition false --action true 2>&1 | sed 's/^/    /'

say "2. an operator relaxes the state root (umask, chmod -R, a helper tool)"
chmod 775 "$H/state"
ls -ld "$H/state" | sed 's/^/    /'

say "3. the watcher's own reconcile call, verbatim: exit and output discarded"
FM_HOME="$H" "$FM_TREE/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
printf '    operator sees: (nothing - that is the swallow)\n'

say "4. is there any durable record of the refusal?"
HAD_RECORD=
if [ -f "$H/.procevent-state-insecure" ] && [ ! -L "$H/.procevent-state-insecure" ]; then
  printf '    %s:\n' "$H/.procevent-state-insecure"
  sed 's/^/      /' "$H/.procevent-state-insecure"
  HAD_RECORD=yes
else
  printf '    NONE - the failure vanished\n'
fi

run_watcher() {  # <out> <tenths>
  local out=$1 tenths=$2 pid= i=0 pf="$H/.demo-watch.pid"
  rm -f -- "$pf"
  ( FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$FM_TREE/bin/fm-watch.sh" > "$out" 2>/dev/null &
    echo $! > "$pf"; wait ) &
  local wrapper=$!
  while [ "$i" -lt 50 ] && [ -z "$pid" ]; do pid=$(cat "$pf" 2>/dev/null); [ -n "$pid" ] && break; sleep 0.1; i=$((i+1)); done
  i=0
  while [ "$i" -lt "$tenths" ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  kill "$pid" 2>/dev/null || true; wait "$wrapper" 2>/dev/null || true; rm -f -- "$pf"
}

say "5. what the captain actually sees from the real watcher (one poll window)"
run_watcher "$H/watch-1.out" 100
if grep -qF 'procevent-state-insecure' "$H/watch-1.out"; then
  grep -F 'procevent-state-insecure' "$H/watch-1.out" | sed 's/^/    /'
else
  printf '    no wake about the state root at all\n'
fi

say "6. does it become a stream? second watcher window, same broken root"
FM_STATE_OVERRIDE="$H/state" bash -c '. "$1"; fm_wake_append check "procevent:demo-anchor" "check: process-event result captured: demo-anchor"' \
  _ "$FM_TREE/bin/fm-wake-lib.sh" 2>/dev/null || true
run_watcher "$H/watch-2.out" 100
printf '    anchor proving the cycle ran past the check: '
grep -cF 'process-event result captured' "$H/watch-2.out"
printf '    repeat insecure-root wakes this window: '
grep -cF 'check: procevent-state-insecure' "$H/watch-2.out"

say "7. operator restores private permissions and reconciles"
chmod 700 "$H/state"
FM_HOME="$H" "$FM_TREE/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 \
  && printf '    reconcile: ok\n' || printf '    reconcile: FAILED\n'
if [ -e "$H/.procevent-state-insecure" ]; then
  printf '    record still present (stale)\n'
elif [ -n "$HAD_RECORD" ]; then
  printf '    record cleared automatically\n'
else
  printf '    nothing to clear - there never was a record\n'
fi

FM_HOME="$H" "$FM_TREE/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
rm -rf "$H"
