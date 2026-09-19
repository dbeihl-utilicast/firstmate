#!/usr/bin/env bash
# fm-secondmate-lane.sh - the captain's stop and reopen verbs for a secondmate lane.
#
# Usage: fm-secondmate-lane.sh stop <id>
#        fm-secondmate-lane.sh reopen <id>
#
#   stop    Record state/<id>.stopped, then exit the mate's agent through the
#           control plane, keeping its endpoint, home, and every uncommitted
#           change. The marker is written first, so a failure or crash after it
#           still leaves the lane held down. A remote mate is stopped on its
#           host through fm-remote-secondmate-control.sh stop.
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

if ! { [ -f "$META" ] && grep -q '^kind=secondmate$' "$META"; }; then
  die "no registered secondmate '$ID' in $STATE"
fi
REMOTE_HOST=$(fm_meta_get "$META" remote_host)

case "$VERB" in
  stop)
    printf 'stopped %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
    if [ -n "$REMOTE_HOST" ]; then
      "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh stop "$ID" < /dev/null
    else
      "$SCRIPT_DIR/fm-control.sh" "$ID" exit
      echo
    fi
    ;;
  reopen)
    rm -f -- "$MARKER"
    "$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate
    ;;
  *) die "unknown verb '$VERB'; expected stop or reopen" ;;
esac
