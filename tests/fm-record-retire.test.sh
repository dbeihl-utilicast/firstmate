#!/usr/bin/env bash
# Tests for the guarded record-only retirement path.
# A record that lost its pooled slot must become inactive without returning or
# resetting the slot now owned by its replacement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-retire)

make_case() {
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/data/old" "$dir/home/config" "$dir/fakebin" "$dir/pool/3"
  touch "$dir/home/state/.last-watcher-beat" "$dir/pool/treehouse-state.json"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$dir/project" remote add origin https://github.com/o/r.git
  git -C "$dir/project" worktree add -q -b fm/retire-record "$dir/pool/3/repo"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_CALLS:?}"
exit 99
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes) printf '%%1\n' ;;
  display-message) printf 'claude\n' ;;
  list-windows) cat "${FM_TMUX_WINDOWS:?}" ;;
esac
exit 0
SH
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
id=${2:-}
state_file="${FM_ROW_STATE_DIR:?}/$id"
[ -f "$state_file" ] || { printf 'code: NOT_FOUND\n'; exit 1; }
printf '  state: %s\n  held: no\n  blocked: no\n' "$(cat "$state_file")"
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux" "$dir/fakebin/tasks-axi"
  printf 'fm-destination\n' > "$dir/tmux.windows"
  mkdir -p "$dir/rows"
  printf 'done\n' > "$dir/rows/old"
  printf 'in_flight\n' > "$dir/rows/destination"
  printf '%s\n' '# Backlog' > "$dir/home/data/backlog.md"
  fm_write_meta "$dir/home/state/old.meta" \
    "window=fm:fm-old" "endpoint_task_id=old" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes" "spawn_gen=old-incarnation"
  fm_write_meta "$dir/home/state/destination.meta" \
    "window=fm:fm-destination" "endpoint_task_id=destination" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=destination-incarnation"
  printf 'finished scout report\n' > "$dir/home/data/old/report.md"
}

run_retire() {
  local dir=$1
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TREEHOUSE_CALLS="$dir/treehouse.calls" FM_TMUX_WINDOWS="$dir/tmux.windows" \
    FM_ROW_STATE_DIR="$dir/rows" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" old --retire-record
}

