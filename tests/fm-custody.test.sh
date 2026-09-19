#!/usr/bin/env bash
# Shared custody capture, preservation, and canonical-copy locking.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-custody)
mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/project"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=/dev/null
. "$ROOT/bin/fm-nm-run-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-custody-lib.sh"

STATE="$TMP_ROOT/state"
FM_STATE_OVERRIDE=$STATE
FM_ROOT_OVERRIDE=$ROOT
export STATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE

test_two_task_ids_serialize_on_one_physical_copy() {
  local alias lock_a lock_b holder waiter
  alias="$TMP_ROOT/project-alias"
  ln -s "$TMP_ROOT/project" "$alias"
  lock_a=$(fm_custody_lock_path "$STATE" "$TMP_ROOT/project") || fail "could not resolve first custody lock"
  lock_b=$(fm_custody_lock_path "$STATE" "$alias") || fail "could not resolve aliased custody lock"
  [ "$lock_a" = "$lock_b" ] || fail "two task records could lock one copy under different identities"

  bash -c '
    set -u
    STATE=$1; FM_STATE_OVERRIDE=$1; FM_ROOT_OVERRIDE=$2
    . "$2/bin/fm-wake-lib.sh"
    . "$2/bin/fm-nm-run-lib.sh"
    . "$2/bin/fm-custody-lib.sh"
    lock=$(fm_custody_lock_path "$1" "$3") || exit 2
    fm_lock_acquire_wait "$lock" || exit 3
    : > "$4"
    while [ ! -e "$5" ]; do sleep 0.01; done
    fm_lock_release "$lock"
  ' _ "$STATE" "$ROOT" "$TMP_ROOT/project" "$TMP_ROOT/holder-ready" "$TMP_ROOT/release" &
  holder=$!
  for _ in $(seq 1 200); do [ -e "$TMP_ROOT/holder-ready" ] && break; sleep 0.01; done
  [ -e "$TMP_ROOT/holder-ready" ] || fail "first task did not acquire the copy lock"

  bash -c '
    set -u
    STATE=$1; FM_STATE_OVERRIDE=$1; FM_ROOT_OVERRIDE=$2
    . "$2/bin/fm-wake-lib.sh"
    . "$2/bin/fm-nm-run-lib.sh"
    . "$2/bin/fm-custody-lib.sh"
    lock=$(fm_custody_lock_path "$1" "$3") || exit 2
    fm_lock_acquire_wait "$lock" || exit 3
    : > "$4"
    fm_lock_release "$lock"
  ' _ "$STATE" "$ROOT" "$alias" "$TMP_ROOT/waiter-acquired" &
  waiter=$!
  sleep 0.1
  [ ! -e "$TMP_ROOT/waiter-acquired" ] || fail "second task entered the same copy while recovery held custody"
  : > "$TMP_ROOT/release"
  wait "$holder" || fail "first task failed while releasing custody"
  wait "$waiter" || fail "second task did not acquire custody after release"
  [ -e "$TMP_ROOT/waiter-acquired" ] || fail "serialized second task never entered"
  pass "two task ids naming one physical copy serialize on one custody lock"
}

test_two_task_ids_serialize_on_one_physical_copy

echo "# all fm-custody tests passed"
