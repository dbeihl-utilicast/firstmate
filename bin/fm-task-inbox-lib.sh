#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/claimed/      live take claims, one claimant directory per taker
#   <task>.inbox/handled/      completed take acknowledgement records
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    "<msg>\t<highest-unhandled-seq>": oldest-message
#                              surfaced as stale, plus the highest eligible seq
#                              then; a newer record's seq re-escalates later
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans the inbox
# root, claimed/, and handled/. The .seq.lock serializes every record transition
# among those locations with allocation and deduplication, and every destination
# move refuses to replace an existing record. fm_task_inbox_claim moves the
# lowest unhandled record into a claimant directory before it is read, and
# fm_task_inbox_complete_claim moves it into handled/ only after its body was
# returned. A later take returns an abandoned claim to the inbox when its owner
# process is gone, its process-start identity changed, or its lease expires, so
# a taker crash replays rather than loses work. Lease expiry can replay an
# instruction while the original taker is still alive; callers must tolerate
# duplicate delivery.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring or be skipped to protect proven pending composer text. After
# FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates. The
# caller owns the busy and recovery-grade endpoint checks: a busy pane waits,
# while a positively dead or missing endpoint skips delivery and the ladder and
# escalates directly. This library owns only the schedule and escalation marker.
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface an unchanged oldest
# and highest eligible sequence once, while a newer record can surface it again.
# The watcher captures that sequence before queuing the wake, so a record
# arriving during wake publication remains eligible for a later escalation.
# A crash or marker failure may produce a rare duplicate rather than lose a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Both dependencies are canonical lint roots in their own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5
FM_TASK_INBOX_CLAIM_MAX_DEFAULT=300

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_claim_max_secs() {
  local max=${FM_TASK_INBOX_CLAIM_MAX_SECS:-$FM_TASK_INBOX_CLAIM_MAX_DEFAULT}
  case "$max" in ''|*[!0-9]*) max=$FM_TASK_INBOX_CLAIM_MAX_DEFAULT ;; esac
  printf '%s' "$max"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled" "$dir/claimed"/*; do
    [ -d "$d" ] || continue
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Move one record without replacing an existing destination. Caller must hold
# .seq.lock, so the existence check and portable mv -n form one serialized
# no-clobber transition even on platforms without renameat2.
_fm_task_inbox_move_no_clobber_locked() {  # <source> <destination>
  local source=$1 destination=$2
  [ -e "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 2
  mv -n "$source" "$destination" || return 1
  [ ! -e "$source" ] && [ ! -L "$source" ] && [ -f "$destination" ] || return 2
}

# Write one record into the next sequence slot: temp-write, then an atomic
# no-clobber rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec move_status
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  if ! {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    case "$delivery_mode" in
      fire-and-forget|stopped) printf 'delivery=%s\n' "$delivery_mode" ;;
    esac
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  while :; do
    seq=$(fm_task_inbox_next_seq "$dir") || { rm -f "$tmp"; return 1; }
    rec="$dir/$seq.msg"
    move_status=0
    _fm_task_inbox_move_no_clobber_locked "$tmp" "$rec" || move_status=$?
    case "$move_status" in
      0) printf '%s' "$rec"; return 0 ;;
      2) continue ;;
      *) rm -f "$tmp"; return 1 ;;
    esac
  done
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once while its exact body remains
# unhandled. An identical body already in the inbox is left in place and its
# path is printed; once taken, the same body is a new instruction and receives
# a new record, unless dedup-handled is 1, in which case an identical record
# already taken into handled/ is reused as well. Resend-recovery callers
# (fire-and-forget, watcher refresh, remote steer) pass 1 so an uncertain retry
# converges on the existing record instead of piling up duplicates. Two distinct logical requests do not collapse in
# practice because a marked secondmate request embeds a per-request correlation
# token in its body.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode] [dedup-handled]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dedup_handled=${5:-0} dir lock want have f record_mode rec='' reused=0 relocated=0 relocated_base='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      # The lock prevents library-owned relocation. A manual fallback move can
      # still race this scan, so restart the whole search whenever a candidate
      # vanishes rather than guessing which root or claimant now owns it.
      while :; do
        relocated=0
        for f in "$dir"/*.msg "$dir/claimed"/*/*.msg "$dir/handled"/*.msg; do
          [ -e "$f" ] || continue
          if [ "${f%/*}" = "$dir/handled" ] && [ "$dedup_handled" != 1 ] \
            && [ "${f##*/}" != "$relocated_base" ]; then
            continue
          fi
          if ! record_mode=$(fm_task_inbox_delivery_mode "$f"); then
            relocated=1
            relocated_base=${f##*/}
            break
          fi
          case "$delivery_mode" in
            fire-and-forget) [ "$record_mode" = fire-and-forget ] || continue ;;
            stopped) [ "$record_mode" = stopped ] || continue ;;
            *) case "$record_mode" in fire-and-forget|stopped) continue ;; esac ;;
          esac
          if [ ! -e "$f" ]; then
            relocated=1
            relocated_base=${f##*/}
            break
          fi
          if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
            if [ ! -e "$f" ]; then
              relocated=1
              relocated_base=${f##*/}
              break
            fi
            continue
          fi
          cmp -s "$want" "$have" || continue
          if [ ! -e "$f" ]; then
            relocated=1
            relocated_base=${f##*/}
            break
          fi
          rec=$f
          reused=1
          break
        done
        [ "$relocated" = 1 ] || break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  if [ "$reused" = 1 ]; then
    printf 'notice: identical unhandled inbox record stands at %s\n' "$rec" >&2
  fi
  printf '%s' "$rec"
}

# Stable numeric identity for one live process start. ps lstart is available on
# both macOS and Linux; hashing its fixed English timestamp keeps claimant paths
# portable and distinguishes PID reuse without parsing platform-specific dates.
fm_task_inbox_process_identity() {  # <pid>
  local pid=$1 started
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  started=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
  [ -n "$started" ] || return 1
  printf '%s' "$started" | cksum | awk '{print $1}'
}

# Return abandoned claims to the inbox before selecting new work. Caller must
# hold .seq.lock. A valid claimant is <pid>-<process-start-id>-<epoch>-<nonce>.
# Malformed directories are reported and preserved for operator inspection.
_fm_task_inbox_recover_claims_locked() {  # <inbox-dir>
  local dir=$1 max claim_dir claimant pid identity epoch nonce extra malformed live_identity age claim dest move_status
  [ -d "$dir/claimed" ] || return 0
  max=$(fm_task_inbox_claim_max_secs)
  for claim_dir in "$dir/claimed"/*; do
    [ -d "$claim_dir" ] || continue
    claimant=${claim_dir##*/}
    pid=''
    identity=''
    epoch=''
    nonce=''
    extra=''
    IFS=- read -r pid identity epoch nonce extra <<EOF
$claimant
EOF
    if [ -n "$extra" ]; then
      printf 'warning: malformed claimant directory: %s\n' "$claim_dir" >&2
      continue
    fi
    case "$pid" in ''|*[!0-9]*) malformed=1 ;; *) malformed=0 ;; esac
    case "$identity" in ''|*[!0-9]*) malformed=1 ;; esac
    case "$epoch" in ''|*[!0-9]*) malformed=1 ;; esac
    case "$nonce" in ''|*[!0-9]*) malformed=1 ;; esac
    if [ "$malformed" = 1 ]; then
      printf 'warning: malformed claimant directory: %s\n' "$claim_dir" >&2
      continue
    fi
    live_identity=$(fm_task_inbox_process_identity "$pid" 2>/dev/null || true)
    age=$(fm_path_age "$claim_dir")
    if [ "$live_identity" = "$identity" ] && [ "$age" -lt "$max" ]; then
      continue
    fi
    rmdir "$claim_dir" 2>/dev/null || true
    for claim in "$claim_dir"/*.msg; do
      [ -f "$claim" ] || continue
      dest="$dir/${claim##*/}"
      move_status=0
      _fm_task_inbox_move_no_clobber_locked "$claim" "$dest" || move_status=$?
      case "$move_status" in
        0) rmdir "$claim_dir" 2>/dev/null || true ;;
        2)
          printf 'warning: recovered claim destination already exists: %s\n' "$dest" >&2
          return 1 ;;
        *) return 1 ;;
      esac
    done
  done
}

