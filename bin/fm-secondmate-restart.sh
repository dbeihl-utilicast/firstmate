#!/usr/bin/env bash
# Restart second mates onto the current instruction surface and launch-time
# wiring, persisting their open records first.
#
# Usage: fm-secondmate-restart.sh [--harness <name>] [--model <name>]
#                                 [--effort <level>] <secondmate-id>...
#
# This is the executable half of /updatefirstmate's reload step. A running agent
# holds AGENTS.md and every skill it has loaded frozen from launch, and no
# verified harness offers a reload, so a re-read steer cannot replace either -
# it appends a second copy of the mate's own job description with no defined
# precedence. Replacing the agent is the only mechanism that guarantees the new
# bytes are the ones read, and the only one that reconstructs the launch-time
# wiring - harness, model, effort, turn-end hooks, and every other flag a harness
# reads once at startup. A restart preserves the runtime recorded for each mate;
# the optional profile flags deliberately change every named mate instead of
# consulting the fleet-wide default. That second half is why the update pass sends every live
# mate here, including one already on the target commit: launch-time wiring is
# not derivable from a git diff, so an unchanged tracked surface does not mean
# the running agent is already on the current behavior.
#
# The cost of that guarantee is the conversation, which is why this command runs
# in two phases and why the first one is a GATE, not a courtesy:
#
#   A. PERSIST. Every mate is asked, in one marked request, to durably record the
#      open work it holds only in conversation - a task for each unfiled open
#      record, including a captain call it formed but never registered, and a
#      status correction for each task whose recorded state is now stale. That is
#      the /stow skill's "Open-record persistence" contract and nothing else from
#      it: no memory, learnings, or captain-preference sweep, which would make
#      every instruction update cost far more than the reload it is paying for.
#      All requests go out before any restart, so a slow mate delays only its own
#      restart instead of serializing the fleet behind it.
#   B. RESTART. Only after that mate's own correlated answer lands on the parent
#      channel. The gate is that answer, never a wall clock, so a mate that is
#      mid-turn queues the request behind that turn; the bound below exists to
#      end the wait, not to authorize a restart without the answer. A timeout
#      deliberately leaves that unanswered expectation open: it is a genuine
#      open loop owned by the ordinary pending-reply recovery ladder, not state
#      this restart pass may close.
#
# A mate that cannot enter the restart phase gets the ordinary re-read nudge and
# is reported as a nudge, never as a clean reload. A failed remote prelaunch
# convergence is reported as unreached; after a relaunch attempt, a failed or
# ambiguous result is reported as unknown rather than attributed to an incarnation.
#
# Placement changes the prelaunch path as well as the transport. A local mate is
# restarted with bin/fm-control.sh <id> relaunch. A remote mate first holds the
# inheritance lock, pushes current config, and passes host readiness. It then
# runs that same control plane on its host over bin/fm-on.sh, through the
# host-local fm-remote-secondmate-control.sh relaunch verb. The profile and
# outcome report remain computed here in the primary for both placements, and
# once the host reports the relaunch a remote mate's primary record is updated to
# the profile that host actually launched, so the next plain restart keeps it.
#
# Nothing here forces, stashes, or discards anything. bin/fm-control.sh owns the
# restart transaction, its checkpoint, its journal, and its rollback; a refusal
# before the agent is stopped leaves the mate running exactly as it was.
#
# A lane with state/<id>.stopped is skipped and reported, never restarted or nudged.
#
# Restart candidacy itself belongs to bin/fm-update.sh, which knows which homes
# the update pass actually left on the target commit; this command re-checks
# capability on its own argv rather than trusting a caller's list.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for one mate's persist answer (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
#
# Exit status: 0 every named mate restarted; 3 at least one was nudged or left
# unreached and every mate was still accounted for; 1 the input itself is
# unusable; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,67{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-restart refuses to resolve second mates without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-restart cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac

