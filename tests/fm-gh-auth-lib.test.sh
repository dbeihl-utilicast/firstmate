#!/usr/bin/env bash
# Repository-scoped GitHub auth selects a configured login without altering gh's
# active account. The fake gh records only which branch ran and never emits its
# token, so this suite also proves the secret stays out of observable output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gh-auth-lib-tests)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

new_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/home/config"
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-} ${3:-}" in
  "auth token --user")
    case "${4:-}" in
      mapped-login) printf '%s\n' 'secret-mapped-token' ;;
      missing-login) exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  *)
    if [ "${GH_TOKEN:-}" = secret-mapped-token ]; then
      printf 'target mapped-token\n'
    elif [ "${GH_TOKEN:-}" = caller-token ]; then
      printf 'target caller-token\n'
    elif [ -z "${GH_TOKEN:-}" ]; then
      printf 'target no-token\n'
    else
      printf 'target unexpected-token\n'
      exit 9
    fi
    ;;
esac
SH
  chmod +x "$dir/bin/gh"
  printf '%s\n' "$dir"
}

run_case() {  # <dir> <owner> [GH_TOKEN]
  local dir=$1 owner=$2 token=${3-}
  if [ -n "$token" ]; then
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" GH_TOKEN="$token" \
      bash -c '. "$1"; fm_gh_run "$2" gh target' _ "$ROOT/bin/fm-gh-auth-lib.sh" "$owner"
  else
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" \
      bash -c '. "$1"; fm_gh_run "$2" gh target' _ "$ROOT/bin/fm-gh-auth-lib.sh" "$owner"
  fi
}

test_mapped_owner_uses_its_login_token() {
  local dir out
  dir=$(new_case mapped)
  printf '%s\n' 'Mapped-Owner mapped-login' > "$dir/home/config/gh-accounts"
  out=$(run_case "$dir" mapped-owner)
  [ "$out" = 'target mapped-token' ] || fail "mapped owner did not receive its configured token: $out"
  pass "fm-gh-auth-lib uses the mapped login token for a repository owner"
}

test_unmapped_owner_inherits_active_account_behavior() {
  local dir out
  dir=$(new_case unmapped)
  printf '%s\n' 'mapped-owner mapped-login' > "$dir/home/config/gh-accounts"
  out=$(run_case "$dir" other-owner)
  [ "$out" = 'target no-token' ] || fail "unmapped owner did not leave GH_TOKEN untouched: $out"
  pass "fm-gh-auth-lib leaves an unmapped owner to gh's active account"
}

test_default_owner_mapping_applies_only_when_configured() {
  local dir out
  dir=$(new_case default)
  printf '%s\n' 'default mapped-login' > "$dir/home/config/gh-accounts"
  out=$(run_case "$dir" other-owner)
  [ "$out" = 'target mapped-token' ] || fail "configured default did not supply its token: $out"
  pass "fm-gh-auth-lib applies a configured default mapping"
}

test_missing_mapped_login_fails_without_running_target() {
  local dir out rc
  dir=$(new_case missing-login)
  printf '%s\n' 'mapped-owner missing-login' > "$dir/home/config/gh-accounts"
  set +e
  out=$(run_case "$dir" mapped-owner 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "missing configured login ran the target"
  assert_contains "$out" 'missing-login' "missing login was not named"
  assert_contains "$out" 'gh auth login' "missing login did not name the repair command"
  case "$out" in *target*) fail "missing configured login reached the target: $out" ;; esac
  pass "fm-gh-auth-lib refuses a configured login whose token cannot be read"
}

test_caller_token_is_preserved() {
  local dir out
  dir=$(new_case caller-token)
  printf '%s\n' 'mapped-owner mapped-login' > "$dir/home/config/gh-accounts"
  out=$(run_case "$dir" mapped-owner caller-token)
  [ "$out" = 'target caller-token' ] || fail "caller GH_TOKEN was replaced: $out"
  pass "fm-gh-auth-lib preserves a caller-supplied GH_TOKEN"
}

test_token_never_appears_in_output() {
  local dir out err rc combined
  dir=$(new_case no-leak)
  printf '%s\n' 'mapped-owner mapped-login' > "$dir/home/config/gh-accounts"
  err="$dir/stderr"
  set +e
  out=$(run_case "$dir" mapped-owner 2>"$err")
  rc=$?
  set -e
  combined="$out$(cat "$err")"
  [ "$rc" -eq 0 ] || fail "mapped call unexpectedly failed: $combined"
  case "$combined" in *secret-mapped-token*) fail "token appeared in output: $combined" ;; esac
  pass "fm-gh-auth-lib keeps the configured token out of command output"
}

test_mapped_owner_uses_its_login_token
test_unmapped_owner_inherits_active_account_behavior
test_default_owner_mapping_applies_only_when_configured
test_missing_mapped_login_fails_without_running_target
test_caller_token_is_preserved
test_token_never_appears_in_output
