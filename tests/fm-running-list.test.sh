#!/usr/bin/env bash
# Behavior tests for the read-only running-list view over fm-bearings-snapshot.sh.
# Exercises grouping through the public command, not by reading its source.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIST="$ROOT/bin/fm-running-list.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
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
  list-windows)
    printf '%s\n' fm-ship-task fm-paused-task fm-working-held fm-blocked-live fm-unknown-live
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf 'claude\n' ;;
      *pane_id*)
        case "$*" in
          *fm-dead-paused*|*fm-qwen-process*|*fm-watch-ssh*) exit 1 ;;
          *) printf '%%1\n' ;;
        esac
        ;;
    esac
    ;;
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

make_secondmate_home() {  # <id> <home>
  local id=$1 home=$2
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf '# Firstmate fixture\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

register_secondmate() {  # <parent> <id> <home>
  printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

refresh_secondmate_home() {  # <home> <fakebin>
  PATH="$2:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$1" \
    FM_SNAPSHOT_NOW="$NOW" "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
    || fail "could not publish secondmate fixture ledger: $1"
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

add_remote_ledger_ssh() {  # <fakebin>
  local fb=$1
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4")
[ "${args[0]:-}" = fm-remote-file.sh ] || exit 91
[ ! -f "$remote_home/state/fail-ledger-read" ] || exit 1
cat "$remote_home/state/home-summary.json"
SH
  chmod +x "$fb/fake-ssh"
}

run_remote_list() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_BEARINGS_NOW="$NOW" FM_SNAPSHOT_NOW="$NOW" \
    FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_SNAPSHOT_CACHE_DIR="$home/state/summary-cache" \
    "$LIST" "$@"
}

write_open_work_fixture() {  # <home>
  local home=$1 missing
  missing="$TMP_ROOT/missing-mate-home"
  mkdir -p "$home/projects/ship-wt" "$home/projects/paused-wt" \
    "$home/projects/dead-paused-wt" "$home/projects/blocked-live-wt" \
    "$home/projects/unknown-live-wt"
  printf -- '- missing-mate - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' \
    "$missing" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] ship-task - Ship the thing (repo: sample) (kind: ship) (since 2026-09-12)
- [ ] paused-task - Wait on counsel (repo: sample) (kind: ship) (since 2026-09-10)
- [ ] dead-paused - Dead paused copy (repo: sample) (kind: ship) (since 2026-09-10)
- [ ] blocked-live - Blocked live work (repo: sample) (kind: ship) (since 2026-09-10)
- [ ] unknown-live - Unclear live work (repo: sample) (kind: ship) (since 2026-09-10)
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-09-13)
- [ ] qwen-process - Idle qwen copy (repo: sample) (kind: ship) (since 2026-09-01)
- [ ] watch-ssh - Idle watch copy (repo: sample) (kind: ship) (since 2026-09-01)

## Queued
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-09-13)
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain) (since 2026-08-01)
- [ ] blocked-work - Real queued work blocked-by: ship-task (repo: sample) (kind: ship)
- [ ] observation - Held observation (repo: sample) (kind: scout) (hold: waiting on Jane at legal) (hold-kind: external)
- [ ] vendor-wait - Vendor release (repo: sample) (kind: ship) (hold: until vendor ships) (hold-kind: external)
- [ ] legal-wait - Legal review (repo: sample) (kind: ship) (hold: held 20d by legal) (hold-kind: external)
- [ ] renewal-date - Renewal window (repo: sample) (kind: ship) (hold: wait for renewal) (hold-kind: external) (hold-until: 2026-12-15)
- [ ] abandoned-issue - Still reading as a to-do (repo: sample) (kind: ship) (since 2026-07-01)
- [ ] vault-note - Vault note with nobody tracking it (repo: sample) (kind: ship)

