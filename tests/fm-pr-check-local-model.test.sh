#!/usr/bin/env bash
# Behavior tests for fm-pr-check.sh's local-model verification gate: a ship
# task recorded on a local-model harness (bin/fm-harness.sh is-local-model)
# must clear bin/fm-local-model-verify.sh's revert-check before its PR is
# registered ready, and a task that is not both ship and local-model must see
# no change in behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-local-model)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_case() {  # <name> -> echoes <dir>
  local name=$1 dir fake_root
  dir="$TMP_ROOT/$name"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  printf '%s\n' "$dir"
}

# A tiny git project with a default branch and one initial commit.
new_project() {  # <dir> -> echoes <proj-dir>
  local dir=$1 proj
  proj="$dir/proj"
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
# implementation reverted.
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
  wt="$(dirname "$proj")/wt-$id"
  git -C "$proj" worktree add -q -b "fm/$id" "$wt" main >/dev/null
  printf '%s' "$wt"
}

write_meta_and_brief() {  # <dir> <id> <proj> <wt> <harness> <red-test-line>
  local dir=$1 id=$2 proj=$3 wt=$4 harness=$5 redline=$6
  mkdir -p "$dir/home/data/$id"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=$harness" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=1"
  {
    printf '# Local-model red-first contract\nLocal-model contract: enabled\n'
    [ -z "$redline" ] || printf '%s\n' "$redline"
  } > "$dir/home/data/$id/brief.md"
}

run_check_entry() {  # <dir> <args...>
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

test_passbody_local_model_task_is_refused() {
  local dir id proj wt out rc
  dir=$(make_case passbody-refused)
  id=pb-1
  proj=$(new_project "$dir")
  add_passbody_test "$proj" tests/pb.test.sh
  wt=$(new_task_worktree "$proj" "$id")
  write_meta_and_brief "$dir" "$id" "$proj" "$wt" qwen "Red test: tests/pb.test.sh"

  set +e
  out=$(run_check_entry "$dir" "$id" https://github.com/o/r/pull/1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check.sh registered a pass-body local-model task as ready"
  assert_contains "$out" "not testing what it claims to" \
    "refusal did not surface the verifier's own reason"
  [ ! -e "$dir/home/state/$id.check.sh" ] \
    || fail "a refused local-model task still armed a merge poll"
  assert_no_grep '^pr=' "$dir/home/state/$id.meta" \
    "a refused local-model task still recorded pr= metadata"
  pass "fm-pr-check.sh refuses to register a pass-body local-model ship task as ready"
}

test_genuine_red_test_local_model_task_is_registered_ready() {
  local dir id proj wt
  dir=$(make_case genuine-registered)
  id=gr-1
  proj=$(new_project "$dir")
  add_red_test "$proj" tests/add.test.sh add
  wt=$(new_task_worktree "$proj" "$id")
  cat > "$wt/lib/add.sh" <<'EOF'
add() { echo $(( $1 + $2 )); }
EOF
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "implement add"
  write_meta_and_brief "$dir" "$id" "$proj" "$wt" qwen "Red test: tests/add.test.sh"

  run_check_entry "$dir" "$id" https://github.com/o/r/pull/2 >/dev/null 2>"$dir/stderr" \
    || fail "fm-pr-check.sh refused a genuine red-first local-model ship task (got: $(cat "$dir/stderr"))"
  [ -f "$dir/home/state/$id.check.sh" ] \
    || fail "a verified local-model task did not arm a merge poll"
  grep -qxF 'pr=https://github.com/o/r/pull/2' "$dir/home/state/$id.meta" \
    || fail "a verified local-model task did not record pr= metadata"
  pass "fm-pr-check.sh registers a genuine red-first local-model ship task as ready"
}

test_non_local_model_task_is_unaffected() {
  local dir id
  dir=$(make_case non-local-model)
  id=nlm-1
  mkdir -p "$dir/wt"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/proj-does-not-exist" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=1"

  run_check_entry "$dir" "$id" https://github.com/o/r/pull/3 >/dev/null 2>"$dir/stderr" \
    || fail "fm-pr-check.sh refused a non-local-model ship task (got: $(cat "$dir/stderr"))"
  [ -f "$dir/home/state/$id.check.sh" ] \
    || fail "a non-local-model task did not arm a merge poll"
  grep -qxF 'pr=https://github.com/o/r/pull/3' "$dir/home/state/$id.meta" \
    || fail "a non-local-model task did not record pr= metadata"
  pass "fm-pr-check.sh leaves a non-local-model ship task's registration unaffected"
}

test_passbody_local_model_task_is_refused
test_genuine_red_test_local_model_task_is_registered_ready
test_non_local_model_task_is_unaffected
echo "# all fm-pr-check-local-model tests passed"
