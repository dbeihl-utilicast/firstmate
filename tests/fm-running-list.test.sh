#!/usr/bin/env bash
# Behavior tests for the read-only running-list view over fm-bearings-snapshot.sh.
# Exercises grouping through the public command, not by reading its source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIST="$ROOT/bin/fm-running-list.sh"
TMP_ROOT=$(fm_test_tmproot fm-running-list)
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

NOW=2026-09-14T12:00:00Z

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
exit 1
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic_state=$3 gen event
  case "$semantic_state" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported semantic fixture state: $semantic_state" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic_state" --gen "$gen" \
    --source claude-hook --event "$event"
}

run_list() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_BEARINGS_NOW="$NOW" FM_SNAPSHOT_NOW="$NOW" \
    "$LIST" "$@"
}

write_open_work_fixture() {  # <home>
  local home=$1 missing
  missing="$TMP_ROOT/missing-mate-home"
  mkdir -p "$home/projects/ship-wt" "$home/projects/paused-wt"
  printf -- '- missing-mate - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' \
    "$missing" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: sample) (kind: ship) (since 2026-09-12)
- [ ] paused-task - Wait on counsel (repo: sample) (kind: ship) (since 2026-09-10)
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-09-13)
- [ ] qwen-process - Idle qwen copy (repo: sample) (kind: ship) (since 2026-09-01)
- [ ] watch-ssh - Idle watch copy (repo: sample) (kind: ship) (since 2026-09-01)

## Queued
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-09-13)
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-08-01)
- [ ] blocked-work - Real queued work blocked-by: ship-task (repo: sample) (kind: ship)
- [ ] observation - Held observation (repo: sample) (kind: scout) (hold: waiting on Jane at legal) (hold-kind: external)
- [ ] abandoned-issue - Still reading as a to-do (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] vault-note - Vault note with nobody tracking it (repo: sample) (kind: ship)

## Done
- [x] done-task - Done Task (repo: sample) (kind: ship) (merged 2026-09-01)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" "worktree=$home/projects/ship-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" ship-task busy
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/paused-task.meta" \
    "window=firstmate:fm-paused-task" "worktree=$home/projects/paused-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" paused-task idle
  printf 'paused: waiting on Jane at counsel\n' > "$home/state/paused-task.status"
  fm_write_meta "$home/state/working-held.meta" \
    "window=firstmate:fm-working-held" "worktree=$home/projects/ship-wt" \
    "project=sample" "harness=claude" "kind=captain" "mode=ship"
  record_claude_state "$home/state" working-held busy
  printf 'working: still held for a route choice\n' > "$home/state/working-held.status"
  fm_write_meta "$home/state/qwen-process.meta" \
    "window=firstmate:fm-qwen-process" "worktree=$home/projects/missing-qwen" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  printf 'done: leftover idle copy\n' > "$home/state/qwen-process.status"
  fm_write_meta "$home/state/watch-ssh.meta" \
    "window=firstmate:fm-watch-ssh" "worktree=$home/projects/missing-watch" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  printf 'done: leftover idle copy\n' > "$home/state/watch-ssh.status"
}

test_help_and_bad_flag() {
  local out rc
  out=$("$LIST" --help) || fail "help should exit 0"
  assert_contains "$out" "fm-running-list.sh" "help should name the command"
  rc=0
  "$LIST" --nope >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || fail "unknown flag should exit 2, got $rc"
  pass "help and unknown-flag usage"
}

