#!/usr/bin/env bash
# Behavior tests for fm-pr-check.sh's issue-closing gate: when the recorded
# captain's intent names parseable issue numbers, registering a GitHub PR as
# ready is refused unless the PR body closes each one with its own keyword.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-issue-close)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
VALID_HEAD=0123456789abcdef0123456789abcdef01234567

make_case() {  # <name> -> echoes <dir>
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" \
    "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
case " $* " in
  *" -q .body "*|*" -q .body")
    printf '%s' "${FM_TEST_GH_PR_BODY-}"
    exit "${FM_TEST_GH_BODY_RC:-0}"
    ;;
  *" headRefOid "*)
    printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

write_ship_meta() {  # <dir> <id>
  local dir=$1 id=$2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=1"
}

write_brief() {  # <dir> <id> <intent>
  local dir=$1 id=$2 intent=$3
  mkdir -p "$dir/home/data/$id"
  cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Implement the named fix.
EOF
}

run_check() {  # <dir> <id> <url>
  local dir=$1 id=$2 url=$3
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_HEAD="$VALID_HEAD" \
    FM_TEST_GH_PR_BODY="${FM_TEST_GH_PR_BODY-}" \
    FM_TEST_GH_BODY_RC="${FM_TEST_GH_BODY_RC:-0}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$id" "$url"
}

# Red case: captain's intent names #42, the PR body never closes it, and
# today's registration path still arms a merge poll.
test_named_issue_without_closing_keyword_is_refused() {
  local dir id out rc
  dir=$(make_case missing-keyword)
  id=close-missing
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" "Fix the parser crash tracked as #42."

  set +e
  FM_TEST_GH_PR_BODY="This pull request fixes the parser crash." \
    out=$(run_check "$dir" "$id" https://github.com/o/r/pull/7 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check.sh registered a PR that does not close named issue #42"
  assert_contains "$out" "#42" "refusal did not name the unclosed issue"
  [ ! -e "$dir/home/state/$id.check.sh" ] \
    || fail "a refused issue-close registration still armed a merge poll"
  assert_no_grep '^pr=' "$dir/home/state/$id.meta" \
    "a refused issue-close registration still recorded pr= metadata"
  pass "fm-pr-check.sh refuses to register a PR that leaves a named issue open"
}

test_own_keyword_per_named_issue_is_registered() {
  local dir id
  dir=$(make_case own-keywords)
  id=close-ok
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" "Fix the parser crash in #42 and the timeout in #43."

  FM_TEST_GH_PR_BODY="Closes #42"$'\n'"Fixes #43" \
    run_check "$dir" "$id" https://github.com/o/r/pull/8 >/dev/null 2>"$dir/stderr" \
    || fail "fm-pr-check.sh refused a PR that closes each named issue (got: $(cat "$dir/stderr"))"
  [ -f "$dir/home/state/$id.check.sh" ] \
    || fail "a PR that closes each named issue did not arm a merge poll"
  grep -qxF 'pr=https://github.com/o/r/pull/8' "$dir/home/state/$id.meta" \
    || fail "a PR that closes each named issue did not record pr= metadata"
  pass "fm-pr-check.sh registers a PR that closes each named issue with its own keyword"
}

test_chained_issues_under_one_keyword_do_not_close_the_rest() {
  local dir id out rc
  dir=$(make_case chained-keyword)
  id=close-chain
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" "Close the three board items #421, #431, and #440."

  set +e
  FM_TEST_GH_PR_BODY="Closes #421, #431, #440" \
    out=$(run_check "$dir" "$id" https://github.com/o/r/pull/9 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check.sh registered a PR that chained #431 and #440 under one keyword"
  assert_contains "$out" "#431" "refusal did not name an issue left open by chaining"
  [ ! -e "$dir/home/state/$id.check.sh" ] \
    || fail "a chained-keyword PR still armed a merge poll"
  pass "fm-pr-check.sh refuses a PR that lists several issues after a single closing keyword"
}

test_quoted_example_issue_numbers_are_not_work_to_close() {
  local dir id
  dir=$(make_case quoted-example)
  id=close-quoted
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" \
    'A neighboring repo once wrote "Closes #421, #431, #440" under one keyword. This task has no issue to close.'

  FM_TEST_GH_PR_BODY="No related issue." \
    run_check "$dir" "$id" https://github.com/o/r/pull/10 >/dev/null 2>"$dir/stderr" \
    || fail "quoted example issue numbers were treated as work to close (got: $(cat "$dir/stderr"))"
  [ -f "$dir/home/state/$id.check.sh" ] \
    || fail "a brief whose only #N refs are quoted examples did not register"
  pass "fm-pr-check.sh does not treat quoted example issue numbers as work to close"
}

test_intent_without_issue_numbers_is_unchanged() {
  local dir id
  dir=$(make_case no-issues)
  id=close-none
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" "Refactor the parser. No tracked issue."

  FM_TEST_GH_PR_BODY="Refactor only." \
    run_check "$dir" "$id" https://github.com/o/r/pull/11 >/dev/null 2>"$dir/stderr" \
    || fail "fm-pr-check.sh refused a PR whose captain intent named no issue (got: $(cat "$dir/stderr"))"
  [ -f "$dir/home/state/$id.check.sh" ] \
    || fail "a no-issue intent did not arm a merge poll"
  pass "fm-pr-check.sh leaves registration unchanged when captain intent names no issue"
}

test_unreadable_pr_body_with_named_issue_is_refused() {
  local dir id out rc
  dir=$(make_case body-unreadable)
  id=close-nobody
  write_ship_meta "$dir" "$id"
  write_brief "$dir" "$id" "Fix the crash in #42."

  set +e
  FM_TEST_GH_BODY_RC=1 \
    out=$(run_check "$dir" "$id" https://github.com/o/r/pull/12 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-pr-check.sh registered a named-issue PR whose body could not be read"
  [ ! -e "$dir/home/state/$id.check.sh" ] \
    || fail "an unreadable-body named-issue PR still armed a merge poll"
  pass "fm-pr-check.sh refuses when a named issue cannot be verified against the PR body"
}

test_named_issue_without_closing_keyword_is_refused
test_own_keyword_per_named_issue_is_registered
test_chained_issues_under_one_keyword_do_not_close_the_rest
test_quoted_example_issue_numbers_are_not_work_to_close
test_intent_without_issue_numbers_is_unchanged
test_unreadable_pr_body_with_named_issue_is_refused
echo "# all fm-pr-check-issue-close tests passed"
