#!/usr/bin/env bash
# Live supervised Qwen scout dispatch on an isolated tmux server, plus
# refuse-before-provisioning adversarial cases. Evidence only; not a repo test.
set -u
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M2JVTGMQ5S6P9PF6NHTGG8W5
E=/home/dbeihl/.no-mistakes/evidence/01M2JVTGMQ5S6P9PF6NHTGG8W5
LAB=$(mktemp -d /tmp/fm-qwen-dispatch.XXXXXX)
SOCKET=fm-qwen-dispatch-$$
REAL_TMUX=$(command -v tmux)
SENTINEL=fm-e2e-sentinel-key-7731
ID=qwen-scout
H=$LAB/home
PROJ=$LAB/project
cd "$ROOT" || exit 1

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  git -C "$PROJ" worktree prune 2>/dev/null || true
  [ -n "${KEEP_LAB:-}" ] || rm -rf "$LAB"
}
trap cleanup EXIT

say() { printf '\n## %s\n' "$*"; }
sanitize() { sed -e "s#$LAB#<lab>#g" -e "s#$HOME#<home>#g"; }

mkdir -p "$LAB/shim" "$LAB/qwen-home" "$H"/{data,projects,state,config}
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
# Scratch stand-in for treehouse get: a real git worktree, then a shell in it.
printf 'treehouse %s\n' "\$*" >> "$LAB/treehouse.log"
if [ "\${1:-}" = return ]; then
  for a in "\$@"; do case "\$a" in "$LAB"/wt-*) git -C "$PROJ" worktree remove --force "\$a" >&2 || exit 1 ;; esac; done
  exit 0
fi
[ "\${1:-}" = get ] || exit 2
wt=$LAB/wt-\$\$
git -C "\$(git rev-parse --show-toplevel)" worktree add -q --detach "\$wt" HEAD >&2 || exit 1
cd "\$wt" && exec bash --norc -i
SH
chmod +x "$LAB/shim/tmux" "$LAB/shim/treehouse"
printf '%s\n' '{"ui":{"autoModeAcknowledged":true},"$version":4}' > "$LAB/qwen-home/settings.json"

printf 'qwen\n' > "$H/config/crew-harness"
touch "$H/state/.last-watcher-beat"
mkdir -p "$H/data/$ID"
cat > "$H/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Reply with the single word PONG and do nothing else. Do not run any tools.

## Firstmate spec
Reply PONG. This is a dispatch smoke test.
EOF
git init -q "$PROJ" && git -C "$PROJ" -c user.name=probe -c user.email=probe@example.invalid commit --allow-empty -qm init

export PATH="$LAB/shim:$PATH" QWEN_HOME="$LAB/qwen-home" FM_ROOT_OVERRIDE='' FM_HOME="$H" \
  FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects" \
  FM_CONFIG_OVERRIDE="$H/config" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1
unset TMUX OPENAI_API_KEY OPENAI_BASE_URL QWEN_DEFAULT_AUTH_TYPE NO_MISTAKES_GATE
: > "$LAB/treehouse.log"
tmux new-session -d -s firstmate -x 200 -y 50 -c "$PROJ" "bash --norc --noprofile"
tmux set -g default-command "bash --norc --noprofile"

