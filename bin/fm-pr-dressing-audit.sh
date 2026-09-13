#!/usr/bin/env bash
# Audit every open GitHub pull request in one repository against the locally
# configured dressing rules, printing only violations.
#
# Usage: fm-pr-dressing-audit.sh <owner/repository>
#
# The configuration is config/pr-dressing-audit.json under FM_HOME, unless
# FM_PR_DRESSING_AUDIT_CONFIG names a test or alternate configuration file.
# docs/configuration.md owns that schema and the scope this command does not
# claim to check.
#
# This is a committed script, not an agent's interactive operation.  It uses
# gh rather than gh-axi because gh provides stable machine-readable PR fields
# and explicit --repo selection, neither available from gh-axi's PR interface.
# The command only reads forge state and never edits a pull request.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${FM_PR_DRESSING_AUDIT_CONFIG:-$FM_HOME/config/pr-dressing-audit.json}"

usage() {
  cat <<'EOF'
Usage: fm-pr-dressing-audit.sh <owner/repository>

Audit every open GitHub pull request in the named repository against its entry
in config/pr-dressing-audit.json.  The command is silent when every configured
rule passes and prints only violations otherwise.

It checks a configured integration branch, reviewer team, assignees,
mergeability, and configured required checks that are currently failing.
It does not infer branch protection, review approvals, merge authority, or
required checks absent from configuration.
EOF
}

die() {
  printf 'fm-pr-dressing-audit: %s\n' "$1" >&2
  exit 2
}

[ "${1:-}" = --help ] || [ "${1:-}" = -h ] && { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
REPO=$1
case "$REPO" in
  */*) ;;
  *) die 'repository must be owner/repository' ;;
esac

command -v gh >/dev/null 2>&1 || die 'gh not found'
command -v jq >/dev/null 2>&1 || die 'jq not found'
[ -f "$CONFIG" ] || die "configuration not found: $CONFIG"

if ! rules=$(jq -ce --arg repo "$REPO" '
    .repositories[$repo]
    | select(type == "object")
    | .integration_branch as $branch
    | .reviewer_team as $team
    | .assignees as $assignees
    | .required_checks as $checks
    | select(($branch | type) == "string" and ($branch | length) > 0)
    | select(($team | type) == "string" and ($team | test("^[^/[:space:]]+/[^/[:space:]]+$")))
    | select(($assignees | type) == "array" and all($assignees[]; type == "string" and length > 0))
    | select(($checks | type) == "array" and all($checks[]; type == "string" and length > 0))
  ' "$CONFIG" 2>/dev/null); then
  die "invalid or missing configuration for $REPO in $CONFIG"
fi

if ! pull_requests=$(gh pr list --repo "$REPO" --state open --limit 1000 \
    --json number,url,baseRefName,assignees,reviewRequests,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null) \
  || ! printf '%s' "$pull_requests" | jq -e 'type == "array"' >/dev/null 2>&1; then
  die "could not read open pull requests for $REPO"
fi

printf '%s' "$pull_requests" | jq -r --argjson rules "$rules" '
  def check_is_green:
    if .__typename == "CheckRun" then
      .status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")
    elif .__typename == "StatusContext" then .state == "SUCCESS"
    else false end;
  def check_name: if .__typename == "CheckRun" then .name else .context end;
  .[]
  | . as $pr
  | $pr.url as $url
  | (
      if $pr.baseRefName == "main" and $rules.integration_branch != "main" then
        "\($url): base branch is main; expected \($rules.integration_branch)"
      else empty end
    ),
    (
      if ([ $pr.reviewRequests[]? | select(.__typename == "Team") | .slug ] | index($rules.reviewer_team)) == null then
        "\($url): reviewer team missing: \($rules.reviewer_team)"
      else empty end
    ),
    (
      [ $rules.assignees[] | select(. as $login | ([ $pr.assignees[]?.login ] | index($login)) == null) ]
      | if length > 0 then "\($url): assignees missing: \(join(", "))" else empty end
    ),
    (
      if $pr.mergeable != "MERGEABLE" then
        "\($url): mergeable is \($pr.mergeable // "unreadable"), not MERGEABLE"
      else empty end
    ),
    (
      $rules.required_checks[] as $required
      | [ $pr.statusCheckRollup[]? | select(check_name == $required) ] as $runs
      | if ($runs | length) > 0 and any($runs[]; check_is_green | not) then
          "\($url): required check failing: \($required)"
        else empty end
    )
  '
