#!/usr/bin/env bash
# Behavior tests for the scout-report second-reading path.
#
# Stubs the fm-agy-print boundary so CI proves the structured verdict contract
# without a live agy call.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-agy-second-read.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-second-read-tests)

make_fake_helper() {
  local dir=$1 helper
  helper="$dir/fm-agy-print.sh"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HELPER_LOG"
printf '%s\n' '{"status":"SUCCESS","structured_output":'"$FM_FAKE_VERDICT"'}'
SH
  chmod +x "$helper"
  printf '%s\n' "$helper"
}

RUN_ERR=
RUN_RC=0
RUN_LOG=
run_second_read() {
  local case_name=$1 verdict=$2
  shift 2
  local case_dir helper rc=0
  case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir/results"
  printf '# Sample report\n\nThe claimed launch date is 2026-10-01.\n' > "$case_dir/report.md"
  helper=$(make_fake_helper "$case_dir")
  RUN_LOG="$case_dir/helper.log"
  : > "$RUN_LOG"
  env "FM_AGY_PRINT_BIN=$helper" "FM_FAKE_HELPER_LOG=$RUN_LOG" \
    "FM_FAKE_VERDICT=$verdict" \
    "$SCRIPT" --report "$case_dir/report.md" --verdict "$case_dir/results/verdict.json" \
    --model gemini-3.8-flash --effort low "$@" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  RUN_RC=$rc
  RUN_ERR=$(cat "$case_dir/stderr")
  CASE_DIR="$case_dir"
}

KNOWN_ERROR_VERDICT='{"schema_version":"agy-second-reading.v1","verdict":"concerns","checks_performed":[{"claim_or_question":"Does the report state a supported launch date?","method":"Compared the stated date against the report timeline.","evidence_locations":["paragraph 2"],"result":"The report claims 2026-10-01 despite the timeline stating 2026-11-01."}],"checks_not_performed":[{"check":"Validate the external release calendar.","reason":"The deliverable contains no linked calendar or source."}],"findings":[{"severity":"high","location":"paragraph 2","problem":"The launch date is one month earlier than the timeline date.","evidence":"The claim says 2026-10-01 while the timeline says 2026-11-01.","recommended_action":"Correct the launch date and cite the authoritative timeline."}],"conclusion":"A specific date contradiction would cause an incorrect launch decision, so this report needs correction."}'
CLEAN_VERDICT='{"schema_version":"agy-second-reading.v1","verdict":"pass","checks_performed":[{"claim_or_question":"Are the stated dates internally consistent?","method":"Compared every date claim in the report.","evidence_locations":["paragraph 2"],"result":"The date claim agrees with the timeline in the deliverable."}],"checks_not_performed":[{"check":"Verify the external release calendar.","reason":"No external calendar was supplied with this deliverable."}],"findings":[],"no_findings_basis":"The independently checked internal date claim is consistent, and no unsupported contradiction remains in the supplied report.","conclusion":"The checked deliverable is internally consistent, with the external calendar explicitly left unverified."}'

assert_helper_contract() {
  local log
  log=$(cat "$RUN_LOG")
  assert_contains "$log" '--model gemini-3.8-flash' 'model is explicit at the helper boundary'
  assert_contains "$log" '--effort low' 'effort is explicit at the helper boundary'
  assert_contains "$log" '--json-schema ' 'second-reading schema is passed to the helper'
  assert_contains "$log" 'second-reading.schema.json' 'the canonical schema file is used'
  assert_contains "$log" '--cwd ' 'the helper receives an isolated directory'
  assert_contains "$log" 'fm-agy-second-read.' 'the helper cwd is created for this reading'
}

test_known_error_is_preserved_as_a_locatable_finding() {
  run_second_read known-error "$KNOWN_ERROR_VERDICT"
  expect_code 0 "$RUN_RC" 'a structured verdict with a known error succeeds'
  assert_helper_contract
  [ -f "$CASE_DIR/results/verdict.json" ] || fail 'known-error verdict was not written'
  jq -e '.verdict == "concerns" and .findings[0].location == "paragraph 2" and .findings[0].severity == "high"' \
    "$CASE_DIR/results/verdict.json" >/dev/null || fail 'known error was not preserved as a precise finding'
  pass 'known deliverable error becomes a locatable structured concern'
}

test_clean_report_is_preserved_without_an_invented_finding() {
  run_second_read clean "$CLEAN_VERDICT"
  expect_code 0 "$RUN_RC" 'a clean structured verdict succeeds'
  jq -e '.verdict == "pass" and (.findings | length == 0) and (.no_findings_basis | length >= 30)' \
    "$CASE_DIR/results/verdict.json" >/dev/null || fail 'clean report did not retain its justified empty findings list'
  pass 'clean deliverable preserves a justified pass without invented findings'
}

test_non_object_verdict_refuses_to_publish() {
  run_second_read invalid '"not an object"'
  expect_code 1 "$RUN_RC" 'non-object structured output is rejected'
  assert_contains "$RUN_ERR" 'not an agy-second-reading.v1 object' 'invalid structured output identifies the contract'
  [ ! -e "$CASE_DIR/results/verdict.json" ] || fail 'invalid verdict must not be published'
  pass 'non-object model output cannot become a second-reading verdict'
}

test_known_error_is_preserved_as_a_locatable_finding
test_clean_report_is_preserved_without_an_invented_finding
test_non_object_verdict_refuses_to_publish
