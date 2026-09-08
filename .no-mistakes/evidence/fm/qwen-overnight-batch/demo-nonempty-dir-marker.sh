#!/usr/bin/env bash
# The round-5 hardening: a NON-EMPTY directory planted at either marker path.
# Plant one at both paths, break the state root, and see whether the captain
# still gets the wake. FM_TREE points at the tree under test.
set -u
FM_TREE=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-3929-dirmarker.XXXXXX")
mkdir -p "$H/state"
chmod 700 "$H/state"
say() { printf '\n=== %s\n' "$*"; }

FM_HOME="$H" "$FM_TREE/bin/fm-procevent-when.sh" arm dir-demo --interval 0.1 \
  --condition false --action true >/dev/null 2>&1

say "plant a non-empty directory at BOTH marker paths"
mkdir -p "$H/.procevent-state-insecure/kept" "$H/.procevent-state-insecure-surfaced/kept"
printf 'do not lose me\n' > "$H/.procevent-state-insecure/kept/payload"
ls -d "$H"/.procevent-state-insecure* | sed 's|.*/|    |'

say "relax the state root, then run the swallowed reconcile"
chmod 775 "$H/state"
FM_HOME="$H" "$FM_TREE/bin/fm-procevent.sh" reconcile >/dev/null 2>&1 || true
if [ -f "$H/.procevent-state-insecure" ] && [ ! -L "$H/.procevent-state-insecure" ]; then
  printf '    durable record written:\n'; sed 's/^/      /' "$H/.procevent-state-insecure"
else
  printf '    NO record - the planted directory was read as a valid one\n'
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

say "one watcher window: does the captain hear about the broken root?"
FM_STATE_OVERRIDE="$H/state" bash -c '. "$1"; fm_wake_append check "procevent:dir-anchor" "check: process-event result captured: dir-anchor"' \
  _ "$FM_TREE/bin/fm-wake-lib.sh" 2>/dev/null || true
run_watcher "$H/watch.out" 250
printf '    anchor proving the cycle ran past the check: '; grep -cF 'process-event result captured' "$H/watch.out"
if grep -qF 'check: procevent-state-insecure' "$H/watch.out"; then
  grep -F 'check: procevent-state-insecure' "$H/watch.out" | sed 's/^/    /'
else
  printf '    SILENT - the planted directory latched the wake away\n'
fi

say "was the planted directory content preserved?"
d=$(printf '%s\n' "$H"/.procevent-state-insecure.displaced-* 2>/dev/null | head -1)
if [ -f "$d/kept/payload" ]; then
  printf '    moved aside to %s, payload intact: %s\n' "${d##*/}" "$(cat "$d/kept/payload")"
elif [ -f "$H/.procevent-state-insecure/kept/payload" ]; then
  printf '    left in place untouched\n'
else
  printf '    payload LOST\n'
fi

FM_HOME="$H" "$FM_TREE/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
chmod -R 700 "$H/state" 2>/dev/null || true
printf "\nhome: %s\n" "$H"
