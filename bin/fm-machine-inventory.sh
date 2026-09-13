#!/usr/bin/env bash
# fm-machine-inventory.sh - report host-wide resource leaks that need a human
# owner, and remain silent only when every requested measurement is available
# and below its threshold.
#
# Usage:
#   fm-machine-inventory.sh [--help]
#
# The command is strictly observational.
# It never stops, signals, restarts, or changes a process, container, or
# simulator.
#
# Every successful scan covers the whole host rather than a configured port or
# Firstmate-home subset:
#   - TCP LISTEN and UDP bound network sockets from lsof
#   - every running Docker container
#   - every booted CoreSimulator device
#   - every process recognized by fm-agent-process-lib.sh
#   - the fifteen-minute load average against online CPU cores
#
# Unix-domain sockets are intentionally outside the network-listener category.
# The command's name and output therefore never claim to inventory them.
# A missing command, inaccessible system-wide result, or failed query emits a
# NOT CHECKED finding instead of silently making a broader claim than it proved.
#
# FM_MACHINE_INVENTORY_AGE_SECS is the strictly-greater-than age threshold for
# listeners, containers, and agent processes, in seconds.
# It defaults to 86400 (one day).
# FM_MACHINE_INVENTORY_LOAD_PER_CORE is the fifteen-minute load permitted per
# online CPU core, and defaults to 1.
# FM_MACHINE_INVENTORY_NOW is an epoch-seconds test hook for Docker timestamps.
#
# Exit 0 means every measurement completed and no finding exceeded its rule.
# Exit 1 means at least one leak or unmeasured category was reported.
# Exit 2 means invalid invocation or configuration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '1,36p' "$0"
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

AGE_SECS=${FM_MACHINE_INVENTORY_AGE_SECS:-86400}
LOAD_PER_CORE=${FM_MACHINE_INVENTORY_LOAD_PER_CORE:-1}
case "$AGE_SECS" in ''|*[!0-9]*) echo 'fm-machine-inventory: FM_MACHINE_INVENTORY_AGE_SECS must be whole seconds' >&2; exit 2 ;; esac
case "$LOAD_PER_CORE" in ''|*[!0-9.]*|*.*.*) echo 'fm-machine-inventory: FM_MACHINE_INVENTORY_LOAD_PER_CORE must be a decimal number' >&2; exit 2 ;; esac

# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine-inventory.XXXXXX") || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM
FINDINGS="$TMP_ROOT/findings"
: > "$FINDINGS"

finding() {
  printf '%s\n' "$*" >> "$FINDINGS"
}

elapsed_seconds() {  # [[days-]hours:]minutes:seconds -> integer seconds
  local elapsed=$1 days=0 hours=0 minutes=0 seconds=0 rest
  case "$elapsed" in
    *-*) days=${elapsed%%-*}; rest=${elapsed#*-} ;;
    *) rest=$elapsed ;;
  esac
  IFS=: read -r hours minutes seconds <<EOF
$rest
EOF
  if [ -z "${seconds:-}" ]; then
    seconds=$minutes
    minutes=$hours
    hours=0
  fi
  case "$days:$hours:$minutes:$seconds" in *[!0-9:]*|*::*|:*) return 1 ;; esac
  printf '%s\n' $((10#$days * 86400 + 10#$hours * 3600 + 10#$minutes * 60 + 10#$seconds))
}

pid_elapsed() {  # <pid> -> ps etime, or empty
  ps -o etime= -p "$1" 2>/dev/null | awk 'NR == 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }'
}

report_listener_records() {  # <protocol> <lsof output>
  local protocol=$1 records=$2 pid='' command='' line age age_seconds
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      p*) pid=${line#p} ;;
      c*) command=${line#c} ;;
      n*)
        age=$(pid_elapsed "$pid")
        age_seconds=$(elapsed_seconds "$age" 2>/dev/null || true)
        if [ -z "$age_seconds" ]; then
          finding "NOT CHECKED: $protocol socket pid=$pid command=${command:-unknown} age unreadable"
        elif [ "$age_seconds" -gt "$AGE_SECS" ]; then
          finding "LISTENER: protocol=$protocol pid=$pid age=$age command=${command:-unknown} endpoint=${line#n}"
        fi
        ;;
    esac
  done < "$records"
}

scan_listeners() {
  local protocol=$1; shift
  local output="$TMP_ROOT/lsof-$protocol" errors="$TMP_ROOT/lsof-$protocol.err" rc
  if ! command -v lsof >/dev/null 2>&1; then
    finding "NOT CHECKED: $protocol network sockets (lsof unavailable)"
    return
  fi
  lsof -nP "$@" -Fpcn > "$output" 2> "$errors"
  rc=$?
  if [ "$rc" -gt 1 ] || [ -s "$errors" ]; then
    finding "NOT CHECKED: $protocol network sockets (lsof query incomplete)"
    return
  fi
  report_listener_records "$protocol" "$output"
}