IDS=()
DUPLICATE_IDS=()
TOTAL_INPUTS=0
PROFILE_HARNESS=""
PROFILE_MODEL=""
PROFILE_EFFORT=""
PROFILE_HARNESS_SET=0
PROFILE_MODEL_SET=0
PROFILE_EFFORT_SET=0
want_value=""
for arg in "$@"; do
  if [ -n "$want_value" ]; then
    case "$want_value" in
      harness) PROFILE_HARNESS=$arg; PROFILE_HARNESS_SET=1 ;;
      model) PROFILE_MODEL=$arg; PROFILE_MODEL_SET=1 ;;
      effort) PROFILE_EFFORT=$arg; PROFILE_EFFORT_SET=1 ;;
    esac
    want_value=""
    continue
  fi
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --harness) want_value=harness; continue ;;
    --harness=*) PROFILE_HARNESS=${arg#--harness=}; PROFILE_HARNESS_SET=1; continue ;;
    --model) want_value=model; continue ;;
    --model=*) PROFILE_MODEL=${arg#--model=}; PROFILE_MODEL_SET=1; continue ;;
    --effort) want_value=effort; continue ;;
    --effort=*) PROFILE_EFFORT=${arg#--effort=}; PROFILE_EFFORT_SET=1; continue ;;
    -*) echo "error: unexpected argument '$arg'" >&2; usage >&2; exit 2 ;;
  esac
  # /updatefirstmate's action line names each mate by its fm-<id> selector; the
  # bare id is equally acceptable so a hand-run stays natural.
  id=${arg#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $arg" >&2; exit 2 ;; esac
  TOTAL_INPUTS=$((TOTAL_INPUTS + 1))
  case " ${IDS[*]:-} " in
    *" $id "*) DUPLICATE_IDS+=("$id"); continue ;;
  esac
  IDS+=("$id")
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
[ "$PROFILE_HARNESS_SET" -eq 0 ] || [ -n "$PROFILE_HARNESS" ] || { echo "error: --harness requires a non-empty value" >&2; exit 2; }
[ "$PROFILE_MODEL_SET" -eq 0 ] || [ -n "$PROFILE_MODEL" ] || { echo "error: --model requires a non-empty value" >&2; exit 2; }
[ "$PROFILE_EFFORT_SET" -eq 0 ] || [ -n "$PROFILE_EFFORT" ] || { echo "error: --effort requires a non-empty value" >&2; exit 2; }
case "$PROFILE_EFFORT" in ''|default|low|medium|high|xhigh|max|ultra) ;; *) echo "error: --effort must be default, low, medium, high, xhigh, max, or ultra" >&2; exit 2 ;; esac
[ "${#IDS[@]}" -gt 0 ] || { usage >&2; exit 2; }

# Per-mate pass state, kept as parallel indexed arrays so this stays bash-3.2
# safe. PLAN is the phase the mate reached: persist-sent, or fallback with the
# reason already decided.
PLAN=()
REASON=()
CORR=()
DEADLINE=()
PLACEMENT=()
HOST=()
HARNESS=()
MODEL=()
EFFORT=()
RESTART_PID=()
RESTART_RESULT=()
OUTCOME=()

restarted_count=0
nudged_count=0
unreached_count=0
skipped_count=0

for id in "${DUPLICATE_IDS[@]+"${DUPLICATE_IDS[@]}"}"; do
  skipped_count=$((skipped_count + 1))
  printf 'skipped: %s: duplicate argument; the mate is processed once\n' "$id"
done

# The first line of a command's output that carries anything, flattened to one
# readable line with its "error: " prefix dropped. A refusal's own words are the
# most useful thing this report can carry, and its first line is often blank.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

# Send the ordinary re-read steer to a mate this pass will not restart, and say
# plainly which it was. A nudge is a partial reload and is never reported as more.
fall_back_to_nudge() {  # <id> <reason>
  local id=$1 reason=$2 out
  if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECOND_MATE_NUDGE_MESSAGE" 2>&1); then
    nudged_count=$((nudged_count + 1))
    printf 'nudged: %s: %s\n' "$id" "$reason"
  else
    unreached_count=$((unreached_count + 1))
    printf 'unreached: %s: %s; the re-read message could not be delivered either: %s\n' \
      "$id" "$reason" "$(first_reported_line "$out")"
  fi
}

report_unreached() {  # <id> <reason>
  unreached_count=$((unreached_count + 1))
  printf 'unreached: %s: %s\n' "$1" "$2"
}

