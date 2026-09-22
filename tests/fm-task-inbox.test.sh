#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records claimed before their body is read and completed into
# handled/ after output; the terminal carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. An atomic take preserves unread records before invocation and lets one
#      concurrent taker move and read the lowest record exactly once.
#   3. Sequencing dedups a still-unhandled exact-body resend, while a different
#      body or a body taken earlier becomes a new record.
#   4. Concurrent writers serialize on the sequence lock: no clobbered records.
#   5. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   5. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
#   6. Dead panes: the doorbell line is a shell no-op when executed by a bare
#      shell, the ring skips an agent the backend classifies dead, and the
#      watcher surfaces such a record exactly once instead of re-ringing.
#   7. A lane carrying state/<id>.stopped produces no inbox stale wakes at all,
#      whether its agent reads dead or merely idle: a stopped lane has no
#      worker to recover. Quiet, unreachable, dead, missing, ambiguous, and
#      unreadable agent states without that marker keep their current wakes.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# A fake tmux for the watcher cases: capture-pane replays FM_FAKE_TMUX_CAPTURE,
# display-message yields a numeric cursor row, and every literal send-keys is
# logged to FM_SEND_LOG so a doorbell ring is observable. With
# FM_FAKE_TMUX_AGENT set, the inventory lists window fm-t1 and its
# #{pane_current_command} answers with that value, so `zsh` makes
# fm_backend_tmux_agent_state read the pane as a dead bare shell.
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
      if [ -n "${FM_ACK_RECORD:-}" ] && [ -f "$FM_ACK_RECORD" ]; then
        mv "$FM_ACK_RECORD" "${FM_ACK_RECORD%/*}/handled/"
      fi
    fi
    exit 0 ;;
  list-panes)
    printf 'fakepane\n'; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '%s\n' "$FM_FAKE_TMUX_AGENT"; exit 0; } ;;
        *pane_tty*) [ -z "${FM_FAKE_TMUX_AGENT:-}" ] || { printf '\n'; exit 0; } ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && [ -f "$FM_FAKE_TMUX_CAPTURE" ]; then
      cat "$FM_FAKE_TMUX_CAPTURE"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] || printf 'fm-t1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "'$state/t1.inbox'/*.msg" "doorbell should quote and name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "'$state/t1.inbox'/handled/" "doorbell should quote and name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

# The doorbell may land in a pane whose agent has exited, where it is a shell
# command line. Execute the real line in real shells and assert it is inert:
# exit 0, no output, and nothing in the inbox touched.
test_doorbell_is_a_shell_noop() {
  local state rec doorbell sh out before after marker
  state="$TMP_ROOT/noop/x; touch marker; #'s space/state"
  marker="$state/marker"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  case "$doorbell" in
    ': '*) ;;
    *) fail "the doorbell must start with the shell no-op prefix, got: $doorbell" ;;
  esac
  assert_contains "$doorbell" "'\\''s space/state/t1.inbox'" \
    "the doorbell should escape an embedded single quote in its quoted path"
  before=$(ls -R "$state/t1.inbox")
  for sh in sh bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out=$(cd "$state" && "$sh" -c "$doorbell" 2>&1) \
      || fail "$sh executed the hostile-path doorbell with a non-zero status: $out"
    [ -z "$out" ] || fail "$sh produced output while executing the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "$sh executed shell syntax embedded in the inbox path"
  done
  # An interactive-style zsh with the line fed on stdin, the closest portable
  # stand-in for a dead pane's login shell reading typed keystrokes.
  if command -v zsh >/dev/null 2>&1; then
    out=$(cd "$state" && printf '%s\n' "$doorbell" | zsh -s 2>&1) \
      || fail "zsh reading the hostile-path doorbell from stdin failed: $out"
    [ -z "$out" ] || fail "zsh printed while reading the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "zsh executed shell syntax from the stdin doorbell"
  fi
  after=$(ls -R "$state/t1.inbox")
  [ "$before" = "$after" ] || fail "executing the doorbell changed the inbox:"$'\n'"$after"
  [ -f "$rec" ] || fail "executing the doorbell removed the unhandled record"
  pass "inbox: a hostile-path doorbell executes as a no-op in bare shells"
}

