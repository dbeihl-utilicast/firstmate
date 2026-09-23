#!/usr/bin/env bash
# Home-scoped Treehouse pool root: two Firstmate homes cloning the same
# project must not share a pool, and a handed-out slot whose .git belongs to
# the other clone must be refused rather than launched into.
#
# The red reproduction drives real treehouse against two same-basename clones
# with no --root (skip when treehouse is absent). The Firstmate contract is
# pinned hermetically: the helper appends a per-home --root that lies OUTSIDE
# the home (so a pooled copy never finds the home's own CLAUDE.md in a parent
# directory), spawn/seed/teardown invoke it, and spawn refuses a foreign-clone
# pool slot.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-treehouse-pool-root)
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-treehouse-lib.sh
. "$ROOT/bin/fm-treehouse-lib.sh"

make_same_basename_clones() {  # <dir> -> sets ORIGIN CLONE_A CLONE_B HOME_A HOME_B
  local dir=$1
  ORIGIN="$dir/origin.git"
  HOME_A="$dir/home-a"
  HOME_B="$dir/home-b"
  mkdir -p "$HOME_A/projects" "$HOME_B/projects"
  git init --quiet --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone --quiet "$ORIGIN" "$dir/_seed"
  git -C "$dir/_seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit --allow-empty -qm initial
  git -C "$dir/_seed" push --quiet origin main
  rm -rf "$dir/_seed"
  git clone --quiet "$ORIGIN" "$HOME_A/projects/utilicast-triage"
  git clone --quiet "$ORIGIN" "$HOME_B/projects/utilicast-triage"
  CLONE_A="$HOME_A/projects/utilicast-triage"
  CLONE_B="$HOME_B/projects/utilicast-triage"
}

common_dir_of() {  # <path>
  local d
  d=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  CDPATH='' cd -- "$d" && pwd -P
}

# --- real treehouse: the cross-home collision and the --root isolation ------

test_real_treehouse_same_basename_clones_share_default_pool() {
  command -v treehouse >/dev/null 2>&1 || {
    echo "skip: treehouse not found (cross-home default-pool collision)"
    return 0
  }
  local dir slot_a slot_b slot_recycled pool_a pool_b fakehome
  dir="$TMP_ROOT/red-shared-pool"
  fakehome="$dir/fakehome"
  mkdir -p "$fakehome"
  make_same_basename_clones "$dir"

  slot_a=$(cd "$CLONE_A" && HOME="$fakehome" treehouse get --lease --lease-holder home-a) || \
    fail "treehouse get --lease from clone A failed"
  slot_b=$(cd "$CLONE_B" && HOME="$fakehome" treehouse get --lease --lease-holder home-b) || \
    fail "treehouse get --lease from clone B failed"
  pool_a=$(dirname "$(dirname "$slot_a")")
  pool_b=$(dirname "$(dirname "$slot_b")")
  [ "$pool_a" = "$pool_b" ] || fail "same-basename clones used different default pools: $pool_a vs $pool_b"

  (cd "$CLONE_A" && HOME="$fakehome" treehouse return --force "$slot_a") || \
    fail "treehouse return of clone A slot failed"
  slot_recycled=$(cd "$CLONE_B" && HOME="$fakehome" treehouse get --lease --lease-holder home-b-retry) || \
    fail "treehouse get --lease recycle from clone B failed"
  [ "$(common_dir_of "$slot_recycled")" = "$(common_dir_of "$CLONE_A")" ] || \
    fail "recycled slot common-dir was not clone A's; the collision did not reproduce"
  [ "$(common_dir_of "$slot_recycled")" != "$(common_dir_of "$CLONE_B")" ] || \
    fail "recycled slot unexpectedly belonged to clone B"

  (cd "$CLONE_B" && HOME="$fakehome" treehouse return --force "$slot_b") || true
  (cd "$CLONE_B" && HOME="$fakehome" treehouse return --force "$slot_recycled") || true
  pass "real treehouse: same-basename clones share a default pool and recycle a foreign slot"
}

