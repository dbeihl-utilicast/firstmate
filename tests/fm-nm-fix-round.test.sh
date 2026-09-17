#!/usr/bin/env bash
# Behavior tests for firstmate's per-step no-mistakes fix-round cap.
#
# The no-mistakes product does not expose a durable per-step round count
# across worker re-responds (axi status is TOON; active_steps.round is only
# a per-respond "auto-fix N/3" display). Today's worker polling/reattach
# loop answers fix at every parked gate with no bound. These tests prove
# that unbounded loop goes red, then that bin/fm-nm-fix-round.sh stops a
# fourth silent fix.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-fix-round)
FIX_ROUND="$ROOT/bin/fm-nm-fix-round.sh"

toon_gate() {  # <run-id> <step> <finding-id>
  cat <<EOF
run:
  id: "$1"
  branch: fm/feat
  status: awaiting_approval
  head: abc1234
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    $3,warning,a.go,,auto-fix,ignored error
gate: $2
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  $2,fix_review,1,0
  test,pending,0,0
EOF
}

toon_fixing() {  # <run-id> <step> <round-label>
  cat <<EOF
run:
  id: "$1"
  branch: fm/feat
  status: fixing
  head: abc1234
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    $2,12m3s,8s,44121,"$3"
EOF
}

toon_running() {  # <run-id> <step>
  cat <<EOF
run:
  id: "$1"
  branch: fm/feat
  status: running
  head: abc1234
  pr: ""
  findings: none
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  $2,running,0,0
  test,pending,0,0
EOF
}

new_home() {  # <name> -> home dir with state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

observe() {  # <home> <task> <status-file>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$FIX_ROUND" observe --task "$2" --status-file "$3"
}

guard() {  # <home> <task> <action> <status-file>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$FIX_ROUND" guard --task "$2" --action "$3" --status-file "$4"
}

verdict_of() {  # <observe-output>
  printf '%s\n' "$1" | sed -n 's/^verdict=//p' | head -1
}

count_of() {  # <observe-output>
  printf '%s\n' "$1" | sed -n 's/^count=//p' | head -1
}

phase_of() {  # <observe-output>
  printf '%s\n' "$1" | sed -n 's/^phase=//p' | head -1
}

# Fake no-mistakes whose review step reports a fresh auto-fixable finding
# after every fix. axi status serves the current snapshot; respond --action
# fix records the call and moves the run into fixing; the next status poll
# that sees fixing completes the round and returns to a new gate. This is
# the unbounded polling/reattach shape the worker brief used to describe.
install_unbounded_fake_nm() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb" "$dir/nm"
  printf 'gate\n' > "$dir/nm/phase"
  printf '0\n' > "$dir/nm/fixes"
  : > "$dir/nm/calls"
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
ROOT="$dir/nm"
log_call() { printf '%s\n' "\$*" >> "\$ROOT/calls"; }
phase=\$(cat "\$ROOT/phase")
fixes=\$(cat "\$ROOT/fixes")
case "\${1:-}" in
  axi)
    shift
    case "\${1:-}" in
      status)
        log_call "axi status"
        if [ "\$phase" = fixing ]; then
          cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat
  status: fixing
  head: abc1234
  pr: ""
  findings: none
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m3s,8s,44121,"auto-fix 1/3"
EOF
          printf 'gate\n' > "\$ROOT/phase"
          exit 0
        fi
        cat <<EOF
run:
  id: "01RUN"
  branch: fm/feat
  status: awaiting_approval
  head: abc1234
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    f\$fixes,warning,a.go,,auto-fix,new finding after auto-fix
gate: review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
        exit 0
        ;;
      respond)
        log_call "\$*"
        action=none
        while [ "\$#" -gt 0 ]; do
          case "\$1" in
            --action) action=\$2; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ "\$action" = fix ]; then
          fixes=\$((fixes + 1))
          printf '%s\n' "\$fixes" > "\$ROOT/fixes"
          printf 'fixing\n' > "\$ROOT/phase"
        fi
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

status_has_gate() {  # <toon>
  printf '%s\n' "$1" | grep -Eq '^[[:space:]]*gate:|^[[:space:]]*status:[[:space:]]*"?(awaiting_approval|fix_review)"?'
}

# Today's polling/reattach logic: whenever a step is parked at a gate,
# answer fix and keep going. No firstmate counter, no cap.
uncapped_reattach_loop() {  # <fakebin> <worktree> <max-fixes>
  local fakebin=$1 wt=$2 max=$3 n=0 toon
  while [ "$n" -lt "$max" ]; do
    toon=$(PATH="$fakebin:$PATH" no-mistakes axi status) || fail "uncapped axi status failed"
    if status_has_gate "$toon"; then
      PATH="$fakebin:$PATH" no-mistakes axi respond --action fix --step review \
        || fail "uncapped axi respond fix failed"
      n=$((n + 1))
    fi
  done
}

