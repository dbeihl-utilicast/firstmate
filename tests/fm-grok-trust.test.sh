#!/usr/bin/env bash
# Behavior tests for bin/fm-grok-trust.sh: it registers a project's PRIMARY
# checkout, never the task worktree, and refuses anything else.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-grok-trust)

TRUST="$ROOT/bin/fm-grok-trust.sh"

# make_case <name>: a project with one linked worktree plus an isolated Grok
# home. Echoes "<case>|<proj>|<wt>|<grok-home>".
make_case() {
  local name=$1 case_dir proj wt grok_home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  grok_home="$case_dir/grok-home"
  mkdir -p "$grok_home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$grok_home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT GROK_HOME_DIR <<EOF
$1
EOF
}

# run_trust <grok-home> <project> [home]: invoke with an isolated store.
run_trust() {
  local grok_home=$1 proj=$2 home=${3:-$1}
  GROK_HOME="$grok_home" HOME="$home" "$TRUST" "$proj" 2>&1
}

store_text() {  # <grok-home>
  cat "$1/trusted_folders.toml" 2>/dev/null
}

# is_trusted <grok-home> <path>: exit 0 if the store has a trusted=true block
# for <path>. Reused by assert_trusted and assert_not_trusted below.
is_trusted() {
  # shellcheck disable=SC2016 # JS, not the shell, expands $1 as a regex backreference.
  node -e '
const fs=require("node:fs");
const [store,target]=process.argv.slice(1);
const text=fs.existsSync(store)?fs.readFileSync(store,"utf8"):"";
const re=/^\[folders\."((?:[^"\\]|\\.)*)"\]\r?\n([^\[]*)/gm;
let m,found=false;
while((m=re.exec(text))!==null){
  const p=m[1].replace(/\\(.)/g,"$1");
  if(p===target && /trusted\s*=\s*true/.test(m[2])) found=true;
}
process.exit(found?0:1);
' "$1/trusted_folders.toml" "$2"
}

assert_trusted() {  # <grok-home> <path> <msg>
  is_trusted "$1" "$2" || fail "$3"
}

assert_not_trusted() {  # <grok-home> <path> <msg>
  is_trusted "$1" "$2" && fail "$3"
  return 0
}

