#!/usr/bin/env bash
# Behavior tests for Grok-harness hook authentication, teardown cleanup, and session-lock holder detection.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-grok-harness)

make_grok_probe() {
  cat > "$1/grok" <<'SH'
#!/bin/sh
printf '%s\n' "$GROK_HOME" > "$0.home"
printf '%s\n' "${FM_GROK_RAW_SENTINEL:-}" > "$0.sentinel"
SH
  chmod +x "$1/grok"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin grok_home id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
  make_grok_probe "$fakebin"
  grok_home="$case_dir/grok"
  id="grok-$name-x1"
  mkdir -p "$grok_home"
  fm_test_spawn_home "$home"
  fm_test_spawn_brief "$home" "$id" brief
  fm_git_worktree "$proj" "$wt" "fm/$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$grok_home|$id"
}

run_grok_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 grok_home=$5 id=$6
  GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" \
    "$id" "$proj" grok --mode no-mistakes --yolo off || return
  (cd "$wt" && env -i HOME="$home/user-home" GROK_HOME="$grok_home" \
    PATH="$fakebin:$PATH" /bin/sh "$home/launch.log")
}

test_grok_hook_requires_registered_token() {
  local rec case_dir home proj wt fakebin grok_home id out status hook token target evil evil_target
  rec=$(make_spawn_case hook-auth)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed"
  assert_contains "$out" "spawned $id harness=grok" "grok spawn did not report success"

  hook="$grok_home/hooks/fm-turn-end.sh"
  assert_present "$hook" "grok hook script was not installed"
  assert_grep 'token=' "$wt/.fm-grok-turnend" "grok pointer did not contain a token"
  target="$home/state/$id.turn-ended"
  assert_no_grep "$target" "$wt/.fm-grok-turnend" "grok pointer exposed the turn-end path"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")
  assert_present "$grok_home/hooks/fm-turn-end.d/$token" "grok auth registry entry was not written"

  evil="$case_dir/evil"
  evil_target="$case_dir/evil-target.turn-ended"
  mkdir -p "$evil"
  printf '%s\n' "$evil_target" > "$evil/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$evil" bash "$hook"
  assert_absent "$evil_target" "old-style grok pointer touched an arbitrary target"

  {
    printf '%s\n' 'ignored'
    printf 'token=%s\n' "$token"
  } > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_absent "$target" "grok pointer accepted token outside the first line"

  printf 'token=%s\n' "$token" > "$wt/.fm-grok-turnend"
  GROK_WORKSPACE_ROOT="$wt" bash "$hook"
  assert_present "$target" "registered grok pointer did not touch the task turn-end file"
  pass "grok global hook requires a firstmate registry token"
}

