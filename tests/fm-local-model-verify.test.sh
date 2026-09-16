#!/usr/bin/env bash
# Behavior tests for bin/fm-local-model-verify.sh: the one mechanism that
# independently re-runs a local-model ship task's named red test against the
# worker's REAL committed code, trusting none of the worker's own reports
# (status lines, PR bodies, or its own captured red-before/green-after/
# red-revert files). It must accept a genuine implementation, reject the
# pass-body class (a test that cannot fail, so reverting the implementation
# leaves it green), reject a worker whose "done" report does not hold (the
# test still fails at HEAD), and never mutate the worker's own worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-local-model-verify.sh"
TMP_ROOT=$(fm_test_tmproot fm-local-model-verify)

test_script_parses() {
  local out rc
  out=$(bash -n "$VERIFY" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-local-model-verify.sh must parse cleanly (got: $out)"
  pass "fm-local-model-verify.sh: bash -n succeeds"
}

# A tiny git project with a default branch and one initial commit.
new_project() {  # <name> -> echoes <proj-dir>
  local name=$1 proj
  proj="$TMP_ROOT/$name/proj"
  mkdir -p "$proj/tests" "$proj/lib"
  git -C "$proj" init -q -b main
  git -C "$proj" config user.email t@t.test
  git -C "$proj" config user.name t
  printf 'true\n' > "$proj/lib/.keep"
  git -C "$proj" add -A
  git -C "$proj" commit -q -m init
  printf '%s' "$proj"
}

# Commits a red test to main: it fails until lib/<fn>.sh defines a 2-arg <fn>
# that echoes their sum.
add_red_test() {  # <proj> <test-rel-path> <fn>
  local proj=$1 rel=$2 fn=$3
  mkdir -p "$(dirname "$proj/$rel")"
  cat > "$proj/$rel" <<EOF
#!/usr/bin/env bash
set -eu
. "\$(dirname "\$0")/../lib/$fn.sh"
result=\$($fn 2 3)
[ "\$result" = "5" ] || { echo "not ok - expected 5 got \$result"; exit 1; }
echo "ok - $fn works"
EOF
  chmod +x "$proj/$rel"
  git -C "$proj" add -A
  git -C "$proj" commit -q -m "add red test for $fn"
}

# A pass-body test: it can never fail, so it stays green even with the
# implementation reverted. Modeled on the qwen proving-run failure the
# contract exists to reject.
add_passbody_test() {  # <proj> <test-rel-path>
  local proj=$1 rel=$2
  mkdir -p "$(dirname "$proj/$rel")"
  printf '#!/usr/bin/env bash\necho "ok - noop"\nexit 0\n' > "$proj/$rel"
  chmod +x "$proj/$rel"
  git -C "$proj" add -A
  git -C "$proj" commit -q -m "add pass-body test"
}

new_task_worktree() {  # <proj> <id> -> echoes <wt-dir>
  local proj=$1 id=$2 wt
  wt="$TMP_ROOT/$id/wt"
  git -C "$proj" worktree add -q -b "fm/$id" "$wt" main >/dev/null
  printf '%s' "$wt"
}

write_meta_and_brief() {  # <fmhome> <id> <proj> <wt> [<red-test-line>]
  local fmhome=$1 id=$2 proj=$3 wt=$4 redline=${5-omit}
  mkdir -p "$fmhome/state" "$fmhome/data/$id"
  printf 'worktree=%s\nproject=%s\nkind=ship\n' "$wt" "$proj" > "$fmhome/state/$id.meta"
  {
    printf '# Local-model red-first contract\nLocal-model contract: enabled\n'
    [ "$redline" = omit ] || printf '%s\n' "$redline"
  } > "$fmhome/data/$id/brief.md"
}

run_verify() {  # <fmhome> <id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" "$VERIFY" "$2" 2>&1
}

# The accepting case: a real implementation behind a real test that goes red
# when the implementation is reverted. This is the shape every genuine
# local-model ship task must produce to clear verification.
test_accepts_a_genuine_red_test_that_fails_on_revert() {
  local id proj wt fmhome out status before_status before_files after_status after_files worktrees_before worktrees_after
  id=verify-good-a1
  proj=$(new_project "$id")
  add_red_test "$proj" tests/add.test.sh add
  wt=$(new_task_worktree "$proj" "$id")
  cat > "$wt/lib/add.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
EOF
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "implement add"

  before_status=$(git -C "$wt" status --porcelain)
  before_files=$(find "$wt" -type f ! -path '*/.git/*' -exec sha256sum {} + | sort)
  worktrees_before=$(git -C "$wt" worktree list | wc -l)

  fmhome="$TMP_ROOT/$id/fmhome"
  write_meta_and_brief "$fmhome" "$id" "$proj" "$wt" "Red test: tests/add.test.sh"
  out=$(run_verify "$fmhome" "$id"); status=$?
  expect_code 0 "$status" "a genuine implementation with a real red test should verify clean (got: $out)"
  assert_contains "$out" "passes at HEAD and fails with the implementation reverted" \
    "verifier did not confirm both halves of the contract"

  after_status=$(git -C "$wt" status --porcelain)
  after_files=$(find "$wt" -type f ! -path '*/.git/*' -exec sha256sum {} + | sort)
  worktrees_after=$(git -C "$wt" worktree list | wc -l)
  [ "$before_status" = "$after_status" ] || fail "verifying dirtied the worker's own worktree"
  [ "$before_files" = "$after_files" ] || fail "verifying changed a file in the worker's own worktree"
  [ "$worktrees_before" = "$worktrees_after" ] || fail "verifying left a scratch worktree registered against the project"
  pass "fm-local-model-verify.sh: a genuine red test that fails on revert verifies clean and never mutates the worker's worktree"
}

# Negative control (item C): a test whose body cannot fail. Reverting the
# implementation leaves it green, so the verifier must reject it - this is
# the exact pass-body class the whole contract exists to catch mechanically.
test_rejects_a_pass_body_test_that_cannot_go_red_on_revert() {
  local id proj wt fmhome out status
  id=verify-passbody-b1
  proj=$(new_project "$id")
  add_passbody_test "$proj" tests/noop.test.sh
  wt=$(new_task_worktree "$proj" "$id")
  echo "irrelevant" > "$wt/lib/unused.sh"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "unrelated change; the named test never actually exercises it"

  fmhome="$TMP_ROOT/$id/fmhome"
  write_meta_and_brief "$fmhome" "$id" "$proj" "$wt" "Red test: tests/noop.test.sh"
  out=$(run_verify "$fmhome" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a pass-body test must not verify clean"
  assert_contains "$out" "still passes with the implementation reverted" \
    "pass-body rejection did not explain the revert-check failure"
  assert_contains "$out" "the pass-body class this contract exists to reject" \
    "pass-body rejection did not name the failure class"
  pass "fm-local-model-verify.sh: a pass-body test that cannot go red on revert is rejected"
}

# A worker's own "done" report is not evidence: if the named test still fails
# on the worker's committed HEAD, the verifier must say so and never proceed
# to the revert-check.
test_rejects_when_the_test_still_fails_at_head() {
  local id proj wt fmhome out status
  id=verify-stillred-c1
  proj=$(new_project "$id")
  add_red_test "$proj" tests/add.test.sh add
  wt=$(new_task_worktree "$proj" "$id")
  echo "irrelevant" > "$wt/README-c1.md"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "no real implementation; test still fails at HEAD"

  fmhome="$TMP_ROOT/$id/fmhome"
  write_meta_and_brief "$fmhome" "$id" "$proj" "$wt" "Red test: tests/add.test.sh"
  out=$(run_verify "$fmhome" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "a test still failing at HEAD must not verify clean"
  assert_contains "$out" "does not pass on $id's own committed HEAD" \
    "HEAD-failure rejection did not explain which half failed"
  assert_not_contains "$out" "with the implementation reverted" \
    "verifier ran the revert-check after HEAD already failed"
  pass "fm-local-model-verify.sh: a test still failing at HEAD is rejected before the revert-check runs"
}

# The PASS check must judge only what the worker committed, never its live
# worktree: an uncommitted change that happens to make the test pass would
# otherwise verify a commit that does not actually hold the fix - exactly the
# class of false success this whole contract exists to catch.
test_rejects_uncommitted_working_tree_changes_the_committed_head_does_not_have() {
  local id proj wt fmhome out status
  id=verify-uncommitted-e1
  proj=$(new_project "$id")
  add_red_test "$proj" tests/add.test.sh add
  wt=$(new_task_worktree "$proj" "$id")
  echo "irrelevant" > "$wt/README-e1.md"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "no real implementation committed; test still fails at HEAD"
  # Leave an UNCOMMITTED change that makes the test pass. Only the commit above
  # is the worker's "done" report; this file must never be judged.
  cat > "$wt/lib/add.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
EOF

  fmhome="$TMP_ROOT/$id/fmhome"
  write_meta_and_brief "$fmhome" "$id" "$proj" "$wt" "Red test: tests/add.test.sh"
  out=$(run_verify "$fmhome" "$id"); status=$?
  [ "$status" -ne 0 ] || fail "an uncommitted working-tree fix must not verify a commit that lacks it"
  assert_contains "$out" "does not pass on $id's own committed HEAD" \
    "uncommitted-change rejection did not explain which half failed"
  pass "fm-local-model-verify.sh: an uncommitted working-tree change never substitutes for what the worker committed"
}

# Defense in depth: the verifier re-validates the same three Red-test-line
# problems bin/fm-spawn.sh already gates at dispatch time, in case it is ever
# invoked standalone or the brief was hand-edited after spawn.
test_refuses_a_bad_red_test_line_independent_of_fm_spawn() {
  local id proj wt fmhome out status label redline expect n=0
  id=verify-badline-d1
  proj=$(new_project "$id")
  add_red_test "$proj" tests/add.test.sh add
  wt=$(new_task_worktree "$proj" "$id")
  cat > "$wt/lib/add.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
EOF
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "implement add"
  fmhome="$TMP_ROOT/$id/fmhome"

  while IFS='|' read -r label redline expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_meta_and_brief "$fmhome" "$id-$n" "$proj" "$wt" "$redline"
    out=$(run_verify "$fmhome" "$id-$n"); status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the Red test problem"
  done <<'ROWS'
missing Red test line|omit|carries no 'Red test: <path>' line
unfilled placeholder|Red test: {RED_TEST}|is still the unfilled {RED_TEST} placeholder
nonexistent file|Red test: tests/does-not-exist.test.sh|does not exist in
path traversal|Red test: ../escape.test.sh|must be a project-relative path with no traversal
ROWS
  pass "fm-local-model-verify.sh: a missing, placeholder, nonexistent, or traversing Red test line is refused"
}

test_script_parses
test_accepts_a_genuine_red_test_that_fails_on_revert
test_rejects_a_pass_body_test_that_cannot_go_red_on_revert
test_rejects_when_the_test_still_fails_at_head
test_rejects_uncommitted_working_tree_changes_the_committed_head_does_not_have
test_refuses_a_bad_red_test_line_independent_of_fm_spawn
echo "# all fm-local-model-verify tests passed"
