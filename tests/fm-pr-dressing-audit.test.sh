#!/usr/bin/env bash
# Tests for fm-pr-dressing-audit.sh through its executable interface.
#
# The partial-failure fixture records https://github.com/double-d-labs/go-easy-homie/pull/480
# on 2026-09-13, when its assignees applied but its reviewer list was empty.
# That condition was corrected before this audit existed, so a fixture is the
# only honest deterministic proof that its detection remains covered.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-pr-dressing-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-dressing-audit)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/config" "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

write_config() {
  local case_dir=$1
  cat > "$case_dir/home/config/pr-dressing-audit.json" <<'JSON'
{
  "repositories": {
    "double-d-labs/go-easy-homie": {
      "integration_branch": "develop",
      "reviewer_team": "double-d-labs/double-d-labs-reviewers",
      "assignees": ["dbeihl", "dalemichaelclapp-max"],
      "required_checks": ["CI gate"]
    }
  }
}
JSON
}

write_gh() {
  local case_dir=$1 payload=$2
  printf '%s\n' "$payload" > "$case_dir/pull-requests.json"
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") cat "$FM_TEST_PR_DRESSING_PAYLOAD" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_audit() {
  local case_dir=$1 out=$2 status=0
  env FM_HOME="$case_dir/home" FM_TEST_PR_DRESSING_PAYLOAD="$case_dir/pull-requests.json" \
    PATH="$case_dir/fakebin:$PATH" "$AUDIT" double-d-labs/go-easy-homie >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "audit exit"
}

test_partial_failure_fixture_and_live_case_shape_are_reported() {
  local case_dir out report
  case_dir=$(make_case acceptance-cases)
  write_config "$case_dir"
  write_gh "$case_dir" '[
    {"number":480,"url":"https://github.com/double-d-labs/go-easy-homie/pull/480","baseRefName":"main","assignees":[{"login":"dbeihl"},{"login":"dalemichaelclapp-max"}],"reviewRequests":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"SUCCESS"}]},
    {"number":485,"url":"https://github.com/double-d-labs/go-easy-homie/pull/485","baseRefName":"main","assignees":[],"reviewRequests":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"FAILURE"}]}
  ]'
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'https://github.com/double-d-labs/go-easy-homie/pull/480: reviewer team missing: double-d-labs/double-d-labs-reviewers' 'missing team reviewer was not reported with its qualified slug'
  assert_contains "$report" 'https://github.com/double-d-labs/go-easy-homie/pull/485: base branch is main; expected develop' 'live-case production branch was not reported'
  assert_contains "$report" 'https://github.com/double-d-labs/go-easy-homie/pull/485: assignees missing: dbeihl, dalemichaelclapp-max' 'live-case assignees were not reported'
  assert_contains "$report" 'https://github.com/double-d-labs/go-easy-homie/pull/485: required check failing: CI gate' 'live-case failing check was not reported'
  pass 'the partial-failure fixture and live-case violation shape are reported'
}

test_compliant_pull_request_is_silent() {
  local case_dir out
  case_dir=$(make_case compliant)
  write_config "$case_dir"
  write_gh "$case_dir" '[{"number":484,"url":"https://github.com/double-d-labs/go-easy-homie/pull/484","baseRefName":"develop","assignees":[{"login":"dbeihl"},{"login":"dalemichaelclapp-max"}],"reviewRequests":[{"__typename":"Team","slug":"double-d-labs/double-d-labs-reviewers"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"SUCCESS"}]}]'
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  [ ! -s "$out" ] || fail "compliant pull request was not silent: $(cat "$out")"
  pass 'a compliant pull request is silent'
}

test_missing_assignee_mergeability_and_failed_required_check_are_reported() {
  local case_dir out report
  case_dir=$(make_case remaining-rules)
  write_config "$case_dir"
  write_gh "$case_dir" '[{"number":485,"url":"https://github.com/double-d-labs/go-easy-homie/pull/485","baseRefName":"develop","assignees":[{"login":"dbeihl"}],"reviewRequests":[{"__typename":"Team","slug":"double-d-labs/double-d-labs-reviewers"}],"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","statusCheckRollup":[{"__typename":"CheckRun","name":"CI gate","status":"COMPLETED","conclusion":"FAILURE"}]}]'
  out="$case_dir/out"
  run_audit "$case_dir" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'assignees missing: dalemichaelclapp-max' 'missing assignee was not reported'
  assert_contains "$report" 'mergeable is CONFLICTING, not MERGEABLE' 'unmergeable pull request was not reported'
  assert_contains "$report" 'required check failing: CI gate' 'failed configured required check was not reported'
  pass 'remaining configured violations are reported'
}

test_help_states_the_unchecked_scope() {
  local out status=0
  out="$TMP_ROOT/help"
  "$AUDIT" --help >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  assert_contains "$(cat "$out")" 'It does not infer branch protection, review approvals, merge authority, or' 'help did not state the audit boundary'
  pass 'help states what the audit does not check'
}

test_partial_failure_fixture_and_live_case_shape_are_reported
test_compliant_pull_request_is_silent
test_missing_assignee_mergeability_and_failed_required_check_are_reported
test_help_states_the_unchecked_scope
