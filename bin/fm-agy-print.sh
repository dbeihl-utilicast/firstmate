#!/usr/bin/env bash
# fm-agy-print.sh - Firstmate-owned one-shot Antigravity print path.
#
# One prompt in, one JSON envelope out, then exit. This is not a worker
# runtime, not a harness adapter, and not a TUI spawn. There is no busy or
# idle classifier, no steer, no interrupt, no relaunch, and no resume.
# `agy` stays off the verified runtime list.
#
# The helper always runs `agy` in an isolated cwd the caller names. It never
# passes `--dangerously-skip-permissions`, `--prompt-interactive`,
# `--input-format`, `--continue`, or `--conversation`.
#
# Usage:
#   fm-agy-print.sh --prompt <text> --model <id> --effort low|medium|high \
#                   --cwd <dir> [--json-schema <string-or-path>] \
#                   [--print-timeout <bound>]
#
# Required:
#   --prompt TEXT             attached to `agy --print=`
#   --model ID                explicit model id from `agy models`
#   --effort low|medium|high  explicit reasoning effort
#   --cwd DIR                 isolated workspace directory; must exist
#
# Optional:
#   --json-schema VALUE       schema string or schema file path
#   --print-timeout BOUND     Go-style duration passed through to agy
#                             (default 5m). Accepted forms: <n>s, <n>m,
#                             <n>m<n>s with a positive integer second total.
#
# Output: the compact JSON envelope on stdout whenever agy stdout is exactly
# one JSON object.
# Signals: exit 0 only when agy exits 0 and the envelope has status SUCCESS,
# and, when --json-schema was used, a non-empty structured_output. Exit 0 with
# empty structured_output is a known empty-success case and is failed here.
# Stdin to agy is closed.
#
# Exit status:
#   0  gated success
#   1  agy missing, timed out, non-zero, or envelope failed the gate
#   2  usage error
#
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_TIMEOUT_SPEC=5m

usage() {
  cat <<'EOF'
fm-agy-print.sh - Firstmate-owned one-shot Antigravity print path.

One prompt in, one JSON envelope out, then exit. Not a worker runtime.

Usage:
  fm-agy-print.sh --prompt <text> --model <id> --effort low|medium|high \
                  --cwd <dir> [--json-schema <string-or-path>] \
                  [--print-timeout <bound>]

Required flags: --prompt, --model, --effort, --cwd.
--effort must be low, medium, or high.
--print-timeout defaults to 5m. Accepted forms: <n>s, <n>m, <n>m<n>s.

Prints agy's compact JSON envelope on stdout when stdout is exactly one JSON
object. Exit 0 additionally requires agy to exit 0, status SUCCESS, and, if
--json-schema was used, non-empty structured_output.

Never passes --dangerously-skip-permissions or any TUI/session flag.
stdin to agy is closed.

Exit status: 0 success, 1 run/envelope failure, 2 usage error.
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

die_usage() {
  printf 'error: %s\n' "$1" >&2
  printf 'usage: fm-agy-print.sh --prompt <text> --model <id> --effort low|medium|high --cwd <dir> [--json-schema <string-or-path>] [--print-timeout <bound>]\n' >&2
  exit 2
}

# Parse a positive second total from the supported duration forms.
parse_timeout_seconds() {
  local spec=$1 total=0
  local LC_ALL=C
  if [[ "$spec" =~ ^([1-9][0-9]*)m([0-9]+)s$ ]]; then
    total=$((BASH_REMATCH[1] * 60 + BASH_REMATCH[2]))
  elif [[ "$spec" =~ ^([1-9][0-9]*)m$ ]]; then
    total=$((BASH_REMATCH[1] * 60))
  elif [[ "$spec" =~ ^([1-9][0-9]*)s$ ]]; then
    total=${BASH_REMATCH[1]}
  else
    return 1
  fi
  [ "$total" -gt 0 ] || return 1
  printf '%s\n' "$total"
}

extract_envelope() {
  local raw=$1
  printf '%s\n' "$raw" | jq -cse '
    select(length == 1 and (.[0] | type == "object"))
    | .[0]
  ' 2>/dev/null
}

gate_envelope() {
  local envelope="$1" used_schema="$2" used_json=false
  [ "$used_schema" -eq 1 ] && used_json=true
  printf '%s\n' "$envelope" | jq -e --argjson used "$used_json" '
    type == "object"
    and .status == "SUCCESS"
    and (
      ($used | not)
      or (
        has("structured_output")
        and .structured_output != null
        and (
          ((.structured_output | type) == "object" and (.structured_output | length) > 0)
          or ((.structured_output | type) == "array" and (.structured_output | length) > 0)
          or ((.structured_output | type) == "string" and (.structured_output | length) > 0)
          or ((.structured_output | type) == "number")
          or ((.structured_output | type) == "boolean")
        )
      )
    )
  ' >/dev/null
}

PROMPT=
MODEL=
EFFORT=
CWD=
SCHEMA=
TIMEOUT_SPEC=$DEFAULT_TIMEOUT_SPEC
USED_SCHEMA=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --prompt)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      [ -z "$PROMPT" ] || die_usage "prompt may be supplied only once"
      PROMPT=$2
      shift 2
      ;;
    --model)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      [ -z "$MODEL" ] || die_usage "model may be supplied only once"
      MODEL=$2
      shift 2
      ;;
    --effort)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      [ -z "$EFFORT" ] || die_usage "effort may be supplied only once"
      EFFORT=$2
      shift 2
      ;;
    --cwd)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      [ -z "$CWD" ] || die_usage "cwd may be supplied only once"
      CWD=$2
      shift 2
      ;;
    --json-schema)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      [ -z "$SCHEMA" ] || die_usage "json-schema may be supplied only once"
      SCHEMA=$2
      USED_SCHEMA=1
      shift 2
      ;;
    --print-timeout)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      TIMEOUT_SPEC=$2
      shift 2
      ;;
    -*)
      die_usage "unknown option: $1"
      ;;
    *)
      die_usage "unexpected argument: $1"
      ;;
  esac
