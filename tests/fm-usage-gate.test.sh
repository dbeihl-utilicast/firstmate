#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-gate.sh.
#
# Drives the public argv and environment interface: `select` reads a captured
# quota snapshot (--snapshot) or a fake quota-axi on PATH, plus the isolated
# home's config/. `sweep` runs a copy of bin/ whose fm-crew-state.sh and
# fm-control.sh are recording stubs, so the lane detection and the relaunch
# decision are observed through the same executables the real sweep calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-usage-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-gate)
HOME_DIR="$TMP_ROOT/home"
CONFIG="$HOME_DIR/config"
STATE="$HOME_DIR/state"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH
mkdir -p "$CONFIG" "$STATE"
export FM_HOME="$HOME_DIR"
unset FM_USAGE_GATE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE

# snapshot <path> <provider|scope|pct|runway|spendPriority>...
# One schema-5 quota-axi snapshot whose rows are grouped by provider.
snapshot() {
  local path=$1
  shift
  printf '%s\n' "$@" | jq -Rn '
    [inputs | split("|") | {provider: .[0], scope: .[1], pct: (.[2] | tonumber), runway: .[3], prio: (.[4] | tonumber)}]
    | group_by(.provider)
    | {generatedAt: "2030-01-01T00:00:00Z", schemaVersion: 5,
       providers: map({provider: .[0].provider, state: {status: "fresh"},
         quotaSemantics: {status: "known", effectiveAvailability: map({
           scope, status: "known", effectivePercentRemaining: .pct,
           runway: {status: .runway}, selection: {spendPriority: .prio}})}})}' > "$path"
}

# run_gate <args...>: stdout in GATE_OUT, exit code in GATE_RC, stderr in GATE_ERR.
run_gate() {
  GATE_OUT=$("$TOOL" "$@" 2>"$TMP_ROOT/stderr")
  GATE_RC=$?
  GATE_ERR=$(cat "$TMP_ROOT/stderr")
}

write_dispatch() {  # <json>
  printf '%s\n' "$1" > "$CONFIG/crew-dispatch.json"
}

DISPATCH_PAIR='{
  "schema_version": 2,
  "rules": [],
  "default": [
    {"harness": "claude", "model": "sonnet"},
    {"harness": "codex", "model": "gpt-5.6-terra"}]
}'
DISPATCH_MIXED='{
  "schema_version": 2,
  "rules": [],
  "default": [
    {"harness": "claude", "model": "sonnet"},
    {"harness": "codex", "model": "gpt-5.6-terra"},
    {"harness": "grok", "model": "grok-4.6"}]
}'
DISPATCH_TERRA_SOL_SONNET='{
  "schema_version": 2,
  "rules": [
    {"id": "review", "when": "Review work.", "use": [
      {"harness": "codex", "model": "gpt-5.6-terra"},
      {"harness": "codex", "model": "gpt-5.6-sol"},
      {"harness": "claude", "model": "sonnet"}]}
  ],
  "default": [
    {"harness": "codex", "model": "gpt-5.6-terra"},
    {"harness": "codex", "model": "gpt-5.6-sol"},
    {"harness": "claude", "model": "sonnet"}]
}'

Q_HEALTHY="$TMP_ROOT/q-healthy.json"
snapshot "$Q_HEALTHY" \
  'claude|all_models|60|through_reset|0.3' \
  'codex|all_models|80|through_reset|0.5'
Q_CODEX_EXHAUSTED="$TMP_ROOT/q-codex-exhausted.json"
snapshot "$Q_CODEX_EXHAUSTED" \
  'claude|all_models|60|through_reset|0.3' \
  'codex|all_models|0|exhausted_now|-1'
Q_CLAUDE_EXHAUSTED="$TMP_ROOT/q-claude-exhausted.json"
snapshot "$Q_CLAUDE_EXHAUSTED" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5'
Q_MIXED="$TMP_ROOT/q-mixed.json"
snapshot "$Q_MIXED" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5' \
  'grok|all_models|90|through_reset|0.9'

# --- healthy profile is kept ---------------------------------------------------
write_dispatch "$DISPATCH_PAIR"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_HEALTHY"
expect_code 0 "$GATE_RC" "healthy profile"
assert_contains "$GATE_OUT" "status: keep" "a profile with quota left is kept"
assert_contains "$GATE_OUT" "current: claude:sonnet" "the kept profile is named, so the absence below is meaningful"
assert_not_contains "$GATE_OUT" "profile: --harness" "a kept profile names no replacement"
pass "a profile with quota left is kept"

