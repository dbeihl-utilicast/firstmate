#!/usr/bin/env bash
# Behavior tests for fm-agy-print.sh - the Firstmate-owned one-shot
# Antigravity print path.
#
# Pins the contract that this helper is not a worker runtime: one prompt in,
# one JSON envelope out, isolated cwd, explicit model and effort, no
# --dangerously-skip-permissions, no TUI flags, and empty structured_output
# with a schema is a failure even when agy exits 0 with status SUCCESS.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-agy-print-tests)
SCRIPT="$ROOT/bin/fm-agy-print.sh"

STDIN_SENTINEL='SENTINEL-STDIN-MUST-NOT-REACH-AGY'

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_AGY_LOG"
pwd -P >> "$FM_FAKE_AGY_CWD"
if IFS= read -r -t 1 leaked; then
  printf '%s\n' "$leaked" >> "$FM_FAKE_AGY_STDIN"
fi
case "${FM_FAKE_AGY_MODE:-success}" in
  success)
    printf '%s\n' '{"conversation_id":"cid-1","status":"SUCCESS","response":"PING42\n"}'
    exit 0
    ;;
  warning-then-json)
    printf '%s\n' 'warning: ignored hooks'
    printf '%s\n' '{"conversation_id":"cid-2","status":"SUCCESS","response":"PING43\n"}'
    exit 0
    ;;
  multiple-json)
    printf '%s\n' '{"conversation_id":"cid-9","status":"SUCCESS","response":"first"}'
    printf '%s\n' '{"conversation_id":"cid-10","status":"SUCCESS","response":"second"}'
    exit 0
    ;;
  schema-ok)
    printf '%s\n' '{"conversation_id":"cid-3","status":"SUCCESS","structured_output":{"major":2,"minor":14,"patch":3}}'
    exit 0
    ;;
  empty-structured)
    printf '%s\n' '{"conversation_id":"cid-4","status":"SUCCESS","structured_output":{}}'
    exit 0
    ;;
  null-structured)
    printf '%s\n' '{"conversation_id":"cid-5","status":"SUCCESS","structured_output":null}'
    exit 0
    ;;
  missing-structured)
    printf '%s\n' '{"conversation_id":"cid-6","status":"SUCCESS","response":"ok"}'
    exit 0
    ;;
  failed-status)
    printf '%s\n' '{"conversation_id":"cid-7","status":"ERROR","response":""}'
    exit 0
    ;;
  no-json)
    printf '%s\n' 'not an envelope'
    exit 0
    ;;
  nonzero)
    printf '%s\n' '{"conversation_id":"cid-8","status":"SUCCESS","response":"late"}'
    exit 3
    ;;
  nonzero-error)
    printf '%s\n' '{"conversation_id":"cid-11","status":"ERROR","response":"unknown model"}'
    exit 1
    ;;
  hang)
    sleep 30
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