test_doorbell_rejects_terminal_controls() {
  local dir state rec doorbell control label log marker rc
  dir="$TMP_ROOT/control-path"
  marker="$dir/marker"
  mkdir -p "$dir"
  make_watch_stubs "$dir" >/dev/null
  for label in etx esc; do
    case "$label" in
      etx) control=$'\003' ;;
      esc) control=$'\033' ;;
    esac
    state="$dir/${control}touch marker; # $label/state"
    mkdir -p "$state"
    rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
    doorbell=
    rc=0
    doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec") || rc=$?
    [ "$rc" -ne 0 ] || fail "a $label path should make doorbell construction fail"
    [ -z "$doorbell" ] || fail "a rejected $label path emitted doorbell bytes"
    log="$dir/$label.send.log"; : > "$log"
    rc=0
    PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" \
      inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
    [ "$rc" = 2 ] || fail "a rejected $label path should return send-failed status 2, got $rc"
    [ ! -s "$log" ] || fail "a $label path reached send-keys:"$'\n'"$(cat "$log")"
    [ ! -e "$marker" ] || fail "a $label path executed its crafted command"
    [ -f "$rec" ] || fail "rejecting a $label path removed the durable record"
  done
  pass "inbox: terminal-control paths are rejected without typing"
}

# fm_task_inbox_ring against a backend whose agent classifies dead or missing:
# nothing is typed and the distinct return code lets callers route to recovery.
# An unreadable endpoint still rings, so a blind classifier never starves a
# live worker.
test_ring_skips_dead_agent() {
  local dir state rec log rc
  dir="$TMP_ROOT/ring-dead"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  log="$dir/send.log"; : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=zsh \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a dead agent should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping the ring must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_MISSING=1 \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 3 ] || fail "a missing endpoint should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a missing endpoint was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping a missing endpoint must leave the durable record in place"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" FM_FAKE_TMUX_AGENT=claude \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "a live agent should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "a live agent did not receive the doorbell"
  : > "$log"
  rc=0
  PATH="$dir/fakebin:$PATH" FM_SEND_LOG="$log" \
    inbox_lib "$state" fm_task_inbox_ring tmux sess:fm-t1 "$rec" fm-t1 || rc=$?
  [ "$rc" = 0 ] || fail "an endpoint the classifier cannot see should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "an unclassifiable endpoint did not receive the doorbell"
  pass "inbox: the ring skips dead or missing endpoints and still rings live or unclassifiable endpoints"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 r5 r6 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # Only an unhandled duplicate converges. Once the worker took the record,
  # repeating the body is a new instruction and gets the next sequence.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/003.msg" ] \
    || fail "a re-run after an acknowledged steer should create a new record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "a distinct post-take instruction should enqueue, found $count unhandled records"
  # A resend-recovery caller opts into handled dedup: the same body after the
  # take converges on the taken record and writes nothing.
  r5=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed' "" 1)     || fail "idempotent resend with handled dedup failed"
  [ "$r5" = "$state/t1.inbox/002.msg" ] || fail "handled-dedup resend of an unhandled body should reuse it, got $r5"
  mv "$r3" "$state/t1.inbox/handled/"
  r6=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed' "" 1) \
    || fail "idempotent resend after take failed"
  [ "$r6" = "$state/t1.inbox/handled/002.msg" ] || fail "handled-dedup resend after take should reuse the taken record, got $r6"
  [ ! -e "$state/t1.inbox/004.msg" ] && [ ! -e "$state/t1.inbox/005.msg" ] \
    || fail "handled-dedup resend after take must not write a new record"
  pass "inbox: the idempotent enqueue dedups only an exact still-unhandled re-run"
}

