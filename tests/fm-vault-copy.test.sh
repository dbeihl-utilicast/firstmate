#!/usr/bin/env bash
# Behavioral coverage for copying finished reports into the configured vault.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COPY="$ROOT/bin/fm-vault-copy.sh"
TMP_ROOT=$(fm_test_tmproot fm-vault-copy)

make_world() {
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  VAULT="$WORLD/vault"
  mkdir -p "$MAIN"/{state,data,config} "$VAULT"
  printf '%s\n' "$VAULT" > "$MAIN/config/vault-path"
}

run_copy() {
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_DATA_OVERRIDE="$MAIN/data" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$COPY" catch-up
}

run_copy_with_system_awk() {
  local awk_bin="$WORLD/system-awk-bin"
  [ -x /usr/bin/awk ] || fail "system awk is not available at /usr/bin/awk"
  mkdir -p "$awk_bin"
  ln -s /usr/bin/awk "$awk_bin/awk"
  PATH="$awk_bin:$PATH" run_copy
}

report_count() {
  find "$VAULT/research" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '
}

test_main_report_and_boundaries() {
  make_world main
  mkdir -p "$MAIN/data/task" "$MAIN/data/active" "$MAIN/data/task/notes"
  printf 'kind=scout\nproject=/repo/alpha\n' > "$MAIN/state/task.meta"
  printf 'done: complete\n' > "$MAIN/state/task.status"
  printf '# finished\n' > "$MAIN/data/task/report.md"
  printf 'working: still writing\n' > "$MAIN/state/active.status"
  printf '# active\n' > "$MAIN/data/active/report.md"
  printf 'do not copy\n' > "$MAIN/data/task/notes/other.md"
  run_copy >/dev/null
  [ "$(report_count)" = 1 ] || fail "main catch-up copied a non-report or active report"
  grep -Fq '# finished' "$VAULT/research/$(date +%F)-alpha-task.md" \
    || fail "main finished report was not copied with its dated project-task name"
  pass "main catch-up copies only the finished report boundary"
}

test_local_secondmate_report() {
  local mate="$WORLD/mate"
  make_world local
  mkdir -p "$mate"/{state,data/local-task}
  printf 'kind=secondmate\nhome=%s\n' "$mate" > "$MAIN/state/mate.meta"
  printf 'kind=scout\nproject=/repo/beta\n' > "$mate/state/local-task.meta"
  printf 'done: complete\n' > "$mate/state/local-task.status"
  printf '# local\n' > "$mate/data/local-task/report.md"
  run_copy >/dev/null
  [ "$(report_count)" = 1 ] || fail "local secondmate report was not copied"
  grep -Fq '# local' "$VAULT/research/$(date +%F)-beta-local-task.md" \
    || fail "local secondmate report used the wrong project-task name"
  pass "main catches up local secondmate reports"
}

test_remote_secondmate_report() {
  make_world remote
  mkdir -p "$MAIN/data/remote-secondmates/ios/data/remote-task"
  printf 'kind=secondmate\nremote_host=remote-mac\nproject=/repo/gamma\n' > "$MAIN/state/ios.meta"
  printf 'done [key=finished]: child remote-task done report=data/remote-secondmates/ios/data/remote-task/report.md\n' \
    > "$MAIN/state/ios.status"
  printf '# remote\n' > "$MAIN/data/remote-secondmates/ios/data/remote-task/report.md"
  run_copy_with_system_awk >/dev/null
  [ "$(report_count)" = 1 ] || fail "remote secondmate report was not copied from the existing mirror"
  grep -Fq '# remote' "$VAULT/research/$(date +%F)-gamma-remote-task.md" \
    || fail "remote secondmate report used the wrong project-task name"
  pass "main catches up remote secondmate reports already fetched by reply relay"
}

test_disabled_and_collision_are_safe() {
  make_world disabled
  mkdir -p "$MAIN/data/task"
  printf 'kind=scout\nproject=/repo/delta\n' > "$MAIN/state/task.meta"
  printf 'done: complete\n' > "$MAIN/state/task.status"
  printf '# disabled\n' > "$MAIN/data/task/report.md"
  : > "$MAIN/config/vault-path"
  run_copy >/dev/null
  [ ! -d "$VAULT/research" ] || fail "an unset vault path still wrote a report"

  make_world collision
  mkdir -p "$MAIN/data/task"
  printf 'kind=scout\nproject=/repo/epsilon\n' > "$MAIN/state/task.meta"
  printf 'done: complete\n' > "$MAIN/state/task.status"
  mkdir -p "$VAULT/research"
  printf '# first\n' > "$VAULT/research/$(date +%F)-epsilon-task.md"
  printf '# second\n' > "$MAIN/data/task/report.md"
  run_copy >/dev/null
  grep -Fq '# first' "$VAULT/research/$(date +%F)-epsilon-task.md" \
    || fail "a collision overwrote the existing vault document"
  [ "$(report_count)" = 2 ] || fail "a collision did not preserve the new report separately"
  pass "disabled copying and collisions preserve existing files"
}

