#!/usr/bin/env bash
# Evidence driver: walks one PR through the branch-currency lifecycle end to end
# using the real fm-pr-check.sh / fm-pr-poll.sh / fm-watch.sh binaries and the
# suite's forge + worker fakes, printing what the captain and the worker see.
set -u
REPO=/Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M1XVNPHKWC8D7NFYYCJX47TD
SUITE="$REPO/tests/fm-pr-check-security.test.sh"
shim=$(mktemp "${TMPDIR:-/tmp}/fm-evidence-shim.XXXXXX")
trap 'rm -f "$shim"' EXIT
sed -e 's|^\. "\$(dirname "\${BASH_SOURCE\[0\]}")/lib\.sh"|. "'"$REPO"'/tests/lib.sh"|' \
    -e '/^test_branch_currency_dispatch_and_active_refusal$/,$d' "$SUITE" > "$shim"
# shellcheck disable=SC1090
. "$shim"

PR=https://github.com/o/r/pull/42
HEAD_A=0123456789abcdef0123456789abcdef01234567
HEAD_B=2222222222222222222222222222222222222222
HEAD_C=89abcdef0123456789abcdef0123456789abcdef

banner() { printf '\n===== %s =====\n' "$*"; }
captain_view() {  # <label> <stdout-file>
  if [ -s "$2" ]; then printf '%s captain wake:\n' "$1"; sed 's/^/    /' "$2"
  else printf '%s captain wake: (silent - nothing reached the captain)\n' "$1"; fi
}

dir=$(make_case evidence-lifecycle)
state="$dir/home/state"
write_task_meta "$dir"
enable_pr_refresh "$dir"
run_check_entry "$dir" task-a "$PR" >/dev/null || { echo "arm failed"; exit 1; }
cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: done \302\267 source: run-step \302\267 checks green: PR ready for review\n'
SH
chmod +x "$dir/fakebin/fm-crew-state.sh"
fake_idempotent_refresh_send "$dir"
: > "$dir/refresh-send.log"

cycle() {  # <out-name> <BEHIND_BY> <HEAD>
  FM_TEST_GH_STATE=OPEN FM_TEST_GH_BEHIND_BY="$2" FM_TEST_GH_HEAD="$3" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_PR_REFRESH_SEND_BIN="$dir/fakebin/fm-refresh-send.sh" \
    FM_TEST_REFRESH_SEND_LOG="$dir/refresh-send.log" \
    run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/$1.out" 2> "$dir/$1.err"
}

banner "poll 1: base moved, PR is behind at head ${HEAD_A:0:7}"
cycle c1 1 "$HEAD_A"
captain_view "poll 1" "$dir/c1.out"
printf '\ninstruction delivered to the worker inbox (%s):\n' "$(ls "$state/task-a.inbox"/*.msg)"
sed 's/^/    /' "$state/task-a.inbox"/*.msg; printf '\n'

banner "poll 2: worker acknowledged, rebase still in flight, same head"
mv "$state/task-a.inbox"/*.msg "$state/task-a.inbox/handled/"
ack_watcher_cycle "$state" >/dev/null || echo "ack failed"
add_stop_custom_check "$dir"
cycle c2 1 "$HEAD_A"
captain_view "poll 2" "$dir/c2.out"
printf 'poll 2 captain triage log:\n'; grep 'branch-refresh' "$state/.watch-triage.log" | tail -1 | sed 's/^/    /'

banner "poll 3: base advanced again, head genuinely moved to ${HEAD_B:0:7}"
ack_watcher_cycle "$state" >/dev/null || true
cycle c3 1 "$HEAD_B"
captain_view "poll 3" "$dir/c3.out"

banner "poll 4: rebase landed, PR current at ${HEAD_C:0:7}"
mv "$state/task-a.inbox"/*.msg "$state/task-a.inbox/handled/" 2>/dev/null
ack_watcher_cycle "$state" >/dev/null || true
add_stop_custom_check "$dir"
cycle c4 0 "$HEAD_C"
captain_view "poll 4" "$dir/c4.out"

banner "instructions sent across the whole lifecycle"
printf 'one per moved head, %s total:\n' "$(grep -c . "$dir/refresh-send.log")"
grep -o 'at head [0-9a-f]*' "$dir/refresh-send.log" | sed 's/^/    /'

banner "a home that never opted in (no config/pr-refresh)"
out=$(make_case evidence-opted-out)
write_task_meta "$out"
run_check_entry "$out" task-a "$PR" >/dev/null || echo "arm failed"
FM_TEST_GH_STATE=OPEN FM_TEST_GH_BEHIND_BY=1 \
  run_watcher_bounded "$out/home" "$out/fakebin" > "$out/o1.out" 2> "$out/o1.err"
captain_view "opted-out poll" "$out/o1.out"
printf 'opted-out triage log:\n'; grep -o 'check:.*' "$out/home/state/.watch-triage.log" | tail -1 | sed 's/^/    /'
printf '\n'