test_record_only_retirement_preserves_reused_slot() {
  local dir="$TMP_ROOT/reused-slot" out rc=0
  make_case "$dir"
  : > "$dir/treehouse.calls"
  out=$(run_retire "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "a finished scout whose slot is owned by another record should retire its record"
  [ ! -e "$dir/home/state/old.meta" ] || fail "the retired record remained active"
  [ -f "$dir/home/state/retired/old.meta" ] || fail "the retired record lacks an audit copy"
  [ -f "$dir/home/state/retired/old.receipt" ] || fail "the retirement lacks an audit receipt"
  [ -f "$dir/home/state/destination.meta" ] || fail "record-only retirement removed the replacement owner"
  [ ! -s "$dir/treehouse.calls" ] || fail "record-only retirement returned or reset the replacement slot: $(cat "$dir/treehouse.calls")"
  pass "record retirement: a reused pooled slot is never returned"
}

test_retired_identity_is_not_a_send_destination() {
  local dir="$TMP_ROOT/inactive-send" rc=0
  make_case "$dir"
  run_retire "$dir" >/dev/null || fail "fixture retirement failed"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-send.sh" old "do not deliver here" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a retired identity must not remain a message recipient"
  [ ! -d "$dir/home/state/old.inbox" ] || fail "a retired identity received a message"
  pass "record retirement: inactive identity is excluded from delivery"
}

test_record_only_retirement_refuses_its_still_owned_slot() {
  local dir="$TMP_ROOT/still-owned-slot" rc=0
  make_case "$dir"
  rm -f "$dir/home/state/destination.meta"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "retirement must refuse while no replacement owns the slot"
  [ -f "$dir/home/state/old.meta" ] || fail "a refused record retirement removed the active record"
  pass "record retirement: still-owned slot is preserved"
}

test_record_only_retirement_preserves_stopped_marker() {
  local dir="$TMP_ROOT/stopped-marker" rc=0
  make_case "$dir"
  printf 'stopped\n' > "$dir/home/state/old.stopped"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "retiring an old identity should not need to clear a stopped marker"
  [ -f "$dir/home/state/old.stopped" ] || fail "record retirement cleared the stopped marker"
  pass "record retirement: stopped marker remains owned by reopen"
}

test_record_only_retirement_moves_polling_sidecars() {
  local dir="$TMP_ROOT/sidecars" rc=0
  make_case "$dir"
  printf '#!/bin/sh\n' > "$dir/home/state/old.check.sh"
  printf 'done: unread\n' > "$dir/home/state/old.status"
  printf 'refresh\n' > "$dir/home/state/old.pr-refresh-state"
  printf 'rounds\n' > "$dir/home/state/old.nm-fix-rounds"
  mkdir -p "$dir/home/state/old.inbox"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "retirement should succeed"
  [ ! -e "$dir/home/state/old.check.sh" ] || fail "a retired identity is still polled"
  [ ! -e "$dir/home/state/old.status" ] || fail "a retired identity can still ring from unread status"
  [ ! -e "$dir/home/state/old.pr-refresh-state" ] || fail "a retired identity kept refresh state"
  [ ! -e "$dir/home/state/old.nm-fix-rounds" ] || fail "a retired identity kept validation state"
  [ ! -e "$dir/home/state/old.inbox" ] || fail "a retired identity kept its inbox"
  [ -f "$dir/home/state/retired/old.sidecars/old.check.sh" ] || fail "retired sidecar lacks audit copy"
  pass "record retirement: polling, status, and routing sidecars retire with the record"
}

# A closed row is necessary but does not by itself prove that the deliverable
# exists. This protects against prematurely closed, unlanded work.
test_record_only_retirement_requires_closed_row_and_deliverable() {
  local dir="$TMP_ROOT/finished-proof" rc=0
  make_case "$dir"
  rm -f "$dir/home/data/old/report.md"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a closed row without landed work or a report must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "weak finished proof retired an unlanded record"

  printf 'in_flight\n' > "$dir/rows/old"
  printf 'report exists but row remains open\n' > "$dir/home/data/old/report.md"
  rc=0
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a report without a closed row must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "an open record retired from report presence alone"
  pass "record retirement: finished proof requires closure and a deliverable"
}

# The stale record itself must no longer have a live endpoint, even when its
# backlog and deliverable look complete.
test_record_only_retirement_refuses_live_retiring_endpoint() {
  local dir="$TMP_ROOT/live-old" rc=0
  make_case "$dir"
  printf '%s\n' fm-old fm-destination > "$dir/tmux.windows"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a live retiring endpoint must not be orphaned"
  [ -f "$dir/home/state/old.meta" ] || fail "a live endpoint lost its metadata"
  pass "record retirement: the retiring endpoint must be gone"
}

# Ownership is positive evidence, not the absence of finished evidence.
test_record_only_retirement_requires_positive_active_owner() {
  local dir="$TMP_ROOT/positive-owner" rc=0
  make_case "$dir"
  rm -f "$dir/rows/destination"
  : > "$dir/tmux.windows"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a dead claimant with no backlog row is not an active owner"
  [ -f "$dir/home/state/old.meta" ] || fail "an unproved claimant authorized retirement"
  pass "record retirement: replacement ownership is positively proved"
}

# Recovery must converge after metadata moved but before receipt and sidecar
# retirement completed.
test_record_only_retirement_retry_repairs_receipt_and_sidecars() {
  local dir="$TMP_ROOT/retry" rc=0
  make_case "$dir"
  mkdir -p "$dir/home/state/retired/old.sidecars"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  printf '#!/bin/sh\n' > "$dir/home/state/old.check.sh"
  printf 'done: unread\n' > "$dir/home/state/old.status"
  # Retirement already started when metadata became inactive. Its completion
  # must not depend on the replacement still being active later.
  rm -f "$dir/home/state/destination.meta" "$dir/rows/destination"
  : > "$dir/tmux.windows"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "retry should finish after the replacement owner disappears"
  [ -f "$dir/home/state/retired/old.receipt" ] || fail "retry did not repair the audit receipt"
  grep -q '^status=complete$' "$dir/home/state/retired/old.receipt" \
    || fail "retry did not validate a complete receipt"
  [ ! -e "$dir/home/state/old.check.sh" ] || fail "retry left polling active"
  [ ! -e "$dir/home/state/old.status" ] || fail "retry left status ringing active"
  pass "record retirement: retry repairs receipt without re-proving a claimant"
}

# A retry after same-id reuse must bind to the archived spawn generation and
# leave every runtime artifact of the newer generation untouched.
test_record_only_retirement_retry_preserves_new_same_id_incarnation() {
  local dir="$TMP_ROOT/same-id-reuse" rc=0 before_meta before_status before_progress
  make_case "$dir"
  mkdir -p "$dir/home/state/retired/old.sidecars"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  fm_write_meta "$dir/home/state/old.meta" \
    "window=fm:fm-old" "endpoint_task_id=old" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=new-incarnation"
  printf 'working: new incarnation\n' > "$dir/home/state/old.status"
  printf 'new progress\n' > "$dir/home/state/old.progress"
  printf '#!/bin/sh\n' > "$dir/home/state/old.check.sh"
  printf '%s\n' fm-destination > "$dir/tmux.windows"
  before_meta=$(cat "$dir/home/state/old.meta")
  before_status=$(cat "$dir/home/state/old.status")
  before_progress=$(cat "$dir/home/state/old.progress")
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "retry must require manual reconciliation when same-id sidecars are ambiguous"
  [ "$(cat "$dir/home/state/old.meta")" = "$before_meta" ] || fail "retry changed newer metadata"
  [ "$(cat "$dir/home/state/old.status")" = "$before_status" ] || fail "retry changed newer status"
  [ "$(cat "$dir/home/state/old.progress")" = "$before_progress" ] || fail "retry changed newer progress"
  [ -f "$dir/home/state/old.check.sh" ] || fail "retry consumed an ambiguous same-id polling sidecar"
  if [ -f "$dir/home/state/retired/old.receipt" ]; then
    ! grep -q '^status=complete$' "$dir/home/state/retired/old.receipt" \
      || fail "retry finalized while an ambiguous same-id sidecar remained"
  fi
  pass "record retirement: ambiguous same-id resume refuses without finalizing"
}

# Normal publication cannot reuse an id until its earlier record retirement is
# complete, preventing unbound old sidecars from entering a new incarnation.
test_spawn_refuses_id_with_incomplete_retirement() {
  local dir="$TMP_ROOT/spawn-incomplete" out rc=0
  make_case "$dir"
  mkdir -p "$dir/home/state/retired"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  cat > "$dir/home/data/old/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise incomplete-retirement spawn protection.

## Firstmate spec
Refuse before publishing a new record.
EOF
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$PATH" "$SPAWN" old "$dir/project" --scout --harness codex 2>&1) || rc=$?
  expect_code 1 "$rc" "spawn must refuse an id whose prior retirement is incomplete"
  assert_contains "$out" "incomplete retirement" "spawn refusal should name the incomplete retirement"
  [ ! -e "$dir/home/state/old.meta" ] || fail "spawn published over an incomplete retirement"
  pass "record retirement: incomplete retirement blocks same-id spawn"
}

test_spawn_allows_id_with_complete_retirement() {
  local dir="$TMP_ROOT/spawn-complete" out rc=0
  make_case "$dir"
  mkdir -p "$dir/home/state/retired"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  printf '%s\n' version=fm-record-retirement-v2 task_id=old spawn_gen=old-incarnation \
    status=complete runtime_state=retired > "$dir/home/state/retired/old.receipt"
  cat > "$dir/home/data/old/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise completed-retirement id reuse.

## Firstmate spec
Proceed past the retirement guard.
EOF
  out=$(FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    PATH="$dir/fakebin:$PATH" "$SPAWN" old "$dir/project" --scout --harness codex 2>&1) || rc=$?
  assert_not_contains "$out" "incomplete retirement" "a complete receipt must not block same-id spawn"
  pass "record retirement: complete retirement allows same-id spawn"
}

# A failed metadata move must leave no receipt that could imply the still-live
# record was retired.
test_record_only_retirement_moves_identity_before_receipt() {
  local dir="$TMP_ROOT/meta-first" rc=0 real_mv
  make_case "$dir"
  real_mv=$(command -v mv)
  cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  */retired/old.meta) exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$dir/fakebin/mv"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a failed metadata retirement must stop the transaction"
  [ -f "$dir/home/state/old.meta" ] || fail "failed move removed the active identity"
  [ ! -e "$dir/home/state/retired/old.receipt" ] \
    || fail "receipt appeared before the identity became inactive"
  pass "record retirement: metadata becomes inactive before receipt publication"
}