test_grok_teardown_removes_pointer_and_token() {
  local rec case_dir home proj wt fakebin grok_home id out status token
  rec=$(make_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  out=$(run_grok_spawn "$home" "$proj" "$wt" "$fakebin" "$grok_home" "$id")
  status=$?
  expect_code 0 "$status" "grok spawn should succeed before teardown"
  token=$(sed -n 's/^token=//p' "$wt/.fm-grok-turnend")

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    GROK_HOME="$grok_home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" --force >/dev/null 2>&1 \
    || fail "grok teardown failed"

  assert_absent "$wt/.fm-grok-turnend" "grok pointer survived teardown"
  assert_absent "$grok_home/hooks/fm-turn-end.d/$token" "grok auth token survived teardown"
  assert_absent "$home/state/$id.grok-turnend-token" "grok state token survived teardown"
  pass "grok teardown removes pointer and token state"
}

# assert_grok_trusted <grok-home> <path> <msg>: the store has a trusted=true
# block for <path>, immediately followed by its own trusted/decided_at lines.
assert_grok_trusted() {
  awk -v want="[folders.\"$2\"]" '$0==want{f=1;next} f&&/trusted[ \t]*=[ \t]*true/{found=1} f&&/^\[/{f=0}
    END{exit found?0:1}' "$1/trusted_folders.toml" 2>/dev/null || fail "$3"
}

test_grok_spawn_pretrusts_the_project_not_the_worktree() {
  local kind rec case_dir home proj wt fakebin grok_home id out spawning
  for kind in plain linked; do
    rec=$(make_spawn_case "trust-project-$kind")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    spawning=$proj
    if [ "$kind" = linked ]; then
      spawning="$case_dir/spawning-root"
      git -C "$proj" worktree add --quiet -b spawning "$spawning"
    fi
    out=$(run_grok_spawn "$home" "$spawning" "$wt" "$fakebin" "$grok_home" "$id")
    expect_code 0 $? "grok spawn from a $kind root should succeed: $out"
    assert_grok_trusted "$grok_home" "$proj" \
      "grok spawn did not pre-register trust for the project's primary checkout"
    assert_no_grep "\"$wt\"" "$grok_home/trusted_folders.toml" \
      "grok spawn registered the ephemeral worktree instead of relying on grok's own inheritance"
    if [ "$kind" = linked ]; then
      assert_no_grep "\"$spawning\"" "$grok_home/trusted_folders.toml" \
        "grok spawn registered the linked spawning root directly"
    fi
    assert_present "$fakebin/grok.home" "the registered worker did not execute"
    pass "grok spawn from a $kind root pre-trusts only the primary checkout"
  done
}

test_grok_secondmate_spawn_pretrusts_its_primary() {
  local kind case_dir home mate primary fakebin grok_home id out
  for kind in plain linked; do
    case_dir="$TMP_ROOT/secondmate-trust-$kind"
    home="$case_dir/home"
    mate="$case_dir/mate-home"
    primary=$mate
    fakebin=$(make_spawn_fakebin "$case_dir/fake" gh-axi gh)
    make_grok_probe "$fakebin"
    grok_home="$case_dir/grok"
    id="grok-secondmate-$kind-x1"
    mkdir -p "$grok_home"
    fm_test_spawn_home "$home" grok
    if [ "$kind" = linked ]; then
      primary="$case_dir/primary"
      fm_git_worktree "$primary" "$mate" mate
    else
      fm_git_init_commit "$mate"
    fi
    mkdir -p "$mate/bin" "$mate/data"
    printf '# Firstmate\n' > "$mate/AGENTS.md"
    git -C "$mate" add AGENTS.md
    git -C "$mate" -c user.email=t@t -c user.name=t commit --quiet -m agents
    printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
    printf 'charter for %s\n' "$id" > "$mate/data/charter.md"
    printf '[folders."%s"]\ntrusted = false\n' "$primary" > "$grok_home/trusted_folders.toml"
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
      fm_test_run_spawn "$home" "$mate" "$fakebin" "$id" "$mate" --secondmate)
    expect_code 1 $? "an untrusted secondmate must refuse dispatch: $out"
    assert_absent "$home/state/$id.meta" "a refused secondmate published a task record"
    [ ! -s "$home/launch.log" ] || fail "a refused secondmate delivered a worker command"
    assert_not_contains "$out" 'spawned ' "a refused secondmate reported a successful spawn"
    : > "$grok_home/trusted_folders.toml"
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
      fm_test_run_spawn "$home" "$mate" "$fakebin" "$id" "$mate" --secondmate)
    expect_code 0 $? "grok secondmate spawn should succeed: $out"
    assert_grok_trusted "$grok_home" "$primary" "secondmate trust was not registered synchronously"
    out=$(cd "$mate" && env -i HOME="$home/user-home" GROK_HOME="$grok_home" \
      PATH="$fakebin:$PATH" /bin/sh "$home/launch.log")
    expect_code 0 $? "grok secondmate launch should succeed: $out"
    assert_grok_trusted "$grok_home" "$primary" \
      "grok secondmate launch did not pre-register trust for its primary checkout"
    if [ "$kind" = linked ]; then
      assert_no_grep "\"$mate\"" "$grok_home/trusted_folders.toml" "a linked secondmate was trusted directly"
    fi
    assert_present "$fakebin/grok.home" "the registered secondmate did not execute"
    pass "grok secondmate with a $kind home pre-trusts its primary checkout"
  done
}