# Return abandoned claims while serialized with allocation, deduplication,
# claim, and completion.
fm_task_inbox_recover_claims() {  # <inbox-dir>
  local dir=$1 lock status=0
  [ -d "$dir" ] || return 0
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  _fm_task_inbox_recover_claims_locked "$dir" || status=1
  fm_lock_release "$lock"
  return "$status"
}

# Atomically claim the lowest-numbered unhandled record into <claimant>'s
# directory. Only the rename winner receives a claimed path. The caller must
# print the body from that path and complete it separately after successful
# output; no record means there was nothing to claim.
fm_task_inbox_claim() {  # <inbox-dir> <claimant>
  local dir=$1 claimant=$2 f n best='' best_n=0 claim_dir dest lock status=1 move_status
  case "$claimant" in *[!0-9-]*|*-|'' ) return 1 ;; esac
  [ -d "$dir" ] && [ -d "$dir/handled" ] || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if _fm_task_inbox_recover_claims_locked "$dir" && mkdir -p "$dir/claimed/$claimant"; then
    claim_dir="$dir/claimed/$claimant"
    while :; do
      best=''
      best_n=0
      for f in "$dir"/*.msg; do
        [ -f "$f" ] || continue
        n=$(fm_task_inbox_seq_of "${f##*/}") || continue
        if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
          best=$f
          best_n=$n
        fi
      done
      [ -n "$best" ] || { rmdir "$claim_dir" 2>/dev/null || true; break; }
      dest="$claim_dir/${best##*/}"
      move_status=0
      _fm_task_inbox_move_no_clobber_locked "$best" "$dest" || move_status=$?
      case "$move_status" in
        0) status=0; break ;;
        2) continue ;;
        *) break ;;
      esac
    done
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$dest"
}

