#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-inventory.sh.
#
# The command is intentionally silent only when each host-wide category is
# measured and stays within its threshold.
# These tests drive its executable interface through fake host tools, proving
# old listeners, load, containers, simulators, agent processes, and unavailable
# measurement surfaces are reported without ever invoking a lifecycle command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INVENTORY="$ROOT/bin/fm-machine-inventory.sh"
TMP_ROOT=$(fm_test_tmproot fm-machine-inventory)

make_case() {  # <name> -> case root with fake host tools
  local case_dir=$TMP_ROOT/$1
  mkdir -p "$case_dir/fakebin"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case "${FM_INVENTORY_LSOF:-quiet}" in
  listener)
    case " $* " in *' -iTCP '*) printf 'p101\nccodex\nn*:4310\n' ;; *) printf 'p102\nccnode\nn*:5353\n' ;; esac ;;
  error) echo 'lsof fixture error' >&2; exit 2 ;;
esac
SH
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -o ]; then printf '%s\n' "${FM_INVENTORY_PID_ETIME:-2-00:00:00}"; exit 0; fi
case "${FM_INVENTORY_PS:-quiet}" in
  agent) printf ' 202  2-00:00:00 codex /opt/homebrew/bin/codex --resume\n' ;;
esac
SH
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ps) [ "${FM_INVENTORY_DOCKER:-quiet}" = old ] && printf 'abc123\tforgotten\n'; exit 0 ;;
  inspect) printf '%s\n' '2026-09-10T00:00:00.000000000Z' ;;
esac
SH
  cat > "$case_dir/fakebin/xcrun" <<'SH'
#!/usr/bin/env bash
if [ "${FM_INVENTORY_SIMULATOR:-quiet}" = booted ]; then
  cat <<'JSON'
{ "devices": { "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
  { "udid": "00000000-0000-0000-0000-000000000001", "name": "iPhone 16", "state": "Booted", "lastBootedAt": "2026-09-10T00:00:00Z" },
  { "udid": "00000000-0000-0000-0000-000000000002", "name": "iPhone Fresh", "state": "Booted", "lastBootedAt": "2026-09-12T23:55:00Z" },
  { "udid": "00000000-0000-0000-0000-000000000003", "name": "iPhone Off", "state": "Shutdown", "lastBootedAt": "2026-09-01T00:00:00Z" }
] } }
JSON
else
  printf '%s\n' '{ "devices": {} }'
fi
SH
  cat > "$case_dir/fakebin/sysctl" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in hw.ncpu) printf '%s\n' 10 ;; vm.loadavg) printf '{ 1.00 2.00 %s }\n' "${FM_INVENTORY_LOAD15:-1.00}" ;; esac
SH
  cat > "$case_dir/fakebin/getconf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 10
SH
  cat > "$case_dir/fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_INVENTORY_UID:-0}"
SH
  cat > "$case_dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != -j ]; then printf '%s\n' 1789257600; exit 0; fi
case "$*" in *T23:55:00*) printf '%s\n' 1789257300 ;; *) printf '%s\n' 1788998400 ;; esac
SH
  chmod +x "$case_dir/fakebin"/*
  printf '%s\n' "$case_dir"
}

run_inventory() {  # <case-dir>
  PATH="$1/fakebin:$PATH" "$INVENTORY"
}

test_silent_when_everything_is_measured_and_healthy() {
  local case_dir output rc
  case_dir=$(make_case quiet)
  set +e
  output=$(run_inventory "$case_dir" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "healthy inventory exited $rc: $output"
  [ -z "$output" ] || fail "healthy inventory was not silent: $output"
  pass 'healthy complete inventory is silent'
}

test_reports_old_listener_with_age_and_owner() {
  local case_dir output
  case_dir=$(make_case listener)
  output=$(FM_INVENTORY_LSOF=listener run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'LISTENER: protocol=TCP pid=101 age=2-00:00:00 command=codex endpoint=*:4310' 'old listener omitted age, owner, or endpoint'
  pass 'old whole-host listener names its age and owner'
}

test_non_root_listener_scan_reports_other_users_as_unmeasured() {
  local case_dir output
  case_dir=$(make_case non-root)
  output=$(FM_INVENTORY_UID=501 FM_INVENTORY_LSOF=listener run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: TCP network sockets owned by other users (not run as root)' 'non-root TCP scan claimed whole-host coverage'
  assert_contains "$output" 'NOT CHECKED: UDP network sockets owned by other users (not run as root)' 'non-root UDP scan claimed whole-host coverage'
  assert_contains "$output" 'LISTENER: protocol=TCP pid=101' 'non-root scan dropped the sockets it could see'
  pass 'non-root listener scan narrows its claim to the caller'
}

test_reports_each_other_leak_class() {
  local case_dir output
  case_dir=$(make_case leaks)
  output=$(FM_INVENTORY_LOAD15=31.00 FM_INVENTORY_PS=agent FM_INVENTORY_DOCKER=old FM_INVENTORY_SIMULATOR=booted run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'LOAD: fifteen-minute=31.00 cores=10' 'ten-core host at fifteen-minute load 31 was omitted'
  assert_contains "$output" 'CONTAINER: id=abc123 name=forgotten uptime=259200s' 'old container was omitted'
  assert_contains "$output" 'SIMULATOR: udid=00000000-0000-0000-0000-000000000001 name=iPhone 16 uptime=259200s' 'old booted simulator was omitted'
  assert_not_contains "$output" 'iPhone Fresh' 'recently booted simulator was reported'
  assert_not_contains "$output" 'iPhone Off' 'shutdown simulator was reported'
  assert_contains "$output" 'AGENT: pid=202 age=2-00:00:00 command=/opt/homebrew/bin/codex' 'old agent process was omitted'
  pass 'load, containers, simulators, and agent processes report violations'
}

test_reports_incomplete_measurement_instead_of_claiming_the_host_is_clean() {
  local case_dir output
  case_dir=$(make_case incomplete)
  output=$(FM_INVENTORY_LSOF=error run_inventory "$case_dir" 2>&1 || true)
  assert_contains "$output" 'NOT CHECKED: TCP network sockets (lsof query incomplete)' 'failed TCP scan was silent'
  assert_contains "$output" 'NOT CHECKED: UDP network sockets (lsof query incomplete)' 'failed UDP scan was silent'
  pass 'incomplete listener scan narrows the claim visibly'
}

test_silent_when_everything_is_measured_and_healthy
test_reports_old_listener_with_age_and_owner
test_non_root_listener_scan_reports_other_users_as_unmeasured
test_reports_each_other_leak_class
test_reports_incomplete_measurement_instead_of_claiming_the_host_is_clean
