#!/usr/bin/env bash
set -u; export FM_GATE_REFUSE_BYPASS=1; unset NO_MISTAKES_GATE
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M2WP7S1H2SBPPE6M3Z21E018
SCRATCH=$(cd "$(mktemp -d /tmp/fm-custody-c.XXXXXX)" && pwd -P)
export TMUX_TMPDIR="$SCRATCH/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
WTS=()
cleanup() { for w in "${WTS[@]:-}"; do [ -n "$w" ] && treehouse return --force "$w" >/dev/null 2>&1; done; tmux kill-server 2>/dev/null; rm -rf "$SCRATCH"; }; trap cleanup EXIT
FAKEBIN="$SCRATCH/fakebin"; mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nsleep 120\n' > "$FAKEBIN/codex"; chmod +x "$FAKEBIN/codex"; export PATH="$FAKEBIN:$PATH"
H="$SCRATCH/home"; mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects"; printf 'codex\n' > "$H/config/crew-harness"
PROJ="$SCRATCH/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q -b main; echo '# p' > "$PROJ/README.md"; git -C "$PROJ" add .
git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm initial
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"; git -C "$PROJ" fetch -q origin
mkbrief() { mkdir -p "$H/data/$1"; printf '# Task\n## Captain'"'"'s intent\nlab\n\n## Firstmate spec\nlab\n' > "$H/data/$1/brief.md"; }
sp() { env FM_HOME="$H" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1; }
mkbrief seed1
echo "=== seed: real spawn allocates a pool copy ==="
sp seed1 "$PROJ" "sh -c 'sleep 60'" --scout --backend tmux | tail -3
POOL=$(sed -n 's/^worktree=//p' "$H/state/seed1.meta" | tail -1); WTS+=("$POOL"); echo "pool copy: $POOL"
echo "--- add local-only commit in the copy, return it to the pool ---"
tmux kill-window -t firstmate:fm-seed1 2>/dev/null
treehouse return --force "$POOL" >/dev/null 2>&1; echo "return rc=$?"
echo "local-only work" > "$POOL/local-only.txt"; git -C "$POOL" add local-only.txt
git -C "$POOL" -c user.name=t -c user.email=t@e.invalid commit -qm local-only
LOCAL=$(git -C "$POOL" rev-parse HEAD); echo "copy HEAD (local-only commit): $LOCAL"
mkbrief job2
echo; echo "=== SCENARIO 4: spawn onto a pool copy holding a local-only commit REFUSES ==="
sp job2 "$PROJ" "sh -c 'sleep 60'" --scout --backend tmux | tail -5; echo "rc=${PIPESTATUS[0]}"
echo "HEAD after refusal: $(git -C "$POOL" rev-parse HEAD)"; [ "$(git -C "$POOL" rev-parse HEAD)" = "$LOCAL" ] && echo "HEAD UNCHANGED"
echo "custody refs: [$(git -C "$POOL" for-each-ref refs/fm-custody)]"
echo; echo "=== SCENARIO 5: FM_CUSTODY_PRESERVE=1 preserves under custody ref then proceeds ==="
FM_CUSTODY_PRESERVE=1 sp job2 "$PROJ" "sh -c 'sleep 60'" --scout --backend tmux | tail -3; echo "rc=${PIPESTATUS[0]}"
git -C "$POOL" for-each-ref --format='custody ref: %(refname) -> %(objectname)' refs/fm-custody
echo "expected preserved commit: $LOCAL"
echo "pool HEAD now: $(git -C "$POOL" rev-parse HEAD)  origin/main: $(git -C "$POOL" rev-parse origin/main)"
echo "local-only.txt still in preserved ref: $(git -C "$POOL" show "$(git -C "$POOL" for-each-ref --format='%(refname)' refs/fm-custody | head -1):local-only.txt")"
echo "--- custody record ---"; cat "$H/state/job2.custody"
