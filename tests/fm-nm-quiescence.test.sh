#!/usr/bin/env bash
# Behavior tests for the fleet-wide, read-only no-mistakes quiescence census.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-nm-quiescence.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-quiescence)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
repo=$PWD
if [ -f "$PWD/.test-nm-repository" ]; then
  IFS= read -r repo < "$PWD/.test-nm-repository"
fi
if [ "${1:-}" = axi ]; then
  case "$(basename "$PWD")" in
    identity-failed) printf 'repo: "%s"\n' "$repo"; exit 7 ;;
    identity-missing) printf 'current_branch: main\n'; exit 0 ;;
    identity-malformed) printf 'repo: null\n'; exit 0 ;;
  esac
  printf 'repo: "%s"\n' "$repo"
  exit 0
fi
[ "${1:-}" = runs ] || exit 64
[ -z "${FM_TEST_NM_CALLS:-}" ] || printf '%s\n' "$PWD" >> "$FM_TEST_NM_CALLS"
case "$(basename "$repo")" in
  parked|parked-home|linked-parked)
    printf '%s\n' 'running fm/parked a1b2c3d4 2026-09-13 08:00'
    ;;
  unconfigured)
    printf '%s\n' "repo not initialized (run 'no-mistakes init' first)" >&2
    exit 1
    ;;
  malformed)
    printf '%s\n' 'running incomplete-row'
    ;;
  empty)
    ;;
  whitespace)
    printf '  \n\t\n'
    ;;
  partial)
    printf '%s\n' 'git push no-mistakes <branch>'
    ;;
  signaled)
    kill -KILL "$$"
    ;;
  query-error)
    printf '%s\n' 'query failed' >&2
    exit 7
    ;;
  terminal)
    printf '%s\n' 'completed fm/done a1b2c3d4 2026-09-13 08:00' \
      'failed fm/failed deadbeef 2026-09-13 07:00' \
      'cancelled fm/cancelled fedcba98 2026-09-13 06:00'
    ;;
  *)
    printf '  %s\n' 'no runs yet. Push through the gate to start a pipeline:'
    printf '  %s\n' 'git push no-mistakes <branch>'
    ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

epoch_for() {
  local timestamp=$1
  date -j -f '%Y-%m-%d %H:%M:%S' "$timestamp:00" '+%s' 2>/dev/null \
    || date -d "$timestamp:00" '+%s' 2>/dev/null
}

NOW=$(( $(epoch_for '2026-09-14 08:00') ))

