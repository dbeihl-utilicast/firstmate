#!/usr/bin/env bash
# Shared owner for retiring one task identity's runtime artifacts.
# Callers must hold the task metadata lock and must decide independently whether
# the task record itself may be removed or archived.

fm_task_retire_plain_paths() {  # <state-dir> <task-id> [include-stopped]
  local state=$1 id=$2 include_stopped=${3:-yes}
  printf '%s\n' \
    "$state/$id.turn-ended" "$state/$id.progress" \
    "$state/$id.pi-ext.ts" "$state/$id.omp-ext.ts" \
    "$state/$id.grok-turnend-token" "$state/$id.grok-home" \
    "$state/$id.kimi-turnend-token" "$state/$id.muse-session" \
    "$state/$id.muse-session-current" "$state/$id.cursor-session" \
    "$state/$id.control-relaunch" "$state/$id.control-relaunch.meta-prior" \
    "$state/$id.control-relaunch.brief-prior" "$state/$id.control-relaunch.note" \
    "$state/$id.reconcile-nudged" "$state/$id.gemini-settings.json" \
    "$state/$id.qwen-settings.json" "$state/.$id.branch-outcome-index" \
    "$state/$id.pr-refresh-state" "$state/$id.pr-refresh-refused" \
    "$state/$id.nm-fix-rounds" "$state/.lease-$id" \
    "$state/$id.check.sh" "$state/$id.check-trust" \
    "$state/$id.pr-poll" "$state/$id.pr-poll-registration" \
    "$state/$id.pr-poll-retirement" "$state/$id.pr-poll-rearm-notified"
  [ "$include_stopped" != yes ] || printf '%s\n' "$state/$id.stopped"
}

# A retained audit record blocks same-id publication until its transaction has
# a complete receipt bound to the exact archived spawn generation.
fm_task_retirement_complete() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta receipt meta_gen receipt_gen runtime_state
  meta="$state/retired/$id.meta"
  receipt="$state/retired/$id.receipt"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  [ "$(grep -cxF 'version=fm-record-retirement-v2' "$receipt")" -eq 1 ] || return 1
  [ "$(grep -cxF "task_id=$id" "$receipt")" -eq 1 ] || return 1
  [ "$(grep -cxF 'status=complete' "$receipt")" -eq 1 ] || return 1
  meta_gen=$(fm_meta_get "$meta" spawn_gen)
  receipt_gen=$(fm_meta_get "$receipt" spawn_gen)
  [ -n "$meta_gen" ] && [ "$meta_gen" = "$receipt_gen" ] || return 1
  runtime_state=$(fm_meta_get "$receipt" runtime_state)
  [ "$runtime_state" = retired ]
}

fm_task_retire_pr_artifacts_validate() {  # <state-dir> <task-id>
  local state=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 1
  for artifact in "$state/$id.check.sh" "$state/$id.pr-poll" \
    "$state/$id.pr-poll-registration" "$state/$id.pr-poll-retirement" \
    "$state/$id.pr-poll-rearm-notified" "$state/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  for artifact in "$state/$id.check.sh" "$state/$id.pr-poll" \
    "$state/$id.pr-poll-registration" "$state/$id.pr-poll-retirement" \
    "$state/$id.pr-poll-rearm-notified" "$state/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ]; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state/$id.pr-poll-retirement" ] \
    || [ -L "$state/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

fm_task_retire_poll_state() {  # <state-dir> <task-id> <script-dir>
  local state=$1 id=$2 script_dir=$3
  fm_task_retire_pr_artifacts_validate "$state" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state" "$id" "$script_dir/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state" "$id" || return 1
}

fm_task_retire_busy_state() {  # <state-dir> <task-id> <script-dir> [generation]
  local state=$1 id=$2 script_dir=$3 gen=${4:-}
  if [ -n "$gen" ]; then
    "$script_dir/fm-busy-event.sh" retire "$state" "$id" --gen "$gen"
  elif [ -f "$state/$id.busy-gen" ]; then
    "$script_dir/fm-busy-event.sh" retire "$state" "$id" --current-gen
  fi
}

fm_task_retire_runtime() {  # <state-dir> <task-id> <script-dir> <delete|archive> [archive-dir] [busy-gen]
  local state=$1 id=$2 script_dir=$3 mode=$4 archive=${5:-} busy_gen=${6:-}
  local path name destination include_stopped=yes
  fm_task_retire_poll_state "$state" "$id" "$script_dir" || return 1
  fm_task_retire_busy_state "$state" "$id" "$script_dir" "$busy_gen" || return 1
  status_retire_presentation_task "$state" "$id" || return 1
  case "$mode" in
    delete)
      while IFS= read -r path; do rm -f -- "$path" || return 1; done <<EOF
$(fm_task_retire_plain_paths "$state" "$id" yes)
EOF
      rm -rf -- "$state/$id.inbox" || return 1
      ;;
    archive)
      [ -n "$archive" ] && [ -d "$archive" ] && [ ! -L "$archive" ] || return 1
      include_stopped=no
      while IFS= read -r path; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        name=$(basename "$path")
        destination="$archive/$name"
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
          echo "REFUSED: retirement audit artifact already exists at $destination" >&2
          return 1
        }
        mv -- "$path" "$destination" || return 1
      done <<EOF
$(fm_task_retire_plain_paths "$state" "$id" "$include_stopped")
EOF
      if [ -e "$state/$id.inbox" ] || [ -L "$state/$id.inbox" ]; then
        destination="$archive/$id.inbox"
        [ ! -e "$destination" ] && [ ! -L "$destination" ] || {
          echo "REFUSED: retirement audit artifact already exists at $destination" >&2
          return 1
        }
        mv -- "$state/$id.inbox" "$destination" || return 1
      fi
      ;;
    *) return 2 ;;
  esac
}
