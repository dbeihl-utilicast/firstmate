#!/usr/bin/env bash
# Fake-Herdr regressions for missing-endpoint replacement identity.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-control-herdr-relaunch-fake)
trap '[ "${FM_TEST_KEEP_TMP:-0}" = 1 ] || rm -rf "$TMP_ROOT"' EXIT
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/proj"
WT="$TMP_ROOT/wt"
FAKEBIN="$TMP_ROOT/fakebin"
FAKE="$TMP_ROOT/fake"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/lost" "$PROJ" "$FAKEBIN" "$FAKE"
git -C "$PROJ" init -q
echo base > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b lost "$WT"
cat > "$HOME_DIR/data/lost/brief.md" <<'EOF'
# Task
## Captain's intent
Recover the missing endpoint.

## Firstmate spec
Keep the copy and publish the replacement identity.
EOF
cat > "$HOME_DIR/state/lost.meta" <<EOF
window=fake-session:w1:p2
endpoint_task_id=lost
worktree=$WT
project=$PROJ
harness=codex
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=fake-session
herdr_workspace_id=ws1
herdr_tab_id=w1:t2
herdr_pane_id=w1:p2
EOF
cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/codex"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_HERDR_DIR:?}
printf '%s\n' "$*" >> "$D/calls"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"protocol":22,"version":"fake"},"server":{"running":true,"protocol":22,"compatible":true,"socket_path":"%s/socket"}}\n' "$D"
  exit 0
fi
# Remove the required trailing session selector.
argc=$#
[ "$argc" -ge 2 ] || exit 2
eval "prev=\${$((argc-1))}; last=\${$argc}"
[ "$prev" = --session ] && [ "$last" = fake-session ] || exit 90
set -- "${@:1:$((argc-2))}"
case "${1:-} ${2:-}" in
  'session list')
    printf '{"sessions":[{"name":"fake-session","running":true,"socket_path":"%s/socket"}]}\n' "$D"
    ;;
  'pane get')
    pane=${3:-}
    case "$pane" in
      w1:p2) printf '{"error":{"code":"pane_not_found"}}\n' ;;
      w1:p1) printf '{"result":{"pane":{"pane_id":"w1:p1","workspace_id":"ws1","tab_id":"w1:t1","foreground_cwd":"%s"}}}\n' "$FM_FAKE_HERDR_WT" ;;
      w1:p3)
        printf '{"result":{"pane":{"pane_id":"w1:p3","workspace_id":"ws1","tab_id":"w1:t3","foreground_cwd":"%s"}}}\n' "$FM_FAKE_HERDR_WT" ;;
      *) printf '{"error":{"code":"pane_not_found"}}\n' ;;
    esac
    ;;
  'agent get')
    if [ "${3:-}" = w1:p3 ] && [ -e "$D/live" ]; then
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    ;;
  'tab get')
    printf '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"ws1"}}}\n'
    ;;
  'workspace list')
    printf '{"result":{"workspaces":[{"workspace_id":"ws1","label":"firstmate","active_tab_id":"w1:t1","focused":true}]}}\n'
    ;;
  'tab list')
    if [ -e "$D/created" ]; then
      printf '{"result":{"tabs":[{"tab_id":"w1:t3","label":"fm-lost"}]}}\n'
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  'tab create')
    : > "$D/created"
    printf '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}\n'
    ;;
  'pane run') printf '{}\n' ;;
  'pane send-text') printf '%s\n' "${4:-}" > "$D/launch-text"; printf '{}\n' ;;
  'pane send-keys') : > "$D/live"; printf '{}\n' ;;
  'pane read') printf '╭────╮\n│    │\n╰────╯\n' ;;
  'pane process-info') printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p3","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}\n' "$$" "$$" "$$" ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"
: > "$FAKE/calls"

READY="$TMP_ROOT/endpoint-ready"
RELEASE="$TMP_ROOT/endpoint-release"
env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
  HERDR_SESSION=fake-session HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$FAKE/socket" \
  FM_FAKE_HERDR_DIR="$FAKE" FM_FAKE_HERDR_WT="$WT" \
  FM_TEST_RELAUNCH_ENDPOINT_READY="$READY" FM_TEST_RELAUNCH_ENDPOINT_RELEASE="$RELEASE" \
  FM_CONTROL_POLL=0.01 FM_CONTROL_LAUNCH_WAIT=1 \
  "$ROOT/bin/fm-control.sh" lost relaunch --note 'recover fake Herdr endpoint' > "$TMP_ROOT/first.out" 2>&1 &
job_pid=$!
for _ in $(seq 1 200); do [ -s "$READY" ] && break; sleep 0.01; done
[ -s "$READY" ] || fail "fake Herdr replacement never reached the post-creation crash point"
kill -KILL "$(cat "$READY")" 2>/dev/null || fail "could not kill fake Herdr replacement before publication"
wait "$job_pid" 2>/dev/null || true
[ -f "$HOME_DIR/state/lost.relaunch-endpoint" ] \
  || fail "fake Herdr replacement identity was not journaled before publication"

out=$(env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 \
  HERDR_SESSION=fake-session HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH="$FAKE/socket" \
  FM_FAKE_HERDR_DIR="$FAKE" FM_FAKE_HERDR_WT="$WT" \
  FM_CONTROL_POLL=0.01 FM_CONTROL_LAUNCH_WAIT=1 \
  "$ROOT/bin/fm-control.sh" lost relaunch --note 'retry fake Herdr recovery' 2>&1)
status=$?
expect_code 0 "$status" "fake Herdr retry should adopt the journaled endpoint"$'\n'"$out"
assert_grep 'window=fake-session:w1:p3' "$HOME_DIR/state/lost.meta" \
  "replacement Herdr endpoint was not published"
assert_grep 'pane get w1:p1' "$FAKE/calls" \
  "replacement did not use the live launcher identity for workspace placement"
[ "$(tail -1 "$HOME_DIR/state/lost.meta" | sed -n 's/^control_relaunch_tx=//p')" != "" ] \
  || fail "replacement metadata was not published before control confirmation"
[ "$(grep -c 'tab create' "$FAKE/calls")" = 1 ] \
  || fail "missing-endpoint recovery created more than one Herdr task tab"
pass "fake herdr: dead recorded pane is not reused as launcher and control polls the published endpoint"