# --- exhausted profile is replaced by the best declared sibling ------------------
write_dispatch "$DISPATCH_MIXED"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_MIXED"
expect_code 0 "$GATE_RC" "exhausted profile with eligible siblings"
assert_contains "$GATE_OUT" "status: replace" "an exhausted profile is replaced"
assert_contains "$GATE_OUT" "current: claude:sonnet" "the exhausted profile is named"
assert_contains "$GATE_OUT" "not eligible: runway exhausted_now at all_models" "the exhaustion reason is printed"
assert_contains "$GATE_OUT" "candidate: codex:gpt-5.6-terra" "each alternate is listed with its evidence"
assert_contains "$GATE_OUT" "profile: --harness 'grok' --model 'grok-4.6'" "the higher spendPriority sibling is chosen"
pass "an exhausted profile is replaced by the best eligible declared sibling"

# --- a known zero is exhaustion even without an exhausted_now runway ---------------
write_dispatch "$DISPATCH_PAIR"
Q_ZERO="$TMP_ROOT/q-zero.json"
snapshot "$Q_ZERO" \
  'claude|all_models|0|projected_exhaustion|-1' \
  'codex|all_models|80|through_reset|0.5'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_ZERO"
assert_contains "$GATE_OUT" "status: replace" "a known 0% window is exhaustion"
assert_contains "$GATE_OUT" "0% remaining at all_models" "the zero reason is printed"
pass "a known zero remaining is exhaustion"

# --- a model-scoped window exhausts only that model ---------------------------------
Q_FABLE="$TMP_ROOT/q-fable.json"
snapshot "$Q_FABLE" \
  'claude|all_models|60|through_reset|0.3' \
  'claude|model:fable|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_FABLE"
assert_contains "$GATE_OUT" "status: keep" "an exhausted fable window does not exhaust sonnet"
run_gate select --kind ship --harness claude --model fable --snapshot "$Q_FABLE"
assert_contains "$GATE_OUT" "not eligible: runway exhausted_now at model:fable" "fable itself is exhausted"
assert_contains "$GATE_OUT" "status: none" "and nothing declared replaces it"
pass "a model window exhausts only its own model"

# --- no declared alternate: report, never invent one --------------------------------
rm -f "$CONFIG/crew-dispatch.json"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 1 "$GATE_RC" "exhausted with no dispatch file"
assert_contains "$GATE_OUT" "status: none" "no dispatch file means no alternate"
assert_contains "$GATE_OUT" "no alternate profile is declared" "the reason names the missing declaration"
assert_not_contains "$GATE_OUT" "profile: --harness" "no replacement is invented"
pass "an exhausted profile with no declared alternate is reported as none"

# --- alternates come only from the array that lists the exhausted profile ------------
write_dispatch '{
  "schema_version": 2,
  "rules": [
    {"id": "review", "when": "Review.", "use": [
      {"harness": "claude", "model": "sonnet"},
      {"harness": "codex", "model": "gpt-5.6-terra"}]},
    {"id": "hard", "when": "Hard.", "use": [
      {"harness": "grok", "model": "grok-4.6"}]}
  ],
  "default": [{"harness": "cursor", "model": "cursor-grok-4.6-high"}]
}'
Q_ALL="$TMP_ROOT/q-all.json"
snapshot "$Q_ALL" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5' \
  'grok|all_models|90|through_reset|0.9' \
  'cursor|all_models|90|through_reset|0.9'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_ALL"
assert_contains "$GATE_OUT" "profile: --harness 'codex' --model 'gpt-5.6-terra'" "the sibling in the same array is chosen"
assert_not_contains "$GATE_OUT" "grok" "another rule's profile is not an alternate"
assert_not_contains "$GATE_OUT" "cursor" "the default array is not an alternate when it does not list the profile"
pass "alternates come only from the array that lists the exhausted profile"