spawn() { bin/fm-spawn.sh "$ID" "$PROJ" --scout --harness qwen --model qwen3-coder:30b --backend tmux "$@"; }
auth_env=(QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_BASE_URL=http://127.0.0.1:11434/v1 OPENAI_API_KEY=$SENTINEL)

provision_snapshot() {
  printf 'treehouse_calls=%s windows=%s meta=%s settings=%s\n' \
    "$(wc -l < "$LAB/treehouse.log" 2>/dev/null || echo 0)" \
    "$(tmux list-windows -t firstmate -F '#W' | tr '\n' ',')" \
    "$([ -e "$H/state/$ID.meta" ] && echo present || echo absent)" \
    "$([ -e "$H/state/$ID.qwen-settings.json" ] && echo present || echo absent)"
}

if [ "${MODE:-all}" != live ]; then
say "Refusal: missing OpenAI credential"
echo '$ QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_BASE_URL=... bin/fm-spawn.sh qwen-scout <project> --scout --harness qwen --model qwen3-coder:30b --backend tmux'
env QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_BASE_URL=http://127.0.0.1:11434/v1 bash -c "$(declare -f spawn); ID=$ID PROJ=$PROJ; spawn" 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
provision_snapshot

say "Refusal: auth type is not openai"
env QWEN_DEFAULT_AUTH_TYPE=qwen-oauth OPENAI_API_KEY=$SENTINEL bash -c "$(declare -f spawn); ID=$ID PROJ=$PROJ; spawn" 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
provision_snapshot

say "Refusal: qwen executable absent from PATH"
NOQWEN=$(printf '%s' "$PATH" | tr ':' '\n' | while read -r d; do [ -x "$d/qwen" ] || printf '%s:' "$d"; done)
env "${auth_env[@]}" PATH="${NOQWEN%:}" bash -c "type -P qwen || echo 'qwen not on PATH'; $(declare -f spawn); ID=$ID PROJ=$PROJ; spawn" 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
provision_snapshot

say "Refusal: non-Linux host (uname -s reports Darwin)"
mkdir -p "$LAB/darwin"; printf '#!/bin/sh\n[ "$1" = -s ] && { echo Darwin; exit 0; }\nexec /usr/bin/uname "$@"\n' > "$LAB/darwin/uname"; chmod +x "$LAB/darwin/uname"
env "${auth_env[@]}" PATH="$LAB/darwin:$PATH" bash -c "$(declare -f spawn); ID=$ID PROJ=$PROJ; spawn" 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
provision_snapshot

say "Refusal: qwen as a secondmate"
env "${auth_env[@]}" bin/fm-spawn.sh qwen-mate --harness qwen --backend tmux --secondmate 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
provision_snapshot
fi

[ "${MODE:-all}" = refusals ] && exit 0

say "Supervised spawn"
echo '$ QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_BASE_URL=http://127.0.0.1:11434/v1 OPENAI_API_KEY=<sentinel> FM_HOME=<home> bin/fm-spawn.sh qwen-scout <project> --scout --harness qwen --model qwen3-coder:30b --backend tmux'
env "${auth_env[@]}" bash -c "$(declare -f spawn); ID=$ID PROJ=$PROJ; spawn" > "$LAB/spawn.out" 2>&1; rc=$?
sanitize < "$LAB/spawn.out"; echo "[exit $rc]"
[ "$rc" -eq 0 ] || { tmux capture-pane -p -t firstmate: 2>/dev/null | tail -30; exit 1; }
provision_snapshot

say "Recorded metadata (state/$ID.meta)"
sanitize < "$H/state/$ID.meta"
say "Credential containment"
stat -c '%a %n' "$H/state/$ID.qwen-settings.json" | sanitize
echo "files under state/ containing the sentinel credential:"; grep -rl "$SENTINEL" "$H/state" | sanitize
echo "settings keys:"; jq -c '{security: .security, env: (.env // {} | keys), hooks: (.hooks | keys)}' "$H/state/$ID.qwen-settings.json" 2>&1 | sed "s#$SENTINEL#<sentinel>#g"
T=$(sed -n 's/^window=//p' "$H/state/$ID.meta" | head -1)
[ -n "$T" ] || T=$(sed -n 's/^endpoint=//p' "$H/state/$ID.meta" | head -1)
echo "endpoint target: $T"
pane_pid=$(tmux display-message -p -t "$T" '#{pane_pid}')
leak=0
for p in $(ps -o pid= --ppid "$pane_pid"; pgrep -P "$(ps -o pid= --ppid "$pane_pid" | tr -d ' ' | head -1)" 2>/dev/null); do
  if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "$SENTINEL"; then leak=1; fi
done
echo "sentinel present in any pane process argv: $leak"
tmux_env_leak=$(tmux show-environment -g 2>/dev/null | grep -c "$SENTINEL")
echo "sentinel present in isolated tmux global environment: $tmux_env_leak"

. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-busy-lib.sh"
say "Busy state across the launch-brief turn"
last=''; start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 240 ]; do
  v=$(fm_busy_classify_meta "$H/state/$ID.meta" "$ID" "$H/state" 2>/dev/null)
  if [ "$v" != "$last" ]; then printf '+%ss classify=%s\n' "$(( $(date +%s) - start ))" "$v"; last=$v; fi
  case "$v" in idle*qwen-hook*) break ;; esac
  sleep 1