test_grok_registration_uses_the_filtered_launch_environment() {
  local policy rec case_dir home proj wt fakebin grok_home id pane_home selected out refused_id
  for policy in absent allowed excluded; do
    rec=$(make_spawn_case "launch-store-$policy")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    case "$policy" in
      allowed) printf 'GROK_HOME\n' > "$home/config/launch-env-allowlist" ;;
      excluded) : > "$home/config/launch-env-allowlist" ;;
    esac
    pane_home="$case_dir/pane-home"
    mkdir -p "$pane_home" "$case_dir/pane grok"
    ln -s "$case_dir/pane grok" "$case_dir/grok-alias"
    selected="$case_dir/pane grok"
    [ "$policy" != excluded ] || selected="$pane_home/.grok"
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
      FM_TEST_PANE_HOME="$pane_home" FM_TEST_PANE_GROK_HOME="$case_dir/grok-alias" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" grok --mode no-mistakes --yolo off)
    expect_code 0 $? "grok spawn with $policy launch policy should succeed: $out"
    assert_absent "$grok_home/trusted_folders.toml" "spawn registered trust in the invoking process's store"
    assert_grok_trusted "$selected" "$proj" "the worker's store was not registered synchronously"
    out=$(cd "$wt" && env -i HOME="$pane_home" GROK_HOME="$case_dir/grok-alias" \
      PATH="$fakebin:$PATH" /bin/sh "$home/launch.log")
    expect_code 0 $? "grok launch with $policy launch policy should succeed: $out"
    [ "$(cat "$fakebin/grok.home")" = "$selected" ] || fail "grok did not receive the resolved launch store"
    assert_grok_trusted "$selected" "$proj" "the worker's store was not registered before launch"
    rm "$fakebin/grok.home"
    printf '[folders."%s"]\ntrusted = false\n' "$proj" > "$selected/trusted_folders.toml"
    refused_id="$id-refused"
    fm_test_spawn_brief "$home" "$refused_id"
    : > "$home/refused.log"
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/refused.log" \
      FM_TEST_PANE_HOME="$pane_home" FM_TEST_PANE_GROK_HOME="$case_dir/grok-alias" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$refused_id" "$proj" grok --mode no-mistakes --yolo off)
    expect_code 1 $? "an explicit untrust decision must block the worker: $out"
    assert_absent "$fakebin/grok.home" "grok started despite a registration refusal"
    assert_absent "$home/state/$refused_id.meta" "registration refusal published a task record"
    [ ! -s "$home/refused.log" ] || fail "registration refusal delivered a worker command"
    assert_not_contains "$out" 'spawned ' "registration refusal reported a successful spawn"
    assert_grep 'trusted = false' "$selected/trusted_folders.toml" "launch overwrote an explicit untrust decision"
    pass "grok registration and launch share the destination store with policy=$policy"
  done
}

test_grok_raw_home_overrides_are_registered_synchronously() {
  local kind rec case_dir home proj wt fakebin grok_home id pane_home selected raw out
  for kind in literal quoted relative variable empty home; do
    rec=$(make_spawn_case "raw-home-$kind")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    pane_home="$case_dir/pane-home"
    mkdir -p "$pane_home" "$case_dir/pane-grok"
    : > "$home/config/launch-env-allowlist"
    case "$kind" in
      literal) selected="$case_dir/raw-home"; raw="GROK_HOME=$selected grok --always-approve" ;;
      quoted) selected="$case_dir/raw home"; raw="GROK_HOME='$selected' grok --always-approve" ;;
      relative) selected="$case_dir/raw-home"; raw='GROK_HOME=../raw-home grok --always-approve' ;;
      variable) selected="$pane_home/raw home"; raw='GROK_HOME="$HOME/raw home" grok --always-approve' ;;
      empty) selected="$pane_home/.grok"; raw='GROK_HOME= grok --always-approve' ;;
      home) selected="$case_dir/raw-user/.grok"; raw="HOME='$case_dir/raw-user' GROK_HOME= grok --always-approve" ;;
    esac
    raw="FM_GROK_RAW_SENTINEL=retained $raw"
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
      FM_TEST_PANE_HOME="$pane_home" FM_TEST_PANE_GROK_HOME="$case_dir/pane-grok" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$raw" --mode no-mistakes --yolo off)
    expect_code 0 $? "a $kind raw Grok home override must dispatch: $out"
    assert_grok_trusted "$selected" "$proj" "the raw command's store was not registered synchronously"
    assert_absent "$grok_home/trusted_folders.toml" "raw launch registered the caller's store"
    assert_absent "$case_dir/pane-grok/trusted_folders.toml" "raw launch registered the ambient pane store"
    out=$(cd "$wt" && env -i HOME="$pane_home" GROK_HOME="$case_dir/changed-pane-store" \
      PATH="$fakebin:$PATH" /bin/sh "$home/launch.log")
    expect_code 0 $? "the emitted $kind raw launch must execute: $out"
    [ "$(cat "$fakebin/grok.home")" = "$selected" ] || fail "a raw command changed the registered launch store"
    [ "$(cat "$fakebin/grok.sentinel")" = retained ] || fail "raw launch lost another explicit environment assignment"
    pass "grok registers and binds a $kind raw home override before dispatch"
  done
}