# --- a profile in several arrays only falls back to profiles they all list ------------
write_dispatch '{
  "schema_version": 2,
  "rules": [
    {"id": "review", "when": "Review.", "use": [
      {"harness": "codex", "model": "gpt-5.6-terra"},
      {"harness": "codex", "model": "gpt-5.6-sol"},
      {"harness": "claude", "model": "sonnet"}]}
  ],
  "default": [
    {"harness": "codex", "model": "gpt-5.6-terra"},
    {"harness": "codex", "model": "gpt-5.6-sol"}]
}'
run_gate select --kind ship --harness codex --model gpt-5.6-terra --snapshot "$Q_CODEX_EXHAUSTED"
expect_code 1 "$GATE_RC" "sibling shared by every array is exhausted too"
assert_contains "$GATE_OUT" "candidate: codex:gpt-5.6-sol" "the profile every array lists is a candidate"
assert_contains "$GATE_OUT" "status: none" "sonnet is not listed by the default array, so it cannot rescue the lane"
assert_not_contains "$GATE_OUT" "claude:sonnet" "a profile outside the shared set is never a candidate"
pass "a profile listed in several arrays only falls back to profiles every one of them lists"

# --- a declared floor keeps a weak alternate out ---------------------------------------
write_dispatch '{
  "schema_version": 2,
  "rules": [],
  "default": [
    {"harness": "claude", "model": "sonnet"},
    {"harness": "codex", "model": "gpt-5.6-sol", "floor": {"scope": "all_models", "min_percent": 50}},
    {"harness": "grok", "model": "grok-4.6"}]
}'
Q_FLOOR="$TMP_ROOT/q-floor.json"
snapshot "$Q_FLOOR" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|20|through_reset|0.9' \
  'grok|all_models|70|through_reset|0.1'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_FLOOR"
assert_contains "$GATE_OUT" "profile: --harness 'grok' --model 'grok-4.6'" "the alternate below its own floor is skipped"
assert_contains "$GATE_OUT" "profile floor all_models below 50%" "the floor shortfall is printed"
pass "an alternate below its declared floor is not selected"

# --- the current profile's own floor never turns a launch into a refusal ----------------
write_dispatch '{
  "schema_version": 2,
  "rules": [],
  "default": [
    {"harness": "codex", "model": "gpt-5.6-sol", "floor": {"scope": "all_models", "min_percent": 90}},
    {"harness": "claude", "model": "sonnet"}]
}'
run_gate select --kind ship --harness codex --model gpt-5.6-sol --snapshot "$Q_HEALTHY"
assert_contains "$GATE_OUT" "status: keep" "a floor shortfall on the current profile is not exhaustion"
assert_contains "$GATE_OUT" "remaining=80%" "the profile read 80%, below its 90% floor"
pass "only exhaustion, not a floor shortfall, replaces the current profile"

# --- every alternate exhausted -------------------------------------------------------------
write_dispatch "$DISPATCH_TERRA_SOL_SONNET"
Q_BOTH="$TMP_ROOT/q-both.json"
snapshot "$Q_BOTH" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|0|exhausted_now|-1'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_BOTH"
expect_code 1 "$GATE_RC" "every candidate exhausted"
assert_contains "$GATE_OUT" "status: none" "nothing eligible is none"
assert_contains "$GATE_OUT" "no rankable eligible candidate" "the reason says nothing could be ranked"
assert_contains "$GATE_OUT" "candidate: codex:gpt-5.6-sol" "every candidate's evidence is printed"
pass "no eligible alternate is reported as none with every candidate's evidence"

# --- a tie is reported for an attended caller and broken by declared order otherwise ---
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 1 "$GATE_RC" "tie"
assert_contains "$GATE_OUT" "status: none" "equal spendPriority is not resolved by default"
assert_contains "$GATE_OUT" "genuine spendPriority tie" "the tie is named"
assert_contains "$GATE_OUT" "candidate: codex:gpt-5.6-terra" "every tied candidate is listed for the chooser"
assert_contains "$GATE_OUT" "candidate: codex:gpt-5.6-sol" "both tied candidates are listed"
run_gate select --kind ship --harness claude --model sonnet --tie-break declared --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 0 "$GATE_RC" "tie broken by declared order"
assert_contains "$GATE_OUT" "status: replace" "an unattended caller gets a replacement"
assert_contains "$GATE_OUT" "profile: --harness 'codex' --model 'gpt-5.6-terra'" "the first declared tied candidate wins"
assert_contains "$GATE_OUT" "spendPriority tie broken by declared order" "the tie-break is disclosed"
run_gate select --kind ship --harness claude --model sonnet --tie-break sometimes --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 2 "$GATE_RC" "bad tie-break"
pass "a spendPriority tie is reported by default and broken by declared order only on request"