make_home() {
  local name=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

make_project() {
  local home=$1 name=$2
  fm_git_init_commit "$home/projects/$name"
}

run_check() {
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_NM_QUIESCENCE_NOW_EPOCH="$NOW" "$CHECK" "$@"
}

assert_home_result() {
  local output=$1 host=$2 home=$3 path=$4 clones=$5 runs=$6 gaps=$7 status=$8
  assert_contains "$output" "$(printf 'HOME\thost=%s\thome=%s\tpath=%s\tclones=%s\truns=%s\tgaps=%s\tstatus=%s' \
    "$host" "$home" "$path" "$clones" "$runs" "$gaps" "$status")" \
    "$host/$home reported incorrect home coverage"
}

test_parked_run_returns_red_with_state_and_age() {
  local home output rc=0
  home=$(make_home parked-main)
  make_project "$home" parked

  output=$(run_check "$home") || rc=$?

  expect_code 1 "$rc" "known non-terminal run did not return the busy exit code"
  assert_contains "$output" $'RUN\thost=local\thome=main\tclone=parked' \
    "run report did not attribute the parked clone to the main home"
  assert_contains "$output" $'\tbranch=fm/parked\thead=a1b2c3d4\tstate=running\tage=1d0h' \
    "run report omitted the branch, state, or deterministic age"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=1\tgaps=0' \
    "busy summary did not count the discovered run"
  pass "non-terminal run returns red with state and age"
}

test_local_secondmate_is_discovered_from_registry() {
  local main child output rc=0
  main=$(make_home registry-main)
  child=$(make_home registry-child)
  make_project "$child" parked
  printf -- '- reports - report work (home: %s; scope: reports; projects: parked; added 2026-09-14)\n' \
    "$child" > "$main/data/secondmates.md"

  output=$(run_check "$main") || rc=$?

  expect_code 1 "$rc" "registered local secondmate run did not return red"
  assert_contains "$output" $'RUN\thost=local\thome=reports\tclone=parked' \
    "registry-discovered home did not report its run"
  pass "local secondmate homes are discovered from the registry"
}

test_projectless_home_repository_is_queried_once() {
  local main child calls output rc=0
  main=$(make_home projectless-main)
  fm_git_init_commit "$main"
  child="$TMP_ROOT/parked-home"
  git clone --quiet "$main" "$child"
  calls="$TMP_ROOT/projectless-calls"
  printf -- '- reports - firstmate work (home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
    "$child" > "$main/data/secondmates.md"

  output=$(FM_ROOT_OVERRIDE="$main" FM_TEST_NM_CALLS="$calls" run_check "$main") || rc=$?

  expect_code 1 "$rc" "project-less home repository was omitted"
  assert_contains "$output" $'RUN\thost=local\thome=reports\tclone=parked-home' \
    "independently cloned home was not attributed to its registry entry"
  assert_equals "$main"$'\n'"$child" "$(cat "$calls")" \
    "code root and home did not query each distinct checkout exactly once"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=1\tgaps=0' \
    "project-less home's run was not counted exactly once"
  pass "project-less home repositories are queried and shared checkout paths are deduplicated"
}

test_linked_home_keeps_its_own_ledger() {
  local main child output rc=0
  main=$(make_home independent/parked-home)
  fm_git_init_commit "$main"
  child="$TMP_ROOT/linked-parked"
  git -C "$main" worktree add --quiet --detach "$child" HEAD
  printf -- '- linked - firstmate work (home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
    "$child" > "$main/data/secondmates.md"

  output=$(FM_ROOT_OVERRIDE="$main" run_check "$main") || rc=$?

  expect_code 1 "$rc" "distinct worktree ledger was deduplicated by shared git storage"
  assert_contains "$output" $'RUN\thost=local\thome=linked\tclone=linked-parked' \
    "linked home was not queried at its own checkout path"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=2\tgaps=0' \
    "identical rows from separately registered repositories were collapsed"
  assert_home_result "$output" local main "$main" 1 1 0 busy
  assert_home_result "$output" local linked "$child" 1 1 0 busy
  pass "linked homes retain checkout-specific ledger coverage"
}

test_linked_homes_share_inherited_ledger() {
  local main child sibling project calls output rc ledger runs gaps status expected
  for ledger in parked-home query-error empty no-runs; do
    main=$(make_home "inherited root/$ledger")
    fm_git_init_commit "$main"
    child="$TMP_ROOT/inherited-child-$ledger"
    sibling="$TMP_ROOT/inherited-sibling-$ledger"
    project="$main/projects/shared"
    git -C "$main" worktree add --quiet --detach "$child" HEAD
    git -C "$main" worktree add --quiet --detach "$sibling" HEAD
    git -C "$main" worktree add --quiet --detach "$project" HEAD
    printf '%s\n' "$main" > "$child/.test-nm-repository"
    printf '%s\n' "$main" > "$sibling/.test-nm-repository"
    printf '%s\n' "$main" > "$project/.test-nm-repository"
    printf -- '- child - inherited ledger (home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
      "$child" > "$main/data/secondmates.md"
    printf -- '- sibling - inherited ledger (home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
      "$sibling" >> "$main/data/secondmates.md"
    calls="$TMP_ROOT/inherited-calls-$ledger"
    rc=0

    output=$(FM_ROOT_OVERRIDE="$main" FM_TEST_NM_CALLS="$calls" run_check "$main") || rc=$?

    case "$ledger" in
      parked-home) expected=1; runs=1; gaps=0; status=busy ;;
      query-error|empty) expected=2; runs=0; gaps=1; status=incomplete ;;
      no-runs) expected=0; runs=0; gaps=0; status=clear ;;
    esac
    expect_code "$expected" "$rc" "inherited $ledger result was lost"
    assert_equals "$main" "$(cat "$calls")" "inherited repository ledger was queried repeatedly"
    assert_home_result "$output" local root@local "$main" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" local main "$main" 2 "$runs" "$gaps" "$status"
    assert_home_result "$output" local child "$child" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" local sibling "$sibling" 1 "$runs" "$gaps" "$status"
    assert_contains "$output" "$(printf 'SUMMARY\tresult=%s\truns=%s\tgaps=%s' "$status" "$runs" "$gaps")" \
      "linked homes counted the inherited result more than once"
  done
  pass "shared ledger outcomes reach every local home and count once per home and fleet"
}

