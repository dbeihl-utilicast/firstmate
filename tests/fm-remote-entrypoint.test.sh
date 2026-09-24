#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_unavailable_worker_is_a_temporary_failure() {
  # A worker that cannot report ready is a remote-side outage, not a caller
  # error, and must not reuse 75, which the reply source reads as "window
  # closed empty, channel caught up".
  local root home out err code
  root="$TMP_ROOT/no-worker-root"
  home="$TMP_ROOT/no-worker-home"
  mkdir -p "$root/bin" "$home"
  printf 'fixture\n' > "$root/AGENTS.md"
  printf '#!/bin/bash\nprintf ok\\n\n' > "$root/bin/fm-echo-job.sh"
  chmod +x "$root/bin/fm-echo-job.sh"
  git -C "$root" init -q -b main
  git -C "$root" add AGENTS.md bin
  git -C "$root" -c user.email=test@example.com -c user.name=Test commit -qm fixture
  out="$TMP_ROOT/no-worker.stdout"
  err="$TMP_ROOT/no-worker.stderr"
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/no-worker-jobs" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    "$REAL_BIN/fm-remote-entrypoint.sh" 1 \
    "$(printf '%s' "$root" | base64 | tr -d '\n')" \
    "$(printf '%s' "$home" | base64 | tr -d '\n')" \
    "$(printf '%s\0' fm-echo-job.sh | base64 | tr -d '\n')" < /dev/null > "$out" 2> "$err"
  code=$?
  assert_grep 'no safe executable remote job worker' "$err" \
    "the unavailable-worker call did not fail at worker startup"
  expect_code 69 "$code" "unavailable worker exit code"
  pass "an unavailable remote job worker exits 69, distinct from caller errors and an empty reply window"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works
test_unavailable_worker_is_a_temporary_failure
