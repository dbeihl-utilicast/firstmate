#!/usr/bin/env bash
set -u; export FM_GATE_REFUSE_BYPASS=1; unset NO_MISTAKES_GATE
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M2WP7S1H2SBPPE6M3Z21E018
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-custody-a-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-custody-a.XXXXXX")
cleanup() { herdr_safe_stop_and_delete "$SESSION"; rm -rf "$SCRATCH"; }
trap cleanup EXIT
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/codex-launched"\nsleep 30\n' "$SCRATCH" > "$FAKEBIN/codex"; chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
fm_herdr_lab_prepare "$SESSION" || exit 1
echo "LAB SESSION: $SESSION"
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/lostw"
printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$HOME_DIR/data/lostw/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo '# p' > "$PROJ/README.md"; git -C "$PROJ" add .
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b lostw "$WT"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
RAW=$(fm_backend_herdr_container_ensure "$WT"); CONTAINER=${RAW%%$'\t'*}; SEED=${RAW#*$'\t'}; WSID=${CONTAINER#*:}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-lostw "$WT" "$SEED"); read -r TAB PANE <<<"$IDS"
{ echo "window=$SESSION:$PANE"; echo endpoint_task_id=lostw; echo "worktree=$WT"; echo "project=$PROJ"; echo harness=codex; echo kind=ship; echo mode=no-mistakes; echo yolo=off; echo model=default; echo effort=default; echo backend=herdr; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WSID"; echo "herdr_tab_id=$TAB"; echo "herdr_pane_id=$PANE"; } > "$HOME_DIR/state/lostw.meta"
echo "ORIGINAL ENDPOINT: $SESSION:$PANE (tab $TAB)"
printf 'unfinished implementation\n' > "$WT/unfinished.txt"
echo "wip" >> "$WT/README.md"
HB=$(git -C "$WT" rev-parse HEAD); BR=$(git -C "$WT" branch --show-current)
HASH_B=$(sha256sum "$WT/unfinished.txt" "$WT/README.md"); STAT_B=$(git -C "$WT" status --porcelain)
echo "BEFORE: branch=$BR HEAD=$HB"; echo "$HASH_B"; echo "status: $STAT_B"
echo "--- kill pane (session vanishes) ---"
herdr pane close "$PANE" --session "$SESSION"; sleep 1
herdr pane get "$PANE" --session "$SESSION" >/dev/null 2>&1 && echo "pane STILL EXISTS" || echo "pane gone (backend proves absent)"
echo "agent_state: $(fm_backend_agent_state herdr "$SESSION:$PANE")"
echo "--- fm-control relaunch ---"
env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.3 FM_CONTROL_LAUNCH_WAIT=8 "$ROOT/bin/fm-control.sh" lostw relaunch --note "recover vanished session" 2>&1; echo "rc=$?"
echo "--- AFTER ---"
HA=$(git -C "$WT" rev-parse HEAD); echo "AFTER: branch=$(git -C "$WT" branch --show-current) HEAD=$HA"
sha256sum "$WT/unfinished.txt" "$WT/README.md"; echo "status: $(git -C "$WT" status --porcelain)"
[ "$HA" = "$HB" ] && echo "HEAD UNCHANGED"; [ "$(sha256sum "$WT/unfinished.txt" "$WT/README.md")" = "$HASH_B" ] && echo "BYTES UNCHANGED"
grep -E '^(window|worktree|herdr_pane_id|herdr_tab_id)=' "$HOME_DIR/state/lostw.meta"
echo "--- custody record ---"; cat "$HOME_DIR/state/lostw.control-relaunch" 2>/dev/null | grep -E 'worktree_dirty|validation_head|head' ; cat "$HOME_DIR/state/lostw.custody" 2>/dev/null
echo "--- live panes ---"; herdr pane list --session "$SESSION" 2>&1 | head -20
