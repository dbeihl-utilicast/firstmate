#!/usr/bin/env bash
# Per-step no-mistakes fix-round counter and cap for an active run.
#
# Usage:
#   fm-nm-fix-round.sh observe --task <id> [--status-file <path> | --worktree <dir>]
#   fm-nm-fix-round.sh guard --task <id> --action <approve|fix|skip> [--status-file <path> | --worktree <dir>]
#   fm-nm-fix-round.sh count --task <id> --run <run-id> --step <name>
#
# This script is the single owner of firstmate's own per-step auto-fix cap.
# It does not fork or modify the no-mistakes product. `axi status` is TOON,
# not JSON; any `active_steps[].round` string such as "auto-fix 1/3" is the
# product's per-respond display and is never the cap.
#
# observe reads one status snapshot, records a fixing -> re-review/re-test
# transition against state/<task>.nm-fix-rounds, and prints:
#   run=  step=  count=  phase=  verdict=
# verdict is allow-fix (a gate with count < 3), cap (a gate at 3), or none.
# At cap it also prints next=approve-or-skip-or-escalate and
# escalation_key=nm-<run>-<step>-fix-cap.
#
# guard observes, then allows approve or skip at a gate, allows fix only
# below the cap, and refuses a fourth silent fix (exit 3). It never invokes
# `no-mistakes axi respond`; the worker still owns every respond.
#
# --status-file reads captured TOON. --worktree (or the current directory)
# runs a bounded `no-mistakes axi status` in that tree. Exactly one of those
# sources is required for observe and guard.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-nm-fix-round-lib.sh
. "$SCRIPT_DIR/fm-nm-fix-round-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
  exit 2
}

CMD=
TASK=
ACTION=
RUN_ID=
STEP=
STATUS_FILE=
WORKTREE=
NM_TIMEOUT=${FM_NM_FIX_ROUND_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac

[ "$#" -gt 0 ] || usage
CMD=$1
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ -n "${2:-}" ] || die "--task needs an id"
      TASK=$2
      shift 2
      ;;
    --action)
      [ -n "${2:-}" ] || die "--action needs approve, fix, or skip"
      ACTION=$2
      shift 2
      ;;
    --run)
      [ -n "${2:-}" ] || die "--run needs a run id"
      RUN_ID=$2
      shift 2
      ;;
    --step)
      [ -n "${2:-}" ] || die "--step needs a step name"
      STEP=$2
      shift 2
      ;;
    --status-file)
      [ -n "${2:-}" ] || die "--status-file needs a path"
      STATUS_FILE=$2
      shift 2
      ;;
    --worktree)
      [ -n "${2:-}" ] || die "--worktree needs a directory"
      WORKTREE=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

read_status_toon() {
  local out
  if [ -n "$STATUS_FILE" ] && [ -n "$WORKTREE" ]; then
    die "use either --status-file or --worktree, not both"
  fi
  if [ -n "$STATUS_FILE" ]; then
    [ -f "$STATUS_FILE" ] || die "status file not found: $STATUS_FILE"
    cat "$STATUS_FILE"
    return 0
  fi
  [ -n "$WORKTREE" ] || WORKTREE=$PWD
  [ -d "$WORKTREE" ] || die "worktree not found: $WORKTREE"
  out=$(fm_nm_run_bounded "$WORKTREE" "$NM_TIMEOUT" axi status) || die "no-mistakes axi status failed"
  printf '%s' "$out"
}

case "$CMD" in
  observe)
    [ -n "$TASK" ] || die "observe requires --task"
    TOON=$(read_status_toon) || exit $?
    fm_nm_fix_round_observe "$TASK" "$TOON" || die "observe refused task id '$TASK'"
    fm_nm_fix_round_print
    ;;
  guard)
    [ -n "$TASK" ] || die "guard requires --task"
    case "$ACTION" in
      approve|fix|skip) ;;
      *) die "guard --action must be approve, fix, or skip" ;;
    esac
    TOON=$(read_status_toon) || exit $?
    fm_nm_fix_round_guard "$TASK" "$ACTION" "$TOON"
    rc=$?
    fm_nm_fix_round_print
    if [ "$rc" -eq 3 ]; then
      printf 'error: fix-round cap reached for step %s; respond approve or skip, or escalate needs-decision [key=%s]\n' \
        "$FM_NM_FR_STEP" "nm-${FM_NM_FR_RUN_ID}-${FM_NM_FR_STEP}-fix-cap" >&2
      exit 3
    fi
    [ "$rc" -eq 0 ] || die "guard refused --action $ACTION (phase=$FM_NM_FR_PHASE verdict=$FM_NM_FR_VERDICT)"
    ;;
  count)
    if [ -z "$TASK" ] || [ -z "$RUN_ID" ] || [ -z "$STEP" ]; then
      die "count requires --task, --run, and --step"
    fi
    if ! fm_nm_fr_valid_id "$TASK" || ! fm_nm_fr_valid_id "$RUN_ID" || ! fm_nm_fr_valid_id "$STEP"; then
      die "count requires valid --task, --run, and --step"
    fi
    fm_nm_fix_round_count "$TASK" "$RUN_ID" "$STEP"
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "unknown command: $CMD (expected observe, guard, or count)"
    ;;
esac