RUN_OUT=
RUN_ERR=
RUN_RC=0
RUN_LOG=
RUN_CWD_LOG=
RUN_STDIN=
run_print() {
  local case_name=$1
  shift
  local case_dir fakebin workspace rc=0 arg
  local -a script_args=() env_pairs=()
  case_dir="$TMP_ROOT/$case_name"
  mkdir -p "$case_dir/workspace"
  fakebin=$(make_fakebin "$case_dir")
  workspace="$case_dir/workspace"
  RUN_LOG="$case_dir/agy.log"
  RUN_CWD_LOG="$case_dir/agy.cwd"
  RUN_STDIN="$case_dir/agy.stdin"
  : > "$RUN_LOG"
  : > "$RUN_CWD_LOG"
  : > "$RUN_STDIN"
  local seen_separator=0
  for arg in "$@"; do
    if [ "$seen_separator" -eq 0 ] && [ "$arg" = --env ]; then
      seen_separator=1
      continue
    fi
    if [ "$seen_separator" -eq 0 ]; then
      script_args+=("$arg")
    else
      env_pairs+=("$arg")
    fi
  done
  RUN_OUT=$(env "PATH=$fakebin:$BASE_PATH" \
    "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "FM_FAKE_AGY_CWD=$RUN_CWD_LOG" \
    "FM_FAKE_AGY_STDIN=$RUN_STDIN" \
    "${env_pairs[@]+"${env_pairs[@]}"}" \
    "$SCRIPT" --cwd "$workspace" "${script_args[@]+"${script_args[@]}"}" \
    <<<"$STDIN_SENTINEL" 2>"$case_dir/stderr") || rc=$?
  RUN_RC=$rc
  RUN_ERR=$(cat "$case_dir/stderr")
}

# Prompt is a single token so unquoted expansion in the cases below is safe.
PROMPT_ARG=PING42
MODEL_ARG=gemini-3.8-flash-low
EFFORT_ARG=low

assert_agy_never_ran() {
  [ ! -s "$RUN_LOG" ] || fail "$1: agy must not run, but argv was: $(tr '\n' '|' < "$RUN_LOG")"
}

assert_no_forbidden_flags() {
  local token
  for token in --dangerously-skip-permissions --prompt-interactive --input-format --continue --conversation --sandbox; do
    if grep -Fq -- "$token" "$RUN_LOG"; then
      fail "$1: forbidden flag $token in argv: $(tr '\n' '|' < "$RUN_LOG")"
    fi
  done
}

assert_required_argv() {
  local line=$1
  assert_contains "$line" "--print=$PROMPT_ARG" "$2: missing --print="
  assert_contains "$line" '--output-format json' "$2: missing --output-format json"
  assert_contains "$line" "--model $MODEL_ARG" "$2: missing --model"
  assert_contains "$line" "--effort $EFFORT_ARG" "$2: missing --effort"
  assert_contains "$line" '--print-timeout' "$2: missing --print-timeout"
}

test_usage_requires_prompt_model_effort_cwd() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/usage-missing"
  mkdir -p "$case_dir/workspace"
  fakebin=$(make_fakebin "$case_dir")
  RUN_LOG="$case_dir/agy.log"
  : > "$RUN_LOG"

  rc=0
  env "PATH=$fakebin:$BASE_PATH" "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "$SCRIPT" --model m --effort low --cwd "$case_dir/workspace" \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 2 "$rc" "missing --prompt is a usage error"
  assert_contains "$(cat "$case_dir/err")" '--prompt is required' 'missing prompt names the flag'

  rc=0
  env "PATH=$fakebin:$BASE_PATH" "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "$SCRIPT" --prompt p --effort low --cwd "$case_dir/workspace" \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 2 "$rc" "missing --model is a usage error"

  rc=0
  env "PATH=$fakebin:$BASE_PATH" "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "$SCRIPT" --prompt p --model m --cwd "$case_dir/workspace" \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 2 "$rc" "missing --effort is a usage error"

  rc=0
  env "PATH=$fakebin:$BASE_PATH" "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "$SCRIPT" --prompt p --model m --effort low \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 2 "$rc" "missing --cwd is a usage error"

  [ ! -s "$RUN_LOG" ] || fail "usage errors must not invoke agy"
  pass "missing required flags are usage errors and do not invoke agy"
}

test_noncanonical_options_are_usage_errors() {
  run_print bad-effort --prompt p --model m --effort xhigh
  expect_code 2 "$RUN_RC" "unsupported effort is a usage error"
  assert_agy_never_ran "bad-effort"

  run_print skip-perms --prompt p --model m --effort low --dangerously-skip-permissions
  expect_code 2 "$RUN_RC" "--dangerously-skip-permissions is refused"
  assert_agy_never_ran "skip-perms"

  run_print tui --prompt p --model m --effort low --prompt-interactive
  expect_code 2 "$RUN_RC" "--prompt-interactive is refused"
  assert_agy_never_ran "tui"

  run_print harness --prompt p --model m --effort low --harness agy
  expect_code 2 "$RUN_RC" "--harness is refused"
  assert_agy_never_ran "harness"

  run_print long-alias --print p --model m --effort low
  expect_code 2 "$RUN_RC" "--print is not a prompt alias"
  assert_agy_never_ran "long-alias"

  run_print short-alias -p p --model m --effort low
  expect_code 2 "$RUN_RC" "-p is not a prompt alias"
  assert_agy_never_ran "short-alias"

  run_print trailing-separator --prompt p --model m --effort low --
  expect_code 2 "$RUN_RC" "a trailing -- is not accepted"
  assert_agy_never_ran "trailing-separator"

  run_print short-help -h
  expect_code 2 "$RUN_RC" "-h is not a help alias"
  assert_agy_never_ran "short-help"

  run_print equals-prompt --prompt=p --model m --effort low
  expect_code 2 "$RUN_RC" "--prompt= is not accepted"
  assert_agy_never_ran "equals-prompt"

  run_print equals-model --prompt p --model=m --effort low
  expect_code 2 "$RUN_RC" "--model= is not accepted"
  assert_agy_never_ran "equals-model"

  run_print equals-effort --prompt p --model m --effort=low
  expect_code 2 "$RUN_RC" "--effort= is not accepted"
  assert_agy_never_ran "equals-effort"

  run_print equals-cwd --prompt p --model m --effort low --cwd=/
  expect_code 2 "$RUN_RC" "--cwd= is not accepted"
  assert_agy_never_ran "equals-cwd"

  run_print equals-schema --prompt p --model m --effort low --json-schema='{}'
  expect_code 2 "$RUN_RC" "--json-schema= is not accepted"
  assert_agy_never_ran "equals-schema"

  run_print equals-timeout --prompt p --model m --effort low --print-timeout=1s
  expect_code 2 "$RUN_RC" "--print-timeout= is not accepted"
  assert_agy_never_ran "equals-timeout"

  run_print bare-timeout --prompt p --model m --effort low --print-timeout 1
  expect_code 2 "$RUN_RC" "a bare-number timeout is not accepted"
  assert_agy_never_ran "bare-timeout"
  pass "only canonical space-separated options are accepted"
}

