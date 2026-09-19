#!/usr/bin/env bash
set -u; export FM_GATE_REFUSE_BYPASS=1; unset NO_MISTAKES_GATE
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M2WP7S1H2SBPPE6M3Z21E018
SCRATCH=$(mktemp -d /tmp/fm-custody-b.XXXXXX)
export TMUX_TMPDIR="$SCRATCH/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$SCRATCH"; }; trap cleanup EXIT
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\n: > "%s/codex-launched"\nsleep 60\n' "$SCRATCH" > "$FAKEBIN/codex"; chmod +x "$FAKEBIN/codex"
export PATH="$FAKEBIN:$PATH"
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/lostw"
printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$HOME_DIR/data/lostw/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; echo '# p' > "$PROJ/README.md"; git -C "$PROJ" add .
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b lostw "$WT"
tmux new-session -d -s firstmate -c "$WT"
WID=$(tmux new-window -dP -F '#{window_id}' -t firstmate: -n fm-lostw -c "$WT")
mk_meta() { { echo "window=firstmate:fm-lostw"; echo endpoint_task_id=lostw; echo "worktree=$WT"; echo "project=$PROJ"; echo harness=codex; echo kind=ship; echo mode=no-mistakes; echo yolo=off; echo model=default; echo effort=default; echo backend=tmux; } > "$HOME_DIR/state/lostw.meta"; }
mk_meta
echo "ORIGINAL ENDPOINT: firstmate:fm-lostw id=$WID"
printf 'unfinished implementation\n' > "$WT/unfinished.txt"; echo wip >> "$WT/README.md"
snap() { echo "branch=$(git -C "$WT" branch --show-current) HEAD=$(git -C "$WT" rev-parse HEAD)"; sha256sum "$WT/unfinished.txt" "$WT/README.md"; echo "status: $(git -C "$WT" status --porcelain | tr '\n' ';')"; }
echo "=== SCENARIO 1: dirty copy, window killed ==="; echo BEFORE; snap; B=$(snap)
tmux kill-window -t "$WID"; echo "windows after kill: [$(tmux list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')]"
run() { env FM_HOME="$HOME_DIR" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_CONTROL_POLL=0.3 FM_CONTROL_LAUNCH_WAIT=8 "$ROOT/bin/fm-control.sh" "$@" 2>&1; }
run lostw relaunch --note "recover vanished session"; echo "rc=$?"
echo AFTER; snap; [ "$(snap)" = "$B" ] && echo "HEAD, BYTES, STATUS UNCHANGED"
echo "windows: [$(tmux list-windows -t firstmate -F '#{window_id}:#{window_name}' | tr '\n' ' ')]"
echo "new window cwd: $(tmux display-message -p -t firstmate:fm-lostw '#{pane_current_path}')"
grep -E '^(window|worktree)=' "$HOME_DIR/state/lostw.meta"
grep -E 'worktree_dirty|validation_head' "$HOME_DIR/state/lostw.control-relaunch"; cat "$HOME_DIR/state/lostw.custody" 2>/dev/null
echo; echo "=== SCENARIO 3: unreadable validation state refuses, no note ==="
tmux kill-window -t firstmate:fm-lostw; git -C "$WT" remote add no-mistakes "file://$PROJ"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/no-mistakes"; chmod +x "$FAKEBIN/no-mistakes"
rm -f "$HOME_DIR"/state/lostw.control-relaunch.note; B2=$(snap)
run lostw relaunch --note "should be refused"; echo "rc=$?"
[ "$(snap)" = "$B2" ] && echo "HEAD/BYTES UNCHANGED"
ls "$HOME_DIR/state" | grep -i note || echo "no progress note file"
grep -c "should be refused" "$HOME_DIR/data/lostw/brief.md" "$HOME_DIR"/data/lostw/* 2>/dev/null | head
echo "windows: [$(tmux list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')]"
echo; echo "=== SCENARIO 2: pipeline-owned head recovered in place ==="
H=$(git -C "$WT" rev-parse HEAD)
printf '#!/usr/bin/env bash\nif [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then printf "status: running\\nhead: %s\\nbranch_sync:\\n  state: pipeline_owned\\n"; exit 0; fi\nexit 1\n' "$H" > "$FAKEBIN/no-mistakes"
B3=$(snap)
run lostw relaunch --note "recover validation-owned"; echo "rc=$?"
[ "$(snap)" = "$B3" ] && echo "HEAD/BYTES UNCHANGED"
echo "windows: [$(tmux list-windows -t firstmate -F '#{window_name}' | tr '\n' ' ')]"
grep -E 'validation_head' "$HOME_DIR/state/lostw.control-relaunch" "$HOME_DIR/state/lostw.custody" | tail -3
