#!/usr/bin/env bash
# Behavior tests for the Qwen Code harness adapter.
#
# The facts pinned here are the ones a Qwen release could silently change and
# the ones a wrong guess would make dangerous:
#   1. QWEN_CODE=1 is Qwen's own tool-process marker, and it outranks an
#      inherited GROK_AGENT or CLAUDECODE, because qwen does NOT clear those
#      (verified live on qwen 0.23.0 under a grok primary, where a qwen tool
#      process carried QWEN_CODE=1 and GROK_AGENT=1 together).
#   2. QWEN_CODE_CLI is a path, not an identity flag, and GEMINI_CLI is not
#      set despite qwen being a Gemini-CLI fork.
#   3. The installed CLI is a node bundle whose live process reports comm as
#      node-MainThread on modern Node/Linux, so ancestry does NOT reach it
#      without reading the script argument. The comm-name arm is pinned for a
#      future natively-named binary.
#   4. Qwen is a crewmate/scout adapter only: it has no primary supervision
#      protocol, so its control mechanics are verified while a secondmate
#      launch on it is refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-qwen-lib.sh
. "$ROOT/bin/fm-qwen-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-qwen-harness)

detect_harness() {
  env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u QWEN_CODE \
    -u QWEN_CODE_CLI -u ATLASSIAN_AGENT_TYPE -u ROVODEV_CLI -u AGENT \
    -u FM_OMP_HARNESS -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS \
    -u GROK_AGENT "$@" "$HARNESS"
}

test_qwen_marker_outranks_inherited_grok_and_claudecode() {
  local out
  out=$(detect_harness GROK_AGENT=1 QWEN_CODE=1)
  [ "$out" = qwen ] || fail "GROK_AGENT + QWEN_CODE must detect qwen, got '$out'"
  out=$(detect_harness CLAUDECODE=1 QWEN_CODE=1)
  [ "$out" = qwen ] || fail "CLAUDECODE + QWEN_CODE must detect qwen, got '$out'"
  out=$(detect_harness QWEN_CODE=1)
  [ "$out" = qwen ] || fail "QWEN_CODE alone must detect qwen, got '$out'"
  out=$(detect_harness GROK_AGENT=1)
  [ "$out" = grok ] || fail "GROK_AGENT alone must still detect grok, got '$out'"
  out=$(detect_harness CLAUDECODE=1)
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  out=$(detect_harness CURSOR_AGENT=1 QWEN_CODE=1)
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank QWEN_CODE, got '$out'"
  pass "fm-harness.sh: qwen's marker outranks inherited GROK_AGENT and CLAUDECODE"
}

test_qwen_does_not_claim_gemini_cli_or_qwen_code_cli_path() {
  local out
  out=$(detect_harness GEMINI_CLI=1)
  [ "$out" = gemini ] || fail "GEMINI_CLI must remain gemini, got '$out'"
  out=$(detect_harness \
    QWEN_CODE_CLI=/home/u/.local/lib/node_modules/@qwen-code/qwen-code/cli-entry.js)
  [ "$out" != qwen ] \
    || fail "QWEN_CODE_CLI as a path must not claim the qwen identity, got '$out'"
  out=$(detect_harness QWEN_CODE=0)
  [ "$out" != qwen ] \
    || fail "QWEN_CODE=0 must not claim the qwen identity, got '$out'"
  pass "fm-harness.sh: GEMINI_CLI and QWEN_CODE_CLI never claim the qwen identity"
}

test_qwen_ancestry_matches_only_a_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/qwen'; exit 0 ;;
  *"args="*) printf '%s\n' 'qwen -y'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(detect_harness PATH="$fakebin:$PATH")
  [ "$out" = qwen ] \
    || fail "a natively-named qwen command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named qwen command"
}

