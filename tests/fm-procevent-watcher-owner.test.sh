#!/usr/bin/env bash
# A live watcher keeps registered source ownership through a slow cycle and
# restores an unowned source without a firstmate turn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB=$(fm_test_tmproot fm-procevent-watcher-owner)
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
CLAIMS="$LAB/claims"
mkdir -p "$STATE"
fm_test_track_procevent_home "$HOME_DIR" "$CLAIMS"
cat > "$LAB/source.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" >> "$1"
sleep 30
SH
chmod +x "$LAB/source.sh"

pe() {
  FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS=2 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10 \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

watch_pid=
cleanup_watch() {
  [ -z "$watch_pid" ] || { kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; }
  fm_test_cleanup
}
trap cleanup_watch EXIT

pe register lavish still-owned -- "$LAB/source.sh" "$LAB/still-owned-starts" >/dev/null \
  || fail "could not register the live source"
pe reconcile >/dev/null || fail "could not start the live source"
for _ in $(seq 1 100); do
  owner=$(pe list | awk '$1 == "still-owned" { print $3 }')
  [ "$owner" = live ] && break
  sleep 0.1
done
[ "$owner" = live ] || fail "the first source never acquired an owner"
for _ in $(seq 1 100); do
  [ -s "$LAB/still-owned-starts" ] && break
  sleep 0.1
done
[ -s "$LAB/still-owned-starts" ] || fail "the first source command never ran"

pe register lavish needs-owner -- "$LAB/source.sh" "$LAB/needs-owner-starts" >/dev/null \
  || fail "could not register the unowned source"
[ "$(pe list | awk '$1 == "needs-owner" { print $3 }')" = none ] \
  || fail "the second source was already owned before the watcher started"

for n in 1 2 3 4; do
  cat > "$STATE/slow-$n.check.sh" <<SH
#!/usr/bin/env bash
sleep 1.2
: > '$STATE/check-$n-done'
SH
  chmod 700 "$STATE/slow-$n.check.sh"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-check-register.sh" "slow-$n" >/dev/null \
    || fail "could not register slow check $n"
done

FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_PROCEVENT_OWNER_LEASE_SECONDS=2 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=10 \
  FM_POLL=15 FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 FM_HEARTBEAT=999999 \
  FM_SIGNAL_GRACE=1 "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1 &
watch_pid=$!
for _ in $(seq 1 150); do
  [ -e "$STATE/check-4-done" ] && break
  kill -0 "$watch_pid" 2>/dev/null || fail "watcher exited before finishing its cycle: $(cat "$LAB/watch.out")"
  sleep 0.1
done
[ -e "$STATE/check-4-done" ] || fail "watcher never finished the slow checks: $(cat "$LAB/watch.out")"

list=$(pe list)
[ "$(printf '%s\n' "$list" | awk '$1 == "still-owned" { print $3 }')" = live ] \
  || fail "live source lost its owner during watcher work: $list"
[ "$(printf '%s\n' "$list" | awk '$1 == "needs-owner" { print $3 }')" = live ] \
  || fail "watcher did not relaunch the unowned source: $list"
[ "$(wc -l < "$LAB/still-owned-starts" | tr -d ' ')" = 1 ] \
  || fail "watcher launched a second copy of a source that was already live"
[ "$(wc -l < "$LAB/needs-owner-starts" | tr -d ' ')" = 1 ] \
  || fail "watcher launched the missing source more than once"
pass "a between-turn watcher preserves live owners and relaunches only an unowned source"
