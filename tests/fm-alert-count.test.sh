#!/usr/bin/env bash
# tests/fm-alert-count.test.sh - executable behavior coverage for live advisory accounting.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

make_repository() {
  local dir=$1
  mkdir -p "$dir/repo" "$dir/fakebin"
  git init -q "$dir/repo"
  git -C "$dir/repo" config user.email 'alerts-test@example.invalid'
  git -C "$dir/repo" config user.name 'alerts test'
  git -C "$dir/repo" remote add origin https://github.com/acme/widget.git
  cat >"$dir/repo/package-lock.json" <<'JSON'
{"lockfileVersion":3,"packages":{"node_modules/foo":{"version":"1.0.0"},"node_modules/already":{"version":"2.0.0"},"node_modules/rejected":{"version":"1.0.0"},"node_modules/major":{"version":"1.0.0"}}}
JSON
  git -C "$dir/repo" add package-lock.json
  git -C "$dir/repo" commit -qm base
  git -C "$dir/repo" branch integration
  git -C "$dir/repo" checkout -qb security
  perl -0pi -e 's/"node_modules\/foo":\{"version":"1\.0\.0"\}/"node_modules\/foo":{"version":"1.0.1"}/' "$dir/repo/package-lock.json"
  git -C "$dir/repo" commit -am head -q
}

write_gh_axi() {
  local file=$1 payload=$2
  cat >"$file" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  *'/repos/acme/widget/dependabot/alerts?state=open&per_page=100'*)
    printf 'api_response:\n  body: %s\n  truncated: false\n' '$payload'
    ;;
  *) printf 'unexpected gh-axi request: %s\n' "\$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$file"
}

test_verified_remediation_and_exclusions_are_explicit() {
  local dir payload out rc
  dir=$(fm_test_tmproot fm-alert-count)
  make_repository "$dir"
  payload=$(printf '%s' '[
    {"number":101,"dependency":{"package":{"name":"foo"},"manifest_path":"package-lock.json"},"security_vulnerability":{"first_patched_version":{"identifier":"1.0.1"}}},
    {"number":102,"dependency":{"package":{"name":"already"},"manifest_path":"package-lock.json"},"security_vulnerability":{"first_patched_version":{"identifier":"2.0.0"}}},
    {"number":103,"dependency":{"package":{"name":"rejected"},"manifest_path":"package-lock.json"},"security_vulnerability":{"first_patched_version":{"identifier":"1.0.1"}}},
    {"number":104,"dependency":{"package":{"name":"major"},"manifest_path":"package-lock.json"},"security_vulnerability":{"first_patched_version":{"identifier":"2.0.0"}}}
  ]' | base64 | tr -d '\n')
  write_gh_axi "$dir/fakebin/gh-axi" "$payload"
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "complete evidence should succeed: $out"
  printf '%s\n' "$out" | grep -F 'foo: 1 (#101)' >/dev/null || fail "missing per-package count: $out"
  printf '%s\n' "$out" | grep -F '#101 foo (package-lock.json)' >/dev/null || fail "missing advisory identifier: $out"
  printf '%s\n' "$out" | grep -F 'VERIFIED BRANCH REMEDIATION COUNT: 1' >/dev/null || fail "wrong verified count: $out"
  printf '%s\n' "$out" | grep -F '#102 already (package-lock.json): already resolved on integration' >/dev/null || fail "missing already-resolved exclusion: $out"
  printf '%s\n' "$out" | grep -F '#103 rejected (package-lock.json): security does not reach a patched version' >/dev/null || fail "missing rejected exclusion: $out"
  printf '%s\n' "$out" | grep -F '#104 major (package-lock.json): major-only advisory' >/dev/null || fail "missing major-only exclusion: $out"
  printf '%s\n' "$out" | grep -F 'close none now' >/dev/null || fail "missing default-branch caveat: $out"
  printf '%s\n' "$out" | grep -Fx 'NOT CHECKED: none' >/dev/null || fail "missing checked-scope statement: $out"
  pass "alert count prints identifiers, exclusions, and the default-branch caveat"
}

test_empty_live_list_is_silent() {
  local dir out
  dir=$(fm_test_tmproot fm-alert-count-empty)
  make_repository "$dir"
  write_gh_axi "$dir/fakebin/gh-axi" "W10="
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  [ -z "$out" ] || fail "an empty live alert list must be silent: $out"
  pass "alert count is silent when the default branch has no open alerts"
}

test_live_list_failure_is_not_a_count() {
  local dir out rc
  dir=$(fm_test_tmproot fm-alert-count-failure)
  make_repository "$dir"
  cat >"$dir/fakebin/gh-axi" <<'EOF'
#!/usr/bin/env bash
printf 'error: insufficient permissions\n' >&2
exit 1
EOF
  chmod +x "$dir/fakebin/gh-axi"
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an inaccessible live list must fail"
  printf '%s\n' "$out" | grep -F 'NOT CHECKED:' >/dev/null || fail "failure claimed a count: $out"
  pass "alert count reports an inaccessible live list as not checked"
}

test_unsupported_manifest_is_explicitly_not_checked() {
  local dir payload out rc
  dir=$(fm_test_tmproot fm-alert-count-unsupported)
  make_repository "$dir"
  payload=$(printf '%s' '[{"number":201,"dependency":{"package":{"name":"java-lib"},"manifest_path":"pom.xml"},"security_vulnerability":{"first_patched_version":{"identifier":"1.0.1"}}}]' | base64 | tr -d '\n')
  write_gh_axi "$dir/fakebin/gh-axi" "$payload"
  set +e
  out=$(cd "$dir/repo" && PATH="$dir/fakebin:$PATH" "$ROOT/bin/fm-alert-count.py" integration security)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported manifest must not produce a verified count"
  printf '%s\n' "$out" | grep -F '#201 java-lib (pom.xml): unsupported manifest' >/dev/null || fail "missing unsupported manifest evidence: $out"
  printf '%s\n' "$out" | grep -F 'NOT CHECKED:' >/dev/null || fail "unsupported scope was not declared: $out"
  pass "alert count refuses unsupported manifests instead of guessing"
}

test_verified_remediation_and_exclusions_are_explicit
test_empty_live_list_is_silent
test_live_list_failure_is_not_a_count
test_unsupported_manifest_is_explicitly_not_checked