test_qwen_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(detect_harness FAKE_PS_COMM=qwen-helper \
    FAKE_PS_ARGS='qwen-helper --serve' PATH="$fakebin:$PATH")
  [ "$out" != qwen ] \
    || fail "an unrelated qwen-helper command must not detect qwen, got '$out'"

  out=$(detect_harness FAKE_PS_COMM=node \
    FAKE_PS_ARGS='node server.js --model qwen' PATH="$fakebin:$PATH")
  [ "$out" != qwen ] \
    || fail "a later node argument naming qwen must not detect qwen, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated qwen mentions"
}

test_qwen_node_bundle_needs_script_argument_or_marker() {
  command -v node >/dev/null 2>&1 || return 0
  local dir="$TMP_ROOT/ancestry" out comm
  mkdir -p "$dir"
  comm=$(node -e 'const{execSync}=require("child_process");process.stdout.write(execSync("ps -o comm= -p "+process.pid).toString().trim())' 2>/dev/null)
  [ -n "$comm" ] || return 0
  cat > "$dir/qwen" <<'JS'
const { spawnSync } = require('child_process');
const env = { ...process.env };
for (const k of ['CURSOR_AGENT', 'CURSOR_INVOKED_AS', 'GEMINI_CLI',
                 'QWEN_CODE', 'QWEN_CODE_CLI', 'ATLASSIAN_AGENT_TYPE',
                 'ROVODEV_CLI', 'AGENT', 'FM_OMP_HARNESS', 'CLAUDECODE',
                 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'GROK_AGENT']) delete env[k];
const r = spawnSync(process.env.FM_HARNESS_BIN, { env, encoding: 'utf8' });
process.stdout.write(r.stdout || '');
JS
  out=$(FM_HARNESS_BIN="$HARNESS" node "$dir/qwen" 2>/dev/null | tr -d '\n')
  case "$comm" in
    node|node-*|MainThread)
      [ "$out" = qwen ] \
        || fail "where node reports comm=$comm, a qwen script path must detect qwen, got '$out'"
      pass "fm-harness.sh: this platform's node reports comm=$comm and ancestry reaches a qwen script"
      ;;
    *)
      [ "$out" != qwen ] \
        || fail "node reports comm=$comm here, so ancestry must not be claiming qwen from comm alone; got '$out'"
      out=$(FM_HARNESS_BIN="$HARNESS" node -e '
const { spawnSync } = require("child_process");
const env = { ...process.env };
for (const k of ["CURSOR_AGENT", "CURSOR_INVOKED_AS", "GEMINI_CLI",
                 "QWEN_CODE", "QWEN_CODE_CLI", "ATLASSIAN_AGENT_TYPE",
                 "ROVODEV_CLI", "AGENT", "FM_OMP_HARNESS", "CLAUDECODE",
                 "PI_CODING_AGENT", "FM_PI_HARNESS", "GROK_AGENT"]) delete env[k];
env.QWEN_CODE = "1";
const r = spawnSync(process.env.FM_HARNESS_BIN, { env, encoding: "utf8" });
process.stdout.write(r.stdout || "");' 2>/dev/null | tr -d '\n')
      [ "$out" = qwen ] \
        || fail "QWEN_CODE must identify a node-bundle qwen worker, got '$out'"
      pass "fm-harness.sh: the node bundle is marker-detected when comm is not an interpreter name"
      ;;
  esac
}

test_qwen_process_identity_reads_the_script_argument() {
  fm_qwen_args_are_qwen 'node /home/u/.local/bin/qwen -y' \
    || fail "the installed launcher shape must be recognized as qwen"
  fm_qwen_args_are_qwen '/home/u/.hermes/node/bin/node --expose-gc /home/u/.local/lib/node_modules/@qwen-code/qwen-code/cli.js -y' \
    || fail "node option flags before the published package path must be skipped"
  fm_qwen_args_are_qwen 'qwen -y' \
    || fail "a natively-named qwen command must be recognized"

  ! fm_qwen_args_are_qwen '/home/u/.local/node/bin/node' \
    || fail "a bare node process must not be claimed as qwen"
  ! fm_qwen_args_are_qwen 'node /home/u/app/server.js' \
    || fail "an unrelated node script must not be claimed as qwen"
  ! fm_qwen_args_are_qwen 'node /home/u/app/server.js --model qwen' \
    || fail "a later flag value naming qwen must not claim the identity"
  ! fm_qwen_args_are_qwen 'tail -f /var/log/qwen.log' \
    || fail "an unrelated command reading a qwen-named file must not match"
  ! fm_qwen_args_are_qwen 'node /home/u/qwen/other.js' \
    || fail "a qwen directory component alone must not claim the identity"
  pass "fm-qwen-lib.sh: identity comes from the script argument, never a bare interpreter"
}