## Done
- [x] done-task - Done Task (repo: sample) (kind: ship) (merged 2026-09-01)
EOF
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" "worktree=$home/projects/ship-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" ship-task idle
  printf 'working: building the gone-away safeguard\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/paused-task.meta" \
    "window=firstmate:fm-paused-task" "worktree=$home/projects/paused-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" paused-task idle
  printf 'paused: waiting on Jane at counsel\n' > "$home/state/paused-task.status"
  fm_write_meta "$home/state/dead-paused.meta" \
    "window=firstmate:fm-dead-paused" "worktree=$home/projects/dead-paused-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" dead-paused idle
  printf 'paused: waiting on counsel\n' > "$home/state/dead-paused.status"
  fm_write_meta "$home/state/blocked-live.meta" \
    "window=firstmate:fm-blocked-live" "worktree=$home/projects/blocked-live-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$home/state" blocked-live idle
  printf 'blocked: dependency unavailable\n' > "$home/state/blocked-live.status"
  fm_write_meta "$home/state/unknown-live.meta" \
    "window=firstmate:fm-unknown-live" "worktree=$home/projects/unknown-live-wt" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
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
    .nothing_brings_them_back == 5
      and (.rotting | map(.id) | sort) == ["abandoned-issue", "dead-paused", "qwen-process", "vault-note", "watch-ssh"]
      and (.waiting_on_you | map(.id) | sort) == ["aged-hold", "dated-hold", "live-hold", "working-held"]
      and (.waiting_on_you | map(select(.id == "working-held")) | length) == 1
      and (.moving | map(.id) | index("working-held") == null)
      and (.waiting_on_date | map(.id)) == ["renewal-date"]
      and (.waiting_on_you[] | select(.id == "dated-hold") | .wait) == "until 2026-12-01"
      and (.waiting_on_date[] | select(.id == "renewal-date") | .wait) == "until 2026-12-15"
      and (.blocked | map(.id) | sort) == ["blocked-live", "blocked-work", "unknown-live"]
      and (.blocked[] | select(.id == "blocked-work") | .wait) == "ship-task"
      and (.waiting_on_outside | map(.id) | sort) == ["legal-wait", "observation", "paused-task", "vendor-wait"]
      and (.waiting_on_outside | any(.id == "vendor-wait" and .wait == "until vendor ships"))
      and (.waiting_on_outside | any(.id == "legal-wait" and .wait == "held 20d by legal"))
      and (.waiting_on_you | any(.id == "vendor-wait" or .id == "legal-wait") | not)
      and (.moving | map(.id)) == ["ship-task"]
      and (.moving | map(.id) | index("qwen-process") == null)
      and (.moving | map(.id) | index("watch-ssh") == null)
      and (.unreadables | map(.id)) == ["missing-mate"]
      and (.waiting_on_you | any(.id == "aged-hold" and .age_days != null))
      and ([.rotting[], .waiting_on_you[], .waiting_on_outside[], .blocked[],
            .waiting_on_date[], .moving[]] | map([.owner, .id]) | unique | length)
          == ([.rotting[], .waiting_on_you[], .waiting_on_outside[], .blocked[],
               .waiting_on_date[], .moving[]] | length)
  ' >/dev/null || fail "open-work grouping wrong: $json"
  human=$(run_list "$home" "$fakebin") || fail "human running list failed"
  assert_contains "$human" "5 with nothing that will bring them back" \
    "rotting count should lead the human view"
  assert_contains "$human" "abandoned-issue" "rotting rows should be listed"
  assert_contains "$human" "Waiting on you (4)" "captain holds should be grouped"
  assert_contains "$human" "until 2026-12-01" "dated captain holds should show the way-back date"
  assert_contains "$human" "Waiting on someone outside (4)" "named outside waiters should be grouped"
  assert_contains "$human" "Blocked or state unclear (3)" "blocked and unknown live state should be explicit"
  assert_contains "$human" "Waiting on a date (1)" "non-captain time gates should be grouped"
  assert_contains "$human" "Moving (1)" "live work should be grouped"
  assert_not_contains "$human" "Moving (3)" "idle copies must not inflate Moving"
  assert_contains "$human" "Homes that could not be read: missing-mate" \
    "unreadable homes should be named"
  assert_contains "$human" "Snapshot cannot supply:" "missing snapshot fields should be named"
  [ ! -s "$NET_LOG" ] || fail "running list made a GitHub call: $(cat "$NET_LOG")"
  pass "groups open work, names unreadables, and stays off the network"
}

