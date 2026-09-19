#!/usr/bin/env bash
# fm-control.sh relaunch against a REAL Herdr whose pane has vanished.
#
# A positively missing endpoint is recreated against the exact recorded copy:
# the new pane must be a different endpoint, published in the task record and
# confirmed alive by the control plane, while branch, HEAD and dirty bytes stay
# untouched. Runs on a private, named, throwaway lab session only.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-missing-endpoint-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-missing-endpoint.XXXXXX")
cleanup_all() {
  herdr_safe_stop_and_delete "$SESSION"
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/codex-launched"\nsleep 30\n' "$SCRATCH" > "$FAKEBIN/codex"
chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
[ "$("${SHELL:-bash}" -ic 'command -v codex' 2>/dev/null | tail -1)" = "$FAKEBIN/codex" ] \
  || { echo "skip: this shell's rc files put a real codex ahead of the inert test harness"; trap - EXIT; rm -rf "$SCRATCH"; exit 0; }
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/lostw"
cat > "$HOME_DIR/data/lostw/brief.md" <<'BRIEF'
# Task
## Captain's intent
Recover a vanished Herdr pane in place.

## Firstmate spec
Keep the recorded copy, branch and bytes.
BRIEF

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b lostw "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${RAW%%$'\t'*}
WORKSPACE_ID=${CONTAINER#*:}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-lostw "$WT" "${RAW#*$'\t'}") || fail "create_task failed"
read -r TAB_ID PANE_ID <<< "$IDS"
{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=lostw"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=codex"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/lostw.meta"

printf 'unfinished implementation\n' > "$WT/unfinished.txt"
printf 'wip\n' >> "$WT/README.md"
snapshot() { printf '%s %s\n' "$(git -C "$WT" branch --show-current)" "$(git -C "$WT" rev-parse HEAD)"; sha256sum "$WT/unfinished.txt" "$WT/README.md"; git -C "$WT" status --porcelain; }
BEFORE=$(snapshot)

herdr pane close "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 || fail "could not close the task pane"
for _ in $(seq 1 20); do
  herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 || break
  sleep 0.2
done
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = missing ] \
  || fail "a closed pane should read positively missing"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.3 FM_CONTROL_LAUNCH_WAIT=8 \
  "$ROOT/bin/fm-control.sh" lostw relaunch --note "recover vanished session" 2>&1) \
  || fail "relaunch of a positively missing Herdr endpoint failed: $OUT"

[ "$(snapshot)" = "$BEFORE" ] || fail "recovery changed branch, HEAD or dirty bytes"
NEW_WINDOW=$(sed -n 's/^window=//p' "$HOME_DIR/state/lostw.meta" | tail -1)
[ -n "$NEW_WINDOW" ] && [ "$NEW_WINDOW" != "$SESSION:$PANE_ID" ] \
  || fail "recovery did not publish a new endpoint (window=$NEW_WINDOW)"
[ "$(sed -n 's/^worktree=//p' "$HOME_DIR/state/lostw.meta" | tail -1)" = "$WT" ] \
  || fail "recovery replaced the recorded copy"
[ "$(fm_backend_agent_state herdr "$NEW_WINDOW")" = alive ] \
  || fail "the new endpoint $NEW_WINDOW does not host a live agent"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.2
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
pass "real herdr: a vanished pane is recreated in the same copy, published, and confirmed alive with HEAD and bytes untouched"