restart_mate() {  # <array-index>
  local i=$1 id restart_out restart_rc restart_reason ran_on record_err
  local remote_lock remote_generation remote_rc
  id=${IDS[$i]}
  if [ "${PLACEMENT[i]}" = remote ]; then
    remote_lock=$(fm_remote_inherit_transaction_lock_path "$STATE" "$id") || {
      report_unreached "$id" "the restart could not lock inherited config before relaunch"
      return
    }
    if ! fm_lock_acquire_wait "$remote_lock"; then
      report_unreached "$id" "the restart could not lock inherited config before relaunch"
      return
    fi
    remote_generation=$(fm_remote_inherit_generation_next "$STATE" "$id" 2>/dev/null || true)
    if [ -z "$remote_generation" ]; then
      fm_lock_release "$remote_lock" || true
      report_unreached "$id" "the restart could not publish an inheritance generation before relaunch"
      return
    fi
    if ! "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$id" "$remote_generation" >/dev/null; then
      fm_lock_release "$remote_lock" || true
      report_unreached "$id" "inherited config did not land, so the host was not relaunched"
      return
    fi
    remote_rc=0
    fm_remote_readiness_ensure "$SCRIPT_DIR" "$id" || remote_rc=$?
    if [ "$remote_rc" -ne 0 ]; then
      fm_lock_release "$remote_lock" || true
      report_unreached "$id" "plugin readiness failed after inherited config landed, so the host was not relaunched"
      if [ "$remote_rc" -ne 255 ] && [ -n "$FM_REMOTE_READINESS_OUT" ]; then
        printf '%s\n' "$FM_REMOTE_READINESS_OUT"
      fi
      return
    fi
    restart_out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh relaunch \
      "$id" "${HARNESS[i]}" "${MODEL[i]:-default}" "${EFFORT[i]:-default}" < /dev/null 2>&1)
    restart_rc=$?
    fm_lock_release "$remote_lock" || true
  else
    restart_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
      --harness "${HARNESS[i]}" --model "${MODEL[i]}" --effort "${EFFORT[i]}" 2>&1)
    restart_rc=$?
  fi
  if [ "$restart_rc" -eq 0 ]; then
    fm_secondmate_restart_launched_profile "$restart_out" "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"
    ran_on=$FM_SECONDMATE_RESTART_LAUNCHED_HARNESS
    if [ "${PLACEMENT[i]}" = remote ]; then
      if ! record_err=$(fm_secondmate_restart_record_profile "$STATE" "$id" "$ran_on" \
        "$FM_SECONDMATE_RESTART_LAUNCHED_MODEL" "$FM_SECONDMATE_RESTART_LAUNCHED_EFFORT" 2>&1); then
        report_unreached "$id" "restarted on ${HOST[i]} ($ran_on), but its record could not be updated to that profile ($(first_reported_line "$record_err")); the next plain restart would relaunch the previous profile"
        return
      fi
      printf 'restarted: %s on %s (%s)\n' "$id" "${HOST[i]}" "$ran_on"
    else
      printf 'restarted: %s (%s)\n' "$id" "$ran_on"
    fi
    return
  fi

  restart_reason=$(first_reported_line "$restart_out")
  [ -n "$restart_reason" ] || restart_reason="the restart failed without a reported reason"
  report_unreached "$id" "the restart outcome is unknown: $restart_reason"
}

launch_restart() {  # <array-index>
  local i=$1 result tmp
  result="$RESULT_DIR/$i.result"
  tmp="$result.tmp"
  ( trap - EXIT; restart_mate "$i" > "$tmp"; mv -f "$tmp" "$result" ) &
  RESTART_PID[i]=$!
  RESTART_RESULT[i]=$result
  PLAN[i]=restarting
  restart_active_count=$((restart_active_count + 1))
}

harvest_restarts() {
  local i out worker_state
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != restarting ]; then
      i=$((i + 1))
      continue
    fi
    if [ -f "${RESTART_RESULT[i]}" ]; then
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      out=$(cat "${RESTART_RESULT[i]}")
    else
      if kill -0 "${RESTART_PID[i]}" 2>/dev/null; then
        worker_state=$(ps -p "${RESTART_PID[i]}" -o stat= 2>/dev/null || true)
        case "$worker_state" in
          Z*) ;;
          *)
            i=$((i + 1))
            continue
            ;;
        esac
      fi
      wait "${RESTART_PID[i]}" 2>/dev/null || true
      if [ -f "${RESTART_RESULT[i]}" ]; then
        out=$(cat "${RESTART_RESULT[i]}")
      else
        out="unreached: ${IDS[$i]}: the restart worker exited before publishing an outcome"
      fi
    fi
    printf '%s\n' "$out"
    case "$out" in
      restarted:*) restarted_count=$((restarted_count + 1)) ;;
      nudged:*) nudged_count=$((nudged_count + 1)) ;;
      *) unreached_count=$((unreached_count + 1)) ;;
    esac
    PLAN[i]="done"
    OUTCOME[i]="reported"
    restart_active_count=$((restart_active_count - 1))
    i=$((i + 1))
  done
}