test_long_help_remains_available() {
  local rc=0
  RUN_OUT=$("$SCRIPT" --help 2>"$TMP_ROOT/help.stderr") || rc=$?
  expect_code 0 "$rc" "--help succeeds"
  assert_contains "$RUN_OUT" 'Usage:' "--help prints usage"
  assert_equals '' "$(cat "$TMP_ROOT/help.stderr")" "--help does not print an error"
  pass "long-form help remains available"
}

test_missing_cwd_fails_before_agy() {
  local case_dir fakebin rc=0
  case_dir="$TMP_ROOT/missing-cwd"
  mkdir -p "$case_dir"
  fakebin=$(make_fakebin "$case_dir")
  RUN_LOG="$case_dir/agy.log"
  : > "$RUN_LOG"
  env "PATH=$fakebin:$BASE_PATH" "FM_FAKE_AGY_LOG=$RUN_LOG" \
    "$SCRIPT" --prompt p --model m --effort low --cwd "$case_dir/no-such" \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 1 "$rc" "a missing cwd is a run failure, not a usage error"
  assert_contains "$(cat "$case_dir/err")" 'cwd is not a directory' 'missing cwd is named'
  [ ! -s "$RUN_LOG" ] || fail "a missing cwd must not invoke agy"
  pass "a missing cwd fails closed before agy runs"
}

test_success_prints_compact_envelope() {
  run_print success --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG"
  expect_code 0 "$RUN_RC" "SUCCESS envelope exits 0"
  assert_equals '{"conversation_id":"cid-1","status":"SUCCESS","response":"PING42\n"}' \
    "$RUN_OUT" "stdout is the compact envelope only"
  local workspace
  assert_required_argv "$(cat "$RUN_LOG")" "success"
  assert_no_forbidden_flags "success"
  workspace=$(cd "$TMP_ROOT/success/workspace" && pwd -P)
  assert_equals "$workspace" "$(cat "$RUN_CWD_LOG")" "agy ran in the isolated cwd"
  [ ! -s "$RUN_STDIN" ] || fail "agy stdin must stay closed, leaked: $(cat "$RUN_STDIN")"
  pass "SUCCESS without a schema prints the envelope from the isolated cwd"
}

test_stdout_must_be_exactly_one_json_object() {
  run_print preamble --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=warning-then-json"
  expect_code 1 "$RUN_RC" "a stdout preamble invalidates the envelope"
  [ -z "$RUN_OUT" ] || fail "preamble output must not be partially accepted: $RUN_OUT"

  run_print multiple --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=multiple-json"
  expect_code 1 "$RUN_RC" "multiple JSON values invalidate the envelope"
  [ -z "$RUN_OUT" ] || fail "multiple objects must not select one envelope: $RUN_OUT"
  pass "agy stdout must contain exactly one JSON object"
}

test_schema_requires_nonempty_structured_output() {
  local schema='{"type":"object","properties":{"major":{"type":"number"}},"required":["major"]}'
  run_print schema-ok --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --json-schema "$schema" --env "FM_FAKE_AGY_MODE=schema-ok"
  expect_code 0 "$RUN_RC" "non-empty structured_output succeeds"
  assert_contains "$RUN_OUT" '"structured_output":{"major":2,"minor":14,"patch":3}' \
    "schema success keeps structured_output"
  assert_contains "$(cat "$RUN_LOG")" "--json-schema $schema" "schema is passed through"

  run_print empty-so --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --json-schema "$schema" --env "FM_FAKE_AGY_MODE=empty-structured"
  expect_code 1 "$RUN_RC" "empty structured_output fails"
  assert_equals '{"conversation_id":"cid-4","status":"SUCCESS","structured_output":{}}' \
    "$RUN_OUT" "empty structured_output still emits its envelope"
  assert_equals '' "$RUN_ERR" "a parsed empty-result envelope needs no second error signal"

  run_print null-so --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --json-schema "$schema" --env "FM_FAKE_AGY_MODE=null-structured"
  expect_code 1 "$RUN_RC" "null structured_output fails"
  assert_equals '{"conversation_id":"cid-5","status":"SUCCESS","structured_output":null}' \
    "$RUN_OUT" "null structured_output still emits its envelope"

  run_print missing-so --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --json-schema "$schema" --env "FM_FAKE_AGY_MODE=missing-structured"
  expect_code 1 "$RUN_RC" "missing structured_output fails when a schema is used"
  assert_equals '{"conversation_id":"cid-6","status":"SUCCESS","response":"ok"}' \
    "$RUN_OUT" "a missing structured_output still emits its envelope"
  pass "a schema gates on non-empty structured_output, including empty SUCCESS"
}