# --- uncertainty stays launchable -----------------------------------------------------------
write_dispatch "$DISPATCH_PAIR"
Q_NO_CLAUDE="$TMP_ROOT/q-no-claude.json"
snapshot "$Q_NO_CLAUDE" 'codex|all_models|80|through_reset|0.5'
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_NO_CLAUDE"
expect_code 0 "$GATE_RC" "provider absent from the snapshot"
assert_contains "$GATE_OUT" "status: keep" "a provider quota-axi does not report is not exhausted"
assert_contains "$GATE_OUT" "eligible, unranked: provider claude not in the quota snapshot" "the uncertainty is disclosed"
run_gate select --kind ship --harness pi --model 'openai-codex/gpt-5.6-sol' --snapshot "$Q_CODEX_EXHAUSTED"
expect_code 0 "$GATE_RC" "harness with no single provider family"
assert_contains "$GATE_OUT" "status: keep" "an undeclared multi-provider harness is never called exhausted"
assert_contains "$GATE_OUT" "eligible, unranked: no provider family for harness pi" "and the missing provider is disclosed"
pass "unmeasured quota keeps the profile launchable and says why"

# --- a declared provider lets a multi-provider harness be measured -----------------------------
write_dispatch '{
  "schema_version": 2,
  "rules": [],
  "default": [
    {"harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex"},
    {"harness": "claude", "model": "sonnet"}]
}'
run_gate select --kind ship --harness pi --model 'openai-codex/gpt-5.6-sol' --snapshot "$Q_CODEX_EXHAUSTED"
assert_contains "$GATE_OUT" "status: replace" "the profile's declared provider binds the pi lane to its quota row"
assert_contains "$GATE_OUT" "profile: --harness 'claude' --model 'sonnet'" "the healthy sibling replaces it"
pass "a declared provider binds a multi-provider harness to its quota row"

