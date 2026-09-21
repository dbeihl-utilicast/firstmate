#!/usr/bin/env bash
# Isolated live product exercise: real firstmate scripts and real tmux server.
set -euo pipefail
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M31ZFVCN8NWM0H4EP39DMZDT
SOCKET="fm-stopped-live-$$"
SESSION="stoppedlive"
LAB=$(mktemp -d /tmp/fm-stopped-live.XXXXXX)
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/home/state" "$LAB/shim" "$LAB/worktree"
git -C "$LAB/worktree" init -q
git -C "$LAB/worktree" config user.email live-test@example.invalid
git -C "$LAB/worktree" config user.name live-test
touch "$LAB/worktree/.keep"
git -C "$LAB/worktree" add .keep
git -C "$LAB/worktree" commit -qm initial
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec /usr/bin/tmux -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0
printf 'window=%s:fm-domain\nkind=secondmate\nharness=claude\nworktree=%s\nproject=%s\n' "$SESSION" "$LAB/worktree" "$LAB/worktree" > "$LAB/home/state/domain.meta"
printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=domain pending-reply-id=abcdef0123456789 request=config reread\n' > "$LAB/home/state/domain.status"

printf '%s\n' '== Stop reports success when its real tmux endpoint is absent =='
set +e
"$ROOT/bin/fm-secondmate-lane.sh" stop domain >"$LAB/stop.out" 2>"$LAB/stop.err"
STOP_RC=$?
set -e
printf 'stop_exit=%s marker=%s\n' "$STOP_RC" "$([ -f "$LAB/home/state/domain.stopped" ] && echo present || echo absent)"
printf '%s\n' 'stop_output:'; cat "$LAB/stop.out" "$LAB/stop.err"
[ "$STOP_RC" -eq 0 ] && [ -f "$LAB/home/state/domain.stopped" ]

printf '%s\n' '== Stop waits for a real in-flight delivery metadata lock before publishing its marker =='
tmux -L "$SOCKET" new-session -d -s "$SESSION" -n fm-race -- bash -c 'while :; do sleep 60; done'
printf 'window=%s:fm-race\nkind=secondmate\nharness=claude\nworktree=%s\nproject=%s\n' "$SESSION" "$LAB/worktree" "$LAB/worktree" > "$LAB/home/state/race.meta"
bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -e "$4" ]; do sleep 0.05; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB/home/state/.meta-race.lock" "$LAB/lock-held" "$LAB/release-lock" &
LOCK_HOLDER=$!
while [ ! -e "$LAB/lock-held" ]; do sleep 0.05; done
"$ROOT/bin/fm-secondmate-lane.sh" stop race >"$LAB/race-stop.out" 2>"$LAB/race-stop.err" &
RACE_STOPPER=$!
sleep 0.2
printf 'marker_while_delivery_lock_held=%s\n' "$([ -e "$LAB/home/state/race.stopped" ] && echo present || echo absent)"
[ ! -e "$LAB/home/state/race.stopped" ]
touch "$LAB/release-lock"
wait "$LOCK_HOLDER"
for _ in $(seq 1 40); do [ -e "$LAB/home/state/race.stopped" ] && break; sleep 0.05; done
printf 'marker_after_delivery_lock_release=%s\n' "$([ -e "$LAB/home/state/race.stopped" ] && echo present || echo absent)"
# This live pane is intentionally a bare shell rather than a harness, so only
# publication timing is under test; do not wait for its unrelated exit protocol.
kill "$RACE_STOPPER" 2>/dev/null || true
wait "$RACE_STOPPER" 2>/dev/null || true
[ -e "$LAB/home/state/race.stopped" ]

tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-domain -- bash -c 'while :; do sleep 60; done'
printf '%s\n' '== Ordinary send to stopped lane is refused before inbox/pending-reply delivery =='
set +e
"$ROOT/bin/fm-send.sh" domain 'routine config reread' >"$LAB/ordinary.out" 2>"$LAB/ordinary.err"
ORDINARY_RC=$?
set -e
printf 'ordinary_send_exit=%s inbox_001=%s pending_files=%s\n' "$ORDINARY_RC" \
  "$([ -e "$LAB/home/state/domain.inbox/001.msg" ] && echo present || echo absent)" \
  "$(find "$LAB/home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')"
cat "$LAB/ordinary.out" "$LAB/ordinary.err"
[ "$ORDINARY_RC" -ne 0 ] && [ ! -e "$LAB/home/state/domain.inbox/001.msg" ]

printf '%s\n' '== Operator resolves stale pending-reply against stopped lane without a replacement expectation =='
"$ROOT/bin/fm-send.sh" domain --resolve-key pending-reply-abcdef0123456789 'ack, lane is down' >"$LAB/resolve.out" 2>"$LAB/resolve.err"
printf 'resolve_exit=0 inbox_001=%s pending_files=%s tmux_typed_lines=%s\n' \
  "$([ -e "$LAB/home/state/domain.inbox/001.msg" ] && echo present || echo absent)" \
  "$(find "$LAB/home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')" \
  "$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:fm-domain" | grep -c 'Firstmate instruction waiting' || true)"
