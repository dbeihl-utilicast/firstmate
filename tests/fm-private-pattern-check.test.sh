#!/usr/bin/env bash
# fm-private-pattern-check.test.sh - fixture-level proof for
# bin/fm-private-pattern-check.sh: a planted match fails closed naming only
# file:line, an absent/empty/comment-only pattern list fails closed, a clean
# tree passes, comments/blanks are ignored around a real pattern, and
# --diff-range catches an added line with correct line arithmetic.
#
# Every fixture is its own throwaway git repo so the script's own
# `git rev-parse --show-toplevel` resolves inside the fixture, never this
# repo's own tree. Patterns and planted values here are obviously fake
# (ZzZ/YyY/XxX-prefixed, "do-not-reuse" suffixed) and never real secrets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-private-pattern-check.sh"

fixture_repo() {
  local repo
  repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-ppc-fixture.XXXXXX")
  git init -q "$repo"
  printf '# fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  printf '%s' "$repo"
}

fixture_commit() {
  local repo=$1 msg=$2
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "$msg"
}

test_planted_match_fails_and_names_file_line_only() {
  local repo out rc pattern
  repo=$(fixture_repo)
  pattern='ZzZ-fake-secret-marker-9f31-do-not-reuse'
  printf 'context line\n%s\n' "$pattern" > "$repo/secret.txt"
  git -C "$repo" add secret.txt
  fixture_commit "$repo" plant
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS="$pattern" "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 2 ] || fail "planted match must exit 2, got $rc: $out"
  assert_contains "$out" "secret.txt:2" "output must name the planted file and its exact line"
  assert_not_contains "$out" "$pattern" "output must never print the matched text or pattern"
  pass "a planted match fails and names only the file and line"
}

test_absent_pattern_var_fails() {
  local repo out rc
  repo=$(fixture_repo)
  out=$(cd "$repo" && env -u FM_PRIVATE_PATTERNS "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 1 ] || fail "an absent FM_PRIVATE_PATTERNS must exit 1, got $rc: $out"
  assert_contains "$out" "FM_PRIVATE_PATTERNS" "the refusal must name the missing variable"
  pass "an absent FM_PRIVATE_PATTERNS fails closed"
}

test_empty_pattern_var_fails() {
  local repo out rc
  repo=$(fixture_repo)
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS='' "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 1 ] || fail "an empty FM_PRIVATE_PATTERNS must exit 1, got $rc: $out"
  pass "an empty FM_PRIVATE_PATTERNS fails closed"
}

test_comment_and_blank_only_var_fails() {
  local repo out rc
  repo=$(fixture_repo)
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS=$'# a comment\n\n   \n# another' "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 1 ] || fail "comment/blank-only patterns must exit 1, got $rc: $out"
  pass "a pattern list holding only comments and blank lines fails closed"
}

test_comments_and_blanks_are_ignored_around_a_real_pattern() {
  local repo out rc pattern patterns
  repo=$(fixture_repo)
  pattern='YyY-fake-secret-marker-2e77-do-not-reuse'
  printf '%s\n' "$pattern" > "$repo/secret2.txt"
  git -C "$repo" add secret2.txt
  fixture_commit "$repo" plant2
  patterns=$'# leading comment\n\n'"$pattern"$'\n   \n# trailing comment'
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS="$patterns" "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 2 ] || fail "a real pattern surrounded by comments/blanks must still match, got $rc: $out"
  assert_contains "$out" "secret2.txt:1" "the real pattern between comments must still be found"
  pass "blank lines and comments in the pattern list are ignored"
}

test_clean_tree_passes() {
  local repo out rc
  repo=$(fixture_repo)
  printf 'nothing sensitive here\n' > "$repo/plain.txt"
  git -C "$repo" add plain.txt
  fixture_commit "$repo" plain
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS='WwW-fake-pattern-that-will-never-appear-77213' "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 0 ] || fail "a clean tree must pass, got $rc: $out"
  pass "a clean tree with no pattern match passes"
}

test_diff_range_catches_a_planted_addition() {
  local repo out rc pattern
  repo=$(fixture_repo)
  pattern='XxX-fake-diff-secret-marker-5510-do-not-reuse'
  git -C "$repo" branch base
  printf 'context line\n%s\n' "$pattern" > "$repo/added.txt"
  git -C "$repo" add added.txt
  fixture_commit "$repo" 'add planted line'
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS="$pattern" "$SCRIPT" --diff-range 'base...HEAD' 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 2 ] || fail "a planted diff addition must exit 2, got $rc: $out"
  assert_contains "$out" "added.txt:2" "diff scan must name the added file and its exact new-file line"
  assert_not_contains "$out" "$pattern" "diff scan output must never print the matched text"
  pass "--diff-range catches a planted addition with correct line arithmetic"
}

test_planted_match_fails_and_names_file_line_only
test_absent_pattern_var_fails
test_empty_pattern_var_fails
test_comment_and_blank_only_var_fails
test_comments_and_blanks_are_ignored_around_a_real_pattern
test_clean_tree_passes
test_diff_range_catches_a_planted_addition
