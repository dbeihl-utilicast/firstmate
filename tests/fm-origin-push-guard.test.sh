#!/usr/bin/env bash
# Behavior tests for the local unguarded-push refusal.
#
# Drives bin/fm-origin-push-guard.sh through git's pre-push public interface
# (core.hooksPath and the installed hooks/pre-push) against local bare remotes.
# A checkout with a no-mistakes remote must refuse origin and still accept
# no-mistakes; a checkout without that remote must stay unchanged.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-origin-push-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-origin-push-guard)
fm_git_identity fmtest fmtest@example.invalid
ZERO=0000000000000000000000000000000000000000

chmod +x "$HOOK"

# A git repo with a local bare origin, one commit on main, and an isolated
# hooks directory that contains a copy of the guard as pre-push.
make_repo() {
  local dir=$1
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  fm_git_add_origin "$dir" "$dir.origin.git"
  mkdir -p "$dir.hooks"
  cp -- "$HOOK" "$dir.hooks/pre-push"
  chmod 755 "$dir.hooks/pre-push"
  printf '%s\n' "$dir"
}

add_no_mistakes() {
  local dir=$1
  git clone --quiet --bare "$dir" "$dir.nm.git"
  git -C "$dir" remote add no-mistakes "file://$(cd "$dir.nm.git" && pwd)"
}

push() {
  local dir=$1 remote=$2 ref=${3:-HEAD:refs/heads/topic}
  git -C "$dir" -c "core.hooksPath=$dir.hooks" push --quiet "$remote" "$ref"
}

push_out() {
  local dir=$1 remote=$2 ref=${3:-HEAD:refs/heads/topic}
  git -C "$dir" -c "core.hooksPath=$dir.hooks" push --quiet "$remote" "$ref" 2>&1
}

test_without_no_mistakes_origin_still_pushes() {
  local repo rc=0
  repo=$(make_repo "$TMP_ROOT/plain")
  push "$repo" origin HEAD:refs/heads/plain || rc=$?
  expect_code 0 "$rc" "origin push without a no-mistakes remote must still succeed"
  git -C "$repo.origin.git" rev-parse --verify --quiet refs/heads/plain >/dev/null \
    || fail "origin did not receive the unguarded-template push"
  pass "no no-mistakes remote: origin push still succeeds"
}

test_origin_refused_when_no_mistakes_exists() {
  local repo rc=0 out
  repo=$(make_repo "$TMP_ROOT/guarded")
  add_no_mistakes "$repo"
  out=$(push_out "$repo" origin HEAD:refs/heads/blocked) || rc=$?
  expect_code 1 "$rc" "origin push with a no-mistakes remote must be refused"
  assert_contains "$out" "git push no-mistakes" "refusal did not name the guarded command"
  assert_contains "$out" "FM_ALLOW_UNGUARDED_PUSH=1" "refusal did not name the env override"
  git -C "$repo.origin.git" rev-parse --verify --quiet refs/heads/blocked >/dev/null \
    && fail "origin received a push the hook should have refused"
  pass "no-mistakes remote: origin push is refused and nothing is published"
}

test_no_mistakes_push_still_goes_through() {
  local repo rc=0
  repo=$(make_repo "$TMP_ROOT/nm-ok")
  add_no_mistakes "$repo"
  push "$repo" no-mistakes HEAD:refs/heads/gated || rc=$?
  expect_code 0 "$rc" "push to the no-mistakes remote must still succeed"
  git -C "$repo.nm.git" rev-parse --verify --quiet refs/heads/gated >/dev/null \
    || fail "no-mistakes remote did not receive the guarded push"
  pass "no-mistakes remote: git push no-mistakes still goes through"
}

test_url_push_matches_named_remote() {
  local repo origin_url nm_url rc=0 out
  repo=$(make_repo "$TMP_ROOT/by-url")
  add_no_mistakes "$repo"
  origin_url=$(git -C "$repo" config --get remote.origin.url)
  nm_url=$(git -C "$repo" config --get remote.no-mistakes.url)
  out=$(push_out "$repo" "$origin_url" HEAD:refs/heads/url-origin) || rc=$?
  expect_code 1 "$rc" "push by origin URL must be refused"
  assert_contains "$out" "git push no-mistakes" "URL-form origin push did not print the guarded command"
  rc=0
  push "$repo" "$nm_url" HEAD:refs/heads/url-nm || rc=$?
  expect_code 0 "$rc" "push by no-mistakes URL must still succeed"
  git -C "$repo.nm.git" rev-parse --verify --quiet refs/heads/url-nm >/dev/null \
    || fail "no-mistakes URL push did not land"
  pass "push by URL: origin is refused, no-mistakes is allowed"
}

