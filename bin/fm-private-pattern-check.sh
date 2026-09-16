#!/usr/bin/env bash
# fm-private-pattern-check.sh - fail when a pattern from a private, never-committed
# list matches the tracked tree (and, with --diff-range, the diff).
#
# Reads newline-separated extended-regex patterns from the FM_PRIVATE_PATTERNS
# environment variable. Blank lines and lines whose first non-whitespace
# character is '#' are ignored. The variable is never sourced from a file in
# this repository; callers pass it from a secret (see .github/workflows/ci.yml).
# Matching is case-insensitive by default (a company, client, or person name
# appears in varying case across the tree), so a pattern need not spell out
# every capitalization.
#
# On this repository's public CI, a match's file:line is safe to print but the
# matched text and the pattern that matched it are not, so neither is ever
# printed anywhere, including on a config error. For the same reason grep's own
# stderr is always suppressed: an invalid-pattern error from grep or git grep
# can echo the pattern itself, so every failure gets this script's own generic
# message instead.
#
# A malformed pattern must fail the check, not silently match nothing: grep
# and git grep both exit >1 on an unparseable extended regex (exit 1 alone
# means "no match", which is a normal, non-error outcome), so every grep/git
# grep call here is checked for exit >1 specifically and treated as a
# configuration error distinct from "no match found".
#
# Bash 3.2 compatible (no associative arrays, mapfile, or ${var,,}) because
# this script also runs under macOS's shipped bash.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: fm-private-pattern-check.sh [--diff-range RANGE]

Reads newline-separated extended-regex patterns from FM_PRIVATE_PATTERNS and
scans the tracked tree, case-insensitively, for a match. With --diff-range,
also scans the added lines of `git diff RANGE` (for example
"origin/main...HEAD").

Exit codes:
  0  no match
  1  a configuration error: FM_PRIVATE_PATTERNS is unset, empty, holds no
     non-comment pattern, or holds a pattern that is not a valid extended
     regex
  2  a match was found
EOF
}

diff_range=""
while [ $# -gt 0 ]; do
  case "$1" in
    --diff-range)
      [ $# -ge 2 ] || { echo "error: --diff-range needs a value" >&2; usage; exit 1; }
      diff_range=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unrecognized argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [ -z "${FM_PRIVATE_PATTERNS:-}" ]; then
  echo "error: FM_PRIVATE_PATTERNS is unset or empty; refusing to run without a private pattern list" >&2
  exit 1
fi

pattern_file=$(mktemp)
matches_file=$(mktemp)
trap 'rm -f "$pattern_file" "$matches_file"' EXIT

printf '%s\n' "$FM_PRIVATE_PATTERNS" | while IFS= read -r raw_line; do
  line=${raw_line%$'\r'}
  trimmed=${line#"${line%%[![:space:]]*}"}
  case "$trimmed" in
    ''|'#'*) continue ;;
  esac
  printf '%s\n' "$line" >> "$pattern_file"
done

if [ ! -s "$pattern_file" ]; then
  echo "error: FM_PRIVATE_PATTERNS held no usable pattern (only blank lines and/or comments)" >&2
  exit 1
fi

# Validate every pattern compiles before scanning anything: grep against
# /dev/null can only exit 1 (no match, since there is no input) when every
# pattern is well-formed, or >1 when at least one is not. This is the single
# place a malformed pattern is diagnosed, so the tree and diff scans below
# never need to re-litigate it.
set +e
grep -Eiq -f "$pattern_file" /dev/null 2>/dev/null
validate_rc=$?
set -e
if [ "$validate_rc" -gt 1 ]; then
  echo "error: FM_PRIVATE_PATTERNS contains a pattern that is not a valid extended regex; refusing to run rather than silently matching nothing" >&2
  exit 1
fi

set +e
git grep -n -I -E -i -f "$pattern_file" -- . 2>/dev/null | cut -d: -f1,2 >> "$matches_file"
tree_rc=${PIPESTATUS[0]}
set -e
if [ "$tree_rc" -gt 1 ]; then
  echo "error: git grep failed while scanning the tracked tree for private patterns" >&2
  exit 1
fi

if [ -n "$diff_range" ]; then
  current_file=""
  current_line=0
  while IFS= read -r dline; do
    case "$dline" in
      '--- '*)
        : ;;
      '+++ '*)
        current_file=${dline#+++ }
        current_file=${current_file#b/}
        ;;
      '@@ '*)
        plus_part=${dline#*+}
        plus_part=${plus_part%% @@*}
        current_line=${plus_part%%,*}
        ;;
      '+'*)
        content=${dline#+}
        set +e
        printf '%s\n' "$content" | grep -Eiq -f "$pattern_file" 2>/dev/null
        line_rc=$?
        set -e
        case "$line_rc" in
          0) printf '%s:%s\n' "$current_file" "$current_line" >> "$matches_file" ;;
          1) : ;;
          *)
            echo "error: grep failed while scanning the diff for private patterns" >&2
            exit 1
            ;;
        esac
        current_line=$((current_line + 1))
        ;;
      '-'*)
        : ;;
      *)
        : ;;
    esac
  done < <(git diff --unified=0 "$diff_range" -- .)
fi

if [ -s "$matches_file" ]; then
  echo "private pattern check: matches found (file:line only, values withheld):" >&2
  sort -u "$matches_file" >&2
  exit 2
fi

exit 0