test_grok_raw_home_substitutions_are_refused() {
  local rec case_dir home proj wt fakebin grok_home id out raw
  rec=$(make_spawn_case raw-substitution)
  IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
  raw="GROK_HOME=\$(touch '$case_dir/executed') grok --always-approve"
  out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" "$raw" --mode no-mistakes --yolo off 2>&1)
  expect_code 1 $? "home resolution must refuse command substitutions: $out"
  assert_absent "$case_dir/executed" "home resolution executed a command substitution"
  assert_absent "$grok_home/trusted_folders.toml" "an unresolved home granted trust"
  assert_absent "$home/state/$id.meta" "an unresolved home published a task record"
  [ ! -s "$home/launch.log" ] || fail "an unresolved home delivered a worker command"
  pass "grok refuses raw home command substitutions without executing them"
}

test_grok_failed_preflight_keeps_the_task_queued() {
  local kind rec case_dir home proj wt fakebin grok_home id out
  for kind in untrusted symlink missing-probe rejected-probe; do
    rec=$(make_spawn_case "refuse-$kind")
    IFS='|' read -r case_dir home proj wt fakebin grok_home id <<EOF
$rec
EOF
    printf 'backend = "markdown"\n' > "$home/.tasks.toml"
    printf '# Backlog\n' > "$home/data/backlog.md"
    printf 'queued\n' > "$fakebin/tasks-axi.state"
    cat > "$fakebin/tasks-axi" <<'SH'
#!/bin/sh
case "$1" in
  --version) printf '0.2.5\n' ;;
  update) printf '%s\n' '--archive-body' ;;
  mv) printf '%s\n' '[<id>...]' ;;
  show)
    : > "$0.checked"
    printf 'task:\n  state: %s\n  held: no\n  blocked: no\n' "$(cat "$0.state")"
    ;;
  start) printf 'in_flight\n' > "$0.state" ;;
  *) exit 2 ;;
esac
SH
    chmod +x "$fakebin/tasks-axi"
    case "$kind" in
      untrusted) printf '[folders."%s"]\ntrusted = false\n' "$proj" > "$grok_home/trusted_folders.toml" ;;
      symlink) printf 'untouched\n' > "$case_dir/alternate"; ln -s "$case_dir/alternate" "$grok_home/trusted_folders.toml" ;;
    esac
    out=$(GROK_HOME="$grok_home" FM_FAKE_LAUNCH_LOG="$home/launch.log" TASKS_AXI_BACKEND=markdown \
      FM_TEST_GROK_PROBE_DROP="$([ "$kind" = missing-probe ] && echo 1 || echo 0)" \
      FM_TEST_GROK_PROBE_REJECT="$([ "$kind" = rejected-probe ] && echo 1 || echo 0)" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" grok --mode no-mistakes --yolo off)
    expect_code 1 $? "$kind must refuse the spawn itself: $out"
    assert_present "$fakebin/tasks-axi.checked" "the spawn never checked the queued task"
    [ "$(cat "$fakebin/tasks-axi.state")" = queued ] || fail "$kind moved the task In flight"
    assert_absent "$home/state/$id.meta" "$kind published a task record"
    [ ! -s "$home/launch.log" ] || fail "$kind delivered a worker command"
    assert_not_contains "$out" 'spawned ' "$kind reported a successful spawn"
    [ -z "$(find "$home/state" -maxdepth 1 -name '.grok-home-*' -print -quit)" ] || fail "$kind left a probe directory behind"
    pass "grok $kind refuses dispatch and leaves its task queued"
  done
}

test_fm_lock_recognizes_grok_holder() {
  local home fakebin out
  home="$TMP_ROOT/lock-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/lock-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/grok'; exit 0 ;;
  *"args="*) printf '%s\n' 'grok'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-lock.sh" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize grok as a live holder"
  pass "fm-lock recognizes grok harness processes"
}

test_grok_hook_requires_registered_token
test_grok_teardown_removes_pointer_and_token
test_grok_spawn_pretrusts_the_project_not_the_worktree
test_grok_secondmate_spawn_pretrusts_its_primary
test_grok_registration_uses_the_filtered_launch_environment
test_grok_raw_home_overrides_are_registered_synchronously
test_grok_raw_home_substitutions_are_refused
test_grok_failed_preflight_keeps_the_task_queued
test_fm_lock_recognizes_grok_holder