test_env_override_skips_only_this_refusal() {
  local repo rc=0
  repo=$(make_repo "$TMP_ROOT/override")
  add_no_mistakes "$repo"
  FM_ALLOW_UNGUARDED_PUSH=1 push "$repo" origin HEAD:refs/heads/overridden || rc=$?
  expect_code 0 "$rc" "FM_ALLOW_UNGUARDED_PUSH=1 must allow an origin push"
  git -C "$repo.origin.git" rev-parse --verify --quiet refs/heads/overridden >/dev/null \
    || fail "override push did not land on origin"
  pass "FM_ALLOW_UNGUARDED_PUSH=1 allows origin and is a deliberate escape"
}

test_other_boolean_override_values_are_refused() {
  local repo value rc out
  for value in yes YES true TRUE; do
    repo=$(make_repo "$TMP_ROOT/override-$value")
    add_no_mistakes "$repo"
    rc=0
    out=$(FM_ALLOW_UNGUARDED_PUSH="$value" push_out "$repo" origin \
      "HEAD:refs/heads/blocked-$value") || rc=$?
    expect_code 1 "$rc" "FM_ALLOW_UNGUARDED_PUSH=$value must not allow an origin push"
    assert_contains "$out" "git push no-mistakes" \
      "FM_ALLOW_UNGUARDED_PUSH=$value did not produce the refusal"
    git -C "$repo.origin.git" rev-parse --verify --quiet "refs/heads/blocked-$value" >/dev/null \
      && fail "FM_ALLOW_UNGUARDED_PUSH=$value published an origin branch"
  done
  pass "only the exact FM_ALLOW_UNGUARDED_PUSH=1 value bypasses the refusal"
}

test_no_verify_skips_the_hook() {
  local repo rc=0
  repo=$(make_repo "$TMP_ROOT/no-verify")
  add_no_mistakes "$repo"
  git -C "$repo" -c "core.hooksPath=$repo.hooks" push --quiet --no-verify origin \
    HEAD:refs/heads/forced || rc=$?
  expect_code 0 "$rc" "git push --no-verify must skip the refusal"
  git -C "$repo.origin.git" rev-parse --verify --quiet refs/heads/forced >/dev/null \
    || fail "--no-verify push did not land on origin"
  pass "git push --no-verify skips the refusal"
}

