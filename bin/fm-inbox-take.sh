#!/usr/bin/env bash
# Atomically take the next durable task instruction from an inbox.
#
# Usage: fm-inbox-take.sh <inbox-dir>
#
# Moves the lowest-numbered unhandled .msg record into handled/ with one rename,
# then prints its body. Concurrent invocations have one rename winner. Exit 1
# means the inbox is empty or unavailable and prints no instruction body.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
record=$(fm_task_inbox_take "$1") || exit 1
fm_task_inbox_body "$record"