# Complete one successfully read claim by moving it to handled/. This is the
# acknowledgement step, intentionally after body output so a crashed claimant
# leaves a recoverable claim rather than hiding an unacted instruction.
fm_task_inbox_complete_claim() {  # <inbox-dir> <claimed-record>
  local dir=$1 claim=$2 dest lock status=1
  case "$claim" in "$dir/claimed/"*/*.msg) ;; *) return 1 ;; esac
  [ -d "$dir" ] || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  dest="$dir/handled/${claim##*/}"
  if _fm_task_inbox_move_no_clobber_locked "$claim" "$dest"; then
    rmdir "${claim%/*}" 2>/dev/null || true
    status=0
  fi
  fm_lock_release "$lock"
  return "$status"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted take_bin LC_ALL=C
  case "$dir" in
    */claimed/*) dir=${dir%/claimed/*} ;;
  esac
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  take_bin=$(printf '%s/fm-inbox-take.sh' "$_FM_TASK_INBOX_LIB_DIR" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: run '%s' '%s' to claim and complete the next instruction safely, act on its printed body, then repeat until empty. A dead or expired claim replays. Fallback: list '%s'/*.msg, read and act in numeric order, then mv each handled file to '%s'/handled/." \
    "$take_bin" "$quoted" "$quoted" "$quoted"
}

# Ring the doorbell, best-effort: one endpoint-liveness pre-check, one advisory
# composer pre-check, then the backend's submit machinery with a minimal retry
# budget, verdict discarded.
# Returns 0 rang, 1 skipped because the composer PROVENLY holds pending text
# (the watcher re-rings later), 2 the backend send failed, 3 skipped because
# the endpoint is positively dead or missing (nothing typed; recovery owns the
# record). No return value is delivery proof; the acknowledgement move is the
# only delivery signal.
# The skip is deliberately narrow: only an exact `pending` verdict defers,
# because there our Enter could submit someone's real half-typed content.
# `pending-unproven` and `unknown` still ring - the worst outcome is a garbled
# CONSTANT line the worker recovers semantically, while skipping on ambiguous
# verdicts would starve a harness whose idle screen the classifier cannot
# positively identify (that classifier is advisory here by design).
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label]
  local backend=$1 target=$2 rec=$3 label=${4:-} line cstate verdict
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke; every other value
  # (empty, pending, unknown, ...) is deliberately ignored, never proof.
  [ "$verdict" != send-failed ] || return 2
  return 0
}

fm_task_inbox_delivery_mode() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { mode="fire-and-forget" }
    $0 == "delivery=stopped" { mode="stopped" }
    END { print mode }
  ' "$rec"
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  case "$(fm_task_inbox_delivery_mode "$1")" in
    fire-and-forget|stopped) return 0 ;;
  esac
  return 1
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  fm_task_inbox_recover_claims "$dir" || true
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Highest sequence among escalation-eligible unhandled records (same filter
# above). Sequence numbers never repeat, so a rise proves a new record exists
# even when an older one was acknowledged in between (unlike a raw count).
fm_task_inbox_highest_unhandled_seq() {  # <state-dir> <task-id>
  local dir f n best=0
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    [ "$n" -le "$best" ] || best=$n
  done
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated at the current count)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last esc_line esc_base esc_seq now_seq
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  esc_line=$(cat "$dir/.escalated" 2>/dev/null || true)
  esc_base=${esc_line%%$'\t'*}
  esc_seq=${esc_line#*$'\t'}
  case "$esc_seq" in ''|*[!0-9]*) esc_seq=0 ;; esac
  if [ "$esc_base" = "$base" ]; then
    now_seq=$(fm_task_inbox_highest_unhandled_seq "$1" "$2")
    if [ "$now_seq" -le "$esc_seq" ]; then
      printf 'quiet'
      return 0
    fi
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Marks the current oldest escalated with the highest eligible seq at that
# moment, after its stale wake is durably queued (wake-before-marker: a crash
# can cause a rare duplicate; stuck-crewmate-recovery owns it from here).
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path> [highest-seq]
  local dir seq
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  seq=${4-}
  [ -n "$seq" ] || seq=$(fm_task_inbox_highest_unhandled_seq "$1" "$2")
  if ! { printf '%s\t%s\n' "${3##*/}" "$seq" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