test_empty_fleet_prints_fixed_groups() {
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
  assert_not_contains "$human" "Waiting on a date" "the empty date group should stay hidden"
  assert_not_contains "$human" "Homes that could not be read:" \
    "empty fleet should not invent unreadable homes"
  pass "empty fleet prints fixed groups and hides the empty date group"
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

test_keeps_same_local_id_from_different_homes() {
  local home mate fakebin json
  home=$(make_home colliding-ids)
  mate="$TMP_ROOT/colliding-ids-mate"
  : > "$home/data/secondmates.md"
  make_secondmate_home domain-a "$mate"
  register_secondmate "$home" domain-a "$mate"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] deploy - Main deploy (repo: sample) (kind: ship)

## Done
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] deploy - Domain deploy (repo: sample) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  refresh_secondmate_home "$mate" "$fakebin"
  json=$(run_list "$home" "$fakebin" --json) || fail "colliding-id list failed"
  printf '%s' "$json" | jq -e '
    ([.rotting[] | select(.id == "deploy")] | length) == 2
      and ([.rotting[] | select(.id == "deploy") | .owner] | sort) == ["(main)", "domain-a"]
  ' >/dev/null || fail "same local id from separate homes was deduplicated: $json"
  pass "same local task id remains visible in separate homes"
}

test_discloses_bounded_secondmate_overflow() {
  local home mate fakebin i json human
  home=$(make_home mate-overflow)
  mate="$TMP_ROOT/mate-overflow-home"
  : > "$home/data/secondmates.md"
  make_secondmate_home overflow "$mate"
  register_secondmate "$home" overflow "$mate"
  : > "$mate/data/backlog.md"
  printf '%s\n' '## In flight' '' '## Queued' >> "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 22 ]; do
    printf -- '- [ ] call-%02d - Decision %02d (repo: sample) (kind: captain) (hold: choose route %02d) (hold-kind: captain)\n' \
      "$i" "$i" "$i" >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Done' >> "$mate/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  refresh_secondmate_home "$mate" "$fakebin"
  json=$(run_list "$home" "$fakebin" --json) || fail "overflow list failed"
  printf '%s' "$json" | jq -e '
    (.waiting_on_you | length) == 20
      and (.missing | index("secondmate overflow decisions_open omitted by snapshot bound: 2") != null)
      and (.missing | index("secondmate overflow queued omitted by snapshot bound: 2") != null)
  ' >/dev/null || fail "bounded secondmate overflow was not disclosed: $json"
  human=$(run_list "$home" "$fakebin") || fail "overflow human list failed"
  assert_contains "$human" "secondmate overflow decisions_open omitted by snapshot bound: 2" \
    "decision overflow should reach the status line"
  assert_contains "$human" "secondmate overflow queued omitted by snapshot bound: 2" \
    "queued overflow should reach the status line"
  pass "bounded secondmate overflow is disclosed"
}

