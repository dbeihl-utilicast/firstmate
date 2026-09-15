#!/usr/bin/env bash
# Live drive of the real Qwen Code TUI using firstmate's canonical qwen launch
# shape, fm-spawn's settings jq, the real fm-busy-event writer, and the
# control-lib interrupt/exit keys, on an isolated tmux server.
set -u
ROOT=${ROOT:?} LAB=${LAB:?} SOCKET=${SOCKET:?}
REAL_TMUX=$(command -v tmux)
PATH="$LAB/shim:$PATH"; export PATH
unset NO_MISTAKES_GATE
. "$ROOT/bin/fm-busy-lib.sh"
. "$ROOT/bin/fm-control-lib.sh"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
ID=qwen-scout STATE="$LAB/fmhome/state" T="firstmate:qwen"
TURNEND="$STATE/$ID.turn-ended"
tm() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
snap() { echo "--- pane: $1 ---"; tm capture-pane -p -t "$T" | grep '[^[:space:]]' | tail -"${2:-14}"; }
busy() { printf 'busy-classify: %s | record: %s\n' "$(fm_busy_classify tmux "$T" qwen "$ID" "$STATE")" "$(tr '\n' ' ' < "$STATE/$ID.busy" 2>/dev/null)"; }
wait_busy_state() {  # <busy|idle> <tries>
  local i; for i in $(seq 1 "$2"); do
    case "$(fm_busy_classify tmux "$T" qwen "$ID" "$STATE")" in "$1 "*) return 0 ;; esac; sleep 1
  done; return 1
}

export QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_BASE_URL=http://127.0.0.1:11434/v1 OPENAI_API_KEY=lab-secret-sentinel-7731
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || { echo "arm failed"; exit 1; }
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
pre="$(sq "$ROOT/bin/fm-busy-event.sh") apply $(sq "$STATE") $(sq "$ID")"
suf="--gen $(sq "$GEN") --source qwen-hook"
q_submit="$pre busy $suf --event user-prompt-submit >/dev/null 2>&1 || true; printf '{}'"
q_stop="touch $(sq "$TURNEND"); $pre idle $suf --event stop >/dev/null 2>&1 || true; printf '{}'"
q_stopfail="$pre idle $suf --event stop-failure >/dev/null 2>&1 || true; printf '{}'"
q_sessionend="$pre idle $suf --event session-end >/dev/null 2>&1 || true; printf '{}'"
SETTINGS="$STATE/$ID.qwen-settings.json"
( umask 077; jq -n --arg submit "$q_submit" --arg stop "$q_stop" --arg stopfail "$q_stopfail" --arg sessionend "$q_sessionend" '
  { hooks: { UserPromptSubmit: [{hooks: [{type: "command", command: $submit}]}],
             Stop: [{hooks: [{type: "command", command: $stop}]}],
             StopFailure: [{hooks: [{type: "command", command: $stopfail}]}],
             SessionEnd: [{hooks: [{type: "command", command: $sessionend}]}] } }
  + { security: {auth: {selectedType: env.QWEN_DEFAULT_AUTH_TYPE}},
      env: ({OPENAI_API_KEY: env.OPENAI_API_KEY} + {OPENAI_BASE_URL: env.OPENAI_BASE_URL}) }' > "$SETTINGS" )
unset OPENAI_API_KEY OPENAI_BASE_URL QWEN_DEFAULT_AUTH_TYPE
echo "settings mode: $(stat -c %a "$SETTINGS")"

QWEN_BIN=$(command -v qwen)
BRIEF='Reply with the single word PONG and nothing else. Do not run any tools.'
LAUNCH="env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u OPENAI_API_KEY -u OPENAI_BASE_URL QWEN_CODE_SYSTEM_SETTINGS_PATH=$(sq "$SETTINGS") $(sq "$QWEN_BIN") -y --model 'qwen3-coder:30b' --prompt-interactive $(sq "$BRIEF")"
echo "recorded launch (sanitized): ${LAUNCH//$LAB/<lab>}" | sed "s#$QWEN_BIN#<qwen-bin>#"
case "$LAUNCH" in *lab-secret-sentinel-7731*) echo "FAIL: credential in launch command" ;; *) echo "credential absent from launch command: yes" ;; esac

tm new-window -d -t firstmate: -n qwen -c "$LAB/wt" "bash --norc --noprofile -i"
sleep 1
tm send-keys -t "$T" -l "$LAUNCH"; tm send-keys -t "$T" Enter

for i in $(seq 1 60); do [ "$(fm_backend_agent_state tmux "$T")" = alive ] && break; sleep 0.5; done
echo "liveness after launch: $(fm_backend_agent_state tmux "$T")"
pid=$(pgrep -f -n "cli.js.*prompt-interactive|bin/qwen.*prompt-interactive" || true)
if [ -n "$pid" ]; then
  if tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q lab-secret-sentinel-7731 || tr '\0' '\n' < "/proc/$pid/environ" | grep -q lab-secret-sentinel-7731; then
    echo "FAIL: credential in qwen argv or environ"; else echo "credential absent from qwen argv and environ: yes"; fi
fi
if wait_busy_state busy 30; then echo "launch brief opened busy:"; busy; else echo "never observed busy (turn may have finished)"; busy; fi
wait_busy_state idle 180 && { echo "after Stop:"; busy; }
[ -e "$TURNEND" ] && echo "turn-ended marker present: yes" || echo "turn-ended marker present: no"
snap "after launch brief turn (trust dialog / auth picker would appear here)" 20

rm -f "$TURNEND"
tm send-keys -t "$T" -l "Write a 600 word essay about ocean tides. Do not run tools."; tm send-keys -t "$T" Enter
wait_busy_state busy 30 && { echo "doorbell-style submitted line opened busy:"; busy; }
sleep 4
snap "mid-turn (submitted line visible, turn in flight)" 12
key=$(fm_control_interrupt_key qwen); clear=$(fm_control_interrupt_clear_key qwen); exitcmd=$(fm_control_exit_command qwen)
echo "control-lib mechanics: interrupt=$key clear=$clear exit=$exitcmd"
tm send-keys -t "$T" "$key"
sleep 3
snap "after $key (Qwen restores cancelled prompt into composer)" 8
busy
tm send-keys -t "$T" "$clear"
sleep 1
snap "after $clear" 6
tm send-keys -t "$T" -l "$exitcmd"; tm send-keys -t "$T" Enter
for i in $(seq 1 60); do [ "$(fm_backend_agent_state tmux "$T")" != alive ] && break; sleep 0.5; done
echo "liveness after $exitcmd: $(fm_backend_agent_state tmux "$T")"
busy
snap "after $exitcmd" 10
