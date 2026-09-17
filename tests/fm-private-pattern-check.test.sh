#!/usr/bin/env bash
# fm-private-pattern-check.test.sh - fixture-level proof for
# bin/fm-private-pattern-check.sh: a planted match fails closed naming only
# file:line, an absent/empty/comment-only/invalid pattern list fails closed
# (a malformed regex must never silently match nothing), matching is
# case-insensitive by default, a clean tree passes, comments/blanks are
# ignored around a real pattern, a whitespace-padded pattern still matches
# unpadded text, and --diff-range catches an added line with correct line
# arithmetic.
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

test_invalid_pattern_fails_closed_instead_of_matching_nothing() {
  local repo out rc
  repo=$(fixture_repo)
  printf 'nothing sensitive here\n' > "$repo/plain.txt"
  git -C "$repo" add plain.txt
  fixture_commit "$repo" plain
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS='fake-unbalanced-paren-(' "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 1 ] || fail "a malformed extended-regex pattern must exit 1 (config error), got $rc: $out"
  assert_not_contains "$out" 'fake-unbalanced-paren-(' \
    "the refusal must never echo the malformed pattern itself"
  pass "an invalid pattern fails closed instead of silently matching nothing"
}

test_case_insensitive_match_by_default() {
  local repo out rc pattern planted
  repo=$(fixture_repo)
  pattern='vvv-fake-secret-marker-4471-do-not-reuse'
  planted='VvV-Fake-Secret-Marker-4471-Do-Not-Reuse'
  printf 'context line\n%s\n' "$planted" > "$repo/secret3.txt"
  git -C "$repo" add secret3.txt
  fixture_commit "$repo" plant3
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS="$pattern" "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 2 ] || fail "a lower-case pattern must match a mixed-case planted value, got $rc: $out"
  assert_contains "$out" "secret3.txt:2" "the case-insensitive match must still name the file and line"
  pass "matching is case-insensitive by default"
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

test_whitespace_padded_pattern_still_matches_unpadded_text() {
  local repo out rc pattern padded_pattern
  repo=$(fixture_repo)
  pattern='UuU-fake-secret-marker-6602-do-not-reuse'
  padded_pattern=$'  \t'"$pattern"$'  \t'
  printf 'context line\n%s\n' "$pattern" > "$repo/secret4.txt"
  git -C "$repo" add secret4.txt
  fixture_commit "$repo" plant4
  out=$(cd "$repo" && FM_PRIVATE_PATTERNS="$padded_pattern" "$SCRIPT" 2>&1); rc=$?
  rm -rf "$repo"
  [ "$rc" -eq 2 ] || fail "a pattern with incidental leading/trailing whitespace must still match unpadded text, got $rc: $out"
  assert_contains "$out" "secret4.txt:2" "the padded pattern must still find the unpadded match"
  pass "a pattern with incidental leading/trailing whitespace still matches unpadded text"
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
test_invalid_pattern_fails_closed_instead_of_matching_nothing
test_case_insensitive_match_by_default
test_comments_and_blanks_are_ignored_around_a_real_pattern
test_whitespace_padded_pattern_still_matches_unpadded_text
test_clean_tree_passes
test_diff_range_catches_a_planted_addition