# What was observable about a mate that missed its persist bound, so the
# nudge line says which of "still mid-turn", "idle without answering", or "reply
# not mirrored yet" applies instead of leaving the captain to guess.
timeout_evidence() {  # <array-index>
  local i=$1 id caught obs meta
  id=${IDS[$i]}
  meta="$STATE/$id.meta"
  if [ "${PLACEMENT[i]}" = remote ]; then
    caught=$(fm_pending_reply_remote_channel_epoch "$STATE" "$id")
    if [ -z "$caught" ]; then
      printf 'the remote reply mirror has never reported itself caught up'
    elif [ "$caught" -lt "${DEADLINE[i]}" ]; then
      printf 'the remote reply mirror was last caught up %ss before the bound expired' "$((DEADLINE[i] - caught))"
    else
      printf 'the remote reply mirror was current, so no answer had been written'
    fi
    return
  fi
  obs=$(fm_pending_reply_backend_observation "$(fm_backend_of_meta "$meta")" \
    "$(fm_backend_target_of_meta "$meta")" "fm-$id" "${HARNESS[i]}" 2>/dev/null || printf 'unknown')
  case "$obs" in
    busy) printf 'the agent was still mid-turn, so the request was queued behind that turn' ;;
    idle|fallback-idle) printf 'the agent was idle and had not answered' ;;
    *) printf 'the agent state could not be observed' ;;
  esac
}

# --- phase A: persist ------------------------------------------------------
# Every request goes out before any restart, so the fleet persists concurrently
# and one busy mate delays only itself.

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  id=${IDS[$i]}
  PLAN[i]="fallback"
  REASON[i]=""
  CORR[i]=""
  DEADLINE[i]=""
  PLACEMENT[i]=""
  HOST[i]=""
  HARNESS[i]=""
  MODEL[i]=""
  EFFORT[i]=""
  OUTCOME[i]=""
  if [ -e "$STATE/$id.stopped" ]; then
    PLAN[i]="stopped"
    skipped_count=$((skipped_count + 1))
    printf 'skipped: %s: stopped by the captain; reopen it with bin/fm-secondmate-lane.sh to restart it\n' "$id"
    i=$((i + 1))
    continue
  fi
  if ! fm_secondmate_restart_capable "$STATE/$id.meta"; then
    REASON[i]=$FM_SECONDMATE_RESTART_REASON
    i=$((i + 1))
    continue
  fi
  PLACEMENT[i]=$FM_SECONDMATE_RESTART_PLACEMENT
  HOST[i]=$FM_SECONDMATE_RESTART_HOST
  HARNESS[i]=$FM_SECONDMATE_RESTART_HARNESS
  MODEL[i]=${FM_SECONDMATE_RESTART_MODEL:-default}
  EFFORT[i]=${FM_SECONDMATE_RESTART_EFFORT:-default}
  [ -n "${MODEL[i]}" ] || MODEL[i]=default
  [ -n "${EFFORT[i]}" ] || EFFORT[i]=default
  if [ "$PROFILE_HARNESS_SET" -eq 1 ]; then
    if [ "$PROFILE_HARNESS" != "${HARNESS[i]}" ]; then
      [ "$PROFILE_MODEL_SET" -eq 1 ] || MODEL[i]=default
      [ "$PROFILE_EFFORT_SET" -eq 1 ] || EFFORT[i]=default
    fi
    HARNESS[i]=$PROFILE_HARNESS
  fi
  [ "$PROFILE_MODEL_SET" -eq 0 ] || MODEL[i]=$PROFILE_MODEL
  [ "$PROFILE_EFFORT_SET" -eq 0 ] || EFFORT[i]=$PROFILE_EFFORT
  if ! fm_control_harness_supported "${HARNESS[i]}" \
    || ! fm_control_harness_supports_kind "${HARNESS[i]}" secondmate; then
    REASON[i]="the requested worker runtime '${HARNESS[i]}' has no verified restart mechanics for a second mate"
    i=$((i + 1))
    continue
  fi
  if [ "${EFFORT[i]}" = ultra ] && ! "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "${HARNESS[i]}" "${MODEL[i]}" "${EFFORT[i]}"; then
    REASON[i]="the requested Ultra profile does not select native Codex through Pi"
    i=$((i + 1))
    continue
  fi

  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$id" \
    "$FM_SECONDMATE_PERSIST_REQUEST"); then
    REASON[i]="its answer about the open work cannot be tracked, so a clean reload could not be proven"
    i=$((i + 1))
    continue
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$id" "$FM_SECONDMATE_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    REASON[i]="the request to write down its open work could not be delivered: $(first_reported_line "$send_out")"
    i=$((i + 1))
    continue
  fi
  CORR[i]=$corr
  DEADLINE[i]=$(($(date +%s) + PERSIST_WAIT))
  PLAN[i]="persisted-pending"
  i=$((i + 1))