test_unavailable_repository_identity_is_a_gap() {
  local home clone output rc reason
  for clone in identity-failed identity-missing identity-malformed; do
    home=$(make_home "$clone-main")
    make_project "$home" "$clone"
    rc=0

    output=$(run_check "$home") || rc=$?

    expect_code 2 "$rc" "$clone repository identity was accepted as complete coverage"
    case "$clone" in identity-failed) reason=validation-identity-query-failed ;; *) reason=invalid-repository-identity ;; esac
    assert_contains "$output" "clone=$clone"$'\t'"reason=$reason" \
      "$clone repository identity failure was not reported"
  done
  pass "failed and malformed repository identity queries are explicit gaps"
}

test_projects_override_is_scoped_to_active_home() {
  local main child alternate output rc=0
  main=$(make_home override-main)
  child=$(make_home override-child)
  alternate=$(make_home alternate)
  make_project "$alternate" parked
  make_project "$child" parked
  rmdir "$main/projects"
  printf -- '- child - child work (home: %s; scope: child; projects: parked; added 2026-09-14)\n' \
    "$child" > "$main/data/secondmates.md"

  output=$(FM_PROJECTS_OVERRIDE="$alternate/projects" run_check "$main") || rc=$?

  expect_code 1 "$rc" "configured projects directory was omitted"
  assert_contains "$output" $'RUN\thost=local\thome=main\tclone=parked' \
    "active home's override was not scanned"
  assert_contains "$output" $'RUN\thost=local\thome=child\tclone=parked' \
    "active home's override displaced the child's own projects directory"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=2\tgaps=0' \
    "configured and registered project runs were not both counted"
  pass "projects overrides apply to the active home while children retain their directories"
}

test_inaccessible_home_is_a_gap() {
  local main child output rc=0
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skip: home permission denial requires a non-root user\n'
    return
  fi
  main=$(make_home inaccessible-main)
  child=$(make_home inaccessible-child)
  make_project "$child" parked
  printf -- '- child - child work (home: %s; scope: child; projects: parked; added 2026-09-14)\n' \
    "$child" > "$main/data/secondmates.md"
  chmod u-x "$child"

  output=$(run_check "$main") || rc=$?

  chmod u+x "$child"
  expect_code 2 "$rc" "inaccessible home was treated as an empty inventory"
  assert_contains "$output" $'GAP\thost=local\thome=child\tclone=-\treason=home-unreachable' \
    "home access failure did not name the unchecked home"
  pass "home search-permission failures are explicit gaps"
}

test_inaccessible_inventory_directories_are_gaps() {
  local home directory inventory permission output rc reason
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skip: inventory permission denial requires a non-root user\n'
    return
  fi
  for inventory in data projects; do
    for permission in u-x u-r; do
      home=$(make_home "inaccessible-$inventory-$permission")
      directory="$home/$inventory"
      chmod "$permission" "$directory"
      rc=0

      output=$(run_check "$home") || rc=$?

      chmod u+rx "$directory"
      expect_code 2 "$rc" "$inventory with $permission was treated as an empty inventory"
      case "$inventory" in data) reason=registry-unavailable ;; projects) reason='projects-unreachable' ;; esac
      assert_contains "$output" "reason=$reason" "$inventory access failure was not reported"
    done
  done
  pass "unreadable and unsearchable inventory directories are explicit gaps"
}

