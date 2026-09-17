#!/usr/bin/env bash
# tests/fm-send-destination.test.sh - fm-send refuses a steer that names
# another task's backlog row or recorded PR in this home.
#
# A text steer to a recorded task selector is the data plane. When its body
# names a specific backlog row or a PR this home already records on a different
# task, sending it anyway is a silent misroute. These tests drive the real
# fm-send executable over a stubbed tmux and pin:
#   1. RED: a steer to lane-a that names other-ship-task (a row in this home's
#      backlog) is refused before enqueue, with no inbox record.
#   2. The same named row sent to other-ship-task itself still delivers.
#   3. A steer that names nothing backlog-specific (ordinary instruction,
#      a number in prose, a bare #N, a hyphenated English word, an unknown
#      slug) still delivers, including fleet-wide facts.
#   4. A recorded PR URL belonging to another task is refused; the same URL
#      sent to the task that recorded it still delivers.
#   5. An unknown https URL, --key, and an explicit backend target stay on
#      today's path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-destination)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

FOREIGN_ID=other-ship-task
FOREIGN_PR='https://github.com/example/firstmate/pull/42'
UNKNOWN_PR='https://github.com/example/firstmate/pull/99'

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
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
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  list-panes)
    printf 'fakepane\n'; exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
  list-windows) printf 'fm-lane-a\nfm-other-ship-task\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

write_backlog() {  # <home> [extra-id]
  local home=$1 extra=${2:-}
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<EOF
## In flight

- [ ] lane-a - Destination lane (repo: firstmate) (kind: ship)

## Queued

- [ ] $FOREIGN_ID - The other ship work (repo: firstmate) (kind: ship)
${extra:+- [ ] $extra - Extra queued row (repo: firstmate) (kind: ship)
}
## Done
EOF
}

