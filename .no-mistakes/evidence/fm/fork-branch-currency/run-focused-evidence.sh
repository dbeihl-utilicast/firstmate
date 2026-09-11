#!/usr/bin/env bash
set -eu
cd /Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M295FW69QR2TJ5G0SBE0ZPMF
export PHASE_EVIDENCE=/Users/davidsair/.no-mistakes/evidence/01M295FW69QR2TJ5G0SBE0ZPMF
capture_delivery() {
  local mode dir
  test_branch_currency_replaced_poll_refuses
  {
    printf 'Public path: fm-pr-check -> fm-watch -> fm-send -> durable worker inbox\n'
    printf 'Fixture: OPEN PR, base release/v1+hotfix, behind by 1; classic protection unavailable; strict ruleset on page 2.\n'
    printf 'GitHub responses and tmux delivery are fixtures; registration, watcher, locks, fm-send, inbox and receipts are production code.\n\n'
    for mode in capture-replaced capture-rearmed replaced rearmed unchanged; do
      dir="$TMP_ROOT/branch-currency-poll-$mode"
      printf '\nSCENARIO: %s\n' "$mode"
      cat "$dir/watch.out"
      printf 'Pending inbox records: '
      find "$dir/home/state" -path '*/task-a.inbox/*.msg' -type f | wc -l
    done
    dir="$TMP_ROOT/branch-currency-poll-unchanged"
    printf '\nActual GitHub CLI arguments:\n'
    cat "$dir/gh.log"
    printf '\nPersisted worker instruction:\n'
    cat "$dir/home/state/task-a.inbox/001.msg"
    printf '\nPersisted refresh receipt:\n'
    cat "$dir/home/state/task-a.pr-refresh-state"
  } > "$PHASE_EVIDENCE/branch-refresh-transcript.txt" || return 1
  cp "$dir/home/state/task-a.inbox/001.msg" "$PHASE_EVIDENCE/worker-instruction.msg" || return 1
  cp "$dir/home/state/task-a.pr-refresh-state" "$PHASE_EVIDENCE/refresh-receipt.tsv" || return 1
}
capture_safety() {
  test_branch_currency_cooldown_survives_head_changes
  test_branch_currency_opt_out_by_default
  {
    printf 'Cooldown and default-off public watcher behavior\n\n'
    cat "$TMP_ROOT/branch-currency-cooldown/home/state/.watch-triage.log"
    printf '\nDefault-off observations:\n'
    cat "$TMP_ROOT/branch-currency-opt-out/home/state/.watch-triage.log"
  } > "$PHASE_EVIDENCE/refresh-safety-transcript.txt"
}
capture_retirement() {
  pe() {
    local home=$1 rc=0 captured
    shift
    captured=$(FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@" 2>&1) || rc=$?
    {
      printf '\nScenario: %s\nfm-procevent.sh' "${home##*/}"
      printf ' %q' "$@"
      printf '\n%s\nexit=%s\n' "$captured" "$rc"
    } >> "$PHASE_EVIDENCE/retirement-transcript.txt"
    printf '%s\n' "$captured"
    return "$rc"
  }
  printf 'Public retire with owned fixture processes. ps boundary releases/reaps the matched runner before or after PGID lookup; unreadable live PGID remains refused.\n' > "$PHASE_EVIDENCE/retirement-transcript.txt"
  test_retire_runner_exits_during_stop || return $?
}
capture_triage() {
  test_procevent_captured_result_surfaces_proactively
  test_procevent_unacknowledged_result_redrains_until_handled
  {
    printf 'Original asynchronous register -> reconcile -> captured queue -> retire -> watcher -> drain path\n\n'
    cat "$TMP_ROOT/procevent-delivery/watch.out" "$TMP_ROOT/procevent-delivery/drain.out"
    printf '\nUnacknowledged replay:\n'
    cat "$TMP_ROOT/procevent-redrain/replay.out"
  } > "$PHASE_EVIDENCE/procevent-delivery-transcript.txt"
}
export -f capture_delivery capture_safety capture_retirement capture_triage
case "$1" in
  contract) FM_TEST_ONLY=test_static_poll_contract bin/fm-test-run.sh tests/fm-pr-check-security.test.sh ;;
  delivery)
    FM_TEST_GH_BASE_NAME='release/v1+hotfix' FM_TEST_GH_PROTECTION_FAIL=1 \
      FM_TEST_GH_RULE_PAGES='[[],[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"ci"}]}}]]' \
      FM_TEST_ONLY=capture_delivery bin/fm-test-run.sh tests/fm-pr-check-security.test.sh ;;
  safety) FM_TEST_ONLY=capture_safety bin/fm-test-run.sh tests/fm-pr-check-security.test.sh ;;
  retirement) FM_TEST_ONLY=capture_retirement bin/fm-test-run.sh tests/fm-procevent.test.sh ;;
  triage) FM_TEST_ONLY=capture_triage bin/fm-test-run.sh tests/fm-watch-triage.test.sh ;;
  *) exit 2 ;;
esac
