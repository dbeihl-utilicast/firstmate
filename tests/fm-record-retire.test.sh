#!/usr/bin/env bash
# Tests for the guarded record-only retirement path.
# A record that lost its pooled slot must become inactive without returning or
# resetting the slot now owned by its replacement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-retire)

make_case() {
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/data/old" "$dir/home/config" "$dir/fakebin" "$dir/pool/3"
  touch "$dir/home/state/.last-watcher-beat" "$dir/pool/treehouse-state.json"
  git init -q "$dir/project"
  git -C "$dir/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
  git -C "$dir/project" worktree add -q -b fm/retire-record "$dir/pool/3/repo"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_CALLS:?}"
exit 99
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes) printf '%%1\n' ;;
  display-message) printf 'claude\n' ;;
  list-windows) printf 'fm-destination\n' ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/treehouse" "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/old.meta" \
    "window=fm-old" "endpoint_task_id=old" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes" "spawn_gen=old-incarnation"
  fm_write_meta "$dir/home/state/destination.meta" \
    "window=fm-destination" "endpoint_task_id=destination" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=ship" "mode=no-mistakes" "spawn_gen=destination-incarnation"
  printf 'finished scout report\n' > "$dir/home/data/old/report.md"
}

run_retire() {
  local dir=$1
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_TREEHOUSE_CALLS="$dir/treehouse.calls" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" old --retire-record
}

test_record_only_retirement_preserves_reused_slot() {
  local dir="$TMP_ROOT/reused-slot" out rc=0
  make_case "$dir"
  : > "$dir/treehouse.calls"
  out=$(run_retire "$dir" 2>&1) || rc=$?
  expect_code 0 "$rc" "a finished scout whose slot is owned by another record should retire its record"
  [ ! -e "$dir/home/state/old.meta" ] || fail "the retired record remained active"
  [ -f "$dir/home/state/retired/old.meta" ] || fail "the retired record lacks an audit copy"
  [ -f "$dir/home/state/retired/old.receipt" ] || fail "the retirement lacks an audit receipt"
  [ -f "$dir/home/state/destination.meta" ] || fail "record-only retirement removed the replacement owner"
  [ ! -s "$dir/treehouse.calls" ] || fail "record-only retirement returned or reset the replacement slot: $(cat "$dir/treehouse.calls")"
  pass "record retirement: a reused pooled slot is never returned"
}

test_retired_identity_is_not_a_send_destination() {
  local dir="$TMP_ROOT/inactive-send" rc=0
  make_case "$dir"
  run_retire "$dir" >/dev/null || fail "fixture retirement failed"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    "$ROOT/bin/fm-send.sh" old "do not deliver here" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a retired identity must not remain a message recipient"
  [ ! -d "$dir/home/state/old.inbox" ] || fail "a retired identity received a message"
  pass "record retirement: inactive identity is excluded from delivery"
}

test_record_only_retirement_refuses_its_still_owned_slot() {
  local dir="$TMP_ROOT/still-owned-slot" rc=0
  make_case "$dir"
  rm -f "$dir/home/state/destination.meta"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "retirement must refuse while no replacement owns the slot"
  [ -f "$dir/home/state/old.meta" ] || fail "a refused record retirement removed the active record"
  pass "record retirement: still-owned slot is preserved"
}

test_record_only_retirement_preserves_stopped_marker() {
  local dir="$TMP_ROOT/stopped-marker" rc=0
  make_case "$dir"
  printf 'stopped\n' > "$dir/home/state/old.stopped"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "retiring an old identity should not need to clear a stopped marker"
  [ -f "$dir/home/state/old.stopped" ] || fail "record retirement cleared the stopped marker"
  pass "record retirement: stopped marker remains owned by reopen"
}

test_record_only_retirement_moves_polling_sidecars() {
  local dir="$TMP_ROOT/sidecars" rc=0
  make_case "$dir"
  printf '#!/bin/sh\n' > "$dir/home/state/old.check.sh"
  mkdir -p "$dir/home/state/old.inbox"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "retirement should succeed"
  [ ! -e "$dir/home/state/old.check.sh" ] || fail "a retired identity is still polled"
  [ ! -e "$dir/home/state/old.inbox" ] || fail "a retired identity kept its inbox"
  [ -f "$dir/home/state/retired/old.sidecars/old.check.sh" ] || fail "retired sidecar lacks audit copy"
  pass "record retirement: polling and routing sidecars retire with the record"
}

test_record_only_retirement_ignores_finished_claimant() {
  local dir="$TMP_ROOT/finished-claimant" rc=0
  make_case "$dir"
  mkdir -p "$dir/home/data/destination"
  printf 'finished\n' > "$dir/home/data/destination/report.md"
  fm_write_meta "$dir/home/state/destination.meta" \
    "window=fm-destination" "endpoint_task_id=destination" "worktree=$dir/pool/3/repo" \
    "project=$dir/project" "kind=scout" "mode=no-mistakes" "spawn_gen=destination-incarnation"
  run_retire "$dir" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a finished record is not an active slot claimant"
  [ -f "$dir/home/state/old.meta" ] || fail "refused retirement removed the record"
  pass "record retirement: only an active claimant proves slot ownership"
}

test_record_only_retirement_preserves_reused_slot
test_record_only_retirement_moves_polling_sidecars
test_record_only_retirement_ignores_finished_claimant
test_retired_identity_is_not_a_send_destination
test_record_only_retirement_refuses_its_still_owned_slot
test_record_only_retirement_preserves_stopped_marker
