#!/usr/bin/env bash
# Independently verify a local-model ship task's red-first contract. Trusts
# NOTHING the worker wrote about its own work - not a status line, not a PR
# body, not its captured red-before.txt/green-after.txt/red-revert.txt - and
# reads only the "Red test: <path>" line firstmate wrote into data/<id>/brief.md
# (bin/fm-brief.sh --local-model-contract), which the worker's worktree can
# never touch. Run this after a local-model worker reports done, before
# validation (/no-mistakes or otherwise) starts.
#
# Requires exactly two things, in this order:
#   1. On the worker's own worktree HEAD (read-only: no checkout, no reset,
#      no mutation of that worktree in any way), the named test passes.
#   2. In a throwaway linked git worktree - never the worker's own - every
#      file the branch touched since it diverged from the project's default
#      branch is restored to its pre-implementation content, EXCEPT the named
#      test file itself, and the named test then fails.
# If either does not hold, this refuses: a test that also passes with the
# implementation reverted is not testing what it claims to (the pass-body
# class this whole contract exists to reject), and a test that fails at HEAD
# means the worker's own "done" report was wrong.
#
# Usage: fm-local-model-verify.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-local-model-verify.sh <task-id>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
[ $# -le 1 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
BRIEF="$DATA/$ID/brief.md"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
[ -f "$BRIEF" ] || { echo "error: no brief for task $ID at $BRIEF" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

grep -q '^Local-model contract: enabled$' "$BRIEF" \
  || { echo "error: $BRIEF carries no local-model red-first contract; nothing to verify" >&2; exit 1; }

RED_TEST=$(sed -n 's/^Red test: //p' "$BRIEF" | head -n 1)
[ -n "$RED_TEST" ] || { echo "error: $BRIEF carries no 'Red test: <path>' line" >&2; exit 1; }
[ "$RED_TEST" != "{RED_TEST}" ] || { echo "error: $BRIEF's 'Red test:' line is still the unfilled {RED_TEST} placeholder" >&2; exit 1; }
case "$RED_TEST" in
  /*|*..*) echo "error: 'Red test:' line '$RED_TEST' must be a project-relative path with no traversal" >&2; exit 1 ;;
esac
[ -f "$WT/$RED_TEST" ] || { echo "error: named red test '$RED_TEST' does not exist in $WT" >&2; exit 1; }

BRANCH="fm/$ID"
if ! git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: branch fm/$ID does not exist and worktree $WT is detached" >&2; exit 1; }
  git -C "$WT" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

run_named_test() {  # <dir> <path>
  local dir=$1 path=$2
  if [ -x "$dir/$path" ]; then
    ( cd "$dir" && "./$path" )
  else
    ( cd "$dir" && bash "$path" )
  fi
}

echo "verify $ID: running $RED_TEST on the worker's own committed HEAD (must PASS)"
if ! run_named_test "$WT" "$RED_TEST"; then
  echo "error: $RED_TEST does not pass on $ID's own committed HEAD; the worker's done report does not hold" >&2
  exit 1
fi

DEFAULT=$(default_branch "$PROJ") || { echo "error: cannot determine default branch for $PROJ" >&2; exit 1; }
if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  git -C "$WT" fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet 2>/dev/null || true
fi
if git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$DEFAULT^{commit}" >/dev/null; then
  BASE="origin/$DEFAULT"
elif git -C "$WT" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}" >/dev/null; then
  BASE="$DEFAULT"
else
  echo "error: base $DEFAULT does not resolve in $WT" >&2
  exit 1
fi
MB=$(git -C "$WT" merge-base "$BASE" "$BRANCH") \
  || { echo "error: cannot find a merge-base between $BASE and $BRANCH in $WT" >&2; exit 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-local-model-verify.$ID.XXXXXX")
cleanup() {
  git -C "$WT" worktree remove --force "$SCRATCH" >/dev/null 2>&1 || true
  rm -rf -- "$SCRATCH"
}
trap cleanup EXIT

git -C "$WT" worktree add --detach --quiet "$SCRATCH" "$BRANCH" \
  || { echo "error: could not create a scratch worktree for the revert-check" >&2; exit 1; }

CHANGED=$(git -C "$WT" diff --name-only "$MB" "$BRANCH" --)
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$f" = "$RED_TEST" ] && continue
  if git -C "$SCRATCH" cat-file -e "$MB:$f" 2>/dev/null; then
    git -C "$SCRATCH" checkout --quiet "$MB" -- "$f" \
      || { echo "error: could not revert $f to its pre-implementation content" >&2; exit 1; }
  else
    rm -f -- "${SCRATCH:?}/$f"
  fi
done <<EOF
$CHANGED
EOF

echo "verify $ID: running $RED_TEST with the implementation reverted, the test itself kept (must FAIL)"
if run_named_test "$SCRATCH" "$RED_TEST"; then
  echo "error: $RED_TEST still passes with the implementation reverted; it is not testing what it claims to (the pass-body class this contract exists to reject)" >&2
  exit 1
fi

echo "ok $ID: $RED_TEST passes at HEAD and fails with the implementation reverted"
