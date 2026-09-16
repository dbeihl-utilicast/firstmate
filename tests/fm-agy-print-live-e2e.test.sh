#!/usr/bin/env bash
# Opt-in live check for the Firstmate-owned one-shot Antigravity print helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PRINT_LIVE_E2E agy jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/fm-agy-print.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-print-live)
MODEL=gemini-3.8-flash-low
EFFORT=low
AGY_VERSION=$(agy --version 2>&1 | head -1 | tr -d '\r')

[ -n "$AGY_VERSION" ] || fail "agy version was empty"
mkdir -p "$TMP_ROOT/plain" "$TMP_ROOT/schema"

PLAIN_OUTPUT=$("$HELPER" \
  --prompt 'Reply with exactly AGY-PLAIN-OK.' \
  --model "$MODEL" \
  --effort "$EFFORT" \
  --cwd "$TMP_ROOT/plain" \
  --print-timeout 2m) \
  || fail "agy $AGY_VERSION plain print failed"
printf '%s\n' "$PLAIN_OUTPUT" | jq -e '
  type == "object"
  and .status == "SUCCESS"
  and (.response | type == "string" and contains("AGY-PLAIN-OK"))
' >/dev/null \
  || fail "agy $AGY_VERSION plain print returned an unexpected envelope: $PLAIN_OUTPUT"
pass "agy $AGY_VERSION plain JSON envelope passed with $MODEL at $EFFORT effort"

SCHEMA='{"type":"object","properties":{"proof":{"type":"string"}},"required":["proof"],"additionalProperties":false}'
SCHEMA_OUTPUT=$("$HELPER" \
  --prompt 'Set proof to exactly AGY-SCHEMA-OK.' \
  --model "$MODEL" \
  --effort "$EFFORT" \
  --cwd "$TMP_ROOT/schema" \
  --json-schema "$SCHEMA" \
  --print-timeout 2m) \
  || fail "agy $AGY_VERSION schema print failed"
printf '%s\n' "$SCHEMA_OUTPUT" | jq -e '
  type == "object"
  and .status == "SUCCESS"
  and .structured_output == {"proof":"AGY-SCHEMA-OK"}
' >/dev/null \
  || fail "agy $AGY_VERSION schema print returned unexpected structured output: $SCHEMA_OUTPUT"
pass "agy $AGY_VERSION schema output passed with $MODEL at $EFFORT effort"
