#!/usr/bin/env bash
# fm-ci-test-evidence.sh - verify required GitHub Actions test jobs from their
# own logs rather than their green check conclusions.
#
# Usage:
#   fm-ci-test-evidence.sh --pr https://github.com/OWNER/REPO/pull/N --required-job NAME [--required-job NAME ...]
#   fm-ci-test-evidence.sh --run https://github.com/OWNER/REPO/actions/runs/RUN --required-job NAME [--required-job NAME ...]
#
# A required job is matched by its exact GitHub Actions job name.
# A PR examines every Actions run for its current head commit, while --run
# examines that exact run.
# Each matching job log must contain either an FM_TEST_EVIDENCE summary
# (`executed=N skipped=N deselected=N`) or a pytest-style terminal summary.
# The checker prints nothing and exits zero when every required job has a
# positive executed count with zero skipped and deselected tests.
# It prints only violations: absent jobs, unreadable logs, missing summaries,
# or nonzero skipped/deselected counts.
#
# An unavailable GitHub read is deliberately non-fatal outside CI, where a
# contributor may lack the services or credentials required to inspect a run.
# The same condition fails closed when GITHUB_ACTIONS=true, so configuration
# drift cannot turn a required measurement into a green skip.
set -u

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

ci_mode() {
  [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]
}

TARGET_KIND=
TARGET=
REQUIRED_JOBS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr|--run)
      [ -z "$TARGET_KIND" ] || die 'choose exactly one of --pr or --run'
      [ "$#" -ge 2 ] || die "$1 requires a URL"
      TARGET_KIND=${1#--}
      TARGET=$2
      shift 2
      ;;
    --required-job)
      [ "$#" -ge 2 ] || die '--required-job requires a job name'
      REQUIRED_JOBS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TARGET_KIND" ] || die 'choose --pr or --run'
[ "${#REQUIRED_JOBS[@]}" -gt 0 ] || die 'name at least one --required-job'
command -v gh-axi >/dev/null 2>&1 || {
  if ci_mode; then
    printf 'unverified: GitHub Actions evidence could not be read because gh-axi is unavailable\n' >&2
    exit 1
  fi
  printf 'not checked: GitHub Actions evidence could not be read because gh-axi is unavailable\n' >&2
  exit 0
}

OWNER=
REPO=
PR_NUMBER=
RUN_ID=
if [ "$TARGET_KIND" = pr ]; then
  if [[ "$TARGET" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(/)?$ ]]; then
    OWNER=${BASH_REMATCH[1]}
    REPO=${BASH_REMATCH[2]}
    PR_NUMBER=${BASH_REMATCH[3]}
  else
    die 'invalid GitHub pull request URL'
  fi
else
  if [[ "$TARGET" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/actions/runs/([0-9]+)(/)?$ ]]; then
    OWNER=${BASH_REMATCH[1]}
    REPO=${BASH_REMATCH[2]}
    RUN_ID=${BASH_REMATCH[3]}
  else
    die 'invalid GitHub Actions run URL'
  fi
fi

api_body() {  # <path> <jq-expression>
  local output
  output=$(gh-axi api "$1" --jq "$2") || return 1
  python3 -c '
import json
import sys
for line in sys.stdin.read().splitlines():
    if line.startswith("  body: "):
        value = line[len("  body: "):]
        if value.startswith("\""):
            print(json.loads(value))
            raise SystemExit(0)
raise SystemExit(1)
' <<< "$output"
}

unreadable() {
  local detail=$1
  if ci_mode; then
    printf 'unverified: %s\n' "$detail" >&2
    return 1
  fi
  printf 'not checked: %s\n' "$detail" >&2
  return 0
}

