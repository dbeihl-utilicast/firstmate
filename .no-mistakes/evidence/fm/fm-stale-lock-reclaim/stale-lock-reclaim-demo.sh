#!/usr/bin/env bash
# End-to-end demonstration of the stale-lock reclaim fix at the operator surface.
#
# Surface: bin/fm-wake-drain.sh - the status-presentation drain that issue 3966
# was filed against. It waits FM_STATUS_PRESENTATION_LOCK_TIMEOUT seconds for
# the shared wake-queue lock, then gives up.
#
# Identical planted state, two libraries: base b84e0e3 vs branch HEAD.
set -u

BASE_REV=b84e0e362face25f3dd8945297a3df1320d7668c
WORKTREE=${FM_DEMO_WORKTREE:?set FM_DEMO_WORKTREE to the checkout}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/stale-lock-demo.XXXXXX")
SQUATTERS=
cleanup() {
  local p
  for p in $SQUATTERS; do kill "$p" 2>/dev/null; done
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

git -C "$WORKTREE" archive "$BASE_REV" bin | tar -x -C "$SCRATCH"
BASE_BIN="$SCRATCH/bin"
HEAD_BIN="$WORKTREE/bin"
mkdir -p "$SCRATCH/nongit-root"
export FM_ROOT_OVERRIDE="$SCRATCH/nongit-root"
export FM_STATUS_PRESENTATION_LOCK_TIMEOUT=6

hr() { printf '%s\n' '-------------------------------------------------------------------------'; }

seed_state() {  # <bin> <state>
  local bin=$1 state=$2
  mkdir -p "$state"
  FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/fm-wake-lib.sh"; fm_wake_append signal captain-check "signal: captain wants the fleet status"' \
    _ "$bin" >/dev/null 2>&1
}

plant_reused_pid_lock() {  # <state> <live-pid>: owner died, its pid number was reused
  local state=$1 live=$2 owner="$1/.wake-queue.lock.owner.dead"
  mkdir -p "$owner"
  printf '%s\n' "$live" > "$owner/pid"
  printf '%s\n' 'identity-of-the-process-that-died' > "$owner/pid-identity"
  ln -s "$owner" "$state/.wake-queue.lock"
}

run_drain() {  # <bin> <state> <label>
  local bin=$1 state=$2 label=$3 start end rc
  start=$(date +%s)
  FM_STATE_OVERRIDE="$state" "$bin/fm-wake-drain.sh" > "$state/out" 2> "$state/err"
  rc=$?
  end=$(date +%s)
  printf '$ FM_STATE_OVERRIDE=<state> fm-wake-drain.sh        # %s\n' "$label"
  sed 's/^/    /' "$state/out"
  [ -s "$state/err" ] && sed 's/^/    (stderr) /' "$state/err"
  printf '    [exit %s, waited %ss]\n' "$rc" "$((end - start))"
}

printf '### Scenario 1 - the reported bug.\n'
printf '### The lock owner is long gone; its pid number is now occupied by an\n'
printf '### unrelated live process. One wake is queued and waiting to be shown.\n\n'

for variant in base head; do
  case $variant in
    base) bin=$BASE_BIN; label="base $BASE_REV" ;;
    head) bin=$HEAD_BIN; label="branch HEAD" ;;
  esac
  state="$SCRATCH/s1-$variant/state"
  seed_state "$bin" "$state"
  sleep 120 &
  squatter=$!
  SQUATTERS="$SQUATTERS $squatter"
  plant_reused_pid_lock "$state" "$squatter"
  hr
  printf 'library: %s\n' "$label"
  printf 'planted .wake-queue.lock -> pid %s (live, unrelated), recorded identity %s\n' \
    "$squatter" "$(cat "$state/.wake-queue.lock.owner.dead/pid-identity")"
  printf 'kill -0 %s says: %s\n' "$squatter" "$(kill -0 "$squatter" 2>/dev/null && echo 'alive - a pid alone cannot tell you the owner died' || echo dead)"
  printf 'queued wake rows: %s\n' "$(wc -l < "$state/.wake-queue" | tr -d ' ')"
  run_drain "$bin" "$state" "$label"
  if [ -L "$state/.wake-queue.lock" ] || [ -e "$state/.wake-queue.lock" ]; then
    printf 'lock afterwards: still held, pid=%s\n' "$(cat "$state/.wake-queue.lock/pid" 2>/dev/null || echo '?')"
  else
    printf 'lock afterwards: reclaimed, used, and released\n'
  fi
  printf 'unrelated pid %s afterwards: %s\n' "$squatter" \
    "$(kill -0 "$squatter" 2>/dev/null && echo 'still alive, never signalled' || echo 'GONE - reclaim signalled an innocent process')"
  kill "$squatter" 2>/dev/null; wait "$squatter" 2>/dev/null