test_record_only_retirement_ignores_finished_claimant() {
  local dir="$TMP_ROOT/finished-claimant" rc=0
  make_case "$dir"
  mkdir -p "$dir/home/data/destination"
  printf 'finished\n' > "$dir/home/data/destination/report.md"
  printf 'done\n' > "$dir/rows/destination"
  : > "$dir/tmux.windows"
  fm_write_meta "$dir/home/state/destination.meta" \
    "window=fm:fm-destination" "endpoint_task_id=destination" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes" "spawn_gen=destination-incarnation"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a finished record is not an active slot claimant"
  [ -f "$dir/home/state/old.meta" ] || fail "refused retirement removed the record"
  pass "record retirement: only an active claimant proves slot ownership"
}

test_ship_report_does_not_prove_landed_work() {
  local dir="$TMP_ROOT/ship-report" rc=0
  make_case "$dir"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "${FM_PR_VIEW_FIXTURE:?}"
SH
  chmod +x "$dir/fakebin/gh-axi"
  fm_write_meta "$dir/home/state/old.meta" \
    "window=fm:fm-old" "endpoint_task_id=old" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=old-incarnation" \
    "pr=https://github.com/o/r/pull/7" "branch=fm/retire-record"

  cat > "$dir/pr-open.out" <<'EOF'
pull_request:
  number: 7
  title: "fix(bin): refuse duplicate-claim fresh spawn and hold copy reservation through worker launch"
  state: open
  author: dbeihl-utilicast
  draft: yes
  merged: no
  checks: "6 passed, 0 failed, 15 total"
EOF
  FM_PR_VIEW_FIXTURE="$dir/pr-open.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a ship report with an open PR must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "an open ship record was retired from a report"

  cat > "$dir/pr-closed.out" <<'EOF'
pull_request:
  number: 7
  title: "feat(bin): add atomic inbox take and resend dedup"
  state: closed
  author: dbeihl-utilicast
  draft: no
  merged: no
  checks: "0 passed, 0 failed - this PR has no CI checks configured"
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-closed.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a ship report with a closed-unmerged PR must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "a closed-unmerged ship record was retired from a report"

  cat > "$dir/pr-spoof.out" <<'EOF'
pull_request:
  number: 7
  title: "docs: explain why state: merged is not proof"
  body: |
    Notes for reviewers.
  state: merged
    state: merged
  state: open
  author: dbeihl-utilicast
  draft: yes
  merged: no
  checks: "1 passed, 0 failed, 1 total"
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-spoof.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an open PR with state: merged in a body before the state field must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "a body-before-state spoof retired the record"

  cat > "$dir/pr-spoof-after.out" <<'EOF'
pull_request:
  number: 7
  title: "docs: explain why state: merged is not proof"
  state: open
  draft: yes
  merged: no
  body: |
    Notes for reviewers.
    state: merged
  checks: "1 passed, 0 failed, 1 total"
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-spoof-after.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an open PR with state: merged in a body after the state field must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "a body-after-state spoof retired the record"

  cat > "$dir/pr-other-number.out" <<'EOF'
pull_request:
  number: 8
  state: merged
  merged: "2026-09-19T15:55:08Z"
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-other-number.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a merged PR with a different number must not retire the record"
  [ -f "$dir/home/state/old.meta" ] || fail "a number-mismatched merged PR retired the record"

  cat > "$dir/pr-scope.out" <<'EOF'
extra:
  number: 7
  state: merged
pull_request:
  number: 7
  state: open
  merged: no
trailer:
  number: 7
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-scope.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "merged fields outside the pull_request block must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "an out-of-scope merged block retired the record"

  cat > "$dir/pr-wrong-block.out" <<'EOF'
head_ref:
  number: 7
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-wrong-block.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a merged block that is not pull_request must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "a non-pull_request block retired the record"

  cat > "$dir/pr-number-outside.out" <<'EOF'
head_ref:
  number: 7
pull_request:
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-number-outside.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a number found only outside the pull_request block must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "an out-of-scope number retired the record"

  cat > "$dir/pr-state-outside.out" <<'EOF'
pull_request:
  number: 7
head_ref:
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-state-outside.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a state found only outside the pull_request block must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "an out-of-scope state retired the record"

  cat > "$dir/pr-dup-state-last.out" <<'EOF'
pull_request:
  number: 7
  state: open
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-dup-state-last.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a duplicate state line with merged last must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "duplicate state (merged last) retired the record"

  cat > "$dir/pr-dup-state-first.out" <<'EOF'
pull_request:
  number: 7
  state: merged
  state: open
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-dup-state-first.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a duplicate state line with merged first must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "duplicate state (merged first) retired the record"

  cat > "$dir/pr-dup-number.out" <<'EOF'
pull_request:
  number: 7
  number: 7
  state: merged
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-dup-number.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a duplicate number line must not retire"
  [ -f "$dir/home/state/old.meta" ] || fail "duplicate number retired the record"

  cat > "$dir/pr-merged.out" <<'EOF'
pull_request:
  number: 7
  title: "fix(bin): bind record-only retirement to spawn generation and guard id reuse"
  state: merged
  author: dbeihl-utilicast
  draft: no
  merged: "2026-09-19T15:55:08Z"
  checks: "18 passed, 0 failed, 18 total"
EOF
  rc=0
  FM_PR_VIEW_FIXTURE="$dir/pr-merged.out" run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a merged PR proves landed ship work"
  [ ! -e "$dir/home/state/old.meta" ] || fail "a landed ship record stayed active"
  pass "record retirement: GitHub PR state distinguishes landed ship work"
}

