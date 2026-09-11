#!/usr/bin/env bash
# Negative controls: mutate a scratch copy of the lock library and prove the new tests go red.
set -u
SRC=${1:?worktree root}
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-negctl.XXXXXX")
trap 'rm -rf "$scratch_root"' EXIT

make_copy() {  # <name> -> prints dir
  local d="$scratch_root/$1"
  mkdir -p "$d"
  git -C "$SRC" archive HEAD bin tests | tar -x -C "$d"
  printf '%s\n' "$d"
}

runner() {  # <dir> <test calls...>
  local d=$1; shift
  local file="$d/tests/fm-watcher-lock.test.sh" first
  first=$(grep -nE '^test_[a-z_]+( |$)' "$file" | grep -v '()' | head -1 | cut -d: -f1)
  head -n $((first - 1)) "$file" > "$d/tests/negctl.test.sh"
  printf '%s\n' "$@" >> "$d/tests/negctl.test.sh"
  bash "$d/tests/negctl.test.sh" 2>&1 | grep -E '^(ok|not ok|FAIL|fail)|FAIL' | head -5
  return "${PIPESTATUS[0]}"
}

echo "== M0 unmodified control =="
d=$(make_copy m0)
runner "$d" test_lock_steals_reused_pid_lock test_lock_exec_holder_is_not_stolen "test_lock_interrupted_handoff pending KILL recycled"; echo "exit=$?"

echo
echo "== M1 identity liveness only (pre-change semantics: live pid always held) =="
d=$(make_copy m1)
perl -0pi -e 's/(fm_lock_owner_is_abandoned\(\) \{  # <lockdir> <pid>\n  local lockdir=\$1 pid=\$2 recorded current_lock current_full\n)/$1  if [ "\$pid" != 0 ] \&\& fm_pid_alive "\$pid"; then return 1; fi\n/' "$d/bin/fm-wake-lib.sh"
grep -c 'then return 1; fi' "$d/bin/fm-wake-lib.sh" >/dev/null || echo "MUTATION NOT APPLIED"
runner "$d" test_lock_steals_reused_pid_lock; echo "exit=$?"

echo
echo "== M2 collapse fm_lock_pid_identity into fm_pid_identity (cmdline-sensitive) =="
d=$(make_copy m2)
perl -0pi -e 's/(fm_lock_pid_identity\(\) \{\n)/$1  fm_pid_identity "\$1"; return\n/' "$d/bin/fm-wake-lib.sh"
runner "$d" test_lock_exec_holder_is_not_stolen; echo "exit=$?"

echo
echo "== M3 reintroduce pending-pid liveness rule (round-3 wedge) =="
d=$(make_copy m3)
perl -0pi -e 's/(fm_lock_owner_is_abandoned\(\) \{  # <lockdir> <pid>\n  local lockdir=\$1 pid=\$2 recorded current_lock current_full\n)/$1  pending_pid=\$(cat "\$lockdir\/pid.pending" 2>\/dev\/null || true)\n  if [ -n "\$pending_pid" ] \&\& fm_pid_alive "\$pending_pid"; then return 1; fi\n/' "$d/bin/fm-wake-lib.sh"
runner "$d" "test_lock_interrupted_handoff pending KILL recycled"; echo "exit=$?"