test_projects_bounded_secondmate_child_holds() {
  local home mate fakebin i id json
  home=$(make_home mixed-child-state)
  mate="$TMP_ROOT/mixed-child-state-home"
  : > "$home/data/secondmates.md"
  make_secondmate_home mixed "$mate"
  register_secondmate "$home" mixed "$mate"
  : > "$mate/data/backlog.md"
  printf '%s\n' '## In flight' >> "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 21 ]; do
    id=$(printf 'paused-%02d' "$i")
    mkdir -p "$mate/projects/$id"
    printf -- '- [ ] %s - Paused child %02d (repo: sample) (kind: ship)\n' \
      "$id" "$i" >> "$mate/data/backlog.md"
    fm_write_meta "$mate/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
      "project=sample" "harness=claude" "kind=ship" "mode=ship"
    record_claude_state "$mate/state" "$id" idle
    printf 'paused: waiting for dependency %02d\n' "$i" > "$mate/state/$id.status"
    i=$((i + 1))
  done
  id=zz-working
  mkdir -p "$mate/projects/$id"
  printf -- '- [ ] %s - Working child (repo: sample) (kind: ship)\n' "$id" \
    >> "$mate/data/backlog.md"
  fm_write_meta "$mate/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$mate/projects/$id" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"
  record_claude_state "$mate/state" "$id" busy
  printf 'working: progressing mixed child work\n' > "$mate/state/$id.status"
  printf '%s\n' '' '## Queued' \
    '- [ ] captain-call - Choose route (repo: sample) (kind: captain) (hold: choose route) (hold-kind: captain)' \
    '' '## Done' >> "$mate/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  refresh_secondmate_home "$mate" "$fakebin"

  json=$(run_list "$home" "$fakebin" --json) || fail "mixed child-state list failed"
  printf '%s' "$json" | jq -e '
    (.waiting_on_you | any(.id == "mixed/captain-call" and .owner == "mixed"))
      and ([.waiting_on_outside[]
            | select(.owner == "mixed" and (.id | startswith("mixed/paused-")))] | length) == 19
      and (.waiting_on_outside | any(.id == "mixed") | not)
      and (.moving | any(.id == "mixed/zz-working" and .owner == "mixed"))
      and (.missing | index("secondmate mixed holds omitted by snapshot bound: 2") != null)
      and (.missing | index("secondmate mixed endpoints omitted by snapshot bound: 2") != null)
  ' >/dev/null || fail "secondmate child-state holds were collapsed or silently bounded: $json"
  pass "secondmate child-state holds stay task-qualified with bounded gaps disclosed"
}

test_projects_secondmate_reconcile_rows() {
  local home mixed fakebin json id state
  home=$(make_home reconcile-rows)
  mixed="$TMP_ROOT/reconcile-mixed-home"
  : > "$home/data/secondmates.md"
  make_secondmate_home mixed "$mixed"
  register_secondmate "$home" mixed "$mixed"

  cat > "$mixed/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-child - Orphan child still open (repo: sample) (kind: ship)
- [ ] done-child - Done child still open (repo: sample) (kind: ship)
- [ ] failed-child - Failed child still open (repo: sample) (kind: ship)
- [ ] unknown-child - Unknown child still open (repo: sample) (kind: ship)

## Queued

## Done
EOF
  for id in done-child failed-child; do
    mkdir -p "$mixed/projects/$id"
    fm_write_meta "$mixed/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$mixed/projects/$id" \
      "project=sample" "harness=claude" "kind=ship" "mode=ship"
    record_claude_state "$mixed/state" "$id" idle
    case "$id" in
      done-child) state='done' ;;
      failed-child) state=failed ;;
    esac
    printf '%s: terminal fixture\n' "$state" > "$mixed/state/$id.status"
  done

  mkdir -p "$mixed/projects/unknown-child"
  fm_write_meta "$mixed/state/unknown-child.meta" \
    "window=firstmate:fm-unknown-child" \
    "worktree=$mixed/projects/unknown-child" \
    "project=sample" "harness=claude" "kind=ship" "mode=ship"

  fakebin=$(make_fakebin "$home")
  refresh_secondmate_home "$mixed" "$fakebin"
  json=$(run_list "$home" "$fakebin" --json) || fail "reconcile-row list failed"
  printf '%s' "$json" | jq -e '
    ([.rotting[] | select(.owner == "mixed") | .id] | sort)
        == ["mixed/done-child", "mixed/failed-child", "mixed/orphan-child"]
      and (.blocked | any(.id == "mixed/unknown-child" and .owner == "mixed"))
  ' >/dev/null || fail "secondmate reconciliation rows disappeared from the list: $json"
  pass "coexisting secondmate reconciliation failures remain visible"
}