test_inaccessible_override_ancestors_are_gaps() {
  local home directory inventory output rc reason
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skip: override permission denial requires a non-root user\n'
    return
  fi
  for inventory in data projects; do
    home=$(make_home "inaccessible-override-$inventory")
    directory="$home/overrides"
    mkdir -p "$directory/$inventory"
    chmod u-x "$directory"
    rc=0

    if [ "$inventory" = data ]; then
      output=$(FM_DATA_OVERRIDE="$directory/data" run_check "$home") || rc=$?
      reason=registry-unavailable
    else
      output=$(FM_PROJECTS_OVERRIDE="$directory/projects" run_check "$home") || rc=$?
      reason='projects-unreachable'
    fi

    chmod u+x "$directory"
    expect_code 2 "$rc" "inaccessible $inventory ancestor was treated as a missing directory"
    assert_contains "$output" "reason=$reason" "$inventory ancestor access failure was not reported"
  done
  pass "inaccessible override ancestors cannot hide inventories"
}

test_unconfigured_clone_is_an_explicit_gap() {
  local home output rc=0
  home=$(make_home unconfigured-main)
  make_project "$home" unconfigured

  output=$(run_check "$home") || rc=$?

  expect_code 2 "$rc" "unconfigured clone did not return the incomplete exit code"
  assert_contains "$output" $'GAP\thost=local\thome=main\tclone=unconfigured\treason=validation-not-configured' \
    "unconfigured clone was silently omitted"
  assert_contains "$output" $'SUMMARY\tresult=incomplete\truns=0\tgaps=1' \
    "incomplete summary did not count the clone gap"
  pass "unconfigured clones are explicit gaps"
}

test_malformed_ledger_is_an_explicit_gap() {
  local home output rc=0
  home=$(make_home malformed-main)
  make_project "$home" malformed

  output=$(run_check "$home") || rc=$?

  expect_code 2 "$rc" "malformed ledger did not return the incomplete exit code"
  assert_contains "$output" $'GAP\thost=local\thome=main\tclone=malformed\treason=unparseable-ledger-row' \
    "malformed ledger row was silently omitted"
  pass "unparseable run data makes the census incomplete"
}

test_empty_or_partial_ledger_is_a_gap() {
  local home clone output rc reason
  for clone in empty whitespace partial; do
    home=$(make_home "$clone-main")
    make_project "$home" "$clone"
    rc=0

    output=$(run_check "$home") || rc=$?

    expect_code 2 "$rc" "$clone query output was accepted as an empty ledger"
    case "$clone" in partial) reason=unparseable-ledger-row ;; *) reason=empty-ledger-response ;; esac
    assert_contains "$output" "clone=$clone"$'\t'"reason=$reason" \
      "$clone query output did not produce a coverage gap"
  done
  pass "empty and partial ledger responses are explicit gaps"
}

test_recognized_empty_and_terminal_ledgers_are_clear() {
  local home output rc=0
  home=$(make_home clear-main)
  make_project "$home" terminal
  make_project "$home" no-runs

  output=$(run_check "$home") || rc=$?

  expect_code 0 "$rc" "recognized empty or terminal ledger was not clear"
  assert_contains "$output" $'SUMMARY\tresult=clear\truns=0\tgaps=0' \
    "complete terminal and empty ledgers did not prove quiescence"
  pass "recognized empty and terminal ledgers remain clear"
}

test_perl_fallback_preserves_signal_and_exit_failures() {
  local home toolbin tool clone output rc expected
  home=$(make_home signal-main)
  make_project "$home" signaled
  make_project "$home" query-error
  toolbin="$TMP_ROOT/perl-tools"
  mkdir -p "$toolbin"
  for tool in bash basename dirname date find git sed perl; do
    ln -s "$(command -v "$tool")" "$toolbin/$tool"
  done
  for clone in signaled query-error; do
    rc=0

    output=$(PATH="$FAKEBIN:$toolbin" bash -c \
      '. "$1"; fm_nm_run_bounded "$2" 15 runs --limit 1' \
      _ "$ROOT/bin/fm-nm-run-lib.sh" "$home/projects/$clone" 2>&1) || rc=$?

    case "$clone" in signaled) expected=137 ;; query-error) expected=7 ;; esac
    expect_code "$expected" "$rc" "Perl fallback lost the $clone failure status"
  done
  rc=0

  output=$(PATH="$toolbin" run_check "$home") || rc=$?

  expect_code 2 "$rc" "failed queries through Perl were reported as clear"
  assert_contains "$output" $'clone=signaled\treason=validation-query-failed' \
    "signaled query was not reported as a query failure"
  assert_contains "$output" $'clone=query-error\treason=validation-query-failed' \
    "nonzero query exit was not reported as a query failure"
  pass "Perl fallback preserves signal and nonzero exits and the census reports gaps"
}

