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
case "$(basename "$PWD")" in
  parked)
    printf '%s\n' 'running fm/parked a1b2c3d4 2026-09-13 08:00'
    ;;
  unconfigured)
    printf '%s\n' "repo not initialized (run 'no-mistakes init' first)" >&2
    exit 1
    ;;
  malformed)
    printf '%s\n' 'running incomplete-row'
    ;;
  *)
    printf '%s\n' 'no runs yet. Push through the gate to start a pipeline:'
    printf '%s\n' 'git push no-mistakes <branch>'
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
test_unconfigured_clone_is_an_explicit_gap
test_malformed_ledger_is_an_explicit_gap
test_unreachable_remote_names_host_and_every_home
test_remote_home_run_is_included