# Firstmate's capped polling/reattach path: observe every status poll, and
# never send a fourth silent fix on the same step.
capped_reattach_loop() {  # <home> <task> <fakebin> <worktree> <max-iters>
  local home=$1 task=$2 fakebin=$3 wt=$4 max=$5 i=0 out rc
  while [ "$i" -lt "$max" ]; do
    i=$((i + 1))
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$FIX_ROUND" observe --task "$task" --worktree "$wt") \
      || fail "capped observe failed: $out"
    case "$(verdict_of "$out")" in
      cap) printf '%s\n' "$out"; return 0 ;;
      allow-fix)
        PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
          "$FIX_ROUND" guard --task "$task" --action fix --worktree "$wt" >/dev/null
        rc=$?
        [ "$rc" -eq 0 ] || fail "capped guard fix refused before cap (exit $rc)"
        PATH="$fakebin:$PATH" no-mistakes axi respond --action fix --step review \
          || fail "capped axi respond fix failed"
        ;;
      none) ;;
      *) fail "unexpected verdict in: $out" ;;
    esac
  done
  fail "capped loop never reached the cap after $max polls"
}

test_scripts_parse() {
  local out rc
  out=$(bash -n "$ROOT/bin/fm-nm-fix-round.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-nm-fix-round.sh (got: $out)"
  out=$(bash -n "$ROOT/bin/fm-nm-fix-round-lib.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-nm-fix-round-lib.sh (got: $out)"
  pass "fix-round scripts parse"
}

# Named red test: a step that keeps reporting a new finding after every
# auto-fix is chained indefinitely by today's poll/reattach-and-fix loop.
test_unbounded_fix_rounds_keep_chaining_without_the_cap() {
  local d fb calls
  d=$(new_home red-unbounded)
  mkdir -p "$d/wt"
  fb=$(install_unbounded_fake_nm "$d")
  uncapped_reattach_loop "$fb" "$d/wt" 6
  calls=$(grep -c -- '--action fix' "$d/nm/calls" || true)
  [ "$calls" -eq 6 ] \
    || fail "uncapped reattach should keep sending fix with no bound (got $calls)"
  [ "$(cat "$d/nm/fixes")" -eq 6 ] \
    || fail "fake should have accepted six fix rounds, got $(cat "$d/nm/fixes")"
  pass "without the cap, polling/reattach keeps chaining fix rounds"
}

test_cap_stops_a_fourth_silent_fix() {
  local d fb out calls rc
  d=$(new_home green-cap)
  mkdir -p "$d/wt"
  fb=$(install_unbounded_fake_nm "$d")
  out=$(capped_reattach_loop "$d" feat "$fb" "$d/wt" 20)
  assert_equals cap "$(verdict_of "$out")" "capped loop should stop with verdict=cap"
  assert_equals 3 "$(count_of "$out")" "cap should fire at count 3"
  assert_contains "$out" "next=approve-or-skip-or-escalate" "cap should name the allowed next actions"
  assert_contains "$out" "escalation_key=nm-01RUN-review-fix-cap" "cap should name the escalation key"
  calls=$(grep -c -- '--action fix' "$d/nm/calls" || true)
  [ "$calls" -eq 3 ] \
    || fail "capped path should send exactly three fix responses, got $calls"
  PATH="$fb:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$FIX_ROUND" guard --task feat --action fix --worktree "$d/wt" >/dev/null 2>/dev/null
  rc=$?
  expect_code 3 "$rc" "a fourth silent fix must be refused"
  PATH="$fb:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$FIX_ROUND" guard --task feat --action approve --worktree "$d/wt" >/dev/null 2>/dev/null
  rc=$?
  expect_code 0 "$rc" "approve remains allowed at the cap"
  PATH="$fb:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" \
    "$FIX_ROUND" guard --task feat --action skip --worktree "$d/wt" >/dev/null 2>/dev/null
  rc=$?
  expect_code 0 "$rc" "skip remains allowed at the cap"
  pass "the cap refuses a fourth silent fix and still allows approve or skip"
}

test_observe_counts_fixing_then_rereview() {
  local d gate1 fixing rereview gate2 out
  d=$(new_home observe-cycle)
  gate1="$d/gate1.toon"; fixing="$d/fixing.toon"; rereview="$d/running.toon"; gate2="$d/gate2.toon"
  toon_gate 01RUN review f0 > "$gate1"
  toon_fixing 01RUN review "auto-fix 1/3" > "$fixing"
  toon_running 01RUN review > "$rereview"
  toon_gate 01RUN review f1 > "$gate2"
  out=$(observe "$d" feat "$gate1")
  assert_equals allow-fix "$(verdict_of "$out")" "initial gate allows fix"
  assert_equals 0 "$(count_of "$out")" "initial gate is round 0"
  out=$(observe "$d" feat "$fixing")
  assert_equals none "$(verdict_of "$out")" "fixing is not a gate"
  assert_equals fixing "$(phase_of "$out")" "fixing snapshot is phase=fixing"
  assert_equals 0 "$(count_of "$out")" "count does not increment while still fixing"
  out=$(observe "$d" feat "$rereview")
  assert_equals 1 "$(count_of "$out")" "fixing -> re-review increments the counter"
  assert_equals none "$(verdict_of "$out")" "re-review running is not a gate"
  out=$(observe "$d" feat "$gate2")
  assert_equals 1 "$(count_of "$out")" "return to the same gate does not double-count"
  assert_equals allow-fix "$(verdict_of "$out")" "count 1 still allows fix"
  out=$(observe "$d" feat "$gate2")
  assert_equals 1 "$(count_of "$out")" "observing the same gate twice is idempotent"
  pass "observe increments only on fixing -> re-review and is idempotent"
}

test_independent_steps_and_product_round_string() {
  local d review_gate test_gate review_fix test_fix out
  d=$(new_home independent-steps)
  review_gate="$d/review-gate.toon"
  review_fix="$d/review-fix.toon"
  test_gate="$d/test-gate.toon"
  test_fix="$d/test-fix.toon"
  toon_gate 01RUN review r0 > "$review_gate"
  toon_fixing 01RUN review "auto-fix 3/3" > "$review_fix"
  toon_gate 01RUN test t0 > "$test_gate"
  toon_fixing 01RUN test "auto-fix 3/3" > "$test_fix"
  observe "$d" feat "$review_gate" >/dev/null
  observe "$d" feat "$review_fix" >/dev/null
  out=$(observe "$d" feat "$review_gate")
  assert_equals 1 "$(count_of "$out")" "review counted one firstmate round"
  assert_equals allow-fix "$(verdict_of "$out")" "no-mistakes auto-fix 3/3 is not firstmate's cap"
  observe "$d" feat "$test_gate" >/dev/null
  observe "$d" feat "$test_fix" >/dev/null
  out=$(observe "$d" feat "$test_gate")
  assert_equals 1 "$(count_of "$out")" "test has its own counter"
  assert_equals allow-fix "$(verdict_of "$out")" "test is still below the cap"
  out=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" "$FIX_ROUND" count --task feat --run 01RUN --step review)
  assert_equals 1 "$(printf '%s' "$out" | tr -d '\n')" "count subcommand reads the review row"
  pass "steps are independent and the product round string is not the cap"
}

test_three_cycles_reach_cap_on_status_files() {
  local d i gate fixing out rc
  d=$(new_home three-cycles)
  gate="$d/gate.toon"
  fixing="$d/fixing.toon"
  toon_gate 01RUN review f0 > "$gate"
  toon_fixing 01RUN review "auto-fix 1/3" > "$fixing"
  i=0
  while [ "$i" -lt 3 ]; do
    out=$(observe "$d" feat "$gate")
    assert_equals allow-fix "$(verdict_of "$out")" "cycle $i should still allow fix"
    guard "$d" feat fix "$gate" >/dev/null
    rc=$?
    expect_code 0 "$rc" "guard fix allowed on cycle $i"
    observe "$d" feat "$fixing" >/dev/null
    i=$((i + 1))
  done
  out=$(observe "$d" feat "$gate")
  assert_equals cap "$(verdict_of "$out")" "third return to the gate is the cap"
  assert_equals 3 "$(count_of "$out")" "count is 3 at cap"
  guard "$d" feat fix "$gate" >/dev/null 2>/dev/null
  rc=$?
  expect_code 3 "$rc" "guard refuses the fourth fix"
  pass "three fixing-to-gate cycles reach the cap"
}

test_scripts_parse
test_unbounded_fix_rounds_keep_chaining_without_the_cap
test_cap_stops_a_fourth_silent_fix
test_observe_counts_fixing_then_rereview
test_independent_steps_and_product_round_string
test_three_cycles_reach_cap_on_status_files