node_free_path() {  # <case-dir> -> a bin dir holding the script's own tools but no node
  local dir=$1/nonode-bin tool
  mkdir -p "$dir"
  for tool in bash env git mkdir; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

test_fresh_primary_checkout_is_trusted() {
  local rec out
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$GROK_HOME_DIR" "$PROJ")
  expect_code 0 $? "a fresh primary checkout must be trusted: $out"
  assert_contains "$out" "trusted: $PROJ" "registration did not report what it trusted"
  assert_trusted "$GROK_HOME_DIR" "$PROJ" "the project was not recorded as trusted"
  [ -z "$(find "$GROK_HOME_DIR" -maxdepth 1 -name '.trusted_folders.toml.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the Grok home"
  pass "fm-grok-trust.sh: a fresh primary checkout is trusted"
}

test_registration_is_idempotent() {
  local rec out count
  rec=$(make_case idempotent)
  read_case "$rec"
  run_trust "$GROK_HOME_DIR" "$PROJ" >/dev/null
  out=$(run_trust "$GROK_HOME_DIR" "$PROJ")
  expect_code 0 $? "a repeat registration must succeed: $out"
  assert_contains "$out" "already-trusted: $PROJ" "a repeat registration did not report already-trusted"
  count=$(grep -Fc "[folders.\"$PROJ\"]" "$GROK_HOME_DIR/trusted_folders.toml")
  [ "$count" = 1 ] || fail "a repeat registration duplicated the entry ($count)"
  pass "fm-grok-trust.sh: repeat registration is idempotent"
}

test_linked_worktree_is_refused() {
  local rec out
  rec=$(make_case worktree)
  read_case "$rec"
  out=$(run_trust "$GROK_HOME_DIR" "$WT")
  expect_code 1 $? "a linked worktree must be refused as the registration target: $out"
  assert_contains "$out" "linked worktree" "the refusal did not name the linked worktree"
  assert_not_trusted "$GROK_HOME_DIR" "$WT" "a linked worktree was trusted directly"
  pass "fm-grok-trust.sh: refuses a linked worktree as the registration target"
}

test_worktree_inherits_trust_from_primary_checkout() {
  local rec
  rec=$(make_case inherits)
  read_case "$rec"
  run_trust "$GROK_HOME_DIR" "$PROJ" >/dev/null || fail "registering the primary checkout failed"
  assert_trusted "$GROK_HOME_DIR" "$PROJ" "the primary checkout was not trusted"
  assert_not_trusted "$GROK_HOME_DIR" "$WT" \
    "the worktree must never get its own entry; grok inherits trust through the repository, not the store"
  pass "fm-grok-trust.sh: registers only the primary checkout, relying on grok's own worktree inheritance"
}

test_home_directory_is_refused() {
  local rec out home
  rec=$(make_case home)
  read_case "$rec"
  home="$CASE_DIR/home"
  mkdir -p "$home"
  out=$(GROK_HOME="$GROK_HOME_DIR" HOME="$home" "$TRUST" "$home" 2>&1)
  expect_code 1 $? "a home directory must be refused: $out"
  assert_contains "$out" "home directory" "the refusal did not name the home directory"
  pass "fm-grok-trust.sh: refuses the home directory"
}

test_grok_home_directory_is_refused() {
  local rec out
  rec=$(make_case grokhome)
  read_case "$rec"
  out=$(run_trust "$GROK_HOME_DIR" "$GROK_HOME_DIR")
  expect_code 1 $? "the Grok home directory must be refused: $out"
  assert_contains "$out" "Grok home directory" "the refusal did not name the Grok home directory"
  pass "fm-grok-trust.sh: refuses the Grok home directory"
}

test_non_git_directory_is_refused() {
  local rec out plain
  rec=$(make_case plain)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$GROK_HOME_DIR" "$plain")
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal did not name the missing repository"
  assert_not_trusted "$GROK_HOME_DIR" "$plain" "a plain directory was trusted"
  pass "fm-grok-trust.sh: refuses a directory that is not a git repository"
}

test_missing_directory_is_refused() {
  local rec out
  rec=$(make_case missing)
  read_case "$rec"
  out=$(run_trust "$GROK_HOME_DIR" "$CASE_DIR/nope")
  expect_code 1 $? "a nonexistent path must be refused: $out"
  assert_contains "$out" "not an accessible directory" "the refusal did not name the inaccessible path"
  pass "fm-grok-trust.sh: refuses a path that does not exist"
}

test_repository_subdirectory_is_refused() {
  local rec out sub
  rec=$(make_case subdir)
  read_case "$rec"
  sub="$PROJ/sub"
  mkdir -p "$sub"
  out=$(run_trust "$GROK_HOME_DIR" "$sub")
  expect_code 1 $? "a subdirectory of the repository must be refused: $out"
  assert_contains "$out" "is not a repository root" "the refusal did not name the non-root path"
  assert_not_trusted "$GROK_HOME_DIR" "$sub" "a repository subdirectory was trusted"
  pass "fm-grok-trust.sh: refuses a subdirectory of the repository"
}

test_unrelated_store_content_is_preserved() {
  local rec store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$GROK_HOME_DIR/trusted_folders.toml"
  cat > "$store" <<EOF
[folders."/other/path"]
trusted = true
decided_at = 111
EOF
  run_trust "$GROK_HOME_DIR" "$PROJ" >/dev/null || fail "registration failed against an existing store"
  assert_trusted "$GROK_HOME_DIR" "$PROJ" "the project was not recorded in an existing store"
  assert_grep '/other/path' "$store" "an unrelated entry was lost"
  assert_grep 'decided_at = 111' "$store" "an unrelated entry's value was changed"
  pass "fm-grok-trust.sh: preserves unrelated store content"
}

test_explicit_untrust_is_not_overridden() {
  local rec out store
  rec=$(make_case untrusted)
  read_case "$rec"
  store="$GROK_HOME_DIR/trusted_folders.toml"
  cat > "$store" <<EOF
[folders."$PROJ"]
trusted = false
decided_at = 111
EOF
  out=$(run_trust "$GROK_HOME_DIR" "$PROJ")
  expect_code 1 $? "an explicit untrust decision must not be overridden: $out"
  assert_contains "$out" "explicit untrust decision" "the refusal did not name the existing untrust decision"
  assert_grep 'trusted = false' "$store" "the explicit untrust decision was rewritten"
  pass "fm-grok-trust.sh: refuses to override an explicit untrust decision"
}

test_missing_node_is_refused() {
  local rec out bindir
  rec=$(make_case no-node)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$GROK_HOME_DIR" "$PROJ")
  expect_code 1 $? "a missing node must refuse rather than let the spawn proceed: $out"
  assert_contains "$out" "node" "the refusal did not name the missing interpreter"
  assert_not_trusted "$GROK_HOME_DIR" "$PROJ" "a project was trusted without an interpreter to write the store"
  pass "fm-grok-trust.sh: a missing node is refused rather than degraded"
}

test_scope_refusal_stays_fail_closed_without_node() {
  local rec out bindir
  rec=$(make_case no-node-refusal)
  read_case "$rec"
  bindir=$(node_free_path "$CASE_DIR")
  out=$(PATH="$bindir" run_trust "$GROK_HOME_DIR" "$WT")
  expect_code 1 $? "the linked worktree must still be refused without node: $out"
  assert_contains "$out" "linked worktree" "the refusal did not name the linked worktree"
  pass "fm-grok-trust.sh: a scope refusal stays fail-closed without node"
}

test_fresh_primary_checkout_is_trusted
test_registration_is_idempotent
test_linked_worktree_is_refused
test_worktree_inherits_trust_from_primary_checkout
test_home_directory_is_refused
test_grok_home_directory_is_refused
test_non_git_directory_is_refused
test_missing_directory_is_refused
test_repository_subdirectory_is_refused
test_unrelated_store_content_is_preserved
test_explicit_untrust_is_not_overridden
test_missing_node_is_refused
test_scope_refusal_stays_fail_closed_without_node