test_failed_status_and_missing_envelope_fail() {
  run_print failed --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=failed-status"
  expect_code 1 "$RUN_RC" "non-SUCCESS status fails"
  assert_equals '{"conversation_id":"cid-7","status":"ERROR","response":""}' \
    "$RUN_OUT" "a failed status emits its envelope"
  assert_equals '' "$RUN_ERR" "a parsed ERROR envelope needs no second error signal"

  run_print nojson --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=no-json"
  expect_code 1 "$RUN_RC" "stdout without JSON fails"
  assert_contains "$RUN_ERR" 'no JSON envelope' 'missing envelope is named'
  pass "non-SUCCESS status and missing envelopes fail closed"
}

test_nonzero_exit_fails_even_with_success_envelope() {
  run_print nonzero --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=nonzero"
  expect_code 1 "$RUN_RC" "agy non-zero exit fails even with a SUCCESS envelope"
  assert_equals '{"conversation_id":"cid-8","status":"SUCCESS","response":"late"}' \
    "$RUN_OUT" "a non-zero exit still emits its parseable envelope"
  assert_equals '' "$RUN_ERR" "a parsed non-zero envelope needs no second error signal"

  run_print nonzero-error --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "FM_FAKE_AGY_MODE=nonzero-error"
  expect_code 1 "$RUN_RC" "agy ERROR envelope and non-zero exit fail"
  assert_equals '{"conversation_id":"cid-11","status":"ERROR","response":"unknown model"}' \
    "$RUN_OUT" "a non-zero ERROR result emits its envelope"
  assert_equals '' "$RUN_ERR" "an ERROR envelope is the only structured failure detail"
  pass "agy exit status gates success without discarding its envelope"
}

test_print_timeout_is_passed_and_hangs_are_bounded() {
  run_print timeout-flag --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --print-timeout 2m
  expect_code 0 "$RUN_RC" "custom timeout still succeeds"
  assert_contains "$(cat "$RUN_LOG")" '--print-timeout 2m' 'caller timeout is passed through'

  local started finished
  started=$(date +%s)
  run_print hang --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --print-timeout 1s --env "FM_FAKE_AGY_MODE=hang"
  finished=$(date +%s)
  expect_code 1 "$RUN_RC" "a hang is a failure"
  assert_contains "$RUN_ERR" 'timed out' 'a hang is reported as timeout'
  [ $((finished - started)) -lt 25 ] \
    || fail "the hang was not bounded: took $((finished - started))s"
  pass "print-timeout is passed through and a hung agy cannot wedge the caller"
}

test_missing_agy_is_a_run_failure() {
  local case_dir fakebin rc=0
  case_dir="$TMP_ROOT/agy-absent"
  mkdir -p "$case_dir/workspace" "$case_dir/fakebin"
  env "PATH=$case_dir/fakebin:$BASE_PATH" \
    "$SCRIPT" --prompt p --model m --effort low --cwd "$case_dir/workspace" \
    >/dev/null 2>"$case_dir/err" || rc=$?
  expect_code 1 "$rc" "missing agy is a run failure"
  assert_contains "$(cat "$case_dir/err")" 'agy is not on PATH' 'missing binary is named'
  pass "a missing agy binary is reported rather than launched as a worker"
}

test_agy_is_resolved_from_path() {
  run_print path-only --prompt "$PROMPT_ARG" --model "$MODEL_ARG" --effort "$EFFORT_ARG" --env "AGY_BIN=$TMP_ROOT/not-a-command"
  expect_code 0 "$RUN_RC" "unrelated environment does not replace the PATH binary"
  assert_equals '{"conversation_id":"cid-1","status":"SUCCESS","response":"PING42\n"}' \
    "$RUN_OUT" "the PATH agy result is returned"
  pass "agy is resolved only from PATH"
}

test_usage_requires_prompt_model_effort_cwd
test_noncanonical_options_are_usage_errors
test_long_help_remains_available
test_missing_cwd_fails_before_agy
test_success_prints_compact_envelope
test_stdout_must_be_exactly_one_json_object
test_schema_requires_nonempty_structured_output
test_failed_status_and_missing_envelope_fail
test_nonzero_exit_fails_even_with_success_envelope
test_print_timeout_is_passed_and_hangs_are_bounded
test_missing_agy_is_a_run_failure
test_agy_is_resolved_from_path
