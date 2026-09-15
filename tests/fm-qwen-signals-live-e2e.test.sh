#!/usr/bin/env bash
# Live guard for the real, installed Qwen Code CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping. It drives a trivial
# supervised headless turn against whatever model the operator has configured
# (default: qwen3-coder:30b via local Ollama) and proves the harness-dependent
# facts the adapter encodes: QWEN_CODE=1 on a tool child, and the Stop hook
# firing at turn end through QWEN_CODE_SYSTEM_SETTINGS_PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QWEN_BIN=$(command -v qwen 2>/dev/null || true)

fm_live_gate opt-in FM_QWEN_SIGNALS_LIVE qwen

[ -x "$QWEN_BIN" ] || fail "FM_QWEN_SIGNALS_LIVE=1 but no real qwen executable is installed"

VERSION_OUT=$("$QWEN_BIN" --version 2>&1) || fail "qwen --version failed: $VERSION_OUT"
echo "BOOTSTRAP_INFO: live qwen version: $VERSION_OUT"

MODEL=${QWEN_LIVE_MODEL:-qwen3-coder:30b}
BASE_URL=${OPENAI_BASE_URL:-http://127.0.0.1:11434/v1}
LOCAL_OLLAMA=0
OLLAMA_MODEL_WAS_RUNNING=0
case "$BASE_URL" in
  http://127.0.0.1:11434/*|http://localhost:11434/*|http://\[::1\]:11434/*) LOCAL_OLLAMA=1 ;;
esac
ollama_model_running() {
  ollama ps 2>/dev/null | awk -v model="$MODEL" 'NR > 1 && $1 == model { found=1 } END { exit !found }'
}
if [ "$LOCAL_OLLAMA" -eq 1 ] && command -v ollama >/dev/null 2>&1 \
   && ollama_model_running; then
  OLLAMA_MODEL_WAS_RUNNING=1
fi

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-qwen-signals.XXXXXX") || fail "could not create the isolated Qwen lab"
cleanup() {
  if [ "$LOCAL_OLLAMA" -eq 1 ] && [ "$OLLAMA_MODEL_WAS_RUNNING" -eq 0 ] \
     && command -v ollama >/dev/null 2>&1 && ollama_model_running; then
    ollama stop "$MODEL" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/home" "$LAB/ws" "$LAB/hooks"
git -C "$LAB/ws" init -q || fail "could not initialize the isolated Qwen workspace"
git -C "$LAB/ws" -c user.name=probe -c user.email=probe@example.invalid commit --allow-empty -qm init

cat > "$LAB/hooks/log.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
log = os.environ["PROBE_HOOK_LOG"]
raw = sys.stdin.read()
try:
    d = json.loads(raw) if raw.strip() else {}
except Exception as e:
    d = {"parse_error": str(e)}
rec = {"event": d.get("hook_event_name"), "tool": d.get("tool_name")}
with open(log, "a") as f:
    f.write(json.dumps(rec) + "\n")
print("{}")
PY
chmod +x "$LAB/hooks/log.py"

python3 - "$LAB" <<'PY'
import json, os, sys
lab = sys.argv[1]
hook = os.path.join(lab, "hooks", "log.py")
settings = {
  "telemetry": {"enabled": False},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": hook}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": hook}]}],
    "Stop": [{"hooks": [{"type": "command", "command": hook}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": hook}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": hook}]}],
  },
}
open(os.path.join(lab, "system-settings.json"), "w").write(json.dumps(settings))
open(os.path.join(lab, "home", "settings.json"), "w").write(
    json.dumps({"ui": {"autoModeAcknowledged": True}, "$version": 4})
)
PY

: > "$LAB/hooks.jsonl"
PROMPT='Run this exact bash command and nothing else, then reply with the single word PONG: printf "%s\n" "$QWEN_CODE"'

set +e
(
  cd "$LAB/ws" || exit 1
  env -u GROK_AGENT -u GROK_SESSION_ID -u CLAUDECODE -u GEMINI_CLI \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
    QWEN_HOME="$LAB/home" \
    QWEN_CODE_SYSTEM_SETTINGS_PATH="$LAB/system-settings.json" \
    PROBE_HOOK_LOG="$LAB/hooks.jsonl" \
    QWEN_CODE_SUPPRESS_YOLO_WARNING=1 \
    OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
    OPENAI_BASE_URL="$BASE_URL" \
    timeout 180s "$QWEN_BIN" \
      --auth-type openai \
      --model "$MODEL" \
      --yolo \
      --chat-recording=false \
      --max-wall-time 2m \
      --max-tool-calls 8 \
      --output-format stream-json \
      "$PROMPT"
) > "$LAB/stdout.jsonl" 2> "$LAB/stderr.txt"
RC=$?
set -e
[ "$RC" -eq 0 ] || fail "live qwen turn failed (exit $RC): $(tail -20 "$LAB/stderr.txt")"

python3 - "$LAB" <<'PY' || fail "live qwen turn did not prove Stop and QWEN_CODE=1"
import json, sys
lab = sys.argv[1]
events = []
for line in open(lab + "/hooks.jsonl"):
    events.append(json.loads(line).get("event"))
if "Stop" not in events:
    raise SystemExit("Stop hook did not fire; events=%r" % events)
if "UserPromptSubmit" not in events:
    raise SystemExit("UserPromptSubmit hook did not fire; events=%r" % events)
expected_command = 'printf "%s\\n" "$QWEN_CODE"'
tool_calls = {}
tool_results = {}
for line in open(lab + "/stdout.jsonl"):
    d = json.loads(line)
    if d.get("type") == "assistant":
        for block in d.get("message", {}).get("content", []):
            if block.get("type") == "tool_use" and block.get("name") == "run_shell_command":
                if block.get("input", {}).get("command", "").strip() == expected_command:
                    tool_calls[block.get("id")] = block
    if d.get("type") != "user":
        continue
    for block in d.get("message", {}).get("content", []):
        if block.get("type") == "tool_result":
            tool_results[block.get("tool_use_id")] = block
if len(tool_calls) != 1:
    raise SystemExit("expected exactly one intended shell call; calls=%r" % list(tool_calls))
tool_id = next(iter(tool_calls))
result = tool_results.get(tool_id)
if result is None or result.get("is_error") or result.get("content", "").strip() != "1":
    raise SystemExit("intended shell stdout was not exactly QWEN_CODE=1; result=%r" % result)
print("events", events)
print("tool_env_ok")
PY

pass "qwen 0.23.0 Stop hook fires and QWEN_CODE=1 reaches a tool child"