test_real_treehouse_home_root_isolates_pools() {
  command -v treehouse >/dev/null 2>&1 || {
    echo "skip: treehouse not found (cross-home --root isolation)"
    return 0
  }
  local dir slot_a slot_b slot_retry
  dir="$TMP_ROOT/green-root"
  make_same_basename_clones "$dir"

  slot_a=$(cd "$CLONE_A" && treehouse get --lease --lease-holder home-a --root "$HOME_A") || \
    fail "treehouse get --root home-a failed"
  slot_b=$(cd "$CLONE_B" && treehouse get --lease --lease-holder home-b --root "$HOME_B") || \
    fail "treehouse get --root home-b failed"
  case "$slot_a" in
    "$HOME_A"/.treehouse/*) ;;
    *) fail "clone A slot was not under home A: $slot_a" ;;
  esac
  case "$slot_b" in
    "$HOME_B"/.treehouse/*) ;;
    *) fail "clone B slot was not under home B: $slot_b" ;;
  esac
  [ "$(dirname "$(dirname "$slot_a")")" != "$(dirname "$(dirname "$slot_b")")" ] || \
    fail "per-home --root still shared a pool"

  (cd "$CLONE_A" && treehouse return --force "$slot_a" --root "$HOME_A") || \
    fail "return of home-a slot failed"
  slot_retry=$(cd "$CLONE_B" && treehouse get --lease --lease-holder home-b-retry --root "$HOME_B") || \
    fail "treehouse get --root home-b retry failed"
  [ "$(common_dir_of "$slot_retry")" = "$(common_dir_of "$CLONE_B")" ] || \
    fail "home-b retry was handed a slot whose git metadata is not clone B's"

  (cd "$CLONE_B" && treehouse return --force "$slot_b" --root "$HOME_B") || true
  (cd "$CLONE_B" && treehouse return --force "$slot_retry" --root "$HOME_B") || true
  pass "real treehouse: per-home --root isolates pools so a recycle stays on this clone"
}

# The captain-facing bug: a slot inside the home has the home's own CLAUDE.md
# (an @AGENTS.md pointer) in a parent directory, so Claude asks to allow that
# external import. A slot from the helper's root has no home ancestor at all.
# A slot a home took before its root moved (a legacy in-home pool) must still
# go back to its own pool through the helper, so moving the root never strands
# a lease or discards a slot.
test_real_treehouse_slots_live_outside_the_home_and_legacy_slots_still_return() {
  command -v treehouse >/dev/null 2>&1 || {
    echo "skip: treehouse not found (pool root outside the home)"
    return 0
  }
  local dir user slot legacy dir_up status_out
  dir="$TMP_ROOT/outside-home"
  user="$dir/user"
  mkdir -p "$user"
  make_same_basename_clones "$dir"
  printf '@AGENTS.md\n' > "$HOME_A/CLAUDE.md"

  slot=$(cd "$CLONE_A" && HOME="$user" FM_HOME="$HOME_A" fm_treehouse get --lease --lease-holder home-a) || \
    fail "fm_treehouse get --lease from home A failed"
  dir_up=$slot
  while [ "$dir_up" != / ]; do
    [ ! -e "$dir_up/CLAUDE.md" ] || fail "slot '$slot' has the home's CLAUDE.md in its parent '$dir_up'"
    dir_up=$(dirname "$dir_up")
  done
  case "$slot/" in
    "$(phys "$HOME_A")"/*) fail "slot '$slot' was allocated inside the home" ;;
  esac

  legacy=$(cd "$CLONE_A" && treehouse get --lease --lease-holder legacy --root "$HOME_A") || \
    fail "could not seed a legacy in-home slot"
  (cd "$CLONE_A" && HOME="$user" FM_HOME="$HOME_A" fm_treehouse return --force "$legacy") || \
    fail "fm_treehouse could not return a legacy in-home slot after the root moved"
  status_out=$(cd "$CLONE_A" && treehouse status --root "$HOME_A" 2>&1)
  assert_contains "$status_out" "available" "the legacy slot did not go back to its own pool: $status_out"
  [ -d "$legacy" ] || fail "returning the legacy slot removed it instead of returning it"

  (cd "$CLONE_A" && HOME="$user" FM_HOME="$HOME_A" fm_treehouse return --force "$slot") || true
  pass "real treehouse: slots live outside the home, and a legacy in-home slot still returns to its pool"
}

# --- helper contract --------------------------------------------------------

# phys <dir>: the physical path, the way the helper resolves it.
phys() { CDPATH='' cd -- "$1" && pwd -P; }

test_helper_resolves_a_per_home_root_outside_the_home() {
  local base home_a home_b user root_a root_b root_again
  base="$TMP_ROOT/helper-home"
  home_a="$base/a/firstmate"
  home_b="$base/b/firstmate"
  user="$base/user"
  mkdir -p "$home_a" "$home_b" "$user"
  root_a=$(HOME="$user" FM_HOME="$home_a" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed for home a"
  root_b=$(HOME="$user" FM_HOME="$home_b" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed for home b"
  root_again=$(HOME="$user" FM_HOME="$home_a" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed on a repeat"
  case "$root_a/" in
    "$(phys "$home_a")"/*) fail "the pool root '$root_a' is inside the home, where the home's CLAUDE.md is a parent of every slot" ;;
  esac
  case "$root_a" in
    "$(phys "$user")"/.firstmate-pools/firstmate-*) ;;
    *) fail "the pool root '$root_a' is not a per-home directory under the user's .firstmate-pools" ;;
  esac
  [ "$root_a" != "$root_b" ] || fail "two same-basename homes resolved one shared pool root '$root_a'"
  [ "$root_a" = "$root_again" ] || fail "the pool root is not stable for one home: '$root_a' then '$root_again'"
  pass "fm_treehouse_home_root prints a stable per-home root outside the home"
}

test_helper_refuses_a_root_that_would_land_inside_the_home() {
  local home out
  home="$TMP_ROOT/helper-nested/home"
  mkdir -p "$home/user"
  if out=$(HOME="$home/user" FM_HOME="$home" fm_treehouse_home_root 2>&1); then
    fail "a pool root inside the home was accepted: $out"
  fi
  assert_contains "$out" "inside" "the refusal did not say the root would land inside the home"
  pass "fm_treehouse_home_root refuses a user home that sits inside the Firstmate home"
}

test_helper_appends_root_on_invocation() {
  local home fakebin log root
  home="$TMP_ROOT/helper-invoke"
  fakebin=$(fm_fakebin "$home/fake")
  log="$home/treehouse.log"
  mkdir -p "$home"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  : > "$log"
  root=$(FM_HOME="$home" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed"
  PATH="$fakebin:$PATH" FM_HOME="$home" fm_treehouse get --lease --lease-holder dash \
    || fail "fm_treehouse get failed"
  assert_grep "get --lease --lease-holder dash --root $root" "$log" \
    "fm_treehouse did not append the home's pool --root after the subcommand args"
  pass "fm_treehouse appends this home's pool --root on every invocation"
}

test_spawn_get_command_quotes_root() {
  local home cmd root
  home="$TMP_ROOT/helper-cmd"
  mkdir -p "$home/with space"
  home="$home/with space"
  root=$(FM_HOME="$home" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed"
  cmd=$(FM_HOME="$home" fm_treehouse_spawn_get_command) || fail "spawn get command failed"
  [ "$cmd" = "treehouse get --root '$root'" ] || \
    fail "spawn get command was '$cmd', expected treehouse get --root '$root'"
  pass "fm_treehouse_spawn_get_command emits a quoted home-scoped get"
}

# --- spawn / seed / teardown invoke the helper ------------------------------

make_recording_spawn_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-panes) printf '%%1\n'; exit 0 ;;
  new-window) printf '%s\n' "@spawnwid"; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|send-keys|set-window-option|kill-window) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

test_spawn_types_home_scoped_get() {
  local dir home proj wt fakebin rec out status root
  dir="$TMP_ROOT/spawn-root"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  rec="$dir/tmux.rec"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "fm/spawn-root"
  fm_test_spawn_brief "$home" spawn-root-a1
  fakebin=$(make_recording_spawn_fakebin "$dir/fake")
  : > "$rec"
  mkdir -p "$(fm_test_spawn_user_home "$home")"
  root=$(HOME="$(fm_test_spawn_user_home "$home")" FM_HOME="$home" fm_treehouse_home_root) \
    || fail "fm_treehouse_home_root failed"
  out=$(FM_TMUX_REC="$rec" fm_test_run_spawn "$home" "$wt" "$fakebin" \
    spawn-root-a1 "$proj" --scout)
  status=$?
  expect_code 0 "$status" "spawn should succeed into a genuine worktree"$'\n'"$out"
  assert_grep "send-keys -t @spawnwid treehouse get --root '$root' Enter" "$rec" \
    "spawn did not type a home-scoped treehouse get to the stable window id"
  pass "spawn types this home's pool-scoped treehouse get into the worker pane"
}

test_spawn_refuses_foreign_clone_pool_slot() {
  local dir home proj_a proj_b slot pool fakebin out status
  dir="$TMP_ROOT/spawn-foreign"
  home="$dir/home"
  make_same_basename_clones "$dir/clones"
  proj_a=$CLONE_A
  proj_b=$CLONE_B
  pool="$dir/pool"
  slot="$pool/1/utilicast-triage"
  mkdir -p "$pool/1"
  git -C "$proj_a" worktree add --quiet --detach "$slot"
  printf '{}\n' > "$pool/treehouse-state.json"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" foreign-slot-b2
  fakebin=$(make_recording_spawn_fakebin "$dir/fake")
  out=$(fm_test_run_spawn "$home" "$slot" "$fakebin" \
    foreign-slot-b2 "$proj_b" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pool slot whose git metadata belongs to the other clone"$'\n'"$out"
  assert_contains "$out" "different clone" \
    "spawn did not say the handed-out slot belongs to a different clone"
  [ ! -e "$home/state/foreign-slot-b2.meta" ] || fail "refused spawn published task metadata"
  pass "spawn refuses a Treehouse slot whose git common dir is another clone's"
}

test_seed_passes_home_scoped_root() {
  local home acquired fakebin log lease out root
  home="$TMP_ROOT/seed-home"
  acquired="$TMP_ROOT/seed-acquired"
  mkdir -p "$home/projects" "$home/data" "$home/state"
  fm_git_init_commit "$home/projects/alpha"
  fm_git_add_origin "$home/projects/alpha" "$TMP_ROOT/remotes/seed-alpha.git"
  printf '%s\n' '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$home/data/projects.md"
  git clone --quiet "$ROOT" "$acquired"
  fakebin=$(make_fake_tmux "$TMP_ROOT/seed-fake")
  log="$TMP_ROOT/seed-fake/tmux.log"
  lease="$TMP_ROOT/seed-fake/lease"
  root=$(FM_HOME="$home" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TREEHOUSE_HOME="$acquired" \
    FM_FAKE_TMUX_LOG="$log" FM_FAKE_TREEHOUSE_LEASE_FILE="$lease" \
    FM_SECONDMATE_CHARTER='dash acquired scope' FM_SECONDMATE_SCOPE='dash acquired scope' \
    "$ROOT/bin/fm-home-seed.sh" dash - alpha) \
    || fail "seed failed for a treehouse-acquired home"$'\n'"$out"
  grep -F "get --lease --lease-holder dash --root $root" "$log" >/dev/null \
    || fail "seed did not pass this home's pool --root on treehouse get --lease"$'\n'"$(cat "$log")"
  pass "home seed leases with this home's --root"
}

test_teardown_passes_home_scoped_root() {
  local dir home proj wt id fakebin log root out status
  dir="$TMP_ROOT/teardown-root"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id=teardown-root-c3
  fakebin="$dir/fakebin"
  log="$dir/treehouse.log"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$fakebin"
  printf 'scout findings\n' > "$home/data/$id/report.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=claude" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=teardown-root-$id" \
    "decisions_reviewed=1" \
    "decision_keys="
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$log"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_test_fake_no_mistakes "$fakebin"
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  : > "$log"
  root=$(FM_HOME="$home" fm_treehouse_home_root) || fail "fm_treehouse_home_root failed"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  status=$?
  expect_code 0 "$status" "scout teardown with a report should succeed"$'\n'"$out"
  assert_grep "return --force $wt --root $root" "$log" \
    "teardown did not pass this home's pool --root on treehouse return"
  pass "teardown returns a slot with this home's --root"
}

test_real_treehouse_same_basename_clones_share_default_pool
test_real_treehouse_home_root_isolates_pools
test_real_treehouse_slots_live_outside_the_home_and_legacy_slots_still_return
test_helper_resolves_a_per_home_root_outside_the_home
test_helper_refuses_a_root_that_would_land_inside_the_home
test_helper_appends_root_on_invocation
test_spawn_get_command_quotes_root
test_spawn_types_home_scoped_get
test_spawn_refuses_foreign_clone_pool_slot
test_seed_passes_home_scoped_root
test_teardown_passes_home_scoped_root

echo "# all fm-treehouse-pool-root tests passed"