test_qwen_process_identity_preserves_whitespace_in_script_path() {
  command -v node >/dev/null 2>&1 || return 0
  [ -r /proc/self/cmdline ] || return 0
  local dir="$TMP_ROOT/path with spaces" node_bin pid attempts=0
  mkdir -p "$dir"
  node_bin=$(command -v node)
  ln -s "$node_bin" "$dir/node"
  cat > "$dir/qwen" <<'JS'
setTimeout(() => {}, 30000);
JS
  "$dir/node" "$dir/qwen" &
  pid=$!
  while ! fm_qwen_pid_is_qwen "$pid"; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fail "Qwen interpreter and script paths containing spaces must retain process identity"
    fi
    sleep 0.01
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-qwen-lib.sh: process argv preserves whitespace in interpreter and Qwen script paths"
}

test_qwen_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported qwen || fail "qwen must be a supported control harness"
  out=$(fm_control_harness_family qwen-0.23.0)
  [ "$out" = qwen ] || fail "a recorded qwen* harness must resolve to qwen, got '$out'"
  out=$(fm_control_interrupt_key qwen)
  [ "$out" = Escape ] || fail "qwen interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat qwen)
  [ "$out" = 1 ] || fail "qwen interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key qwen)
  [ "$out" = C-u ] || fail "qwen restores the cancelled prompt, so interrupt must Ctrl-U, got '$out'"
  out=$(fm_control_exit_command qwen)
  [ "$out" = /quit ] || fail "qwen exits with /quit, got '$out'"
  pass "fm-control-lib.sh: qwen carries its verified interrupt and exit mechanics"
}

test_qwen_is_crewmate_and_scout_only() {
  fm_control_harness_supports_kind qwen ship \
    || fail "qwen must be verified for ship work"
  fm_control_harness_supports_kind qwen scout \
    || fail "qwen must be verified for scout work"
  ! fm_control_harness_supports_kind qwen secondmate \
    || fail "qwen has no primary supervision protocol and must be refused for secondmates"
  pass "fm-control-lib.sh: qwen is a crewmate/scout adapter only"
}

test_qwen_wiring_stays_outside_the_worktree() {
  local out
  out=$(fm_control_harness_wiring_paths qwen /wt /state task-1)
  [ "$out" = "/state/task-1.qwen-settings.json" ] \
    || fail "qwen's per-task wiring is its firstmate-owned settings file, got '$out'"
  case "$out" in
    /wt/*) fail "qwen must never claim a path inside the worktree: '$out'" ;;
  esac
  pass "fm-control-lib.sh: qwen's wiring stays outside the project worktree"
}

test_qwen_marker_outranks_inherited_grok_and_claudecode
test_qwen_does_not_claim_gemini_cli_or_qwen_code_cli_path
test_qwen_ancestry_matches_only_a_native_command_name
test_qwen_ancestry_rejects_unrelated_mentions
test_qwen_node_bundle_needs_script_argument_or_marker
test_qwen_process_identity_reads_the_script_argument
test_qwen_process_identity_preserves_whitespace_in_script_path
test_qwen_control_mechanics_are_the_verified_ones
test_qwen_is_crewmate_and_scout_only
test_qwen_wiring_stays_outside_the_worktree
