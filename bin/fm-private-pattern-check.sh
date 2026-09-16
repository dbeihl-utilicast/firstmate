#!/usr/bin/env bash
# fm-private-pattern-check.sh - fail when a pattern from a private, never-committed
# list matches the tracked tree (and, with --diff-range, the diff).
#
# Reads newline-separated extended-regex patterns from the FM_PRIVATE_PATTERNS
# environment variable. Blank lines and lines whose first non-whitespace
# character is '#' are ignored. The variable is never sourced from a file in
# this repository; callers pass it from a secret (see .github/workflows/ci.yml).
#
# On this repository's public CI, a match's file:line is safe to print but the
# matched text and the pattern that matched it are not, so neither is ever
# printed anywhere, including on a config error.
#
# Bash 3.2 compatible (no associative arrays, mapfile, or ${var,,}) because
# this script also runs under macOS's shipped bash.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: fm-private-pattern-check.sh [--diff-range RANGE]

Reads newline-separated extended-regex patterns from FM_PRIVATE_PATTERNS and
scans the tracked tree for a match. With --diff-range, also scans the added
lines of `git diff RANGE` (for example "origin/main...HEAD").

Exit codes:
  0  no match
  1  FM_PRIVATE_PATTERNS is unset or empty (or holds no non-comment pattern)
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
trap 'rm -f "$pattern_file"' EXIT

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

matches_file=$(mktemp)
trap 'rm -f "$pattern_file" "$matches_file"' EXIT

git grep -n -I -E -f "$pattern_file" -- . 2>/dev/null | cut -d: -f1,2 >> "$matches_file" || true

if [ -n "$diff_range" ]; then
  current_file=""
  current_line=0
  git diff --unified=0 "$diff_range" -- . | while IFS= read -r dline; do
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
        if printf '%s\n' "$content" | grep -Eq -f "$pattern_file"; then
          printf '%s:%s\n' "$current_file" "$current_line"
        fi
        current_line=$((current_line + 1))
        ;;
      '-'*)
        : ;;
      *)
        : ;;
    esac
  done >> "$matches_file"
fi

if [ -s "$matches_file" ]; then
  echo "private pattern check: matches found (file:line only, values withheld):" >&2
  sort -u "$matches_file" >&2
  exit 2
fi

exit 0