stop_unreadable() {
  unreadable "$1" || exit 1
  exit 0
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-test-evidence.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

RUNS_FILE="$TMP/runs"
if [ "$TARGET_KIND" = pr ]; then
  if ! HEAD_SHA=$(api_body "/repos/$OWNER/$REPO/pulls/$PR_NUMBER" '.head.sha' 2>/dev/null); then
    stop_unreadable "pull request $TARGET could not be read"
  fi
  [ -n "$HEAD_SHA" ] || {
    stop_unreadable "pull request $TARGET did not provide a head commit"
  }
  if ! api_body "/repos/$OWNER/$REPO/actions/runs?event=pull_request&head_sha=$HEAD_SHA&per_page=100" \
    '[.workflow_runs[].id] | join("\n")' > "$RUNS_FILE" 2>/dev/null; then
    stop_unreadable "Actions runs for pull request $TARGET could not be read"
  fi
else
  printf '%s\n' "$RUN_ID" > "$RUNS_FILE"
fi

: > "$TMP/jobs"
while IFS= read -r run; do
  [ -n "$run" ] || continue
  if ! api_body "/repos/$OWNER/$REPO/actions/runs/$run/jobs?per_page=100" \
    '[.jobs[] | [.id, .name, (.conclusion // "")] | @tsv] | join("\n")' > "$TMP/jobs-$run" 2>/dev/null; then
    stop_unreadable "Actions jobs for run $run could not be read"
  fi
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    case "$job" in *$'\t'*) printf '%s\t%s\n' "$run" "$job" >> "$TMP/jobs" ;; *) stop_unreadable "Actions jobs for run $run had an unreadable response" ;; esac
  done < "$TMP/jobs-$run"
done < "$RUNS_FILE"

violations=0
for required in "${REQUIRED_JOBS[@]}"; do
  match=$(awk -F '\t' -v name="$required" '$3 == name { print; exit }' "$TMP/jobs")
  if [ -z "$match" ]; then
    printf 'absent: required job %s was not present in %s\n' "$required" "$TARGET" >&2
    violations=1
    continue
  fi
  job_run=${match%%$'\t'*}
  job_id=${match#*$'\t'}
  job_id=${job_id%%$'\t'*}
  job_conclusion=${match##*$'\t'}
  if [ "$job_conclusion" = skipped ]; then
    printf 'test evidence violation: %s executed=0 skipped=unknown deselected=unknown (job skipped before producing a test log)\n' "$required" >&2
    violations=1
    continue
  fi
  if ! gh-axi run view "$job_run" --job "$job_id" --log -R "$OWNER/$REPO" > "$TMP/log-$job_id" 2>/dev/null; then
    stop_unreadable "required job $required log could not be read"
  fi
  counts=$(python3 - "$TMP/log-$job_id" <<'PY'
import re
import sys
try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError:
    raise SystemExit(1)
matches = []
for line in text.splitlines():
    explicit = re.search(r"FM_TEST_EVIDENCE\s+executed=(\d+)\s+skipped=(\d+)\s+deselected=(\d+)", line)
    if explicit:
        matches.append(tuple(map(int, explicit.groups())))
        continue
    if not re.search(r"\b(?:passed|failed|error|skipped|deselected)\b", line):
        continue
    values = {label: int(number.replace(",", "")) for number, label in re.findall(r"(\d[\d,]*)\s+(passed|failed|errors?|skipped|deselected)\b", line)}
    if values and ("passed" in values or "failed" in values or "error" in values or "errors" in values):
        matches.append((values.get("passed", 0) + values.get("failed", 0) + values.get("error", 0) + values.get("errors", 0), values.get("skipped", 0), values.get("deselected", 0)))
if matches:
    print(*matches[-1])
PY
) || counts=
  if [ -z "$counts" ]; then
    printf 'unverified: required job %s log contained no executed/skipped/deselected test summary\n' "$required" >&2
    violations=1
    continue
  fi
  read -r executed skipped deselected <<EOF
$counts
EOF
  if [ "$executed" -eq 0 ] || [ "$skipped" -ne 0 ] || [ "$deselected" -ne 0 ]; then
    printf 'test evidence violation: %s executed=%s skipped=%s deselected=%s\n' "$required" "$executed" "$skipped" "$deselected" >&2
    violations=1
  fi
done

exit "$violations"