scan_listeners TCP -iTCP -sTCP:LISTEN
scan_listeners UDP -iUDP

online_cores() {
  local cores
  cores=$(sysctl -n hw.ncpu 2>/dev/null || true)
  case "$cores" in ''|*[!0-9]*) cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true) ;; esac
  case "$cores" in ''|*[!0-9]*|0) return 1 ;; esac
  printf '%s\n' "$cores"
}

load15() {
  if [ -r /proc/loadavg ]; then
    awk '{ print $3 }' /proc/loadavg
    return
  fi
  sysctl -n vm.loadavg 2>/dev/null | awk '{ gsub(/[{}]/, ""); print $3 }'
}

scan_load() {
  local cores load threshold
  cores=$(online_cores || true)
  load=$(load15 || true)
  case "$cores" in ''|*[!0-9]*) finding 'NOT CHECKED: fifteen-minute load (online CPU core count unavailable)'; return ;; esac
  case "$load" in ''|*[!0-9.]*|*.*.*) finding 'NOT CHECKED: fifteen-minute load average unavailable'; return ;; esac
  threshold=$(awk -v cores="$cores" -v per_core="$LOAD_PER_CORE" 'BEGIN { printf "%.2f", cores * per_core }')
  if awk -v load="$load" -v threshold="$threshold" 'BEGIN { exit !(load > threshold) }'; then
    finding "LOAD: fifteen-minute=$load cores=$cores threshold=$threshold"
  fi
}

scan_load

docker_started_epoch() {  # <RFC3339 timestamp> -> epoch seconds
  local stamp=${1%%.*} normalized
  normalized=${stamp%Z}
  if date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s >/dev/null 2>&1; then
    date -j -u -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s
  elif date -u -d "${normalized}Z" +%s >/dev/null 2>&1; then
    date -u -d "${normalized}Z" +%s
  else
    return 1
  fi
}

scan_containers() {
  local ids="$TMP_ROOT/docker-ids" errors="$TMP_ROOT/docker.err" id name started now started_epoch age
  if ! command -v docker >/dev/null 2>&1; then
    finding 'NOT CHECKED: running containers (docker unavailable)'
    return
  fi
  if ! docker ps --format '{{.ID}}\t{{.Names}}' > "$ids" 2> "$errors"; then
    finding 'NOT CHECKED: running containers (docker daemon query failed)'
    return
  fi
  now=${FM_MACHINE_INVENTORY_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) finding 'NOT CHECKED: running containers (clock unavailable)'; return ;; esac
  while IFS=$'\t' read -r id name || [ -n "$id" ]; do
    [ -n "$id" ] || continue
    started=$(docker inspect --format '{{.State.StartedAt}}' "$id" 2>/dev/null || true)
    started_epoch=$(docker_started_epoch "$started" 2>/dev/null || true)
    if [ -z "$started_epoch" ] || [ "$started_epoch" -gt "$now" ]; then
      finding "NOT CHECKED: running container id=$id name=${name:-unknown} uptime unreadable"
      continue
    fi
    age=$((now - started_epoch))
    if [ "$age" -gt "$AGE_SECS" ]; then
      finding "CONTAINER: id=$id name=${name:-unknown} uptime=${age}s"
    fi
  done < "$ids"
}

scan_containers

scan_simulators() {
  local output="$TMP_ROOT/simulators" errors="$TMP_ROOT/simulators.err"
  if ! command -v xcrun >/dev/null 2>&1; then
    finding 'NOT CHECKED: booted simulators (xcrun unavailable)'
    return
  fi
  if ! xcrun simctl list devices booted > "$output" 2> "$errors"; then
    finding 'NOT CHECKED: booted simulators (simctl query failed)'
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *'(Booted)'*) finding "SIMULATOR: ${line#"${line%%[![:space:]]*}"}" ;; esac
  done < "$output"
}

scan_simulators

scan_agent_processes() {
  local output="$TMP_ROOT/processes" errors="$TMP_ROOT/processes.err" pid elapsed comm command argv0 age
  if ! ps -axo pid=,etime=,comm=,command= > "$output" 2> "$errors"; then
    finding 'NOT CHECKED: agent processes (process table query failed)'
    return
  fi
  while read -r pid elapsed comm command; do
    [ -n "${pid:-}" ] || continue
    argv0=${command%%[[:space:]]*}
    [ "$(fm_agent_process_classify "$comm" "$argv0" "$command" "$pid")" = agent ] || continue
    age=$(elapsed_seconds "$elapsed" 2>/dev/null || true)
    if [ -z "$age" ]; then
      finding "NOT CHECKED: agent process pid=$pid command=$command age unreadable"
    elif [ "$age" -gt "$AGE_SECS" ]; then
      finding "AGENT: pid=$pid age=$elapsed command=${argv0:-$comm}"
    fi
  done < "$output"
}

scan_agent_processes

if [ -s "$FINDINGS" ]; then
  sort -u "$FINDINGS"
  exit 1
fi