# A PR number is not globally unique. The repository in the recorded URL must
# match the project remote before a merged result can prove landing.
test_ship_merged_pr_proof_binds_full_repository_url() {
  local dir="$TMP_ROOT/pr-repository" rc=0
  make_case "$dir"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' -R o/r '*) printf 'pull_request:\n  number: 7\n  state: open\n  merged: no\n' ;;
  *) printf 'pull_request:\n  number: 7\n  state: merged\n  merged: "2026-09-19T15:55:08Z"\n' ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
  fm_write_meta "$dir/home/state/old.meta" \
    "window=fm:fm-old" "endpoint_task_id=old" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=old-incarnation" \
    "pr=https://github.com/o/r/pull/7" "branch=fm/not-on-default"
  GH_REPO=other/repository run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "GH_REPO must not redirect merged-PR proof to another repository"
  [ -f "$dir/home/state/old.meta" ] || fail "cross-repository PR evidence retired the record"
  pass "record retirement: merged PR proof binds owner, repository, and number"
}

test_retired_secondmate_is_excluded_from_broadcast_enumeration() {
  local dir="$TMP_ROOT/secondmate-broadcast" out
  make_case "$dir"
  fm_write_meta "$dir/home/state/destination.meta" \
    "window=fm-destination" "kind=secondmate" "home=$dir/destination-home"
  mkdir -p "$dir/home/state/retired"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  out=$(FM_HOME="$dir/home" bash -c '. "$1/bin/fm-ff-lib.sh"; live_secondmate_meta_records "$2"' _ "$ROOT" "$dir/home/state")
  assert_contains "$out" "destination|$dir/destination-home|fm-destination" \
    "the live destination should be enumerated once"
  assert_not_contains "$out" "old|" "a retired lane must not be enumerated for broadcast"
  pass "record retirement: a moved lane has one live broadcast destination"
}