test_remote_home_mode_queries_its_repository() {
  local main child calls output rc=0
  main=$(make_home remote-mode-root)
  fm_git_init_commit "$main"
  child="$TMP_ROOT/remote-mode/parked-home"
  fm_git_init_commit "$child"
  calls="$TMP_ROOT/remote-mode-calls"

  output=$(FM_ROOT_OVERRIDE="$main" FM_TEST_NM_CALLS="$calls" \
    run_check "$child" --home-only remote-child fm-spark) || rc=$?

  expect_code 1 "$rc" "remote home mode omitted the home's own repository"
  assert_contains "$output" $'RUN\thost=fm-spark\thome=remote-child\tclone=parked-home' \
    "remote home mode lost the host or home attribution"
  assert_equals "$child" "$(cat "$calls")" "remote home mode did not query only its home repository"
  pass "remote home mode includes the home's own repository"
}

test_remote_modes_reuse_cached_outcomes() {
  local home calls mode counts runs gaps status expected cache output rc expected_gaps
  home=$(make_home cached-home)
  fm_git_init_commit "$home"
  calls="$TMP_ROOT/cached-home-calls"
  : > "$calls"
  for mode in --home-only --root-only; do
    for counts in '0 0 clear 0' '1 0 busy 1' '0 1 incomplete 2' '1 1 incomplete 3' '0 invalid incomplete 2'; do
      read -r runs gaps status expected <<< "$counts"
      cache=$'\nfm-spark\t'"$home"$'\t'"$runs"$'\t'"$gaps"$'\n'
      rc=0

      output=$(FM_ROOT_OVERRIDE="$home" FM_TEST_NM_CALLS="$calls" \
        run_check "$home" "$mode" shared fm-spark "$cache") || rc=$?

      expect_code "$expected" "$rc" "$mode lost the cached outcome in its exit status"
      expected_gaps=$gaps
      if [ "$gaps" = invalid ]; then
        expected_gaps=1
        assert_contains "$output" 'reason=invalid-repository-result' "malformed cache was accepted"
      else
        assert_not_contains "$output" $'GAP\t' "cached gaps were emitted again"
      fi
      assert_home_result "$output" fm-spark shared "$home" 1 "$runs" "$expected_gaps" "$status"
      assert_not_contains "$output" $'RUN\t' "cached runs were emitted again"
    done
  done
  assert_equals '' "$(cat "$calls")" "cached repositories were queried again"
  pass "remote modes retain cached statuses without emitting duplicate records"
}

test_distinct_remote_roots_on_one_host_are_queried_once() {
  local home first second runner calls output rc=0
  home=$(make_home remote-roots-main)
  first="$TMP_ROOT/remote-first"
  second="$TMP_ROOT/remote-second/parked-home"
  fm_git_init_commit "$first"
  fm_git_init_commit "$second"
  runner="$TMP_ROOT/remote-roots-runner"
  calls="$TMP_ROOT/remote-roots-calls"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
case "$1" in
  alpha) root=$FM_TEST_REMOTE_FIRST ;;
  beta) root=$FM_TEST_REMOTE_SECOND ;;
  *) exit 1 ;;
esac
FM_ROOT_OVERRIDE="$root" FM_HOME="$root" "$FM_TEST_QUIESCENCE" "$3" "$4" "$5" "$6"
SH
  chmod +x "$runner"
  printf -- '- alpha - first root (host: fm-spark; root: %s; home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
    "$first" "$first" > "$home/data/secondmates.md"
  printf -- '- beta - second root (host: fm-spark; root: %s; home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
    "$second" "$second" >> "$home/data/secondmates.md"

  output=$(FM_TEST_REMOTE_FIRST="$first" FM_TEST_REMOTE_SECOND="$second" \
    FM_TEST_QUIESCENCE="$CHECK" FM_TEST_NM_CALLS="$calls" FM_NM_ON_BIN="$runner" \
    run_check "$home") || rc=$?

  expect_code 1 "$rc" "second repository on the same remote host was omitted"
  assert_contains "$output" $'RUN\thost=fm-spark\thome=root@fm-spark\tclone=parked-home' \
    "parked run in the second remote root was not reported"
  assert_equals "$ROOT"$'\n'"$first"$'\n'"$second" "$(cat "$calls")" \
    "remote roots were not each queried exactly once across root and home scans"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=1\tgaps=0' \
    "remote root and home scans double-counted or omitted the parked run"
  pass "distinct remote roots on one host are queried once each"
}

