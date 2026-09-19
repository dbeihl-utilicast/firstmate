#!/usr/bin/env bash
# Shared custody preflight: ONE capture and ONE refusal rule for every path that
# may reset, reallocate, or recreate an endpoint against a task's local copy
# (fm-control relaunch, fm-spawn --relaunch, fm-spawn's pooled base freshen).
# Requires fm-nm-run-lib.sh to be sourced first.

# Sets CUSTODY_{BRANCH,HEAD,DIRTY,UNTRACKED,LOCAL_ONLY,VALIDATION_HEAD}.
# VALIDATION_HEAD is the pipeline-owned run head, "none" when no validation can
# own this copy, or "unreadable" when validation state cannot be read.
fm_custody_capture() {  # <worktree>
  local wt=$1 status nm_status
  status=$(git -C "$wt" -c core.quotePath=false status --porcelain) || return 1
  CUSTODY_BRANCH=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || printf detached)
  CUSTODY_HEAD=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || printf unborn)
  CUSTODY_DIRTY=no
  CUSTODY_UNTRACKED=no
  [ -z "$status" ] || CUSTODY_DIRTY=yes
  if printf '%s\n' "$status" | grep -q '^?? '; then CUSTODY_UNTRACKED=yes; fi
  CUSTODY_LOCAL_ONLY=0
  if [ "$CUSTODY_HEAD" != unborn ]; then
    CUSTODY_LOCAL_ONLY=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) || return 1
  fi
  CUSTODY_VALIDATION_HEAD=none
  if git -C "$wt" remote get-url no-mistakes >/dev/null 2>&1; then
    if nm_status=$(fm_nm_run_checked "$wt" 5 axi status); then
      if fm_nm_run_is_pipeline_owned_active "$nm_status"; then
        CUSTODY_VALIDATION_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$nm_status" head)")
        [ -n "$CUSTODY_VALIDATION_HEAD" ] || CUSTODY_VALIDATION_HEAD=unreadable
      fi
    else
      CUSTODY_VALIDATION_HEAD=unreadable
    fi
  fi
}

# Prints the reason and returns 0 when the captured copy must not be used.
# Mode "recover" (endpoint recreated in the exact copy, nothing moved) refuses
# only on unreadable validation state. Mode "reset" (freshen or reallocation)
# also refuses dirty bytes, a validation-owned head, and local-only commits
# unless FM_CUSTODY_PRESERVE=1 lets fm_custody_preserve keep them under a ref.
fm_custody_refusal() {  # <recover|reset>
  local mode=$1
  if [ "$CUSTODY_VALIDATION_HEAD" = unreadable ]; then
    echo "its validation state cannot be read; refusing until it is readable"
    return 0
  fi
  [ "$mode" = reset ] || return 1
  if [ "$CUSTODY_DIRTY" != no ]; then
    echo "its copy has uncommitted or untracked bytes; archive them or prove the copy disposable first"
    return 0
  fi
  if [ "$CUSTODY_VALIDATION_HEAD" != none ]; then
    echo "validation owns head $CUSTODY_VALIDATION_HEAD; preserve or reconcile that validation result first"
    return 0
  fi
  if [ "$CUSTODY_LOCAL_ONLY" != 0 ] && [ "${FM_CUSTODY_PRESERVE:-0}" != 1 ]; then
    echo "its copy holds $CUSTODY_LOCAL_ONLY local-only commit(s) on $CUSTODY_BRANCH at $CUSTODY_HEAD; rerun with FM_CUSTODY_PRESERVE=1 to keep them under a refs/fm-custody ref, or push them first"
    return 0
  fi
  return 1
}

# Keeps local-only commits reachable under refs/fm-custody/<id>/<timestamp>.
fm_custody_preserve() {  # <worktree> <task-id>
  local wt=$1 id=$2
  CUSTODY_REF=
  [ "$CUSTODY_LOCAL_ONLY" != 0 ] || return 0
  CUSTODY_REF="refs/fm-custody/$id/$(date -u +%Y%m%dT%H%M%SZ)"
  git -C "$wt" update-ref "$CUSTODY_REF" "$CUSTODY_HEAD" ""
}

# Appends one record; earlier records for the task are never overwritten.
fm_custody_record() {  # <file>
  {
    printf 'recorded=%s\nbranch=%s\nhead=%s\ndirty=%s\nuntracked=%s\nlocal_only=%s\nvalidation_head=%s\ncustody_ref=%s\n--\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CUSTODY_BRANCH" "$CUSTODY_HEAD" "$CUSTODY_DIRTY" \
      "$CUSTODY_UNTRACKED" "$CUSTODY_LOCAL_ONLY" "$CUSTODY_VALIDATION_HEAD" "${CUSTODY_REF:-none}"
  } >> "$1"
}