cat "$LAB/resolve.out" "$LAB/resolve.err"
printf '%s\n' 'resolved_status:'; cat "$LAB/home/state/domain.status"
printf '%s\n' 'open_decisions_after_resolve:'
FM_STATE_OVERRIDE="$LAB/home/state" "$ROOT/bin/fm-wake-drain.sh" | grep -A5 'OPEN DECISIONS' || echo '(none)'
[ -e "$LAB/home/state/domain.inbox/001.msg" ]
[ "$(find "$LAB/home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ]
! FM_STATE_OVERRIDE="$LAB/home/state" "$ROOT/bin/fm-wake-drain.sh" | grep -q 'OPEN DECISIONS'

# Age the deliberately unread close record and run the real watcher briefly.
touch -d '10 minutes ago' "$LAB/home/state/domain.inbox/001.msg"
printf '%s\n' '== Real watcher leaves stopped lane unread record quiet =='
set +e
timeout 4 "$ROOT/bin/fm-watch.sh" >"$LAB/watch.out" 2>"$LAB/watch.err"
WATCH_RC=$?
set -e
printf 'watch_exit=%s (124 means still polling as expected) wake_queue=%s doorbell_lines=%s escalation=%s\n' \
  "$WATCH_RC" "$([ -s "$LAB/home/state/.wake-queue" ] && echo present || echo absent)" \
  "$(tmux -L "$SOCKET" capture-pane -p -t "$SESSION:fm-domain" | grep -c 'Firstmate instruction waiting' || true)" \
  "$([ -e "$LAB/home/state/domain.inbox/.escalated" ] && echo present || echo absent)"
cat "$LAB/watch.out" "$LAB/watch.err"
[ "$WATCH_RC" -eq 124 ]
[ ! -s "$LAB/home/state/.wake-queue" ]
[ ! -e "$LAB/home/state/domain.inbox/.escalated" ]

printf '%s\n' '== Real config push skips its config-reread doorbell for a stopped seeded lane =='
mkdir -p "$LAB/config-home/state" "$LAB/config-home/config" "$LAB/config-main"
git -C "$LAB/config-main" init -qb main
git -C "$LAB/config-main" config user.email live-test@example.invalid
git -C "$LAB/config-main" config user.name live-test
printf 'projects/\nstate/\ndata/\nconfig/crew-dispatch.json\nconfig/crew-harness\n' > "$LAB/config-main/.gitignore"
printf 'base\n' > "$LAB/config-main/README.md"
printf '# Firstmate\n' > "$LAB/config-main/AGENTS.md"
mkdir -p "$LAB/config-main/bin"
printf '#!/usr/bin/env bash\n' > "$LAB/config-main/bin/tool.sh"
chmod +x "$LAB/config-main/bin/tool.sh"
git -C "$LAB/config-main" add . && git -C "$LAB/config-main" commit -qm base
git -C "$LAB/config-main" worktree add -q --detach "$LAB/sm-home" HEAD
printf 'sm\n' > "$LAB/sm-home/.fm-secondmate-home"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n fm-sm -- bash -c 'while :; do sleep 60; done'
printf 'window=%s:fm-sm\nkind=secondmate\nhome=%s\n' "$SESSION" "$LAB/sm-home" > "$LAB/config-home/state/sm.meta"
printf 'stopped\n' > "$LAB/config-home/state/sm.stopped"
printf '{"default":{"harness":"codex"}}\n' > "$LAB/config-home/config/crew-dispatch.json"
printf 'codex\n' > "$LAB/config-home/config/crew-harness"
touch "$LAB/config-home/state/.last-watcher-beat"
FM_HOME="$LAB/config-home" FM_ROOT_OVERRIDE="$LAB/config-main" "$ROOT/bin/fm-config-push.sh" >"$LAB/config.out" 2>"$LAB/config.err"
printf 'config_push_exit=0 reread_skip=%s inbox_001=%s pending_files=%s\n' \
  "$(grep -cF 'skipped, lane is stopped' "$LAB/config.out" || true)" \
  "$([ -e "$LAB/config-home/state/sm.inbox/001.msg" ] && echo present || echo absent)" \
  "$(find "$LAB/config-home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')"
cat "$LAB/config.out" "$LAB/config.err"
grep -qF 'skipped, lane is stopped' "$LAB/config.out"
[ ! -e "$LAB/config-home/state/sm.inbox/001.msg" ]
[ "$(find "$LAB/config-home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')" = 0 ]
printf '%s\n' 'LIVE STOPPED-LANE E2E: PASS'
