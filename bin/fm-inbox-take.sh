#!/usr/bin/env bash
# Atomically take the next durable task instruction from an inbox.
#
# Usage: fm-inbox-take.sh <inbox-dir>
#
# Claims the lowest-numbered unhandled .msg record with one rename, prints its
# body, then completes it into handled/. Concurrent invocations have one claim
# winner. A later take recovers a dead or expired claimant. Exit 1 means the
# inbox is empty or unavailable and prints no instruction body.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
claimant="${BASHPID:-$$}-$(date +%s)-$RANDOM"
record=$(fm_task_inbox_claim "$1" "$claimant") || exit 1
fm_task_inbox_body "$record"
fm_task_inbox_complete_claim "$1" "$record"