test_places_and_labels_program_rows() {
  local home mate fakebin json human next
  home=$(make_home program-rows)
  mate="$TMP_ROOT/program-secondmate-home"
  make_secondmate_home program-mate "$mate"
  register_secondmate "$home" program-mate "$mate"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program-moving - Moving program (repo: sample) (kind: program)
- [ ] program-blocked - Blocked program blocked-by: dependency (repo: sample) (kind: program)
- [ ] program-outside - Outside program (repo: sample) (kind: program) (hold: waiting on vendor) (hold-kind: external)
- [ ] program-date - Dated program (repo: sample) (kind: program) (hold: waiting on window) (hold-kind: external) (hold-until: 2026-12-15)
- [ ] program-captain - Captain program (repo: sample) (kind: program) (hold: choose program route) (hold-kind: captain)

## Queued

## Done
EOF
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate-program-moving - Moving secondmate program (repo: sample) (kind: program)
- [ ] mate-program-bounded - Bounded secondmate program (repo: sample) (kind: program)
- [ ] mate-program-outside - Outside secondmate program (repo: sample) (kind: program) (hold: waiting on vendor) (hold-kind: external)

## Queued

## Done
EOF

  fakebin=$(make_fakebin "$home")
  FM_SNAPSHOT_SECONDMATE_CHILDREN=1 refresh_secondmate_home "$mate" "$fakebin"
  json=$(run_list "$home" "$fakebin" --json) || fail "program-row list failed"
  printf '%s' "$json" | jq -e '
    (.moving | any(.id == "program-moving" and .kind == "program"))
      and (.moving | any(.id == "program-mate/mate-program-moving" and .kind == "program"))
      and (.blocked | any(.id == "program-blocked" and .kind == "program"))
      and (.waiting_on_outside | any(.id == "program-outside" and .kind == "program"))
      and (.waiting_on_outside | any(.id == "mate-program-outside" and .owner == "program-mate" and .kind == "program"))
      and (.waiting_on_date | any(.id == "program-date" and .kind == "program"))
      and (.waiting_on_you | any(.id == "program-captain" and .kind == "program"))
      and (.rotting | any(.kind == "program") | not)
      and (.missing | index("secondmate program-mate programs omitted by snapshot bound: 1") != null)
  ' >/dev/null || fail "program rows were omitted, mislabeled, or misgrouped: $json"
  human=$(run_list "$home" "$fakebin") || fail "human program-row list failed"
  assert_contains "$human" "program-moving [program]" \
    "main program row lacked its human label"
  assert_contains "$human" "program-mate/mate-program-moving [program]" \
    "secondmate program row lacked its human label"

  next="$mate/state/home-summary.without-programs.json"
  jq 'del(.programs)' "$mate/state/home-summary.json" > "$next" \
    || fail "could not construct legacy home-summary fixture"
  mv "$next" "$mate/state/home-summary.json"
  json=$(run_list "$home" "$fakebin" --json) || fail "legacy program-ledger list failed"
  printf '%s' "$json" | jq -e '
    .missing | index("secondmate program-mate programs unavailable from home summary") != null
  ' >/dev/null || fail "an unavailable secondmate program surface was silent: $json"
  pass "program rows use existing groups, labels, and completeness disclosure"
}

test_preserves_structured_external_hold_age() {
  local home fakebin json
  home=$(make_home external-hold-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] aged-external - Aged external hold (repo: sample) (kind: ship) (hold: waiting on vendor) (hold-kind: external) (since 2026-08-01)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run_list "$home" "$fakebin" --json) || fail "aged external hold list failed"
  printf '%s' "$json" | jq -e '
    (.waiting_on_outside
      | any(.id == "aged-external" and .owner == "(main)" and .age_days == 44))
      and (.missing | index("age in days where the snapshot has no structured age") == null)
  ' >/dev/null || fail "structured external hold age was discarded: $json"
  pass "structured external hold age remains visible"
}