test_take_preserves_unread_before_invocation() {
  local state rec out
  state="$TMP_ROOT/take-crash-before/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "survives before take")
  out="$TMP_ROOT/take-crash-before/out"
  if "$ROOT/bin/fm-inbox-take.sh" "$state/missing.inbox" > "$out" 2>/dev/null; then
    fail "taking an absent inbox should not succeed"
  fi
  [ -f "$rec" ] || fail "a pre-take crash simulation moved the unread record"
  [ ! -e "$state/t1.inbox/handled/001.msg" ] \
    || fail "a pre-take crash simulation acknowledged the record"
  pass "inbox take: a crash before take leaves the message unread"
}

test_take_recovers_a_taker_killed_after_claim() {
  local state rec fakebin out rc real_mv
  state="$TMP_ROOT/take-crash-after-claim/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "survives a dead taker")
  fakebin="$TMP_ROOT/take-crash-after-claim/fakebin"; mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
destination=${!#}
if [[ "$destination" == */claimed/* ]]; then
  "$FM_REAL_MV" "$@"
  kill -KILL "$PPID"
  exit 99
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"
  out="$TMP_ROOT/take-crash-after-claim/out"
  rc=0
  PATH="$fakebin:$PATH" FM_REAL_MV="$real_mv" "$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox" > "$out" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "fault injection should kill the taker after its claim"
  [ ! -e "$rec" ] || fail "the claimed record remained in the inbox after the injected crash"
  find "$state/t1.inbox/claimed" -name 001.msg -type f | grep -q . \
    || fail "the injected crash did not leave a recoverable claim"
  out=$("$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox") \
    || fail "the next taker did not recover the abandoned claim"
  [ "$out" = "survives a dead taker" ] || fail "recovered take returned the wrong body: $out"
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || fail "the recovered take did not complete the original record"
  [ ! -e "$rec" ] || fail "the recovered take left the record pending"
  pass "inbox take: a taker killed after claim is recovered and replayed"
}

test_take_recovers_an_expired_live_claim() {
  local state rec claim out identity
  state="$TMP_ROOT/take-expired-claim/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "expired claimant replay")
  identity=$(inbox_lib "$state" fm_task_inbox_process_identity "$$")
  claim="$state/t1.inbox/claimed/$$-$identity-0-1"
  mkdir -p "$claim"
  mv "$rec" "$claim/001.msg"
  out=$(FM_TASK_INBOX_CLAIM_MAX_SECS=0 "$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox") \
    || fail "the next taker did not reclaim an expired live claim"
  [ "$out" = "expired claimant replay" ] || fail "expired claim returned the wrong body: $out"
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || fail "the expired claim was not completed after replay"
  pass "inbox take: an expired claim replays even while its tagged process lives"
}

test_watcher_rerings_an_abandoned_claim() {
  local dir state out log pid rec claim i=0
  dir=$(setup_watch_case abandoned-claim)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "claimed then abandoned")
  claim="$state/t1.inbox/claimed/99999999-1-1-1"
  mkdir -p "$claim"
  mv "$rec" "$claim/001.msg"
  age_path "$claim/001.msg"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  grep -qF 'Firstmate instruction waiting' "$log" \
    || fail "the watcher never re-rang for a dead taker's abandoned claim:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "the abandoned claim was not returned to the inbox"
  [ ! -d "$claim" ] || fail "the emptied claimant directory was not removed"
  pass "watcher: an abandoned claim returns to the inbox and is re-rung"
}

test_idempotent_write_dedups_claimed_record() {
  local state rec claim r2 count identity
  state="$TMP_ROOT/idem-claimed/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "in flight body")
  identity=$(inbox_lib "$state" fm_task_inbox_process_identity "$$")
  claim=$(inbox_lib "$state" fm_task_inbox_claim "$state/t1.inbox" "$$-$identity-$(date +%s)-1") \
    || fail "claim failed"
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "in flight body") \
    || fail "resend during claim failed"
  [ "$r2" = "$claim" ] || fail "resend of a claimed body should reuse the claim, got $r2"
  count=$(find "$state/t1.inbox" -name '*.msg' -not -path '*/handled/*' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "resend of a claimed body enqueued a duplicate, found $count records"
  pass "inbox: an identical resend of a claimed record does not enqueue a duplicate"
}

test_recovery_removes_empty_dead_claimant_dir() {
  local state dir
  state="$TMP_ROOT/empty-claimant/state"; mkdir -p "$state"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "x" >/dev/null
  dir="$state/t1.inbox/claimed/99999999-1-1-1"
  mkdir -p "$dir"
  inbox_lib "$state" fm_task_inbox_recover_claims "$state/t1.inbox"
  [ ! -d "$dir" ] || fail "recovery left an empty dead claimant directory"
  pass "inbox: recovery removes an empty dead claimant directory"
}

test_recovery_during_sequence_scan_never_overwrites() {
  local state dir claim scan release recovered writer recovery count
  state="$TMP_ROOT/recover-allocation-race/state"; mkdir -p "$state"
  dir="$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "ORIGINAL-INSTRUCTION" >/dev/null
  claim="$dir/claimed/99999999-1-1-1"
  mkdir -p "$claim"
  mv "$dir/001.msg" "$claim/001.msg"
  scan="$TMP_ROOT/recover-allocation-race/scanned"
  release="$TMP_ROOT/recover-allocation-race/release"
  recovered="$TMP_ROOT/recover-allocation-race/recovered"
  FM_SCAN_MARKER="$scan" FM_SCAN_RELEASE="$release" bash -c '
    . "$1"
    fm_task_inbox_next_seq() {
      local dir=$1 max=0 d f n
      for f in "$dir"/*.msg; do
        [ -e "$f" ] || continue
        n=$(fm_task_inbox_seq_of "${f##*/}") || continue
        [ "$n" -le "$max" ] || max=$n
      done
      : > "$FM_SCAN_MARKER"
      while [ ! -e "$FM_SCAN_RELEASE" ]; do sleep 0.01; done
      for d in "$dir/handled" "$dir/claimed"/*; do
        [ -d "$d" ] || continue
        for f in "$d"/*.msg; do
          [ -e "$f" ] || continue
          n=$(fm_task_inbox_seq_of "${f##*/}") || continue
          [ "$n" -le "$max" ] || max=$n
        done
      done
      printf "%03d" "$((max + 1))"
    }
    fm_task_inbox_write "$2" t1 "GENUINELY-NEW-INSTRUCTION"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" >/dev/null & writer=$!
  while [ ! -e "$scan" ]; do sleep 0.01; done
  (inbox_lib "$state" fm_task_inbox_recover_claims "$dir" && : > "$recovered") & recovery=$!
  sleep 0.2
  : > "$release"
  wait "$writer" || fail "writer failed during recovery race"
  wait "$recovery" || fail "recovery failed during allocation race"
  count=$(find "$dir" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "recovery during allocation lost a record; found $count"
  grep -rqF "ORIGINAL-INSTRUCTION" "$dir" || fail "recovery during allocation overwrote the original instruction"
  grep -rqF "GENUINELY-NEW-INSTRUCTION" "$dir" || fail "recovery during allocation lost the new instruction"
  pass "inbox: recovery and allocation serialize without overwriting an instruction"
}

test_writer_retries_a_sequence_destination_collision() {
  local state dir source result count
  state="$TMP_ROOT/sequence-destination-collision/state"; mkdir -p "$state"
  dir="$state/t1.inbox"
  mkdir -p "$dir/handled"
  source="$TMP_ROOT/sequence-destination-collision/existing.msg"
  printf 'schema=fm-task-inbox.v1\nat=2026-09-19T00:00:00Z\n--\nEXISTING-INSTRUCTION' > "$source"
  result=$(FM_COLLISION_SOURCE="$source" FM_COLLISION_MARKER="$source.used" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_next_seq | sed "1s/fm_task_inbox_next_seq/_original_fm_task_inbox_next_seq/")"
    fm_task_inbox_next_seq() {
      if [ ! -e "$FM_COLLISION_MARKER" ]; then
        cp "$FM_COLLISION_SOURCE" "$1/001.msg"
        : > "$FM_COLLISION_MARKER"
        printf 001
      else
        _original_fm_task_inbox_next_seq "$1"
      fi
    }
    fm_task_inbox_write "$2" t1 "NEW-INSTRUCTION"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state") \
    || fail "writer did not retry a sequence destination collision"
  [ "$result" = "$dir/002.msg" ] || fail "writer did not allocate a new sequence after collision: $result"
  grep -qF 'EXISTING-INSTRUCTION' "$dir/001.msg" || fail "writer overwrote an occupied sequence destination"
  grep -qF 'NEW-INSTRUCTION' "$dir/002.msg" || fail "writer lost the new instruction while retrying allocation"
  count=$(find "$dir" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "sequence collision retry should preserve two records, found $count"
  pass "inbox: allocation refuses an occupied destination and retries with a new sequence"
}

test_dedup_restarts_after_recovery_and_reclaim() {
  local state dir claim compared release relocated writer mover count result i
  state="$TMP_ROOT/dedup-relocation-race/state"; mkdir -p "$state"
  dir="$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "SAME-INSTRUCTION" >/dev/null
  claim="$dir/claimed/99999999-1-1-1"
  mkdir -p "$claim"
  mv "$dir/001.msg" "$claim/001.msg"
  compared="$TMP_ROOT/dedup-relocation-race/compared"
  release="$TMP_ROOT/dedup-relocation-race/release"
  relocated="$TMP_ROOT/dedup-relocation-race/relocated"
  result="$TMP_ROOT/dedup-relocation-race/result"
  FM_COMPARE_MARKER="$compared" FM_COMPARE_RELEASE="$release" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      _original_fm_task_inbox_body "$1" || return 1
      case "$1" in
        */claimed/*)
          : > "$FM_COMPARE_MARKER"
          while [ ! -e "$FM_COMPARE_RELEASE" ]; do sleep 0.01; done ;;
      esac
    }
    fm_task_inbox_write_idempotent "$2" t1 "SAME-INSTRUCTION"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" > "$result" & writer=$!
  while [ ! -e "$compared" ]; do sleep 0.01; done
  (
    inbox_lib "$state" fm_task_inbox_recover_claims "$dir"
    inbox_lib "$state" fm_task_inbox_claim "$dir" "$$-1-1-2" >/dev/null
    : > "$relocated"
  ) & mover=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$relocated" ]; do sleep 0.01; i=$((i + 1)); done
  : > "$release"
  wait "$writer" || fail "idempotent resend failed during relocation race"
  wait "$mover" || fail "recovery and re-claim failed during dedup race"
  count=$(find "$dir" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "recovery plus re-claim duplicated an identical resend; found $count"
  [ -s "$result" ] || fail "dedup relocation race did not return the standing record"
  pass "inbox: dedup follows recovery plus re-claim without creating a duplicate"
}

test_recovery_checks_process_start_identity_and_reports_malformed_claimants() {
  local state dir claim identity err
  state="$TMP_ROOT/claimant-identity/state"; mkdir -p "$state"
  dir="$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_write "$state" t1 "reused pid claim" >/dev/null
  identity=$(inbox_lib "$state" fm_task_inbox_process_identity "$$") \
    || fail "could not read the live test process identity"
  claim="$dir/claimed/$$-$((identity + 1))-1-1"
  mkdir -p "$claim"
  mv "$dir/001.msg" "$claim/001.msg"
  mkdir -p "$dir/claimed/not-a-claimant"
  err="$TMP_ROOT/claimant-identity/recovery.err"
  inbox_lib "$state" fm_task_inbox_recover_claims "$dir" 2> "$err" \
    || fail "claim recovery failed while reporting malformed state"
  [ -f "$dir/001.msg" ] || fail "a live reused PID with the wrong start identity kept a dead claim"
  grep -qF "malformed claimant directory" "$err" \
    || fail "recovery silently skipped a malformed claimant directory"
  pass "inbox: recovery binds claims to process start identity and reports malformed claimant directories"
}

test_take_uses_lowest_sequence() {
  local state first second out
  state="$TMP_ROOT/take-order/state"; mkdir -p "$state"
  first=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first instruction")
  second=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second instruction")
  out=$("$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox") \
    || fail "taking the next instruction failed"
  [ "$out" = "first instruction" ] || fail "take did not return the lowest record body: $out"
  [ -f "$state/t1.inbox/handled/001.msg" ] && [ -f "$second" ] \
    || fail "take did not move only the lowest record"
  [ ! -e "$first" ] || fail "take left the lowest record unread"
  pass "inbox take: the lowest unhandled record is moved before its body is returned"
}

test_concurrent_takes_move_once() {
  local state first p1 p2 out1 out2 successes body
  state="$TMP_ROOT/take-race/state"; mkdir -p "$state"
  first=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "only instruction")
  out1="$TMP_ROOT/take-race/one.out"
  out2="$TMP_ROOT/take-race/two.out"
  "$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox" > "$out1" 2>/dev/null & p1=$!
  "$ROOT/bin/fm-inbox-take.sh" "$state/t1.inbox" > "$out2" 2>/dev/null & p2=$!
  wait "$p1" || true
  wait "$p2" || true
  successes=0
  for body in "$(cat "$out1")" "$(cat "$out2")"; do
    [ -z "$body" ] || successes=$((successes + 1))
  done
  [ "$successes" = 1 ] || fail "only one concurrent taker may receive a single record, got $successes bodies"
  [ ! -e "$first" ] || fail "the winning take left the record unread"
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || fail "the winning take did not move the record exactly once"
  [ "$(find "$state/t1.inbox/handled" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "concurrent takes produced duplicate handled records"
  pass "inbox take: concurrent takers atomically move each record exactly once"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently taken record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a duplicate racing its take should not create another record"
  pass "inbox: an enqueue racing a take follows the record already acknowledged"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
}

test_writer_retries_after_a_vanished_lock_collision() {
  local state fakebin marker rec real_ln
  state="$TMP_ROOT/vanished-lock-race/state"
  fakebin="$TMP_ROOT/vanished-lock-race/fakebin"
  marker="$TMP_ROOT/vanished-lock-race/first-ln-failed"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_FAKE_LN_MARKER" ]; then
  : > "$FM_FAKE_LN_MARKER"
  exit 1
fi
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_FAKE_LN_MARKER="$marker" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after collision") \
    || fail "a writer abandoned an acquisition whose competing lock had already vanished"
  [ -f "$rec" ] || fail "the retry after a vanished lock collision did not write its record"
  pass "inbox: a writer retries when a competing lock vanishes after its failed claim"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

# report.md section 1b: escalation keyed only to the oldest record stays
# quiet forever once that head is stuck, even as newer messages pile up.
test_escalation_rekeys_to_unhandled_count_not_just_oldest() {
  local state rec1 rec2 action
  state="$TMP_ROOT/queue-depth/state"; mkdir -p "$state"
  rec1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "stuck head")
  age_path "$rec1"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec1 3" ] || fail "a spent ring budget should escalate, got: $action"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec1"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an unchanged queue behind an escalated head should stay quiet, got: $action"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "piled up behind it")
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec1 3" ] \
    || fail "a newer message behind the same stuck head should re-escalate, got: $action"
  [ -f "$rec2" ] || fail "the new message must stay durable while the head is still stuck"
  pass "inbox: escalation re-fires when the unhandled queue grows behind the same stuck oldest"
}

# The pre-fix marker format was just the base name, no count: it must still
# parse (as count=0), so an already-escalated lane re-escalates once on its
# first poll under the fix rather than staying silently quiet forever.
test_legacy_escalated_marker_format_migrates_forward() {
  local state rec action
  state="$TMP_ROOT/queue-depth-legacy/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "stuck head")
  age_path "$rec"
  printf '001.msg\n' > "$state/t1.inbox/.escalated"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 0" ] \
    || fail "a legacy no-count escalated marker should re-escalate once under the fix, got: $action"
  pass "inbox: a legacy single-field .escalated marker parses as count=0 and re-escalates once"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  fm_write_meta "$dir/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  printf '%s\n' "$dir"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "fm-inbox-take.sh' '$state/t1.inbox'" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the atomic-take doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

test_watcher_dead_pane_escalates_once_without_ringing() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_TMUX_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never surfaced a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a dead pane should surface exactly one stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "agent has exited" "$state/.wake-queue" \
    || fail "the stale wake should say the agent has exited:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF "$rec" "$state/.wake-queue" || fail "the stale wake should name the record path"
  [ -f "$rec" ] || fail "the durable record must survive for recovery"
  [ "$(cut -f1 "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "the escalation marker should suppress further surfacing of this record"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "a dead pane must not enter the re-ring ladder"
  # The ladder is capped: nothing further is due for this record, so no later
  # poll rings the dead pane or queues a second wake.
  [ "$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = quiet ] \
    || fail "a dead pane already surfaced must be quiet on later polls"
  pass "watcher: a positively dead pane is never typed into and surfaces exactly one stale wake"
}

test_watcher_dead_pane_ignores_stale_busy_state() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane-busy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  printf 'some output\nBUSYTOKEN active\n' > "$dir/busy.capture"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$dir/busy.capture" \
    FM_FAKE_TMUX_AGENT=zsh FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "stale busy state hid a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a busy-marked dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a busy-marked dead pane should surface exactly once:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ -f "$rec" ] || fail "the durable record must survive stale busy-state recovery"
  [ "$(cut -f1 "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "stale busy-state recovery should suppress repeated surfacing"
  pass "watcher: dead-pane recovery overrides stale busy state"
}

# The stopped marker, not agent death, is the lever. A dead pane without it
# still wakes (test_watcher_dead_pane_escalates_once_without_ringing); the
# same unhandled record with state/<id>.stopped must not.
test_watcher_stopped_lane_dead_pane_never_wakes() {
  local dir state out log pid rec
  dir=$(setup_watch_case stopped-dead)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  printf 'stopped\n' > "$state/t1.stopped"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_TMUX_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null \
    || fail "a stopped lane's unhandled record woke supervision:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a stopped lane was typed into:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a stopped lane queued an inbox stale wake:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "suppressing the wake must leave the durable record in place"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "a stopped lane must not enter the escalation ladder"
  pass "watcher: a stopped lane's unhandled record produces no inbox stale wake, even when the agent is dead"
}

# Quiet without the marker still rings (test_watcher_rerings_idle_pane_quietly).
# The marker alone must suppress the wake on an idle pane too, so a merely
# quiet or unreachable lane is not weakened.
test_watcher_stopped_lane_idle_pane_never_wakes() {
  local dir state out log pid rec
  dir=$(setup_watch_case stopped-idle)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  printf 'stopped\n' > "$state/t1.stopped"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null \
    || fail "a stopped idle lane's unhandled record woke supervision:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a stopped idle lane was typed into:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a stopped idle lane queued an inbox stale wake:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "suppressing the wake must leave the durable record in place"
  pass "watcher: a stopped lane produces no inbox stale wake on an idle pane either"
}

test_write_is_durable_and_exact
test_doorbell_is_a_shell_noop
test_doorbell_rejects_terminal_controls
test_ring_skips_dead_agent
test_idempotent_write_dedups_exact_body
test_take_preserves_unread_before_invocation
test_take_recovers_a_taker_killed_after_claim
test_take_recovers_an_expired_live_claim
test_watcher_rerings_an_abandoned_claim
test_idempotent_write_dedups_claimed_record
test_recovery_removes_empty_dead_claimant_dir
test_recovery_during_sequence_scan_never_overwrites
test_writer_retries_a_sequence_destination_collision
test_dedup_restarts_after_recovery_and_reclaim
test_recovery_checks_process_start_identity_and_reports_malformed_claimants
test_take_uses_lowest_sequence
test_concurrent_takes_move_once
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_writer_retries_after_a_vanished_lock_collision
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_escalation_rekeys_to_unhandled_count_not_just_oldest
test_legacy_escalated_marker_format_migrates_forward
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_dead_pane_escalates_once_without_ringing
test_watcher_dead_pane_ignores_stale_busy_state
test_watcher_stopped_lane_dead_pane_never_wakes
test_watcher_stopped_lane_idle_pane_never_wakes
