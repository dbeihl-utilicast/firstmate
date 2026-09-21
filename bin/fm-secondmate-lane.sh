#!/usr/bin/env bash
# fm-secondmate-lane.sh - the captain's stop and reopen verbs for a secondmate lane.
#
# Usage: fm-secondmate-lane.sh stop <id>
#        fm-secondmate-lane.sh reopen <id>
#
#   stop    Record state/<id>.stopped, then exit the mate's agent through the
#           control plane, keeping its endpoint, home, and every uncommitted
#           change. The marker is written first, so a failure or crash after it
#           still leaves the lane held down. A missing recorded endpoint is
#           already the state this verb wants, so stop treats that as complete
#           rather than an error; any other control-plane failure is still
#           reported. A remote mate is stopped on its host through
#           fm-remote-secondmate-control.sh stop.
#   reopen  Remove the marker, then relaunch the mate through fm-spawn.sh
#           --secondmate. Reopen is the only path that clears the marker.
#
# The marker is what bin/fm-bootstrap.sh's session-start liveness sweep honors:
# a stopped mate is never relaunched, whatever its endpoint reads. Run these
# only on the captain's word; retiring a lane for good stays with
# bin/fm-teardown.sh, which also removes the marker.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[ "$#" -eq 2 ] || die "usage: fm-secondmate-lane.sh stop|reopen <id>"
VERB=$1
ID=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

[ -n "${FM_HOME:-}" ] || die "FM_HOME is not set; refusing to resolve a lane without an explicit firstmate home"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"
MARKER="$STATE/$ID.stopped"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if ! { [ -f "$META" ] && grep -q '^kind=secondmate$' "$META"; }; then
  die "no registered secondmate '$ID' in $STATE"
fi
REMOTE_HOST=$(fm_meta_get "$META" remote_host)

# Run the post-marker exit. A gone endpoint is already stopped; any other
# failure is still the caller's error. Prints the child's stdout/stderr on
# success or on a real failure, and stays silent on the gone-endpoint case
# because that message is no longer an error.
run_stop_exit() {
  local out rc=0
  out=$("$@" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"recorded endpoint is gone"*) return 0 ;;
    esac
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
  echo
  return 0
}

case "$VERB" in
  stop)
    META_LOCK=$(fm_meta_lock_path "$META") || die "could not resolve metadata lock for '$ID'"
    fm_lock_acquire_wait "$META_LOCK"
    if ! printf 'stopped %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"; then
      fm_lock_release "$META_LOCK"
      die "could not record stopped marker for '$ID'"
    fi
    fm_lock_release "$META_LOCK"
    if [ -n "$REMOTE_HOST" ]; then
      run_stop_exit "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh stop "$ID"
    else
      run_stop_exit "$SCRIPT_DIR/fm-control.sh" "$ID" exit
    fi
    ;;
  reopen)
    rm -f -- "$MARKER"
    "$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate
    ;;
  *) die "unknown verb '$VERB'; expected stop or reopen" ;;
esac