test_protocol_refuse_without_git_push() {
  local repo sha rc=0 out
  repo=$(make_repo "$TMP_ROOT/protocol")
  add_no_mistakes "$repo"
  sha=$(git -C "$repo" rev-parse HEAD)
  origin_url=$(git -C "$repo" config --get remote.origin.url)
  out=$(
    cd "$repo" || exit 1
    printf 'refs/heads/topic %s refs/heads/topic %s\n' "$sha" "$ZERO" \
      | "$HOOK" origin "$origin_url" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "pre-push protocol to origin must be refused"
  assert_contains "$out" "git push no-mistakes" "protocol refusal did not name the guarded command"
  pass "pre-push protocol interface refuses origin without git push"
}

test_install_writes_pre_push_and_is_idempotent() {
  local repo sum1 sum2
  repo=$(make_repo "$TMP_ROOT/installed")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  "$HOOK" install "$repo" || fail "install refused a normal checkout"
  assert_present "$repo/.git/hooks/pre-push" "install did not write hooks/pre-push"
  sum1=$(cksum "$repo/.git/hooks/pre-push")
  "$HOOK" install "$repo" || fail "second install failed"
  sum2=$(cksum "$repo/.git/hooks/pre-push")
  [ "$sum1" = "$sum2" ] || fail "second install rewrote the hook to different bytes"
  assert_absent "$repo/.git/hooks/pre-push.fm-prev" "idempotent install created a chain file with no prior hook"
  pass "install writes hooks/pre-push and is idempotent"
}

test_installed_hook_refuses_origin() {
  local repo rc=0 out
  repo=$(make_repo "$TMP_ROOT/installed-push")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  "$HOOK" install "$repo" || fail "install refused a normal checkout"
  out=$(git -C "$repo" push --quiet origin HEAD:refs/heads/installed-block 2>&1) || rc=$?
  expect_code 1 "$rc" "installed hook must refuse origin"
  assert_contains "$out" "git push no-mistakes" "installed refusal did not name the guarded command"
  pass "installed hooks/pre-push refuses origin without core.hooksPath"
}

test_install_chains_existing_pre_push() {
  local repo log rc=0
  repo=$(make_repo "$TMP_ROOT/chain")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  log="$TMP_ROOT/chain.log"
  : > "$log"
  cat > "$repo/.git/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'chained\\n' >> "$log"
exit 0
SH
  chmod 755 "$repo/.git/hooks/pre-push"
  "$HOOK" install "$repo" || fail "install refused to chain an existing pre-push"
  assert_present "$repo/.git/hooks/pre-push.fm-prev" "install did not preserve the existing pre-push"
  git -C "$repo" push --quiet no-mistakes HEAD:refs/heads/chain-ok || rc=$?
  expect_code 0 "$rc" "chained no-mistakes push must succeed"
  assert_grep "chained" "$log" "allowed push did not run the preserved pre-push"
  : > "$log"
  rc=0
  git -C "$repo" push --quiet origin HEAD:refs/heads/chain-block 2>/dev/null || rc=$?
  expect_code 1 "$rc" "chained origin push must still be refused"
  [ ! -s "$log" ] || fail "refused origin push still ran the preserved pre-push"
  pass "install chains an existing pre-push on allow and skips it on refuse"
}

test_allowed_route_streams_refs_directly_to_chained_hook() {
  local repo log fakebin sha expected nm_url rc=0
  repo=$(make_repo "$TMP_ROOT/direct-ref-stream")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  log="$TMP_ROOT/direct-ref-stream.log"
  sha=$(git -C "$repo" rev-parse HEAD)
  expected="refs/heads/topic $sha refs/heads/topic $ZERO"
  nm_url=$(git -C "$repo" config --get remote.no-mistakes.url)
  cat > "$repo/.git/hooks/pre-push" <<SH
#!/usr/bin/env bash
IFS= read -r line || exit 42
[ "\$line" = "$expected" ] || exit 43
printf '%s\n' "\$line" > "$log"
SH
  chmod 755 "$repo/.git/hooks/pre-push"
  "$HOOK" install "$repo" || fail "install refused the ref-reading pre-push"
  fakebin="$TMP_ROOT/direct-ref-stream-bin"
  mkdir -p "$fakebin"
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod 755 "$fakebin/cat"
  (
    cd "$repo" || exit 1
    printf '%s\n' "$expected" \
      | PATH="$fakebin:$PATH" .git/hooks/pre-push no-mistakes "$nm_url"
  ) || rc=$?
  expect_code 0 "$rc" "allowed route must pass Git's ref stream to the chained hook"
  assert_contains "$(cat "$log")" "$expected" \
    "chained hook did not receive Git's original ref stream"
  pass "allowed route passes Git's ref stream directly to the chained hook"
}

test_install_preserves_disabled_pre_push() {
  local repo log rc=0
  repo=$(make_repo "$TMP_ROOT/disabled-chain")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  log="$TMP_ROOT/disabled-chain.log"
  : > "$log"
  cat > "$repo/.git/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'chained\\n' >> "$log"
exit 1
SH
  chmod 644 "$repo/.git/hooks/pre-push"
  "$HOOK" install "$repo" || fail "install refused a disabled existing pre-push"
  [ ! -x "$repo/.git/hooks/pre-push.fm-prev" ] \
    || fail "install made the disabled preserved pre-push executable"
  git -C "$repo" push --quiet no-mistakes HEAD:refs/heads/disabled-chain || rc=$?
  expect_code 0 "$rc" "disabled chained pre-push must stay skipped"
  [ ! -s "$log" ] || fail "disabled chained pre-push ran after installation"
  pass "install preserves the executable mode of an existing pre-push"
}

test_env_override_still_runs_chained_hook() {
  local repo log rc=0
  repo=$(make_repo "$TMP_ROOT/override-chain")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  log="$TMP_ROOT/override-chain.log"
  : > "$log"
  cat > "$repo/.git/hooks/pre-push" <<SH
#!/usr/bin/env bash
printf 'chained\\n' >> "$log"
exit 0
SH
  chmod 755 "$repo/.git/hooks/pre-push"
  "$HOOK" install "$repo" || fail "install refused to chain an existing pre-push"
  FM_ALLOW_UNGUARDED_PUSH=1 git -C "$repo" push --quiet origin HEAD:refs/heads/override-chain || rc=$?
  expect_code 0 "$rc" "override origin push must succeed"
  assert_grep "chained" "$log" "env override skipped the chained pre-push as well as this refusal"
  pass "FM_ALLOW_UNGUARDED_PUSH=1 still runs a chained pre-push"
}

test_install_skips_hooks_path_outside_clone() {
  local repo outside
  repo=$(make_repo "$TMP_ROOT/outside-hooks")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  outside="$TMP_ROOT/outside-hooks-dir"
  mkdir -p "$outside"
  git -C "$repo" config core.hooksPath "$outside"
  "$HOOK" install "$repo" 2>"$TMP_ROOT/outside-hooks.err" || fail "outside hooksPath install exited non-zero"
  assert_absent "$outside/pre-push" "install wrote a hook outside the clone"
  assert_absent "$repo/.git/hooks/pre-push" "install fell back to ignored .git/hooks while hooksPath was outside"
  assert_contains "$(cat "$TMP_ROOT/outside-hooks.err")" "outside this clone" \
    "outside hooksPath skip did not explain why it did not install"
  pass "install does not write outside the clone when core.hooksPath is external"
}

test_install_resolves_symlinked_hooks_directory() {
  local repo outside rc=0 out
  repo=$(make_repo "$TMP_ROOT/symlink-hooks")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks" "$repo/.git/hooks"
  outside="$TMP_ROOT/symlink-hooks-outside"
  mkdir -p "$outside"
  ln -s "$outside" "$repo/.git/hooks"
  out=$("$HOOK" install "$repo" 2>&1) || rc=$?
  expect_code 0 "$rc" "external symlinked hooks directory must be skipped safely"
  assert_absent "$outside/pre-push" "install followed a symlinked hooks directory outside the clone"
  assert_contains "$out" "outside this clone" \
    "symlinked hooks directory skip did not explain the refusal"
  pass "install resolves the hooks directory before its containment check"
}

test_install_rejects_symlinked_pre_push() {
  local repo external before after rc=0 out
  repo=$(make_repo "$TMP_ROOT/symlink-pre-push")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  external="$TMP_ROOT/external-pre-push"
  printf '#!/usr/bin/env bash\n# FIRSTMATE_ORIGIN_PUSH_GUARD_V1\nprintf external\\n' > "$external"
  chmod 755 "$external"
  before=$(cksum "$external")
  ln -s "$external" "$repo/.git/hooks/pre-push"
  out=$("$HOOK" install "$repo" 2>&1) || rc=$?
  expect_code 1 "$rc" "symlinked pre-push must be rejected"
  after=$(cksum "$external")
  [ "$before" = "$after" ] || fail "install rewrote the external pre-push target"
  [ -L "$repo/.git/hooks/pre-push" ] || fail "install replaced the rejected pre-push symlink"
  assert_absent "$repo/.git/hooks/pre-push.fm-prev" \
    "install moved the rejected pre-push symlink before failing"
  assert_contains "$out" "symbolic link" "symlinked pre-push rejection did not explain the conflict"
  pass "install rejects a pre-push symlink without mutating its target"
}

test_repo_relative_hooks_path_is_installed() {
  local repo rc=0 out
  repo=$(make_repo "$TMP_ROOT/relative-hooks")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  git -C "$repo" config core.hooksPath .githooks
  "$HOOK" install "$repo" || fail "install refused a repo-relative hooksPath"
  assert_present "$repo/.githooks/pre-push" "install did not write the repo-relative hooksPath"
  out=$(git -C "$repo" push --quiet origin HEAD:refs/heads/relative-block 2>&1) || rc=$?
  expect_code 1 "$rc" "repo-relative hooksPath hook must refuse origin"
  assert_contains "$out" "git push no-mistakes" "repo-relative refusal did not name the guarded command"
  pass "repo-relative core.hooksPath is chained/installed and still refuses origin"
}

test_worktree_shares_the_installed_hook() {
  local repo wt rc=0 out
  repo=$(make_repo "$TMP_ROOT/shared-hooks")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  "$HOOK" install "$repo" || fail "install refused a normal checkout"
  wt="$TMP_ROOT/shared-hooks-wt"
  git -C "$repo" worktree add -q -b shared-topic "$wt"
  out=$(git -C "$wt" push --quiet origin HEAD:refs/heads/shared-topic 2>&1) || rc=$?
  expect_code 1 "$rc" "worktree origin push must hit the shared hook"
  assert_contains "$out" "git push no-mistakes" "worktree refusal did not name the guarded command"
  pass "hooks in the common dir refuse origin from a linked worktree"
}

test_detect_only_bootstrap_does_not_install() {
  local repo
  repo=$(make_repo "$TMP_ROOT/detect-only")
  rm -rf "$repo.hooks"
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 \
    || fail "detect-only bootstrap failed"
  assert_absent "$repo/.git/hooks/pre-push" "detect-only bootstrap installed a pre-push hook"
  pass "detect-only bootstrap does not install the hook"
}

test_bootstrap_installs_the_hook() {
  local repo rc=0 out
  repo=$(make_repo "$TMP_ROOT/bootstrap-install")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  mkdir -p "$repo/data" "$repo/state" "$repo/config"
  FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1 \
    || fail "bootstrap failed"
  assert_present "$repo/.git/hooks/pre-push" "bootstrap did not install hooks/pre-push"
  out=$(git -C "$repo" push --quiet origin HEAD:refs/heads/boot-block 2>&1) || rc=$?
  expect_code 1 "$rc" "bootstrap-installed hook must refuse origin"
  assert_contains "$out" "git push no-mistakes" "bootstrap-installed refusal did not name the guarded command"
  pass "session-start bootstrap installs the hook and origin then refuses"
}

test_bootstrap_reports_hook_install_failure_as_actionable() {
  local repo out rc=0
  repo=$(make_repo "$TMP_ROOT/bootstrap-conflict")
  add_no_mistakes "$repo"
  rm -rf "$repo.hooks"
  mkdir -p "$repo/data" "$repo/state" "$repo/config"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.git/hooks/pre-push"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.git/hooks/pre-push.fm-prev"
  chmod 755 "$repo/.git/hooks/pre-push" "$repo/.git/hooks/pre-push.fm-prev"
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$repo" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || rc=$?
  expect_code 0 "$rc" "bootstrap diagnostics must keep the documented zero exit status"
  assert_contains "$out" "ORIGIN_PUSH_GUARD:" \
    "bootstrap did not surface hook installation failure as actionable"
  assert_contains "$out" "both exist" "bootstrap dropped the hook conflict reason"
  assert_not_contains "$out" "BOOTSTRAP_INFO: origin-push-guard install failed" \
    "bootstrap still typed hook installation failure as harmless"
  pass "bootstrap surfaces hook installation failure as an actionable diagnostic"
}

test_without_no_mistakes_origin_still_pushes
test_origin_refused_when_no_mistakes_exists
test_no_mistakes_push_still_goes_through
test_url_push_matches_named_remote
test_env_override_skips_only_this_refusal
test_other_boolean_override_values_are_refused
test_no_verify_skips_the_hook
test_protocol_refuse_without_git_push
test_install_writes_pre_push_and_is_idempotent
test_installed_hook_refuses_origin
test_install_chains_existing_pre_push
test_allowed_route_streams_refs_directly_to_chained_hook
test_install_preserves_disabled_pre_push
test_env_override_still_runs_chained_hook
test_install_skips_hooks_path_outside_clone
test_install_resolves_symlinked_hooks_directory
test_install_rejects_symlinked_pre_push
test_repo_relative_hooks_path_is_installed
test_worktree_shares_the_installed_hook
test_detect_only_bootstrap_does_not_install
test_bootstrap_installs_the_hook
test_bootstrap_reports_hook_install_failure_as_actionable