done

[ -n "$PROMPT" ] || die_usage "--prompt is required"
[ -n "$MODEL" ] || die_usage "--model is required"
[ -n "$EFFORT" ] || die_usage "--effort is required"
[ -n "$CWD" ] || die_usage "--cwd is required"
case "$EFFORT" in
  low|medium|high) ;;
  *) die_usage "--effort must be low, medium, or high" ;;
esac
[ "$USED_SCHEMA" -eq 0 ] || [ -n "$SCHEMA" ] || die_usage "--json-schema requires a value"

TIMEOUT_SECONDS=$(parse_timeout_seconds "$TIMEOUT_SPEC") \
  || die_usage "invalid --print-timeout: $TIMEOUT_SPEC"
AGY_TIMEOUT_SPEC=$TIMEOUT_SPEC
HARD_SECONDS=$TIMEOUT_SECONDS

[ -d "$CWD" ] || die "cwd is not a directory: $CWD"
CWD=$(cd "$CWD" && pwd -P) || die "cwd is not a directory: $CWD"

command -v jq >/dev/null 2>&1 || die "jq is required"

AGY_CMD=$(command -v agy 2>/dev/null) || die "agy is not on PATH"

OUTFILE=$(mktemp "${TMPDIR:-/tmp}/fm-agy-print.out.XXXXXX") || die "could not create temp file"
ERRFILE=$(mktemp "${TMPDIR:-/tmp}/fm-agy-print.err.XXXXXX") || {
  rm -f "$OUTFILE"
  die "could not create temp file"
}
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() { rm -f "$OUTFILE" "$ERRFILE"; }
trap cleanup EXIT

AGY_ARGS=(
  --print="$PROMPT"
  --output-format json
)
if [ "$USED_SCHEMA" -eq 1 ]; then
  AGY_ARGS+=(--json-schema "$SCHEMA")
fi
AGY_ARGS+=(--model "$MODEL" --effort "$EFFORT" --print-timeout "$AGY_TIMEOUT_SPEC")

RC=0
(
  cd "$CWD" || exit 1
  fm_run_timed "$HARD_SECONDS" "$AGY_CMD" "${AGY_ARGS[@]}" </dev/null >"$OUTFILE" 2>"$ERRFILE"
) || RC=$?

OUTPUT=$(cat "$OUTFILE" 2>/dev/null || true)
ERR_TAIL=$(tail -c 1500 "$ERRFILE" 2>/dev/null || true)
ENVELOPE=$(extract_envelope "$OUTPUT") || ENVELOPE=

if [ -z "$ENVELOPE" ]; then
  if [ "$RC" -eq 124 ]; then
    die "agy print timed out${ERR_TAIL:+: $ERR_TAIL}"
  fi
  if [ "$RC" -ne 0 ]; then
    die "agy exited $RC with no JSON envelope${ERR_TAIL:+: $ERR_TAIL}"
  fi
  die "agy returned no JSON envelope${ERR_TAIL:+: $ERR_TAIL}"
fi

printf '%s\n' "$ENVELOPE"

[ "$RC" -eq 0 ] || exit 1
gate_envelope "$ENVELOPE" "$USED_SCHEMA" || exit 1

exit 0
