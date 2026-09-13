#!/usr/bin/env bash
# Behavior tests for CI test-evidence log verification.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-ci-test-evidence.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-test-evidence)

# The fake replays gh-axi 0.1.35 transcripts: api rows arrive in an
# `api_response:` envelope and job logs in a `run_log:` envelope whose tail is
# cut at 20000 chars, with the whole log saved at `full_log`.
make_fixture() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  printf '%s\n' \
    'Integration tests	Run unit	2026-09-12T22:06:35.2761040Z ======== 50 passed, 3 skipped in 5.00s ========' \
    'Integration tests	Run integration	2026-09-12T22:07:05.2761040Z ======== 120 passed in 30.00s ========' > "$dir/full-12.log"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
fixture=${0%/fakebin/gh-axi}
body() { printf '%s\n' 'api_response:' "  body: $1" '  truncated: false'; }
log() { printf '%s\n' 'run_log:' "  run: \"$1\"" '  mode: log' "  output: $2" '  truncated: false'; }
case "$1 ${2:-}" in
  'api '*)
    case " $* " in *' --full '*) ;; *) exit 1 ;; esac
    case "$2" in
      /repos/acme/market-pulse/pulls/458) body '"head\th458"' ;;
      '/repos/acme/market-pulse/actions/runs?event=pull_request&head_sha=h458&per_page=100') body '"run\t101"' ;;
      '/repos/acme/market-pulse/actions/runs/101/jobs?per_page=100') body '"job\t101\t11\tIntegration tests\tsuccess"' ;;
      /repos/acme/market-pulse/pulls/459) body '"head\th459"' ;;
      '/repos/acme/market-pulse/actions/runs?event=pull_request&head_sha=h459&per_page=100') body '"run\t201\nrun\t202"' ;;
      '/repos/acme/market-pulse/actions/runs/201/jobs?per_page=100') body '"job\t201\t11\tIntegration tests\tsuccess"' ;;
      '/repos/acme/market-pulse/actions/runs/202/jobs?per_page=100') body '"job\t202\t22\tIntegration tests\tskipped"' ;;
      '/repos/acme/repo/actions/runs/481/jobs?per_page=100') body '"job\t481\t12\tIntegration tests\tsuccess\njob\t481\t13\tBrowser tests\tsuccess\njob\t481\t14\tCollection tests\tfailure\njob\t481\t15\tJest tests\tsuccess\njob\t481\t16\tStill running\t"' ;;
      /repos/double-d-labs/go-easy-homie/pulls/481) body '"head\tf555c27acbe817beed5ea54d8aa8639d3a77d83f"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs?event=pull_request&head_sha=f555c27acbe817beed5ea54d8aa8639d3a77d83f&per_page=100') body '"run\t34721814954\nrun\t34721814948\nrun\t34721814926"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814954/jobs?per_page=100') body '"job\t34721814954\t103628992346\tMCP - Build, Type Check & Tests\tsuccess"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814948/jobs?per_page=100') body '"job\t34721814948\t103628992350\tWeb Security Scan\tsuccess\njob\t34721814948\t103628992409\tMobile Security Scan\tsuccess\njob\t34721814948\t103628992421\tBackend Security Scan\tsuccess\njob\t34721814948\t103628992427\tSecrets Detection\tsuccess"' ;;
      '/repos/double-d-labs/go-easy-homie/actions/runs/34721814926/jobs?per_page=100') body '"job\t34721814926\t103628992271\tDetect changed packages\tsuccess\njob\t34721814926\t103628992751\tWeb - Lint, Type Check & Build\tskipped\njob\t34721814926\t103628992888\tBackend - Lint, Type Check & Build\tskipped\njob\t34721814926\t103628992957\tBackend - Unit Tests\tskipped\njob\t34721814926\t103628993171\tWeb - E2E Tests (Playwright)\tskipped\njob\t34721814926\t103628993607\tMobile - Type Check & Tests\tskipped\njob\t34721814926\t103629008439\tDevelop slim - Web lint & type check (tests run locally)\tsuccess\njob\t34721814926\t103629008440\tDevelop slim - Backend lint & type check (tests run locally)\tsuccess\njob\t34721814926\t103629008448\tDevelop slim - Mobile type check (tests run locally)\tsuccess\njob\t34721814926\t103629129467\tCI gate\tsuccess"' ;;
      *) exit 1 ;;
    esac
    ;;
  'run view')
    case " $* " in
      *' --job 11 '*) log "$2" '"Integration tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 2366 passed in 40.00s ========\n"' ;;
      *' --job 12 '*)
        printf '%s\n' 'run_log:' "  run: \"$2\"" '  mode: log' \
          '  output: "Integration tests\tRun integration\t2026-09-12T22:07:05.2761040Z ======== 120 passed in 30.00s ========\n"' \
          '  truncated: true' '  original_length: 33797' "  full_log: $fixture/full-12.log" \
          'help[1]:' "  Output shows the last 20000 of 33797 chars; full log saved to $fixture/full-12.log - grep it for earlier context"
        ;;
      *' --job 13 '*) log "$2" '"Browser tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 8 passed, 1 deselected in 1.00s ========\n"' ;;
      *' --job 14 '*) log "$2" '"Collection tests\tRun tests\t2026-09-12T22:06:35.2761040Z ======== 2 errors in 0.30s ========\n"' ;;
      *' --job 15 '*) log "$2" '"Jest tests\tRun tests\t2026-09-12T22:06:35.2761040Z Tests:       40 passed, 40 total\nJest tests\tRun tests\t2026-09-12T22:06:35.2761040Z FM_TEST_EVIDENCE executed=40 skipped=0 deselected=0\n"' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/gh-axi"
}

