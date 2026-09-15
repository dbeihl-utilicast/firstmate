#!/usr/bin/env bash
# Isolated lab for a real canonical qwen scout spawn on a private tmux server.
set -eu
ROOT=${ROOT:?}
LAB=${LAB:?}
SOCKET=${SOCKET:?}
REAL_TMUX=$(command -v tmux)
mkdir -p "$LAB/shim" "$LAB/fmhome/state" "$LAB/fmhome/data/qwen-scout" \
  "$LAB/fmhome/projects" "$LAB/fmhome/config" "$LAB/qwen-home"
touch "$LAB/fmhome/state/.last-watcher-beat"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$LAB/shim/treehouse" <<'SH'
#!/usr/bin/env bash
cd "$FM_LAB_WT" && exec bash --norc --noprofile -i
SH
chmod +x "$LAB/shim/tmux" "$LAB/shim/treehouse"

git init -q "$LAB/project"
git -C "$LAB/project" -c user.name=lab -c user.email=lab@example.invalid commit --allow-empty -qm init
git init -q --bare "$LAB/project.origin.git"
git -C "$LAB/project" remote add origin "$LAB/project.origin.git"
git -C "$LAB/project" worktree add -q -b wt-qwen-scout "$LAB/wt"

cat > "$LAB/fmhome/data/qwen-scout/brief.md" <<'EOF'
# Task
## Captain's intent
Supervised qwen scout dispatch check.

## Firstmate spec
Reply with the single word PONG and do nothing else. Do not run tools.
EOF

printf '{"ui":{"autoModeAcknowledged":true},"$version":4}\n' > "$LAB/qwen-home/settings.json"

env -u TMUX -u CLAUDECODE -u GROK_AGENT -u CURSOR_AGENT \
  PATH="$LAB/shim:$PATH" FM_LAB_WT="$LAB/wt" QWEN_HOME="$LAB/qwen-home" \
  QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -n control -x 200 -y 50 -c "$LAB/project" \
  "bash --norc --noprofile -i"
echo "lab ready: $LAB socket=$SOCKET"
