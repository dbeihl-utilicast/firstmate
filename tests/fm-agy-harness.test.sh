#!/usr/bin/env bash
# Contract tests for the verified agy crewmate/scout adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_fakebin() {  # <case-dir>
  local case_dir=$1 fakebin
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)
screen() {
  case "$state" in
    trust)
      printf 'Do you trust the contents of this project?\n'
      if [ "${FM_FAKE_AGY_TRUST:-yes}" = yes ]; then printf 'Yes, I trust this folder\n'; else printf 'No, exit\n'; fi
      ;;
    busy) printf 'esc to cancel  Gemini 3.8 Flash · low · 1 task(s)\n' ;;
    *) printf 'zsh\n$ \n' ;;
  esac
}
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH" ;;
      *'#{pane_current_command}'*) printf 'agy\n' ;;
      *'#{cursor_y}'*) printf '1\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0 ;;
  capture-pane) screen; exit 0 ;;
  has-session|new-session|new-window|list-windows) exit 0 ;;
  kill-window) printf 'kill-window\n' >> "$FM_FAKE_TMUX_LOG"; exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      printf '%s\n' "$literal" >> "$FM_FAKE_TMUX_LOG"
      case "$literal" in *' agy --dangerously-skip-permissions '*) printf 'launch\n' > "$FM_FAKE_AGY_STATE" ;; esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launch) printf 'trust\n' > "$FM_FAKE_AGY_STATE" ;;
          trust) printf 'busy\n' > "$FM_FAKE_AGY_STATE"; printf 'trust-enter\n' >> "$FM_FAKE_TMUX_LOG" ;;
        esac
        ;;
    esac
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh agy
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task

## Captain's intent

Exercise agy dispatch.

## Firstmate spec

Exercise the verified adapter gate.
EOF
  printf 'agy\n' > "$home/config/crew-harness"
  fm_git_worktree "$project" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/tmux.log"
  : > "$case_dir/agy.state"
  printf '%s\n' "$case_dir|$home|$project|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <id> [fm-spawn args]
  local id=$1
  shift
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_AGY_STATE="$CASE_DIR/agy.state" FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" \
    FM_AGY_READY_POLLS=3 FM_AGY_POLL_INTERVAL=0 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --harness agy --mode no-mistakes --yolo off "$@" 2>&1
}

test_ancestry_is_exact() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/ancestry")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'comm='*) printf '%s\n' "${FM_FAKE_COMM:-agy}" ;;
  *'ppid='*) printf '1\n' ;;
esac
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_FAKE_COMM=agy PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$out" = agy ] || fail "exact agy process must detect agy, got '$out'"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI FM_FAKE_COMM=agylike PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$out" != agy ] || fail "agylike must not claim agy"
  pass "fm-harness.sh: agy ancestry is exact and rejects a short-token decoy"
}

test_busy_signature_has_a_negative_direction() {
  printf 'esc to cancel  Gemini 3.8 Flash · low · 1 task(s)\n' | fm_busy_agy_tail_busy \
    || fail "agy busy footer must classify busy"
  if printf 'Gemini 3.8 Flash · low\n' | fm_busy_agy_tail_busy; then
    fail "agy idle footer must not classify busy"
  fi
  [ "$(fm_busy_classify tmux target agy task "$TMP_ROOT" 'Gemini 3.8 Flash · low')" = 'idle agy-regex' ] \
    || fail "a capture without agy's busy footer must classify idle"
  pass "fm-busy-lib.sh: agy footer proves both busy and idle"
}

test_control_and_scope() {
  [ "$(fm_control_harness_family agy)" = agy ] || fail "exact agy must resolve its recorded runtime"
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy interrupt must use one Escape"
  [ "$(fm_control_exit_command agy)" = /quit ] || fail "agy must exit on /quit"
  fm_control_harness_supports_kind agy ship || fail "agy must support ship work"
  fm_control_harness_supports_kind agy scout || fail "agy must support scout work"
  fm_control_harness_supports_kind agy secondmate && fail "agy must refuse secondmate work"
  pass "fm-control-lib.sh: agy is crew/scout-only with its live interrupt and exit controls"
}

test_spawn_trusts_only_the_verified_dialog_and_starts_a_turn() {
  local id="agy-ok-$$" rec out rc launch meta
  rec=$(make_case success "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --model gemini-3.8-flash-low --effort low); rc=$?
  expect_code 0 "$rc" "agy spawn should pass the trust-and-busy gate"$'\n'"$out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  launch=$(cat "$CASE_DIR/tmux.log")
  assert_contains "$launch" 'agy --dangerously-skip-permissions --mode accept-edits' "agy launch missed its approved per-worker flags"
  assert_contains "$launch" "--model 'gemini-3.8-flash-low'" "agy launch omitted its explicit model"
  assert_contains "$launch" "--effort 'low'" "agy launch omitted its explicit effort"
  assert_contains "$launch" '--prompt-interactive=' "agy launch did not submit its brief interactively"
  assert_not_contains "$launch" 'proceed-in-sandbox' "agy launch changed a persistent sandbox posture"
  assert_not_contains "$launch" ' --sandbox' "agy launch entered sandbox mode"
  [ "$(grep -c '^trust-enter$' "$CASE_DIR/tmux.log")" -eq 1 ] \
    || fail "agy must accept exactly one verified trust prompt"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=gemini-3.8-flash-low' "$meta" "agy metadata lost the model"
  assert_grep 'effort=low' "$meta" "agy metadata lost the effort"
  pass "fm-spawn.sh: agy accepts only its trust dialog and proves the launch brief became busy"
}

test_spawn_rejects_an_unverified_trust_screen() {
  local id="agy-trust-no-$$" rec out rc
  rec=$(make_case trust-no "$id")
  read_case "$rec"
  out=$(FM_FAKE_AGY_TRUST=no run_spawn "$id"); rc=$?
  [ "$rc" -ne 0 ] || fail "agy spawn must refuse a trust screen without its exact affirmative action"
  assert_contains "$out" 'did not accept the launch brief' "agy trust refusal did not identify the unproven gate"
  assert_contains "$(cat "$CASE_DIR/tmux.log")" 'kill-window' "agy trust failure must retire its unpublished endpoint"
  pass "fm-spawn.sh: agy never presses Enter on an unverified trust screen"
}

test_unsupported_effort_is_recorded_but_omitted() {
  local id="agy-xhigh-$$" rec out rc launch
  rec=$(make_case xhigh "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --effort xhigh); rc=$?
  expect_code 0 "$rc" "agy xhigh request should remain launchable"$'\n'"$out"
  launch=$(cat "$CASE_DIR/tmux.log")
  assert_not_contains "$launch" "--effort 'xhigh'" "agy must omit its unsupported xhigh effort"
  assert_grep 'effort=xhigh' "$HOME_DIR/state/$id.meta" "agy metadata must preserve the requested effort"
  pass "fm-spawn.sh: agy records unsupported effort but does not pass it to the CLI"
}

test_ancestry_is_exact
test_busy_signature_has_a_negative_direction
test_control_and_scope
test_spawn_trusts_only_the_verified_dialog_and_starts_a_turn
test_spawn_rejects_an_unverified_trust_screen
test_unsupported_effort_is_recorded_but_omitted