done

# --- phase B: restart ------------------------------------------------------

RESULT_DIR=$(mktemp -d "$STATE/.secondmate-restart.XXXXXX") || {
  echo "error: could not create restart result directory under $STATE" >&2
  exit 1
}
trap 'rm -rf -- "$RESULT_DIR"' EXIT
pending_count=0
restart_active_count=0
i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ "${PLAN[i]}" = persisted-pending ]; then
    pending_count=$((pending_count + 1))
  elif [ "${PLAN[i]}" = stopped ]; then
    PLAN[i]="done"
    OUTCOME[i]="reported"
  else
    fall_back_to_nudge "${IDS[$i]}" "${REASON[i]}"
    PLAN[i]="done"
    OUTCOME[i]="reported"
  fi
  i=$((i + 1))
done

while [ "$((pending_count + restart_active_count))" -gt 0 ]; do
  now=$(date +%s)
  next_wait=$PERSIST_POLL
  # Resolve every arrived answer before processing any timeout. Delivery of a
  # later fleet request can outlast an earlier mate's deadline under load; that
  # expired mate must not hold an already-confirmed mate behind its fallback.
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" = persisted-pending ] \
      && fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
      pending_count=$((pending_count - 1))
      launch_restart "$i"
    fi
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#IDS[@]}" ]; do
    if [ "${PLAN[i]}" != persisted-pending ]; then
      i=$((i + 1))
      continue
    fi
    if [ "$now" -ge "${DEADLINE[i]}" ]; then
      # A reply can land after the fleet-wide resolution pass. Recheck at the
      # timeout decision so an answer already on disk wins over the fallback.
      if fm_pending_reply_try_resolve "$STATE" "${CORR[i]}"; then
        pending_count=$((pending_count - 1))
        launch_restart "$i"
      else
        fall_back_to_nudge "${IDS[$i]}" \
          "it did not confirm within ${PERSIST_WAIT}s that its open work is written down ($(timeout_evidence "$i")), so its conversation was not spent"
        PLAN[i]="done"
        OUTCOME[i]="reported"
        pending_count=$((pending_count - 1))
      fi
    else
      remaining=$((DEADLINE[i] - now))
      [ "$remaining" -ge "$next_wait" ] || next_wait=$remaining
    fi
    i=$((i + 1))
  done
  harvest_restarts
  [ "$((pending_count + restart_active_count))" -eq 0 ] || sleep "$next_wait"
done

# --- summary ---------------------------------------------------------------

i=0
while [ "$i" -lt "${#IDS[@]}" ]; do
  if [ -z "${OUTCOME[i]}" ]; then
    report_unreached "${IDS[$i]}" "the restart pass ended without publishing an outcome"
    OUTCOME[i]="reported"
  fi
  i=$((i + 1))
done

printf 'summary: %d of %d restarted, %d nudged, %d unreached' \
  "$restarted_count" "$TOTAL_INPUTS" "$nudged_count" "$unreached_count"
[ "$skipped_count" -eq 0 ] || printf ', %d skipped' "$skipped_count"
printf '\n'
[ "$((nudged_count + unreached_count))" -eq 0 ] || exit 3
exit 0