test_remote_inherited_ledgers_are_deduplicated_per_host() {
  local home primary inherited separate runner calls output rc ledger runs gaps status expected summary
  runner="$TMP_ROOT/remote-inherited-runner"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
case "$1" in
  shared) home=$FM_TEST_REMOTE_INHERITED ;;
  separate) home=$FM_TEST_REMOTE_SEPARATE ;;
  otherhost) home=$FM_TEST_REMOTE_INHERITED ;;
  *) exit 1 ;;
esac
FM_ROOT_OVERRIDE="$FM_TEST_REMOTE_ROOT" FM_HOME="$home" "$FM_TEST_QUIESCENCE" "$3" "$4" "$5" "$6"
SH
  chmod +x "$runner"
  for ledger in parked-home query-error; do
    home=$(make_home "remote-inherited-main-$ledger")
    primary="$TMP_ROOT/remote-inherited-$ledger/$ledger"
    inherited="$TMP_ROOT/remote-inherited-$ledger/home"
    separate="$TMP_ROOT/remote-inherited-$ledger/linked-parked"
    fm_git_init_commit "$primary"
    git -C "$primary" worktree add --quiet --detach "$inherited" HEAD
    git -C "$primary" worktree add --quiet --detach "$separate" HEAD
    printf '%s\n' "$primary" > "$inherited/.test-nm-repository"
    calls="$TMP_ROOT/remote-inherited-calls-$ledger"
    printf -- '- shared - shared ledger (host: fm-spark; root: %s; home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
      "$primary" "$inherited" > "$home/data/secondmates.md"
    printf -- '- separate - own ledger (host: fm-spark; root: %s; home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
      "$primary" "$separate" >> "$home/data/secondmates.md"
    printf -- '- otherhost - other host ledger (host: fm-other; root: %s; home: %s; scope: firstmate; projects: none; added 2026-09-14)\n' \
      "$primary" "$inherited" >> "$home/data/secondmates.md"
    rc=0

    output=$(FM_TEST_REMOTE_ROOT="$primary" FM_TEST_REMOTE_INHERITED="$inherited" \
      FM_TEST_REMOTE_SEPARATE="$separate" FM_TEST_QUIESCENCE="$CHECK" \
      FM_TEST_NM_CALLS="$calls" FM_NM_ON_BIN="$runner" run_check "$home") || rc=$?

    case "$ledger" in
      parked-home)
        expected=1; runs=1; gaps=0; status=busy
        summary=$'SUMMARY\tresult=busy\truns=3\tgaps=0'
        ;;
      query-error)
        expected=3; runs=0; gaps=1; status=incomplete
        summary=$'SUMMARY\tresult=busy-incomplete\truns=1\tgaps=2'
        ;;
    esac
    expect_code "$expected" "$rc" "remote $ledger outcome was lost"
    assert_equals "$ROOT"$'\n'"$primary"$'\n'"$primary"$'\n'"$separate" "$(cat "$calls")" \
      "remote ledger deduplication ignored resolved identity or host boundaries"
    assert_home_result "$output" fm-spark root@fm-spark "$primary" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" fm-spark shared "$inherited" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" fm-other root@fm-other "$primary" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" fm-other otherhost "$inherited" 1 "$runs" "$gaps" "$status"
    assert_home_result "$output" fm-spark separate "$separate" 1 1 0 busy
    assert_contains "$output" "$summary" "inherited, independent, and same-path remote ledgers were miscounted"
    assert_not_contains "$output" $'REPO\t' "internal repository records leaked into the fleet report"
  done
  pass "remote homes inherit shared outcomes while independent and other-host ledgers remain distinct"
}