test_preserves_cached_ledger_disclosure() {
  local home mate fakebin json
  home=$(make_home cached-ledger)
  mate="$TMP_ROOT/cached-ledger-home"
  : > "$home/data/secondmates.md"
  make_secondmate_home cached "$mate"
  printf -- '- cached - fixture domain (host: fixture-host; root: /remote/root; home: %s; scope: fixture; projects: sample; added 2026-09-14)\n' \
    "$mate" >> "$home/data/secondmates.md"
  fm_write_meta "$home/state/cached.meta" \
    "kind=secondmate" "mode=secondmate" "harness=pi" \
    "remote_host=fixture-host" "remote_root=/remote/root" "home=$mate"
  fakebin=$(make_fakebin "$home")
  add_remote_ledger_ssh "$fakebin"
  refresh_secondmate_home "$mate" "$fakebin"

  json=$(run_remote_list "$home" "$fakebin" --json) || fail "live remote list failed"
  printf '%s' "$json" | jq -e '
    .missing | index("secondmate cached served from cached home ledger") == null
  ' >/dev/null || fail "live remote ledger was incorrectly labeled cached: $json"
  : > "$mate/state/fail-ledger-read"
  json=$(run_remote_list "$home" "$fakebin" --json) || fail "cached remote list failed"
  printf '%s' "$json" | jq -e '
    .missing | index("secondmate cached served from cached home ledger") != null
  ' >/dev/null || fail "cached remote ledger disclosure was filtered out: $json"
  pass "cached remote ledgers remain disclosed in the running list"
}

test_toon_warning_preserves_hold_columns() {
  local home fakebin toon
  home=$(make_home warning-gate-shape)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan - Orphan task (repo: sample) (kind: ship)

## Queued
- [ ] dated-external - Dated external wait (repo: sample) (kind: ship) (hold: wait for window) (hold-kind: external) (hold-until: 2026-12-15)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  toon=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_BEARINGS_NOW="$NOW" FM_SNAPSHOT_NOW="$NOW" \
    "$BEARINGS" --all-queued) || fail "warning-gate TOON failed"
  assert_contains "$toon" "2026-12-15" \
    "warning-first TOON gates should retain later hold fields"
  pass "warning-first TOON gates retain structured hold columns"
}

test_all_decisions_exceeds_default_bearings_cap() {
  local home fakebin i json
  home=$(make_home all-decisions)
  : > "$home/data/backlog.md"
  printf '%s\n' '## In flight' '' '## Queued' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le 21 ]; do
    printf -- '- [ ] call-%02d - Decision %02d (repo: sample) (kind: captain) (hold: choose route %02d) (hold-kind: captain)\n' \
      "$i" "$i" "$i" >> "$home/data/backlog.md"
    i=$((i + 1))
  done
  printf '%s\n' '' '## Done' >> "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  json=$(run_list "$home" "$fakebin" --json) || fail "all-decisions list failed"
  printf '%s' "$json" | jq -e '
    (.waiting_on_you | length) == 21
      and (.missing | any(. == "decisions_open showing 20 of 21") | not)
  ' >/dev/null || fail "the bearings decision cap hid an open captain hold: $json"
  pass "all captain holds bypass the bearings display cap"
}

test_help_and_bad_flag
test_groups_open_work_and_names_unreadables
test_empty_fleet_prints_fixed_groups
test_does_not_mutate_backlog_or_holds
test_done_rows_stay_off_the_list
test_keeps_same_local_id_from_different_homes
test_discloses_bounded_secondmate_overflow
test_projects_bounded_secondmate_child_holds
test_projects_secondmate_reconcile_rows
test_places_and_labels_program_rows
test_preserves_structured_external_hold_age
test_preserves_cached_ledger_disclosure
test_toon_warning_preserves_hold_columns
test_all_decisions_exceeds_default_bearings_cap
