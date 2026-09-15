#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (the Pi extension,
# the OpenCode plugin) in a plain Node host, so the artifact, the real
# bin/fm-busy-event.sh writer, and the real classifier are exercised together
# with no live harness session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi opencode claude codex gemini qwen)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

# Canonical qwen spawn needs non-interactive auth flags or it wedges on the
# ModelStudio picker. Tests that drive the real template export the local
# Ollama placeholders; they are not secrets.
run_qwen_spawn() {
  QWEN_DEFAULT_AUTH_TYPE=openai OPENAI_API_KEY=ollama \
    OPENAI_BASE_URL=http://127.0.0.1:11434/v1 \
    run_spawn "$@"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# drive_pi_ext <ext-path> <mode>: load the generated Pi extension in a plain
# Node host and fire one lifecycle handler. Modes: agent-start, settle-idle,
# settle-continuing, turn-end.
drive_pi_ext() {
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on: (name, fn) => { handlers[name] = fn; } } });
const ctx = { isIdle: () => process.env.MODE !== "settle-continuing" };
switch (process.env.MODE) {
  case "agent-start": await handlers["agent_start"]({}, ctx); break;
  case "settle-idle": await handlers["agent_settled"]({}, ctx); break;
  case "settle-continuing": await handlers["agent_settled"]({}, ctx); break;
  case "settle-then-start":
    await handlers["agent_settled"]({}, ctx);
    await handlers["agent_start"]({}, ctx);
    break;
  case "turn-end": await handlers["turn_end"]({}, ctx); break;
  case "progress": await handlers["codex-native:progress"]({ type: "commandExecution", phase: "completed" }); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (["turn-end", "progress"].includes(process.env.MODE)) {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_pi_extension_semantic_lifecycle() {
  local rec id=busy-pi-1 out state ext
  rec=$(make_spawn_case pi-lifecycle pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"

  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_pi_ext "$ext" progress) || fail "native progress drive failed: $out"
  [ -f "$state/$id.progress" ] || fail "native progress did not write its separate marker"
  [ ! -e "$state/$id.turn-ended" ] || fail "native progress fabricated a completed turn"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "native progress changed semantic state: $out"
  out=$(drive_pi_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "agent_settled drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "agent_settled with isIdle must classify 'idle pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must classify 'busy pi-ext', got '$out'"

  out=$(drive_pi_ext "$ext" settle-continuing) || fail "continuing settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a settle while another run continues must stay busy, got '$out'"

  out=$(drive_pi_ext "$ext" settle-idle) || fail "final settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the final settle must classify idle, got '$out'"
  pass "pi extension reports agent_start busy, settles idle only via ctx.isIdle(), and keeps turn_end a notification"
}

test_pi_extension_serializes_settle_before_next_start() {
  local rec id=busy-pi-order out state ext
  rec=$(make_spawn_case pi-order pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"

  out=$(drive_pi_ext "$ext" settle-then-start) || fail "settle/start drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "a fresh agent_start after agent_settled must win, got '$out'"
  pass "pi extension awaits agent_settled before the next agent_start without a test delay"
}

test_pi_extension_stale_incarnation_rejected() {
  local rec id=busy-pi-2 out state ext
  rec=$(make_spawn_case pi-stale pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  # A re-arm (a rewired incarnation) supersedes the gen embedded in the old
  # extension file: its late events must be rejected and never change state.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  out=$(drive_pi_ext "$ext" settle-idle) || fail "stale settle drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale extension event must not change state, got '$out'"
  out=$(drive_pi_ext "$ext" progress) || fail "stale progress drive failed: $out"
  [ ! -e "$state/$id.progress" ] || fail "stale native progress refreshed the new incarnation"
  pass "pi extension events from a superseded incarnation are rejected as stale"
}

# drive_oc_plugin <plugin-path> <events-json-lines...>: load the generated
# OpenCode plugin in a plain Node host and feed it one event per argument, in
# order, through the same hooks.event entry OpenCode calls.
drive_oc_plugin() {
  local plugin=$1
  shift
  PLUGIN_PATH="$plugin" node --input-type=module - "$@" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const hooks = await mod.FmBusyState({});
for (const arg of process.argv.slice(2)) {
  await hooks.event({ event: JSON.parse(arg) });
}
EOF
}

oc_status() {  # <sessionID> <type>
  printf '{"type":"session.status","properties":{"sessionID":"%s","status":{"type":"%s"}}}' "$1" "$2"
}

oc_idle() {  # <sessionID>
  printf '{"type":"session.idle","properties":{"sessionID":"%s"}}' "$1"
}

test_opencode_plugin_semantic_lifecycle() {
  local rec id=busy-oc-1 out state plugin
  rec=$(make_spawn_case oc-lifecycle opencode "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "opencode spawn should succeed: $out"
  state="$HOME_DIR/state"
  plugin="$WT_DIR/.opencode/plugins/fm-busy-state.js"
  assert_present "$plugin" "opencode spawn did not write the busy-state plugin"

  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  out=$(drive_oc_plugin "$plugin" "$(oc_status ses_main busy)") || fail "busy drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "session busy must classify 'busy opencode-plugin', got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_status ses_child busy)" \
    "$(oc_status ses_child idle)") || fail "child-session drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "a child session's idle must not clear the worker, got '$out'"

  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main retry)" \
    "$(oc_status ses_main idle)") || fail "retry/idle drive failed: $out"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "the latched session's idle must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses_main busy)" \
    "$(oc_idle ses_main)") || fail "session.idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "session.idle no longer touches the notification marker"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "idle opencode-plugin" ] || fail "session.idle for the latched session must classify idle, got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(drive_oc_plugin "$plugin" \
    "$(oc_status ses2 busy)" \
    "$(oc_idle ses_other)") || fail "other-session idle drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "the marker touch must stay a notification for every session.idle"
  out=$(classify opencode "$id" "$state")
  [ "$out" = "busy opencode-plugin" ] || fail "another session's idle must not clear the latched busy, got '$out'"
  pass "opencode plugin classifies from session.status, scoped to the latched worker session"
}

run_claude_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_claude_hooks_semantic_lifecycle() {
  local rec id=busy-cl-1 out state settings
  rec=$(make_spawn_case claude-lifecycle claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "claude hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "claude hook settings lack $ev"
  done

  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  run_claude_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "Stop must classify 'idle claude-hook', got '$out'"

  run_claude_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy claude-hook" ] || fail "UserPromptSubmit must classify 'busy claude-hook', got '$out'"

  run_claude_hook "$settings" StopFailure || fail "StopFailure hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_claude_hook "$settings" UserPromptSubmit
  run_claude_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(classify claude "$id" "$state")
  [ "$out" = "idle claude-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "claude hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_claude_hooks_stale_incarnation_harmless() {
  local rec id=busy-cl-2 out state settings
  rec=$(make_spawn_case claude-stale claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.claude/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_claude_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so Claude's lifecycle is never broken"
  out=$(classify claude "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "claude hook events from a superseded incarnation are rejected without breaking the hook"
}

test_codex_unverified_until_a_semantic_source_exists() {
  local rec id=busy-cx-1 out state
  rec=$(make_spawn_case codex-unverified codex "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "codex spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "codex must not arm a busy contract with no verified semantic source"
  assert_absent "$WT_DIR/.codex/hooks.json" "codex must not install unverified busy hooks"
  assert_contains "$out" 'spawned '"$id"' harness=codex' "codex spawn did not complete normally"
  out=$(classify codex "$id" "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must classify 'unknown codex-unverified', got '$out'"
  out=$(fm_busy_classify tmux fake:w codex "$id" "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "unknown codex-unverified" ] || fail "codex must not fall back to footer text, got '$out'"
  pass "codex classifies unknown until a semantic source is verified, never idle or footer-matched"
}

# Gemini's hooks are PROJECT hooks in the worktree's own .gemini/settings.json,
# and gemini's hook contract requires each command to print a JSON object on
# stdout and nothing else, so these drive the real command and check both the
# classification and that stdout stays parseable JSON.
run_gemini_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_gemini_hooks_semantic_lifecycle() {
  local rec id=busy-gm-1 out state settings
  rec=$(make_spawn_case gemini-lifecycle gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  assert_present "$settings" "gemini spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "gemini hook settings are not valid JSON"
  for ev in BeforeAgent AfterAgent SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "gemini hook settings lack $ev"
  done
  # The worktree's own .gemini/settings.json is the PROJECT's committed file;
  # firstmate must never write it, or a project's configuration is clobbered.
  assert_absent "$WT_DIR/.gemini/settings.json" \
    "gemini spawn must not write the project's own .gemini/settings.json"

  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(run_gemini_hook "$settings" AfterAgent) || fail "AfterAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "AfterAgent must print only a JSON object on stdout, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "AfterAgent no longer touches the notification marker"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "AfterAgent must classify 'idle gemini-hook', got '$out'"

  out=$(run_gemini_hook "$settings" BeforeAgent) || fail "BeforeAgent hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "BeforeAgent must print only a JSON object on stdout, got '$out'"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy gemini-hook" ] || fail "BeforeAgent must classify 'busy gemini-hook', got '$out'"

  # SessionEnd fires TWICE for one /quit on gemini-cli 0.58.0, so the second
  # delivery must be a harmless no-op rather than a state change or a failure.
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "SessionEnd hook command failed"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  run_gemini_hook "$settings" SessionEnd >/dev/null || fail "a repeated SessionEnd must still exit 0"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "idle gemini-hook" ] || fail "a repeated SessionEnd must stay idle, got '$out'"
  pass "gemini hooks open on BeforeAgent and close on AfterAgent and a repeated SessionEnd"
}

test_gemini_hooks_stale_incarnation_harmless() {
  local rec id=busy-gm-2 out state settings
  rec=$(make_spawn_case gemini-stale gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.gemini-settings.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_gemini_hook "$settings" BeforeAgent >/dev/null \
    || fail "a stale-gen hook must still exit 0 so gemini's lifecycle is never broken"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "gemini hook events from a superseded incarnation are rejected without breaking the hook"
}

test_raw_gemini_launch_has_no_semantic_wiring() {
  local rec id=busy-gm-raw out state
  rec=$(make_spawn_case gemini-raw gemini "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" 'gemini --debug')
  expect_code 0 $? "raw gemini spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "raw gemini launch must not arm a busy generation"
  assert_absent "$state/$id.gemini-settings.json" "raw gemini launch must not write hook settings"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "raw gemini launch must classify unknown, got '$out'"
  pass "raw gemini launch remains unwired and classifies unknown"
}

test_gemini_is_refused_as_a_secondmate() {
  local rec id=busy-gm-3 out
  rec=$(make_spawn_case gemini-secondmate gemini "$id")
  read_case_record "$rec"
  # A secondmate spawn carries no delivery contract, so this one deliberately
  # bypasses run_spawn's ship-only --mode/--yolo arguments.
  out=$(GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --secondmate "$id" gemini) && {
    fail "a gemini secondmate must be refused, it has no primary supervision protocol: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "refusing a gemini secondmate must name the crewmate/scout boundary: $out"
  pass "gemini is refused as a secondmate because it has no primary supervision protocol"
}

run_qwen_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd"
}

test_qwen_hooks_semantic_lifecycle() {
  local rec id=busy-qw-1 out state settings
  rec=$(make_spawn_case qwen-lifecycle qwen "$id")
  read_case_record "$rec"
  out=$(run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "qwen spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.qwen-settings.json"
  assert_present "$settings" "qwen spawn did not write hook settings"
  jq -e . "$settings" >/dev/null || fail "qwen hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "qwen hook settings lack $ev"
  done
  assert_absent "$WT_DIR/.qwen/settings.json" \
    "qwen spawn must not write the project's own .qwen/settings.json"

  out=$(classify qwen "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  rm -f "$state/$id.turn-ended"
  out=$(run_qwen_hook "$settings" Stop) || fail "Stop hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "Stop must print only a JSON object on stdout, got '$out'"
  [ -f "$state/$id.turn-ended" ] || fail "Stop no longer touches the notification marker"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "idle qwen-hook" ] || fail "Stop must classify 'idle qwen-hook', got '$out'"

  out=$(run_qwen_hook "$settings" UserPromptSubmit) || fail "UserPromptSubmit hook command failed"
  printf '%s' "$out" | jq -e . >/dev/null \
    || fail "UserPromptSubmit must print only a JSON object on stdout, got '$out'"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "busy qwen-hook" ] || fail "UserPromptSubmit must classify 'busy qwen-hook', got '$out'"

  run_qwen_hook "$settings" StopFailure >/dev/null || fail "StopFailure hook command failed"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "idle qwen-hook" ] || fail "StopFailure must classify idle so an API error cannot strand busy, got '$out'"

  run_qwen_hook "$settings" UserPromptSubmit >/dev/null
  run_qwen_hook "$settings" SessionEnd >/dev/null || fail "SessionEnd hook command failed"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "idle qwen-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "qwen hooks open on UserPromptSubmit and close on Stop, StopFailure, and SessionEnd"
}

test_qwen_hooks_stale_incarnation_harmless() {
  local rec id=busy-qw-2 out state settings
  rec=$(make_spawn_case qwen-stale qwen "$id")
  read_case_record "$rec"
  out=$(run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "qwen spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$state/$id.qwen-settings.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_qwen_hook "$settings" UserPromptSubmit >/dev/null \
    || fail "a stale-gen hook must still exit 0 so qwen's lifecycle is never broken"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "qwen hook events from a superseded incarnation are rejected without breaking the hook"
}

test_raw_qwen_launch_has_no_semantic_wiring() {
  local rec id=busy-qw-raw out state path_without_qwen raw_bin
  rec=$(make_spawn_case qwen-raw qwen "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/qwen"
  raw_bin="$CASE_DIR/raw-bin/qwen"
  mkdir -p "${raw_bin%/*}"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$raw_bin"
  chmod +x "$raw_bin"
  path_without_qwen=$(fm_test_base_path_sans "$PATH" qwen)
  out=$(PATH="$path_without_qwen" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "$raw_bin --debug")
  expect_code 0 $? "raw qwen spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "raw qwen launch must not arm a busy generation"
  assert_absent "$state/$id.qwen-settings.json" "raw qwen launch must not write hook settings"
  out=$(classify qwen "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "raw qwen launch must classify unknown, got '$out'"
  pass "raw qwen launch bypasses canonical preflight, remains unwired, and classifies unknown"
}

test_qwen_spawn_refuses_without_auth() {
  local rec id=busy-qw-noauth out tmux_log treehouse_log
  rec=$(make_spawn_case qwen-noauth qwen "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  out=$(
    unset QWEN_DEFAULT_AUTH_TYPE OPENAI_API_KEY OPENAI_BASE_URL
    FM_FAKE_TMUX_COMMAND_LOG="$tmux_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
      run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR"
  ) && {
    fail "qwen spawn without auth must refuse, got: $out"
  }
  assert_contains "$out" 'qwen-auth-unavailable' \
    "qwen spawn without auth must name the auth refusal: $out"
  assert_absent "$tmux_log" "qwen auth refusal created or wrote to an endpoint"
  assert_absent "$treehouse_log" "qwen auth refusal provisioned a worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "qwen auth refusal published metadata"
  assert_absent "$HOME_DIR/state/$id.qwen-settings.json" "qwen auth refusal wrote settings"
  pass "qwen spawn refuses before provisioning when no secure auth shape exists"
}

test_qwen_spawn_refuses_without_executable() {
  local rec id=busy-qw-nobin out tmux_log treehouse_log path_without_qwen
  rec=$(make_spawn_case qwen-nobin qwen "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  rm -f "$FAKEBIN_DIR/qwen"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  path_without_qwen=$(fm_test_base_path_sans "$PATH" qwen)
  out=$(PATH="$path_without_qwen" FM_FAKE_TMUX_COMMAND_LOG="$tmux_log" \
    FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR") && {
    fail "qwen spawn without its executable must refuse, got: $out"
  }
  assert_contains "$out" 'qwen-executable-unavailable' \
    "qwen spawn without its executable must name the refusal: $out"
  assert_absent "$tmux_log" "qwen executable refusal created or wrote to an endpoint"
  assert_absent "$treehouse_log" "qwen executable refusal provisioned a worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "qwen executable refusal published metadata"
  assert_absent "$HOME_DIR/state/$id.qwen-settings.json" "qwen executable refusal wrote settings"
  pass "qwen spawn resolves its executable before provisioning"
}

test_qwen_spawn_refuses_off_linux() {
  local rec id=busy-qw-darwin out tmux_log treehouse_log
  rec=$(make_spawn_case qwen-darwin qwen "$id")
  read_case_record "$rec"
  tmux_log="$CASE_DIR/tmux.log"
  treehouse_log="$CASE_DIR/treehouse.log"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
SH
  cat > "$FAKEBIN_DIR/uname" <<'SH'
#!/usr/bin/env bash
[ "$*" = -s ] && { echo Darwin; exit 0; }
exec /usr/bin/env -u PATH PATH=/usr/bin:/bin uname "$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/uname"
  out=$(FM_FAKE_TMUX_COMMAND_LOG="$tmux_log" FM_FAKE_TREEHOUSE_LOG="$treehouse_log" \
    run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR") && {
    fail "qwen spawn off Linux must refuse, got: $out"
  }
  assert_contains "$out" 'qwen-platform-unsupported' \
    "qwen spawn off Linux must name the platform refusal: $out"
  assert_absent "$tmux_log" "qwen platform refusal created or wrote to an endpoint"
  assert_absent "$treehouse_log" "qwen platform refusal provisioned a worktree"
  assert_absent "$HOME_DIR/state/$id.meta" "qwen platform refusal published metadata"
  assert_absent "$HOME_DIR/state/$id.qwen-settings.json" "qwen platform refusal wrote settings"
  pass "qwen spawn refuses a non-Linux host before provisioning"
}

test_qwen_failed_delivery_removes_private_settings() {
  local rec id=busy-qw-abort out settings observed
  rec=$(make_spawn_case qwen-abort qwen "$id")
  read_case_record "$rec"
  settings="$HOME_DIR/state/$id.qwen-settings.json"
  observed="$CASE_DIR/settings-observed"
  out=$(FM_FAKE_TMUX_LITERAL_FAIL=1 FM_FAKE_EXPECT_PATH="$settings" \
    FM_FAKE_OBSERVED_PATH="$observed" \
    run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR") && {
    fail "qwen spawn must fail when launch delivery fails, got: $out"
  }
  assert_present "$observed" "launch delivery did not observe Qwen settings, so the cleanup case was vacuous"
  assert_absent "$settings" "aborted qwen spawn retained credential-bearing settings"
  assert_absent "$HOME_DIR/state/$id.meta" "aborted qwen spawn retained metadata"
  assert_absent "$HOME_DIR/state/$id.busy-state" "aborted qwen spawn retained busy state"
  assert_absent "$HOME_DIR/state/$id.busy-gen" "aborted qwen spawn retained busy generation"
  pass "qwen spawn abort removes its credential-bearing settings"
}

test_qwen_launch_stays_interactive() {
  local rec id=busy-qw-i out log launch settings mode
  rec=$(make_spawn_case qwen-interactive qwen "$id")
  read_case_record "$rec"
  log="$CASE_DIR/launch.log"
  settings="$HOME_DIR/state/$id.qwen-settings.json"
  printf '{}\n' > "$settings"
  chmod 644 "$settings"
  out=$(FM_FAKE_LAUNCH_LOG="$log" run_qwen_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "qwen spawn should succeed: $out"
  launch=$(cat "$log")
  assert_contains "$launch" '--prompt-interactive' \
    "qwen launch must use --prompt-interactive so a positional brief is not one-shot headless"
  assert_contains "$launch" "'$FAKEBIN_DIR/qwen' -y" \
    "qwen launch must pin the resolved executable and keep -y"
  assert_not_contains "$launch" 'OPENAI_API_KEY' "qwen launch recorded a credential name"
  assert_not_contains "$launch" 'ollama' "qwen launch recorded a credential value"
  jq -e '.security.auth.selectedType == "openai" and .env.OPENAI_API_KEY == "ollama" and .env.OPENAI_BASE_URL == "http://127.0.0.1:11434/v1"' "$settings" >/dev/null \
    || fail "qwen settings did not carry the selected auth and environment"
  mode=$(stat -c '%a' "$settings" 2>/dev/null || stat -f '%Lp' "$settings")
  [ "$mode" = 600 ] || fail "qwen settings must be private, got mode $mode"
  pass "qwen launch stays interactive and keeps credentials out of recorded commands"
}

test_qwen_is_refused_as_a_secondmate() {
  local rec id=busy-qw-3 out
  rec=$(make_spawn_case qwen-secondmate qwen "$id")
  read_case_record "$rec"
  out=$(GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --secondmate "$id" qwen) && {
    fail "a qwen secondmate must be refused, it has no primary supervision protocol: $out"
  }
  assert_contains "$out" 'crewmate/scout adapter only' \
    "refusing a qwen secondmate must name the crewmate/scout boundary: $out"
  pass "qwen is refused as a secondmate because it has no primary supervision protocol"
}

test_kimi_and_grok_install_no_unverified_wiring() {
  local state out
  state="$TMP_ROOT/gates/state"
  mkdir -p "$state"
  [ -z "$(fm_busy_sources_for_harness kimi)" ] \
    || fail "standalone kimi must trust no semantic source until it is verified"
  [ -z "$(fm_busy_sources_for_harness grok)" ] \
    || fail "grok must trust no semantic source while its structured path is unverified"
  out=$(fm_busy_classify tmux fake:w kimi gate-k "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must classify unknown, not from its spinner, got '$out'"
  out=$(fm_busy_classify tmux fake:w grok gate-g "$state" 'Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok must classify through its isolated fallback, got '$out'"
  pass "kimi and grok install no unverified semantic wiring and classify through their own gates"
}

test_pi_extension_semantic_lifecycle
test_pi_extension_serializes_settle_before_next_start
test_pi_extension_stale_incarnation_rejected
test_kimi_and_grok_install_no_unverified_wiring
test_opencode_plugin_semantic_lifecycle
test_claude_hooks_semantic_lifecycle
test_claude_hooks_stale_incarnation_harmless
test_gemini_hooks_semantic_lifecycle
test_gemini_hooks_stale_incarnation_harmless
test_raw_gemini_launch_has_no_semantic_wiring
test_gemini_is_refused_as_a_secondmate
test_qwen_hooks_semantic_lifecycle
test_qwen_hooks_stale_incarnation_harmless
test_raw_qwen_launch_has_no_semantic_wiring
test_qwen_spawn_refuses_without_auth
test_qwen_spawn_refuses_without_executable
test_qwen_spawn_refuses_off_linux
test_qwen_failed_delivery_removes_private_settings
test_qwen_launch_stays_interactive
test_qwen_is_refused_as_a_secondmate
test_codex_unverified_until_a_semantic_source_exists

echo "all fm-busy-adapter-wiring tests passed"