# --- live read: a fake quota-axi, and its failures ----------------------------------------------
write_dispatch "$DISPATCH_PAIR"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) echo "quota-axi 0.1.37"; exit 0 ;;
  --json)
    [ -z "${FAKE_QUOTA_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
    cat "$FAKE_QUOTA_FILE"
    ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi"
export FAKE_QUOTA_FILE="$Q_CLAUDE_EXHAUSTED"
PATH="$FAKEBIN:$BASE_PATH" run_gate select --kind ship --harness claude --model sonnet
assert_contains "$GATE_OUT" "status: replace" "without --snapshot the gate takes one quota-axi --json snapshot"
FAKE_QUOTA_FAIL=1 PATH="$FAKEBIN:$BASE_PATH" run_gate select --kind ship --harness claude --model sonnet
expect_code 0 "$GATE_RC" "quota-axi failing"
assert_contains "$GATE_OUT" "status: keep" "an unreadable quota-axi never blocks a launch"
assert_contains "$GATE_OUT" "quota-axi --json failed" "the failure is disclosed"
mkdir -p "$TMP_ROOT/no-quota-bin"
for tool in bash jq dirname cat awk sed tr head; do
  ln -sf "$(command -v "$tool")" "$TMP_ROOT/no-quota-bin/$tool"
done
PATH="$TMP_ROOT/no-quota-bin" run_gate select --kind ship --harness claude --model sonnet
expect_code 0 "$GATE_RC" "quota-axi missing"
assert_contains "$GATE_OUT" "status: keep" "a missing quota-axi never blocks a launch"
assert_contains "$GATE_OUT" "quota-axi is missing" "the absence is disclosed"
FM_USAGE_GATE=off PATH="$FAKEBIN:$BASE_PATH" run_gate select --kind ship --harness claude --model sonnet
assert_contains "$GATE_OUT" "status: keep" "FM_USAGE_GATE=off disables the gate"
assert_contains "$GATE_OUT" "disabled by FM_USAGE_GATE=off" "the switch is named"
pass "the live read, its failures, and the off switch"

# --- configuration and usage errors exit 2 ------------------------------------------------------
printf '{not json' > "$CONFIG/crew-dispatch.json"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 2 "$GATE_RC" "malformed dispatch file with an exhausted profile"
assert_contains "$GATE_ERR" "crew-dispatch.json" "the malformed file is named"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$Q_HEALTHY"
expect_code 0 "$GATE_RC" "malformed dispatch file with a healthy profile"
assert_contains "$GATE_OUT" "status: keep" "a healthy profile is not blocked by a config error it does not need"
write_dispatch "$DISPATCH_PAIR"
printf '{not json' > "$TMP_ROOT/bad-snapshot.json"
run_gate select --kind ship --harness claude --model sonnet --snapshot "$TMP_ROOT/bad-snapshot.json"
expect_code 2 "$GATE_RC" "malformed snapshot"
run_gate select --kind bogus --harness claude --snapshot "$Q_HEALTHY"
expect_code 2 "$GATE_RC" "unknown kind"
run_gate select --kind ship --snapshot "$Q_HEALTHY"
expect_code 2 "$GATE_RC" "no profile"
run_gate frobnicate
expect_code 2 "$GATE_RC" "unknown verb"
pass "malformed input and bad usage exit 2 without selecting around them"

# --- secondmate: alternates are the later lines of config/secondmate-harness -------------------
rm -f "$CONFIG/crew-dispatch.json"
printf '%s\n' '# pin, then ordered alternates' 'claude sonnet high' 'codex gpt-5.6-sol xhigh' 'grok grok-4.6' > "$CONFIG/secondmate-harness"
run_gate select --kind secondmate --config-pin --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 0 "$GATE_RC" "secondmate pin exhausted"
assert_contains "$GATE_OUT" "status: replace" "an exhausted secondmate pin is replaced"
assert_contains "$GATE_OUT" "current: claude:sonnet" "the pin is the first non-comment line"
assert_contains "$GATE_OUT" "profile: --harness 'codex' --model 'gpt-5.6-sol' --effort 'xhigh'" "the alternate carries its own effort"
run_gate select --kind secondmate --config-pin --snapshot "$Q_HEALTHY"
assert_contains "$GATE_OUT" "status: keep" "a healthy pin is kept"
printf '%s\n' 'claude sonnet' > "$CONFIG/secondmate-harness"
run_gate select --kind secondmate --config-pin --snapshot "$Q_CLAUDE_EXHAUSTED"
expect_code 1 "$GATE_RC" "pin without alternates"
assert_contains "$GATE_OUT" "status: none" "a lone pin has no alternate"
printf '%s\n' 'claude sonnet' 'qwen qwen3-coder' 'codex-foundry-luna gpt-5.6-luna' 'codex gpt-5.6-sol' > "$CONFIG/secondmate-harness"
run_gate select --kind secondmate --config-pin --snapshot "$Q_CLAUDE_EXHAUSTED"
assert_contains "$GATE_OUT" "profile: --harness 'codex' --model 'gpt-5.6-sol'" "harnesses that cannot run a secondmate are never alternates"
assert_not_contains "$GATE_OUT" "qwen" "qwen is not a secondmate candidate"
pass "a secondmate pin falls back to the later lines of config/secondmate-harness"

# --- a recorded secondmate profile falls back to every other line ---------------------------------
printf '%s\n' 'claude sonnet' 'codex gpt-5.6-sol' > "$CONFIG/secondmate-harness"
run_gate select --kind secondmate --harness codex --model gpt-5.6-sol --snapshot "$Q_CODEX_EXHAUSTED"
assert_contains "$GATE_OUT" "profile: --harness 'claude' --model 'sonnet'" "a mate already on an alternate can fall back to the pin"
pass "a mate running an alternate can fall back to the pin"

# === sweep: exhausted live lanes ==============================================
# A copy of bin/ whose fm-crew-state.sh and fm-control.sh are recording stubs.
SWEEP_ROOT="$TMP_ROOT/sweep-root"
mkdir -p "$SWEEP_ROOT"
cp -R "$ROOT/bin" "$SWEEP_ROOT/bin"
STUBS="$TMP_ROOT/stubs"
mkdir -p "$STUBS/crew-state" "$STUBS/control-rc"
: > "$STUBS/control.log"
cat > "$SWEEP_ROOT/bin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
if [ -f "$STUBS/crew-state/\$1" ]; then cat "$STUBS/crew-state/\$1"; else echo "state: working · source: status-log · mid-task"; fi
SH
cat > "$SWEEP_ROOT/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUBS/control.log"
rc=0
[ ! -f "$STUBS/control-rc/\$1" ] || rc=\$(cat "$STUBS/control-rc/\$1")
if [ "\$rc" -ne 0 ]; then echo "error: relaunch of \$1 was refused before its agent was touched" >&2; exit "\$rc"; fi
echo "relaunched \$1 harness=ok"
SH
chmod +x "$SWEEP_ROOT/bin/fm-crew-state.sh" "$SWEEP_ROOT/bin/fm-control.sh"

run_sweep() {
  GATE_OUT=$("$SWEEP_ROOT/bin/fm-usage-gate.sh" sweep "$@" 2>"$TMP_ROOT/stderr")
  GATE_RC=$?
  GATE_ERR=$(cat "$TMP_ROOT/stderr")
}

lane() {  # <id> <kind> <harness> <model> [extra meta lines...]
  local id=$1 kind=$2 harness=$3 model=$4
  shift 4
  fm_write_meta "$STATE/$id.meta" "window=firstmate:fm-$id" "kind=$kind" "harness=$harness" "model=$model" "effort=default" "worktree=$TMP_ROOT/wt-$id" "$@"
}

write_dispatch "$DISPATCH_MIXED"
printf '%s\n' 'claude sonnet' 'codex gpt-5.6-terra' > "$CONFIG/secondmate-harness"
lane w1 ship claude sonnet
lane d1 ship claude sonnet
lane p1 scout claude sonnet
lane h1 ship codex gpt-5.6-terra
lane n1 ship pi 'openai-codex/gpt-5.6-sol'
lane s1 secondmate claude sonnet "home=$TMP_ROOT/home-s1"
lane s2 secondmate claude sonnet
lane r1 secondmate claude sonnet remote_host=box
lane i1 ship claude sonnet
lane b1 ship claude sonnet
lane x1 ship claude sonnet
lane e1 ship claude sonnet
printf 'state: done · source: status-log · finished\n' > "$STUBS/crew-state/d1"
printf 'state: parked · source: run-step · awaiting the captain\n' > "$STUBS/crew-state/p1"
printf 'state: unknown · source: none · no current-state source available\n' > "$STUBS/crew-state/i1"
printf 'state: blocked · source: status-log · waiting on a decision\n' > "$STUBS/crew-state/b1"
printf 'state: working · source: run-step · no-mistakes review\n' > "$STUBS/crew-state/x1"
: > "$STUBS/crew-state/e1"
printf 'stopped 2030-01-01T00:00:00Z\n' > "$STATE/s2.stopped"
Q_SWEEP="$TMP_ROOT/q-sweep.json"
snapshot "$Q_SWEEP" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5' \
  'grok|all_models|90|through_reset|0.9'

# --- detect: read-only, exit 1 while an actionable exhausted lane exists -------------
run_sweep --snapshot "$Q_SWEEP"
expect_code 1 "$GATE_RC" "sweep detect with exhausted lanes"
assert_contains "$GATE_OUT" "exhausted: w1 ship claude:sonnet -> grok:grok-4.6" "a working lane on an exhausted model is detected with its replacement"
assert_contains "$GATE_OUT" "exhausted: s1 secondmate claude:sonnet -> codex:gpt-5.6-terra" "a secondmate on an exhausted model is detected with its replacement"
assert_contains "$GATE_OUT" "held: d1 ship claude:sonnet exhausted; state done via status-log" "a finished lane is held, not restarted"
assert_contains "$GATE_OUT" "held: p1 scout claude:sonnet exhausted; state parked via run-step" "a lane parked on a gate is held"
assert_contains "$GATE_OUT" "exhausted: i1 ship claude:sonnet -> grok:grok-4.6" "an idle lane with no declared state, the usual shape of a harness that hit its limit, is actionable"
assert_contains "$GATE_OUT" "held: b1 ship claude:sonnet exhausted; state blocked via status-log" "a blocked lane is held"
assert_contains "$GATE_OUT" "held: x1 ship claude:sonnet exhausted; state working via run-step" "a lane the pipeline owns is held"
assert_contains "$GATE_OUT" "held: e1 ship claude:sonnet exhausted; state unreadable via none" "a lane whose state cannot be read is held"
assert_not_contains "$GATE_OUT" " h1 " "a lane on a healthy model is not reported"
assert_not_contains "$GATE_OUT" " n1 " "a lane whose provider cannot be measured is not reported as exhausted"
assert_not_contains "$GATE_OUT" " s2 " "a stopped secondmate lane is skipped"
assert_not_contains "$GATE_OUT" " r1 " "a remote secondmate is skipped: its quota is measured on its own host"
assert_present "$STUBS/control.log" "the control-plane stub records its calls"
[ ! -s "$STUBS/control.log" ] || fail "detect mode must never call the control plane"
pass "sweep detects exhausted live lanes and touches nothing"

# --- relaunch: replaces exactly the actionable lanes through the control plane ---------
run_sweep --relaunch --snapshot "$Q_SWEEP"
expect_code 0 "$GATE_RC" "sweep relaunch"
assert_contains "$GATE_OUT" "relaunched: w1 on grok:grok-4.6" "the ship lane is relaunched"
assert_contains "$GATE_OUT" "relaunched: s1 on codex:gpt-5.6-terra" "the secondmate lane is relaunched"
assert_grep "w1 relaunch --harness grok --model grok-4.6 --effort default --note" "$STUBS/control.log" "the ship lane goes through fm-control relaunch with the replacement profile and a progress note"
assert_grep "s1 relaunch --harness codex --model gpt-5.6-terra --effort default --note" "$STUBS/control.log" "the secondmate lane goes through fm-control relaunch too"
assert_no_grep "d1 relaunch" "$STUBS/control.log" "a finished lane is never relaunched"
assert_no_grep "p1 relaunch" "$STUBS/control.log" "a parked lane is never relaunched"
assert_grep "i1 relaunch --harness grok --model grok-4.6" "$STUBS/control.log" "an idle exhausted lane is relaunched"
assert_no_grep "b1 relaunch" "$STUBS/control.log" "a blocked lane is never relaunched"
assert_no_grep "x1 relaunch" "$STUBS/control.log" "a pipeline-owned lane is never relaunched"
assert_no_grep "e1 relaunch" "$STUBS/control.log" "a lane whose state cannot be read is never relaunched"
assert_no_grep "h1 relaunch" "$STUBS/control.log" "a healthy lane is never relaunched"
assert_no_grep "s2 relaunch" "$STUBS/control.log" "a stopped lane is never relaunched"
assert_no_grep "r1 relaunch" "$STUBS/control.log" "a remote lane is never relaunched"
assert_contains "$(grep '^w1 ' "$STUBS/control.log")" "claude:sonnet" "the note names the exhausted profile"
assert_contains "$GATE_OUT" "summary:" "the sweep ends with a summary"
pass "sweep --relaunch replaces exactly the actionable exhausted lanes through fm-control"

# --- a refused relaunch and an unresolvable lane are reported, never hidden -------------
: > "$STUBS/control.log"
printf '2\n' > "$STUBS/control-rc/w1"
lane n2 ship claude sonnet
write_dispatch "$DISPATCH_PAIR"
rm -f "$CONFIG/secondmate-harness"
Q_PAIR_BOTH="$TMP_ROOT/q-pair-both.json"
snapshot "$Q_PAIR_BOTH" \
  'claude|all_models|0|exhausted_now|-1' \
  'codex|all_models|80|through_reset|0.5'
run_sweep --relaunch --snapshot "$Q_PAIR_BOTH"
expect_code 3 "$GATE_RC" "sweep with a refused relaunch"
assert_contains "$GATE_OUT" "unreached: w1: " "a control-plane refusal is reported with its reason"
assert_contains "$GATE_OUT" "refused before its agent was touched" "the refusal's own words are carried"
assert_contains "$GATE_OUT" "unresolved: s1 secondmate claude:sonnet: no alternate profile is declared" "a secondmate with no declared alternate is reported unresolved"
pass "a refused relaunch and a lane with no alternate exit 3 with their reasons"

# --- quota unavailable is its own exit, not a clean sweep ---------------------------------------
PATH="$TMP_ROOT/no-quota-bin" run_sweep
expect_code 4 "$GATE_RC" "sweep without quota-axi"
assert_contains "$GATE_OUT" "quota unavailable: quota-axi is missing" "an unreadable quota source is not reported as healthy"
FM_USAGE_GATE=off PATH="$FAKEBIN:$BASE_PATH" run_sweep
expect_code 0 "$GATE_RC" "sweep disabled"
assert_contains "$GATE_OUT" "disabled by FM_USAGE_GATE=off" "the off switch is named"
pass "an unavailable quota source is exit 4, and the off switch is a clean no-op"

# --- the watcher runs the sweep itself, with no operator or quota wake ------------
WATCH_HOME="$TMP_ROOT/watch-home"
mkdir -p "$WATCH_HOME/state" "$WATCH_HOME/data" "$WATCH_HOME/config" "$WATCH_HOME/projects"
printf '# Seeded Firstmate home\n' > "$WATCH_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$WATCH_HOME/data/backlog.md"
printf '%s\n' "$DISPATCH_PAIR" > "$WATCH_HOME/config/crew-dispatch.json"
fm_write_meta "$WATCH_HOME/state/w9.meta" "window=firstmate:fm-w9" "kind=ship" "harness=claude" "model=sonnet" "effort=default" "worktree=$TMP_ROOT/wt-w9"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
: > "$STUBS/control.log"
export FAKE_QUOTA_FILE="$Q_PAIR_BOTH"
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$WATCH_HOME" FM_ROOT_OVERRIDE="$SWEEP_ROOT" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  FM_HOME_SUMMARY_INTERVAL=9999999 \
  "$SWEEP_ROOT/bin/fm-watch.sh" > "$TMP_ROOT/watch.out" 2> "$TMP_ROOT/watch.err" &
WATCH_PID=$!
i=0
until grep -q '^w9 relaunch' "$STUBS/control.log" 2>/dev/null; do
  [ "$i" -lt 150 ] || { kill "$WATCH_PID" 2>/dev/null; fail "the watcher did not relaunch an exhausted lane on its own: $(cat "$WATCH_HOME/state/.usage-sweep.log" "$TMP_ROOT/watch.err" 2>/dev/null)"; }
  sleep 0.1
  i=$((i + 1))
done
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
assert_grep "w9 relaunch --harness codex --model gpt-5.6-terra" "$STUBS/control.log" "the watcher's sweep moves the lane onto the declared alternate"
assert_present "$WATCH_HOME/state/.usage-sweep.log" "the watcher keeps the sweep's last report"
pass "the watcher sweeps exhausted lanes and relaunches them without being asked"

# --- a sweep that cannot restart a lane wakes the watcher's supervisor -----------
STUCK_HOME="$TMP_ROOT/stuck-home"
mkdir -p "$STUCK_HOME/state" "$STUCK_HOME/data" "$STUCK_HOME/config" "$STUCK_HOME/projects"
printf '# Seeded Firstmate home\n' > "$STUCK_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$STUCK_HOME/data/backlog.md"
printf '%s\n' '{"schema_version":2,"rules":[],"default":[{"harness":"claude","model":"sonnet"}]}' > "$STUCK_HOME/config/crew-dispatch.json"
fm_write_meta "$STUCK_HOME/state/u9.meta" "window=firstmate:fm-u9" "kind=ship" "harness=claude" "model=sonnet" "effort=default" "worktree=$TMP_ROOT/wt-u9"
PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$STUCK_HOME" FM_ROOT_OVERRIDE="$SWEEP_ROOT" \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=9999999 FM_HEARTBEAT=9999999 \
  FM_HOME_SUMMARY_INTERVAL=9999999 \
  "$SWEEP_ROOT/bin/fm-watch.sh" > "$TMP_ROOT/stuck-watch.out" 2> "$TMP_ROOT/stuck-watch.err" &
WATCH_PID=$!
i=0
while kill -0 "$WATCH_PID" 2>/dev/null; do
  [ "$i" -lt 150 ] || { kill "$WATCH_PID" 2>/dev/null; fail "the watcher never surfaced a sweep that could not restart a lane: $(cat "$STUCK_HOME/state/.usage-sweep.log" "$TMP_ROOT/stuck-watch.err" 2>/dev/null)"; }
  sleep 0.1
  i=$((i + 1))
done
wait "$WATCH_PID" 2>/dev/null || true
assert_contains "$(cat "$TMP_ROOT/stuck-watch.out")" "check: usage-sweep: unresolved: u9 ship claude:sonnet: no alternate profile is declared" "the unresolved lane wakes the supervisor with its reason"
assert_no_grep "^u9 relaunch" "$STUBS/control.log" "a lane with no eligible alternate is never relaunched"
pass "a watcher sweep that leaves a lane unresolved raises a usage-sweep wake"

echo "# all fm-usage-gate tests passed"