done
hr

printf '\n### Scenario 2 - a slow but LIVE owner, same drain, same timeout.\n'
printf '### This lock must NOT be reclaimed. Two writers would be worse than the bug.\n\n'

for variant in base head; do
  case $variant in
    base) bin=$BASE_BIN; label="base $BASE_REV" ;;
    head) bin=$HEAD_BIN; label="branch HEAD" ;;
  esac
  state="$SCRATCH/s2-$variant/state"
  seed_state "$bin" "$state"
  ready="$SCRATCH/s2-$variant-ready"; release="$SCRATCH/s2-$variant-release"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.wake-queue.lock" || exit 7
    : > "$2"
    while [ ! -e "$3" ]; do sleep 0.05; done
    fm_lock_release "$STATE/.wake-queue.lock"
  ' _ "$bin" "$ready" "$release" &
  holder=$!
  i=0; while [ "$i" -lt 200 ] && [ ! -e "$ready" ]; do sleep 0.05; i=$((i+1)); done
  hr
  printf 'library: %s\n' "$label"
  printf 'live holder pid %s is inside the critical section, busy, not dead\n' \
    "$(cat "$state/.wake-queue.lock/pid" 2>/dev/null || echo '?')"
  run_drain "$bin" "$state" "$label"
  printf 'lock owner afterwards: pid=%s   (the holder is pid %s)\n' \
    "$(cat "$state/.wake-queue.lock/pid" 2>/dev/null || echo 'GONE - THE LOCK WAS STOLEN')" "$holder"
  : > "$release"
  wait "$holder" 2>/dev/null
  printf 'holder finished its section and released: %s\n' \
    "$([ -e "$state/.wake-queue.lock" ] && echo no || echo yes)"
done
hr

printf '\n### Scenario 3 - two waiters arrive at once.\n'
printf '### 8 real wake appends launched together against one reused-pid stale lock\n'
printf '### (branch HEAD). Exactly one may reclaim; no row may be lost or doubled.\n\n'

state="$SCRATCH/s3/state"
mkdir -p "$state"
sleep 120 &
squatter=$!
SQUATTERS="$SQUATTERS $squatter"
plant_reused_pid_lock "$state" "$squatter"
hr
printf 'planted .wake-queue.lock -> pid %s (live, unrelated); launching 8 appenders\n' "$squatter"
writers=
for i in 1 2 3 4 5 6 7 8; do
  ( FM_STATE_OVERRIDE="$state" bash -c \
      '. "$1/fm-wake-lib.sh"; fm_wake_append signal "writer-$2" "signal: concurrent writer $2"' \
      _ "$HEAD_BIN" "$i" >/dev/null 2>&1
    printf 'writer %s exit %s\n' "$i" "$?" >> "$SCRATCH/s3-rc" ) &
  writers="$writers $!"
done
# shellcheck disable=SC2086 # Deliberate word splitting over the collected writer pids.
wait $writers
sort "$SCRATCH/s3-rc" | sed 's/^/    /'
printf 'resulting queue, %s rows:\n' "$(wc -l < "$state/.wake-queue" | tr -d ' ')"
sed 's/^/    /' "$state/.wake-queue"
printf 'distinct sequence numbers: %s (8 means no writer overwrote another)\n' \
  "$(cut -f2 "$state/.wake-queue" | sort -u | wc -l | tr -d ' ')"
printf 'lock afterwards: %s\n' "$([ -e "$state/.wake-queue.lock" ] && echo 'still held' || echo 'released by its last owner')"
printf 'unrelated pid %s afterwards: %s\n' "$squatter" \
  "$(kill -0 "$squatter" 2>/dev/null && echo 'still alive, never signalled' || echo 'GONE - reclaim signalled an innocent process')"
hr