test_unreachable_remote_names_host_and_every_home() {
  local home runner output rc=0
  home=$(make_home remote-main)
  runner="$TMP_ROOT/remote-runner"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'ssh: connect to host fm-spark: Operation timed out' >&2
exit 255
SH
  chmod +x "$runner"
  cat > "$home/data/secondmates.md" <<'EOF'
- alpha - alpha work (host: fm-spark; root: /srv/firstmate; home: /srv/homes/alpha; scope: alpha; projects: one; added 2026-09-14)
- beta - beta work (host: fm-spark; root: /srv/firstmate; home: /srv/homes/beta; scope: beta; projects: two; added 2026-09-14)
EOF

  output=$(FM_NM_ON_BIN="$runner" run_check "$home") || rc=$?

  expect_code 2 "$rc" "unreachable host did not return the incomplete exit code"
  assert_contains "$output" $'GAP\thost=fm-spark\thome=root@fm-spark\tclone=-\treason=host-unreachable' \
    "unreachable remote root was not named"
  assert_contains "$output" $'GAP\thost=fm-spark\thome=alpha\tclone=-\treason=host-unreachable' \
    "first unreachable remote home was not named"
  assert_contains "$output" $'GAP\thost=fm-spark\thome=beta\tclone=-\treason=host-unreachable' \
    "second unreachable remote home was not named"
  pass "unreachable host names every unchecked home"
}

test_remote_home_run_is_included() {
  local home runner output rc=0
  home=$(make_home remote-run-main)
  runner="$TMP_ROOT/remote-runner-success"
  cat > "$runner" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in
  --root-only)
    printf 'HOME\thost=%s\thome=%s\tpath=/srv/firstmate\tclones=1\truns=0\tgaps=0\tstatus=clear\n' "$5" "$4"
    ;;
  --home-only)
    printf 'RUN\thost=%s\thome=%s\tclone=alpha\tbranch=fm/remote\thead=deadbee\tstate=running\tage=2h0m\tstarted=2026-09-14T06:00\n' "$5" "$4"
    printf 'HOME\thost=%s\thome=%s\tpath=/srv/homes/alpha\tclones=1\truns=1\tgaps=0\tstatus=busy\n' "$5" "$4"
    exit 1
    ;;
esac
SH
  chmod +x "$runner"
  printf '%s\n' \
    '- alpha - alpha work (host: fm-spark; root: /srv/firstmate; home: /srv/homes/alpha; scope: alpha; projects: one; added 2026-09-14)' \
    > "$home/data/secondmates.md"

  output=$(FM_NM_ON_BIN="$runner" run_check "$home") || rc=$?

  expect_code 1 "$rc" "remote non-terminal run did not return the busy exit code"
  assert_contains "$output" $'RUN\thost=fm-spark\thome=alpha\tclone=alpha\tbranch=fm/remote' \
    "remote home's run was not included"
  assert_contains "$output" $'SUMMARY\tresult=busy\truns=1\tgaps=0' \
    "remote run was not counted in the fleet summary"
  pass "remote home runs are included in the fleet result"
}

test_parked_run_returns_red_with_state_and_age
test_local_secondmate_is_discovered_from_registry
test_projectless_home_repository_is_queried_once
test_linked_home_keeps_its_own_ledger
test_linked_homes_share_inherited_ledger
test_unavailable_repository_identity_is_a_gap
test_projects_override_is_scoped_to_active_home
test_inaccessible_home_is_a_gap
test_inaccessible_inventory_directories_are_gaps
test_inaccessible_override_ancestors_are_gaps
test_unconfigured_clone_is_an_explicit_gap
test_malformed_ledger_is_an_explicit_gap
test_empty_or_partial_ledger_is_a_gap
test_recognized_empty_and_terminal_ledgers_are_clear
test_perl_fallback_preserves_signal_and_exit_failures
test_remote_home_mode_queries_its_repository
test_remote_modes_reuse_cached_outcomes
test_distinct_remote_roots_on_one_host_are_queried_once
test_remote_inherited_ledgers_are_deduplicated_per_host
test_unreachable_remote_names_host_and_every_home
test_remote_home_run_is_included