test_ledger_skips_recorded_sources() {
  local dated
  make_world ledger
  mkdir -p "$MAIN/data/task"
  printf 'kind=scout\nproject=/repo/zeta\n' > "$MAIN/state/task.meta"
  printf 'done: complete\n' > "$MAIN/state/task.status"
  printf '# one\n' > "$MAIN/data/task/report.md"
  run_copy >/dev/null
  dated="$VAULT/research/$(date +%F)-zeta-task.md"
  printf '# annotated\n' > "$dated"
  run_copy >/dev/null
  [ "$(report_count)" = 1 ] || fail "an edited vault copy was copied again"
  grep -Fq '# annotated' "$dated" || fail "an edited vault copy was overwritten"
  mv "$dated" "$VAULT/curated.md"
  run_copy >/dev/null
  [ ! -e "$dated" ] || fail "a moved vault copy was copied again"
  printf '# two\n' > "$MAIN/data/task/report.md"
  run_copy >/dev/null
  [ "$(report_count)" = 1 ] || fail "a changed source report was not copied once more"
  grep -Fq '# two' "$dated" || fail "a changed source report was not copied under a new name"
  run_copy >/dev/null
  [ "$(report_count)" = 1 ] || fail "a recorded changed report was copied again"
  pass "ledger copies each source path and content once"
}

test_remote_status_scan_does_not_fork_per_line() {
  local started elapsed i
  make_world scan-cost
  mkdir -p "$MAIN/data/remote-secondmates/ios/data/remote-task"
  printf 'kind=secondmate\nremote_host=remote-mac\nproject=/repo/gamma\n' > "$MAIN/state/ios.meta"
  : > "$MAIN/state/ios.status"
  for i in $(seq 1 4000); do
    printf 'working [at=%s]: line %s\n' "$i" "$i" >> "$MAIN/state/ios.status"
  done
  started=$SECONDS
  run_copy >/dev/null
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 3 ] \
    || fail "remote status scan took ${elapsed}s for 4000 lines; it must not fork a subprocess per line (this is what stalls fm-procevent-remote-reply.sh cmd_ingest and fm-inactive-reconcile.sh scan() on every call, starving remote-reply source relaunches)"
  pass "remote status scan stays bounded across thousands of non-report lines"
}

test_symlinked_ancestor_is_rejected() {
  make_world symlink-ancestor
  mkdir -p "$MAIN/data/real/task"
  ln -s "$MAIN/data/real/task" "$MAIN/data/linked"
  printf 'kind=scout\nproject=/repo/theta\n' > "$MAIN/state/linked.meta"
  printf 'done: complete\n' > "$MAIN/state/linked.status"
  printf '# via symlink\n' > "$MAIN/data/real/task/report.md"
  run_copy >/dev/null
  [ "$(report_count)" = 0 ] || fail "a report reached through a symlinked ancestor directory was copied"
  pass "a symlinked ancestor directory is refused, not just a symlinked report file"
}

test_realistic_scale_catch_up_stays_bounded() {
  local n mate line_no task started elapsed offers=0
  make_world realistic-scale
  for n in $(seq 1 15); do
    mate="mate-$n"
    mkdir -p "$MAIN/data/remote-secondmates/$mate/data"
    printf 'kind=secondmate\nremote_host=remote-mac\nproject=/repo/eta\n' > "$MAIN/state/$mate.meta"
    : > "$MAIN/state/$mate.status"
    for line_no in $(seq 1 700); do
      if [ $((line_no % 20)) -eq 0 ]; then
        task="task-$n-$line_no"
        mkdir -p "$MAIN/data/remote-secondmates/$mate/data/$task"
        printf '# report %s\n' "$task" > "$MAIN/data/remote-secondmates/$mate/data/$task/report.md"
        printf 'done [key=finished]: child %s done report=data/remote-secondmates/%s/data/%s/report.md\n' \
          "$task" "$mate" "$task" >> "$MAIN/state/$mate.status"
        if [ "$n" -lt 15 ] || [ "$line_no" -lt 680 ]; then
          entry="$(sha256sum "$MAIN/data/remote-secondmates/$mate/data/$task/report.md" 2>/dev/null \
            || shasum -a 256 "$MAIN/data/remote-secondmates/$mate/data/$task/report.md")"
          printf '%s %s\n' "${entry%% *}" "$MAIN/data/remote-secondmates/$mate/data/$task/report.md" \
            >> "$MAIN/state/vault-copied.ledger"
        fi
        offers=$((offers + 1))
      else
        printf 'working [at=%s]: line %s\n' "$line_no" "$line_no" >> "$MAIN/state/$mate.status"
      fi
    done
  done
  started=$SECONDS
  run_copy_with_system_awk >/dev/null
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 15 ] \
    || fail "catch-up took ${elapsed}s across $offers report offers at production scale (~10,500 status lines, 15 remote second mates); it must not fork a subprocess per offer to scan status lines, walk ancestor directories, or check the ledger"
  [ "$(report_count)" -ge 1 ] || fail "the newly-uncached reports at the end of the fixture were not copied"
  pass "catch-up stays bounded at production-scale status log volume"
}

test_main_report_and_boundaries
test_local_secondmate_report
test_remote_secondmate_report
test_disabled_and_collision_are_safe
test_ledger_skips_recorded_sources
test_remote_status_scan_does_not_fork_per_line
test_symlinked_ancestor_is_rejected
test_realistic_scale_catch_up_stays_bounded
printf 'all vault copy tests passed\n'
