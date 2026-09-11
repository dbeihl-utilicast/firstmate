#!/usr/bin/env bash
set -eu
cd /Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M287K9797DAPVHHW8PY7P4FW
export TMPDIR="$PWD/.test-tmp" FM_TEST_SKIP_ORPHAN_REAP=1
mkdir -p "$TMPDIR"
. tests/lib.sh
VERIFY_CODE_ROOT=${VERIFY_CODE_ROOT:-$PWD}
TMP_ROOT=$(fm_test_tmproot fm-scope-hooks)
fm_git_identity fmtest fmtest@example.invalid
unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE PI_CODING_AGENT FM_ALLOW_SUBAGENT
ln -s /bin/bash "$TMP_ROOT/claude"
base="$TMP_ROOT/base"
fm_git_init_commit "$base"
for scenario in leased recorded-by-sibling gate-env gate-path foreign-state symlink-lock; do
  dir="$TMP_ROOT/$scenario"
  if [ "$scenario" = gate-path ]; then
    mkdir -p "$TMP_ROOT/.no-mistakes/repos"
    git clone -q --bare "$base" "$TMP_ROOT/.no-mistakes/repos/fixture.git"
    git -C "$TMP_ROOT/.no-mistakes/repos/fixture.git" worktree add --quiet --detach "$dir" main
  else
    git -C "$base" worktree add --quiet --detach "$dir" main
  fi
  mkdir -p "$dir/state" "$dir/bin"
  : > "$dir/AGENTS.md"
  if [ "$scenario" = recorded-by-sibling ]; then
    sibling="$TMP_ROOT/leased-sibling"
    git -C "$base" worktree add --quiet --detach "$sibling" main
    mkdir -p "$sibling/state"
    printf 'worktree=%s\nkind=ship\n' "$dir" > "$sibling/state/child.meta"
  fi
  state="$dir/state"
  if [ "$scenario" = foreign-state ]; then
    state="$TMP_ROOT/foreign-state-storage"
    mkdir -p "$state"
  fi
  cat > "$state/scope.check.sh" <<'CHECK'
#!/usr/bin/env bash
sleep 1
printf 'scope hook delivery verified\n'
CHECK
  chmod 700 "$state/scope.check.sh"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
    bin/fm-check-register.sh scope >/dev/null
  for hook in fm-turnend-guard.sh fm-subagent-pretool-check.sh fm-claude-stop-autoarm.sh fm-turnend-guard-cursor.sh; do
    env FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
      VERIFY_CODE_ROOT="$VERIFY_CODE_ROOT" VERIFY_SCENARIO="$scenario" VERIFY_HOOK="$hook" \
      FM_POLL=1 FM_CHECK_INTERVAL=1 FM_CURSOR_PARK_POLL=1 \
      "$TMP_ROOT/claude" -c '
        set -u
        if [ "$VERIFY_SCENARIO" = symlink-lock ]; then
          printf "%s\n" "$$" > "$FM_HOME/lock-target"
          [ -L "$FM_STATE_OVERRIDE/.lock" ] || ln -s "$FM_HOME/lock-target" "$FM_STATE_OVERRIDE/.lock"
        else
          printf "%s\n" "$$" > "$FM_STATE_OVERRIDE/.lock"
        fi
        [ "$VERIFY_SCENARIO" != gate-env ] || export NO_MISTAKES_GATE=1
        find "$FM_STATE_OVERRIDE" -type f -exec shasum {} \; | sort > "$FM_HOME/before"
        rc=0
        if [ "$VERIFY_HOOK" = fm-subagent-pretool-check.sh ]; then
          "$VERIFY_CODE_ROOT/bin/$VERIFY_HOOK" --claude --tool Agent > "$FM_HOME/out" 2> "$FM_HOME/err" || rc=$?
        elif [ "$VERIFY_HOOK" = fm-turnend-guard-cursor.sh ]; then
          printf "%s\n" "{\"session_id\":\"scope-test\",\"loop_count\":0,\"hook_event_name\":\"stop\",\"cursor_version\":\"fixture\"}" |
            "$VERIFY_CODE_ROOT/bin/$VERIFY_HOOK" > "$FM_HOME/out" 2> "$FM_HOME/err" || rc=$?
        else
          printf "%s\n" "{\"session_id\":\"scope-test\",\"stop_hook_active\":false}" |
            "$VERIFY_CODE_ROOT/bin/$VERIFY_HOOK" > "$FM_HOME/out" 2> "$FM_HOME/err" || rc=$?
        fi
        printf "\nScenario=%s hook=%s exit=%s\n" "$VERIFY_SCENARIO" "$VERIFY_HOOK" "$rc"
        if [ "$VERIFY_SCENARIO" = leased ]; then
          cat "$FM_HOME/out" "$FM_HOME/err"
          case "$VERIFY_HOOK" in
            fm-subagent-pretool-check.sh)
              [ "$rc" = 2 ] && jq -e ".hookSpecificOutput.permissionDecision == \"deny\"" "$FM_HOME/err" >/dev/null || exit 1 ;;
            fm-turnend-guard-cursor.sh)
              [ "$rc" = 0 ] && jq -e ".followup_message | contains(\"FIRSTMATE_OP: v1 watcher\")" "$FM_HOME/out" >/dev/null || exit 1
              "$VERIFY_CODE_ROOT/bin/fm-wake-drain.sh" > "$FM_HOME/drain" 2> "$FM_HOME/drain-err" || exit 1
              grep -F "scope hook delivery verified" "$FM_HOME/drain" || exit 1 ;;
            *) [ "$rc" = 2 ] || exit 1 ;;
          esac
        else
          [ "$rc" = 0 ] && [ ! -s "$FM_HOME/out" ] && [ ! -s "$FM_HOME/err" ] || exit 1
          find "$FM_STATE_OVERRIDE" -type f -exec shasum {} \; | sort > "$FM_HOME/after"
          diff "$FM_HOME/before" "$FM_HOME/after" || exit 1
          printf "stdout=empty stderr=empty state=unchanged\n"
        fi
      '
  done
done