done
echo "busy record:"; for f in "$H/state/$ID".busy*; do [ -e "$f" ] && { echo "${f##*/}:"; cat "$f"; }; done 2>/dev/null | sanitize
echo "turn-ended marker:"; ls "$H/state" | grep -i "$ID.*turn" || echo "(none)"
echo "--- pane after launch turn"
tmux capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -25 | sanitize

say "Doorbell via fm-send"
echo "$ FM_HOME=<home> bin/fm-send.sh $ID 'Reply PONG.'"
bin/fm-send.sh "$ID" 'Reply PONG.' 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
saw_busy=0
for _ in $(seq 1 40); do
  v=$(fm_busy_classify_meta "$H/state/$ID.meta" "$ID" "$H/state" 2>/dev/null)
  screen=$(tmux capture-pane -p -t "$T")
  case "$v" in busy*) saw_busy=1 ;; esac
  if printf '%s' "$screen" | grep -q 'Firstmate instruction waiting' && printf '%s' "$screen" | grep -qi 'esc to cancel'; then break; fi
  sleep 0.5
done
echo "classify during doorbell turn: $v (busy observed: $saw_busy)"
echo "--- pane during doorbell turn"
printf '%s\n' "$screen" | grep '[^[:space:]]' | tail -20 | sanitize

say "Interrupt"
echo "$ FM_HOME=<home> bin/fm-control.sh $ID interrupt"
bin/fm-control.sh "$ID" interrupt 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
sleep 2
echo "--- pane after interrupt"
tmux capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -12 | sanitize

say "Exit"
echo "$ FM_HOME=<home> bin/fm-control.sh $ID exit"
bin/fm-control.sh "$ID" exit 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
echo "--- pane after exit"
tmux capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -8 | sanitize
echo "pane foreground command: $(tmux display-message -p -t "$T" '#{pane_current_command}')"

say "Resume is not a control verb"
echo "$ FM_HOME=<home> bin/fm-control.sh $ID resume"
bin/fm-control.sh "$ID" resume 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"

say "Relaunch is the recovery path"
echo "$ QWEN_DEFAULT_AUTH_TYPE=openai ... FM_HOME=<home> bin/fm-control.sh $ID relaunch --note 'Previous worker was interrupted and exited; reply PONG again.'"
env "${auth_env[@]}" bin/fm-control.sh "$ID" relaunch --note 'Previous worker was interrupted and exited; reply PONG again.' 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
start=$(date +%s); last=''
while [ $(( $(date +%s) - start )) -lt 180 ]; do
  v=$(fm_busy_classify_meta "$H/state/$ID.meta" "$ID" "$H/state" 2>/dev/null)
  if [ "$v" != "$last" ]; then printf '+%ss classify=%s\n' "$(( $(date +%s) - start ))" "$v"; last=$v; fi
  case "$v" in idle*qwen-hook*) break ;; esac
  sleep 1
done
echo "pane foreground command: $(tmux display-message -p -t "$T" '#{pane_current_command}')"
tmux capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -10 | sanitize
echo "files under state/ containing the sentinel credential:"; grep -rl "$SENTINEL" "$H/state" | sanitize
bin/fm-control.sh "$ID" exit 2>&1 | sanitize; echo "[exit ${PIPESTATUS[0]}]"

say "Teardown removes the credential-bearing settings"
echo "$ FM_HOME=<home> bin/fm-teardown.sh $ID --force   # scratch scout wrote no report"
bin/fm-teardown.sh "$ID" --force 2>&1 | tail -8 | sanitize; echo "[exit ${PIPESTATUS[0]}]"
echo "treehouse shim calls: $(cat "$LAB/treehouse.log")"
echo "settings file: $([ -e "$H/state/$ID.qwen-settings.json" ] && echo present || echo absent)"
echo "files under state/ containing the sentinel credential:"; grep -rl "$SENTINEL" "$H/state" | sanitize || echo "(none)"
