#!/usr/bin/env bash
# Behavior tests for CI test-evidence log verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ci-test-evidence.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-test-evidence)

make_fixture() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'api '*)
    case "$2" in
      */pulls/458) printf '%s\n' 'api_response:' '  body: "head458"' ;;
      *'actions/runs?event=pull_request&head_sha=head458&per_page=100') printf '%s\n' 'api_response:' '  body: "101"' ;;
      */actions/runs/101/jobs?per_page=100) printf '%s\n' 'api_response:' '  body: "11\tIntegration tests\tsuccess"' ;;
      */actions/runs/481/jobs?per_page=100) printf '%s\n' 'api_response:' '  body: "12\tIntegration tests\tsuccess\n13\tBrowser tests\tsuccess\n14\tSkipped suite\tskipped"' ;;
      *) exit 1 ;;
    esac
    ;;
  'run view')
    case "$*" in
      *' --job 11 '*) printf '%s\n' '2366 passed, 0 skipped, 0 deselected in 40.00s' ;;
      *' --job 12 '*) printf '%s\n' '4 passed, 2 skipped, 0 deselected in 1.00s' ;;
      *' --job 13 '*) printf '%s\n' '8 passed, 0 skipped, 1 deselected in 1.00s' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
}

test_positive_pr_is_silent() {
  local dir out rc
  dir="$TMP_ROOT/positive"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" "$CHECK" --pr https://github.com/acme/market-pulse/pull/458 --required-job 'Integration tests' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "positive PR exit=$rc: $out"
  [ -z "$out" ] || fail "positive PR printed despite complete evidence: $out"
  pass 'positive PR is silent with executed tests and zero skipped/deselected'
}

test_skip_and_deselection_are_red() {
  local dir out rc
  dir="$TMP_ROOT/negative"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" "$CHECK" --run https://github.com/acme/go-easy-homie/actions/runs/481 --required-job 'Integration tests' --required-job 'Browser tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "negative run exit=$rc: $out"
  assert_contains "$out" 'Integration tests executed=4 skipped=2 deselected=0' 'skip count was not a violation'
  assert_contains "$out" 'Browser tests executed=8 skipped=0 deselected=1' 'deselected count was not a violation'
  pass 'skip and deselection evidence fail despite a log that could be green'
}

test_absent_required_job_is_red() {
  local dir out rc
  dir="$TMP_ROOT/absent"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" "$CHECK" --run https://github.com/acme/go-easy-homie/actions/runs/481 --required-job 'Missing tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "absent job exit=$rc: $out"
  assert_contains "$out" 'absent: required job Missing tests' 'absent job was not named'
  pass 'absent required job fails rather than trusting other green checks'
}

test_skipped_job_without_a_log_is_red() {
  local dir out rc
  dir="$TMP_ROOT/skipped-job"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" "$CHECK" --run https://github.com/acme/go-easy-homie/actions/runs/481 --required-job 'Skipped suite' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "skipped job exit=$rc: $out"
  assert_contains "$out" 'Skipped suite executed=0 skipped=unknown deselected=unknown' 'skipped job did not fail without treating green as evidence'
  pass 'skipped job without a log is an explicit failed measurement'
}

test_unavailable_read_is_local_notice_but_ci_failure() {
  local dir out rc
  dir="$TMP_ROOT/unavailable"
  mkdir -p "$dir/fakebin"
  out=$(PATH="$dir/fakebin:$PATH" "$CHECK" --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "local unavailable exit=$rc: $out"
  assert_contains "$out" 'not checked:' 'local unavailable read was not scoped'
  out=$(PATH="$dir/fakebin:$PATH" GITHUB_ACTIONS=true "$CHECK" --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "CI unavailable exit=$rc: $out"
  assert_contains "$out" 'unverified:' 'CI unavailable read did not fail closed'
  pass 'unavailable evidence is usable locally and fail-closed in CI'
}

test_positive_pr_is_silent
test_skip_and_deselection_are_red
test_absent_required_job_is_red
test_skipped_job_without_a_log_is_red
test_unavailable_read_is_local_notice_but_ci_failure