test_groups_open_work_and_names_unreadables() {
  local home fakebin json human
  home=$(make_home groups)
  write_open_work_fixture "$home"
  fakebin=$(make_fakebin "$home")
  NET_LOG="$home/net.log"
  export NET_LOG
  : > "$NET_LOG"
  json=$(run_list "$home" "$fakebin" --json) || fail "running list failed: $json"
  printf '%s' "$json" | jq -e '.schema == "fm-running-list.v1"' >/dev/null \
    || fail "schema missing: $json"
  printf '%s' "$json" | jq -e '
    .nothing_brings_them_back == 4
      and (.rotting | map(.id) | sort) == ["abandoned-issue", "qwen-process", "vault-note", "watch-ssh"]
      and (.waiting_on_you | map(.id) | sort) == ["aged-hold", "dated-hold", "live-hold", "working-held"]
      and (.waiting_on_you | map(select(.id == "working-held")) | length) == 1
      and (.moving | map(.id) | index("working-held") == null)
      and (.waiting_on_date | length) == 0
      and (.waiting_on_you[] | select(.id == "dated-hold") | .wait) == "until 2026-12-01"
      and (.blocked | map(.id)) == ["blocked-work"]
      and (.blocked[] | select(.id == "blocked-work") | .wait) == "ship-task"
      and (.waiting_on_outside | map(.id) | sort) == ["observation", "paused-task"]
      and (.moving | map(.id)) == ["ship-task"]
      and (.moving | map(.id) | index("qwen-process") == null)
      and (.moving | map(.id) | index("watch-ssh") == null)
      and (.unreadables | map(.id)) == ["missing-mate"]
      and (.waiting_on_you | any(.id == "aged-hold" and .age_days != null))
      and ([.rotting[], .waiting_on_you[], .waiting_on_outside[], .blocked[],
            .waiting_on_date[], .moving[]] | map(.id) | unique | length)
          == ([.rotting[], .waiting_on_you[], .waiting_on_outside[], .blocked[],
               .waiting_on_date[], .moving[]] | map(.id) | length)
  ' >/dev/null || fail "open-work grouping wrong: $json"
  human=$(run_list "$home" "$fakebin") || fail "human running list failed"
  assert_contains "$human" "4 with nothing that will bring them back" \
    "rotting count should lead the human view"
  assert_contains "$human" "abandoned-issue" "rotting rows should be listed"
  assert_contains "$human" "Waiting on you (4)" "captain holds should be grouped"
  assert_contains "$human" "until 2026-12-01" "dated captain holds should show the way-back date"
  assert_contains "$human" "Waiting on someone outside (2)" "named outside waiters should be grouped"
  assert_contains "$human" "Blocked on other work (1)" "blockers should be grouped"
  assert_contains "$human" "Waiting on a date (0)" "dated captain holds are not waiting on a date"
  assert_contains "$human" "Moving (1)" "live work should be grouped"
  assert_not_contains "$human" "Moving (3)" "idle copies must not inflate Moving"
  assert_contains "$human" "Homes that could not be read: missing-mate" \
    "unreadable homes should be named"
  assert_contains "$human" "Snapshot cannot supply:" "missing snapshot fields should be named"
  [ ! -s "$NET_LOG" ] || fail "running list made a GitHub call: $(cat "$NET_LOG")"
  pass "groups open work, names unreadables, and stays off the network"
}

test_empty_fleet_still_prints_groups() {
  local home fakebin json human
  home=$(make_home empty)
  fakebin=$(make_fakebin "$home")
  json=$(run_list "$home" "$fakebin" --json) || fail "empty list failed"
  printf '%s' "$json" | jq -e '
    .nothing_brings_them_back == 0
      and (.rotting | length) == 0
      and (.waiting_on_you | length) == 0
      and (.moving | length) == 0
      and (.unreadables | length) == 0
  ' >/dev/null || fail "empty model wrong: $json"
  human=$(run_list "$home" "$fakebin") || fail "empty human list failed"
  assert_contains "$human" "0 with nothing that will bring them back" \
    "empty rotting count should still print"
  assert_contains "$human" "Waiting on you (0)" "empty groups should still print"
  assert_contains "$human" "Moving (0)" "empty moving group should still print"
  assert_not_contains "$human" "Homes that could not be read:" \
    "empty fleet should not invent unreadable homes"
  pass "empty fleet still prints every group"
}

test_does_not_mutate_backlog_or_holds() {
  local home fakebin before after files_before files_after
  home=$(make_home readonly)
  write_open_work_fixture "$home"
  fakebin=$(make_fakebin "$home")
  before=$(cksum "$home/data/backlog.md")
  files_before=$(find "$home/data" "$home/state" -type f ! -path '*/secondmate-summary-cache/*' \
    | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
  run_list "$home" "$fakebin" >/dev/null || fail "readonly run failed"
  after=$(cksum "$home/data/backlog.md")
  [ "$before" = "$after" ] || fail "running list mutated data/backlog.md"
  files_after=$(find "$home/data" "$home/state" -type f ! -path '*/secondmate-summary-cache/*' \
    | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
  [ "$files_before" = "$files_after" ] \
    || fail "running list changed task or backlog files besides the snapshot cache"
  pass "running list does not mutate backlog or holds"
}

test_done_rows_stay_off_the_list() {
  local home fakebin json
  home=$(make_home done-only)
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
- [x] done-task - Done Task (repo: sample) (kind: ship) (merged 2026-09-01)
EOF
  json=$(run_list "$home" "$fakebin" --json) || fail "done-only list failed"
  printf '%s' "$json" | jq -e '
    ([.rotting[], .waiting_on_you[], .waiting_on_outside[], .blocked[],
      .waiting_on_date[], .moving[]] | map(.id) | index("done-task") == null)
      and .nothing_brings_them_back == 0
  ' >/dev/null || fail "done row leaked onto the open list: $json"
  pass "done rows stay off the open list"
}

test_help_and_bad_flag
test_groups_open_work_and_names_unreadables
test_empty_fleet_still_prints_groups
test_does_not_mutate_backlog_or_holds
test_done_rows_stay_off_the_list