test_interrupted_retirement_resumes_sidecar_archival() {
  local dir="$TMP_ROOT/interrupted" rc=0
  make_case "$dir"
  mkdir -p "$dir/home/state/old.inbox" "$dir/home/state/retired"
  printf '#!/bin/sh\n' > "$dir/home/state/old.check.sh"
  mv "$dir/home/state/old.meta" "$dir/home/state/retired/old.meta"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-send.sh" old "do not ring" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "an identity whose metadata is archived must not be rung"
  rc=0
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a retry after metadata archival should finish sidecar retirement"
  [ ! -e "$dir/home/state/old.check.sh" ] || fail "the retry left a polling sidecar"
  [ ! -e "$dir/home/state/old.inbox" ] || fail "the retry left the inbox"
  [ -f "$dir/home/state/retired/old.sidecars/old.check.sh" ] || fail "the retry lacks the sidecar audit copy"
  [ -f "$dir/home/state/destination.meta" ] || fail "the retry removed the replacement owner"
  rc=0
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" old --retire-record --force >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "incompatible flags must be refused on the resume path too"
  pass "record retirement: interrupted retirement resumes and finishes sidecars"
}

test_retired_secondmate_is_excluded_from_broadcast_enumeration

test_record_only_retirement_preserves_reused_slot
test_record_only_retirement_moves_polling_sidecars
test_record_only_retirement_requires_closed_row_and_deliverable
test_record_only_retirement_refuses_live_retiring_endpoint
test_record_only_retirement_requires_positive_active_owner
test_record_only_retirement_retry_repairs_receipt_and_sidecars
test_record_only_retirement_retry_preserves_new_same_id_incarnation
test_spawn_refuses_id_with_incomplete_retirement
test_spawn_allows_id_with_complete_retirement
test_record_only_retirement_moves_identity_before_receipt
test_ship_report_does_not_prove_landed_work
test_ship_merged_pr_proof_binds_full_repository_url
test_record_only_retirement_ignores_finished_claimant
test_retired_identity_is_not_a_send_destination
test_record_only_retirement_refuses_its_still_owned_slot
test_record_only_retirement_preserves_stopped_marker
test_interrupted_retirement_resumes_sidecar_archival