setup_case() {  # <name> [with-foreign-meta] -> echoes case dir
  local name=$1 with_foreign=${2:-0} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  write_backlog "$dir/home"
  fm_write_meta "$dir/home/state/lane-a.meta" \
    "window=sess:fm-lane-a" "kind=ship" "harness=claude"
  if [ "$with_foreign" = 1 ]; then
    fm_write_meta "$dir/home/state/$FOREIGN_ID.meta" \
      "window=sess:fm-$FOREIGN_ID" "kind=ship" "harness=claude" \
      "pr=$FOREIGN_PR"
  fi
  printf '%s\n' "$dir"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : > "$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

inbox_empty() {  # <dir> <id>
  local dir=$1 id=$2
  [ ! -e "$dir/home/state/$id.inbox" ] \
    || [ -z "$(find "$dir/home/state/$id.inbox" -name '*.msg' -print -quit 2>/dev/null)" ]
}

# 1. The red case: naming a real foreign backlog row used to deliver silently.
test_foreign_backlog_row_is_refused() {
  local dir err rc
  dir=$(setup_case foreign-row); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "Please handle $FOREIGN_ID: rebase onto main"; rc=$?
  expect_code 1 "$rc" "a steer naming a foreign backlog row must refuse"
  inbox_empty "$dir" lane-a \
    || fail "a refused misroute must not enqueue on lane-a"
  assert_contains "$(cat "$err")" "$FOREIGN_ID" \
    "the refusal should name the foreign backlog row"
  assert_contains "$(cat "$err")" "not sent" \
    "the refusal should say the steer was not sent"
  pass "fm-send destination: a steer naming a foreign backlog row is refused before enqueue"
}

test_same_row_still_delivers() {
  local dir err rc
  dir=$(setup_case same-row 1); err="$dir/send.err"
  run_send "$dir" "$err" -- "$FOREIGN_ID" "Please handle $FOREIGN_ID: rebase onto main"; rc=$?
  expect_code 0 "$rc" "a steer naming its own backlog row should still deliver"
  [ -f "$dir/home/state/$FOREIGN_ID.inbox/001.msg" ] \
    || fail "the matching destination should still get an inbox record"
  pass "fm-send destination: naming the destination's own row still delivers"
}

test_fm_prefix_form_is_refused() {
  local dir err rc
  dir=$(setup_case fm-prefix); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "Work on fm-$FOREIGN_ID next"; rc=$?
  expect_code 1 "$rc" "fm-<id> naming a foreign row must refuse"
  inbox_empty "$dir" lane-a \
    || fail "fm-<id> misroute must not enqueue"
  pass "fm-send destination: fm-<id> naming a foreign row is refused"
}

test_foreign_live_meta_without_backlog_row_is_refused() {
  local dir err rc live=onboarding-mate
  dir=$(setup_case live-meta); err="$dir/send.err"
  fm_write_meta "$dir/home/state/$live.meta" \
    "window=sess:fm-$live" "kind=secondmate" "harness=claude"
  run_send "$dir" "$err" -- lane-a "This instruction is for $live only"; rc=$?
  expect_code 1 "$rc" "naming another live task in this home must refuse"
  inbox_empty "$dir" lane-a \
    || fail "a live-meta misroute must not enqueue"
  pass "fm-send destination: naming another live task with no backlog row is refused"
}

test_unspecific_steer_still_delivers() {
  local dir err rc
  dir=$(setup_case unspecific); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "please rebase onto main"; rc=$?
  expect_code 0 "$rc" "an ordinary steer with no named row should deliver"
  [ -f "$dir/home/state/lane-a.inbox/001.msg" ] \
    || fail "the ordinary steer should still enqueue"
  pass "fm-send destination: a steer that names nothing backlog-specific still delivers"
}

test_number_and_hash_prose_still_delivers() {
  local dir err rc
  dir=$(setup_case prose-numbers); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "retry in 5 minutes, then look at item #12 and step 2"; rc=$?
  expect_code 0 "$rc" "prose numbers and bare #N must not trip the destination check"
  [ -f "$dir/home/state/lane-a.inbox/001.msg" ] \
    || fail "prose-number steer should still enqueue"
  pass "fm-send destination: numbers and bare #N in prose do not refuse"
}

test_unknown_hyphenated_word_still_delivers() {
  local dir err rc
  dir=$(setup_case unknown-slug); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "please re-read your config and use kebab-case names"; rc=$?
  expect_code 0 "$rc" "hyphenated English that is not a backlog id should deliver"
  [ -f "$dir/home/state/lane-a.inbox/001.msg" ] \
    || fail "unknown hyphenated words should still enqueue"
  pass "fm-send destination: unknown hyphenated words do not refuse"
}

test_fleet_wide_fact_still_delivers() {
  local dir err rc
  dir=$(setup_case fleet-fact); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "Firstmate instructions or inherited config changed on this host. Re-read AGENTS.md and the inherited config files before further work."; rc=$?
  expect_code 0 "$rc" "a fleet-wide config re-read should still deliver"
  [ -f "$dir/home/state/lane-a.inbox/001.msg" ] \
    || fail "fleet-wide fact should still enqueue"
  pass "fm-send destination: a fleet-wide fact with no named row still delivers"
}

test_foreign_recorded_pr_is_refused() {
  local dir err rc
  dir=$(setup_case foreign-pr 1); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "Review $FOREIGN_PR before landing"; rc=$?
  expect_code 1 "$rc" "a steer naming another task's recorded PR must refuse"
  inbox_empty "$dir" lane-a \
    || fail "a refused PR misroute must not enqueue on lane-a"
  assert_contains "$(cat "$err")" "$FOREIGN_PR" \
    "the refusal should name the foreign PR URL"
  pass "fm-send destination: a steer naming another task's recorded PR is refused"
}

test_own_recorded_pr_still_delivers() {
  local dir err rc
  dir=$(setup_case own-pr 1); err="$dir/send.err"
  run_send "$dir" "$err" -- "$FOREIGN_ID" "Review $FOREIGN_PR before landing"; rc=$?
  expect_code 0 "$rc" "a steer naming the destination's own recorded PR should deliver"
  [ -f "$dir/home/state/$FOREIGN_ID.inbox/001.msg" ] \
    || fail "the PR owner should still get an inbox record"
  pass "fm-send destination: naming the destination's own recorded PR still delivers"
}

test_unknown_pr_url_still_delivers() {
  local dir err rc
  dir=$(setup_case unknown-pr 1); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a "Someone filed $UNKNOWN_PR elsewhere"; rc=$?
  expect_code 0 "$rc" "an unknown PR URL is not this home's recorded work"
  [ -f "$dir/home/state/lane-a.inbox/001.msg" ] \
    || fail "an unknown PR URL should still enqueue"
  pass "fm-send destination: an unknown PR URL does not refuse"
}

test_key_path_skips_the_check() {
  local dir err rc
  dir=$(setup_case key-path); err="$dir/send.err"
  run_send "$dir" "$err" -- lane-a --key Enter; rc=$?
  expect_code 0 "$rc" "--key is lifecycle, not a text steer"
  inbox_empty "$dir" lane-a \
    || fail "--key must not write an inbox record"
  pass "fm-send destination: --key is unchanged"
}

test_explicit_backend_target_skips_the_check() {
  local dir err rc
  dir=$(setup_case explicit-target); err="$dir/send.err"
  # An explicit session:window names an endpoint, not a task ledger.
  run_send "$dir" "$err" -- sess:fm-lane-a "Please handle $FOREIGN_ID: rebase onto main"; rc=$?
  expect_code 0 "$rc" "an explicit backend target stays on the typed plane without a destination ledger"
  inbox_empty "$dir" lane-a \
    || fail "an explicit target must not write this home's inbox"
  pass "fm-send destination: an explicit backend target is unchanged"
}

test_foreign_backlog_row_is_refused
test_same_row_still_delivers
test_fm_prefix_form_is_refused
test_foreign_live_meta_without_backlog_row_is_refused
test_unspecific_steer_still_delivers
test_number_and_hash_prose_still_delivers
test_unknown_hyphenated_word_still_delivers
test_fleet_wide_fact_still_delivers
test_foreign_recorded_pr_is_refused
test_own_recorded_pr_still_delivers
test_unknown_pr_url_still_delivers
test_key_path_skips_the_check
test_explicit_backend_target_skips_the_check