local_check() {
  env -u GITHUB_ACTIONS -u CI "$CHECK" "$@"
}

test_positive_pr_is_silent() {
  local dir out rc
  dir="$TMP_ROOT/positive"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/acme/market-pulse/pull/458 --required-job 'Integration tests' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "positive PR exit=$rc: $out"
  [ -z "$out" ] || fail "positive PR printed despite complete evidence: $out"
  pass 'positive single-run PR is silent with executed tests and zero skipped/deselected'
}

test_go_easy_homie_pr_481_skipped_jobs_are_red() {
  local dir out rc job
  dir="$TMP_ROOT/pr-481"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/double-d-labs/go-easy-homie/pull/481 \
    --required-job 'Web - Lint, Type Check & Build' --required-job 'Backend - Lint, Type Check & Build' \
    --required-job 'Backend - Unit Tests' --required-job 'Web - E2E Tests (Playwright)' \
    --required-job 'Mobile - Type Check & Tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "PR 481 exit=$rc: $out"
  for job in 'Web - Lint, Type Check & Build' 'Backend - Lint, Type Check & Build' 'Backend - Unit Tests' 'Web - E2E Tests (Playwright)' 'Mobile - Type Check & Tests'; do
    assert_contains "$out" "$job executed=0 skipped=unknown" "skipped PR 481 job $job was not a violation"
  done
  pass 'go-easy-homie PR 481 rejects its five skipped jobs'
}

test_duplicate_job_names_are_all_checked() {
  local dir out rc
  dir="$TMP_ROOT/duplicate"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --pr https://github.com/acme/market-pulse/pull/459 --required-job 'Integration tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "duplicate job exit=$rc: $out"
  assert_contains "$out" 'Integration tests executed=0 skipped=unknown' 'skipped copy of a measured job name passed'
  pass 'every job sharing a required name is measured'
}

test_log_evidence_violations_are_red() {
  local dir out rc
  dir="$TMP_ROOT/negative"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Integration tests' \
    --required-job 'Browser tests' --required-job 'Collection tests' --required-job 'Jest tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "negative run exit=$rc: $out"
  assert_contains "$out" 'Integration tests executed=170 skipped=3 deselected=0' 'skip count before the truncated log tail was not a violation'
  assert_contains "$out" 'Browser tests executed=8 skipped=0 deselected=1' 'deselected count was not a violation'
  assert_contains "$out" 'Collection tests errors=2' 'collection errors were not a distinct violation'
  assert_contains "$out" 'Collection tests executed=0' 'collection errors were counted as executed tests'
  assert_contains "$out" 'not measured: required job Jest tests' 'non-pytest log was accepted as evidence'
  pass 'skipped, deselected, errored, and unmeasured logs fail despite green conclusions'
}

test_absent_required_job_is_red() {
  local dir out rc
  dir="$TMP_ROOT/absent"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Missing tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "absent job exit=$rc: $out"
  assert_contains "$out" 'absent: required job Missing tests' 'absent job was not named'
  pass 'absent required job fails rather than trusting other green checks'
}

test_unreadable_log_is_local_notice_but_ci_failure() {
  local dir out rc
  dir="$TMP_ROOT/unreadable-log"
  make_fixture "$dir"
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' --required-job 'Browser tests' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "local unreadable log with a violation exit=$rc: $out"
  assert_contains "$out" 'not checked: required job Still running log could not be read' 'local unreadable log was not scoped'
  assert_contains "$out" 'Browser tests executed=8 skipped=0 deselected=1' 'unreadable log stopped later required jobs'
  out=$(PATH="$dir/fakebin:$PATH" local_check --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "local unreadable log exit=$rc: $out"
  out=$(PATH="$dir/fakebin:$PATH" GITHUB_ACTIONS=true "$CHECK" --run https://github.com/acme/repo/actions/runs/481 --required-job 'Still running' 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "CI unreadable log exit=$rc: $out"
  assert_contains "$out" 'unverified: required job Still running log could not be read' 'CI unreadable log did not fail closed'
  pass 'unreadable log keeps earlier violations locally and fails closed in CI'
}

test_unavailable_read_is_local_notice_but_ci_failure() {
  local out rc path
  path=$(fm_test_base_path_sans "$PATH" gh-axi)
  out=$(PATH="$path" local_check --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "local unavailable exit=$rc: $out"
  assert_contains "$out" 'not checked: GitHub Actions evidence could not be read because gh-axi is unavailable' 'local unavailable read was not scoped'
  out=$(PATH="$path" GITHUB_ACTIONS=true "$CHECK" --run https://github.com/acme/repo/actions/runs/9 --required-job tests 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "CI unavailable exit=$rc: $out"
  assert_contains "$out" 'unverified: GitHub Actions evidence could not be read because gh-axi is unavailable' 'CI unavailable read did not fail closed'
  pass 'unavailable evidence is usable locally and fail-closed in CI'
}

test_positive_pr_is_silent
test_go_easy_homie_pr_481_skipped_jobs_are_red
test_duplicate_job_names_are_all_checked
test_log_evidence_violations_are_red
test_absent_required_job_is_red
test_unreadable_log_is_local_notice_but_ci_failure
test_unavailable_read_is_local_notice_but_ci_failure
