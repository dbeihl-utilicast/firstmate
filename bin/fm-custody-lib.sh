#!/usr/bin/env bash
# Shared custody preflight: ONE capture and ONE refusal rule for every path that
# may reset, reallocate, or recreate an endpoint against a task's local copy
# (fm-control relaunch, fm-spawn --relaunch, fm-spawn's pooled base freshen).
# Requires fm-nm-run-lib.sh to be sourced first.

# Canonical copy identity is the physical worktree root, hashed only to keep the
# state-directory lock name bounded and free of path separators. Callers hold
# this lock across their last custody capture and every reset, reallocation, or
# replacement-endpoint publication that follows it.
fm_custody_lock_path() {  # <state-dir> <worktree>
  local state=$1 wt=$2 canonical digest
  canonical=$(CDPATH='' cd -P -- "$wt" 2>/dev/null && pwd -P) || return 1
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | shasum -a 256 2>/dev/null | awk '{print $1}') || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$canonical" | sha256sum 2>/dev/null | awk '{print $1}') || return 1
  else
    return 1
  fi
  case "$digest" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
  printf '%s/.custody-%s.lock\n' "$state" "$digest"
}

# Sets CUSTODY_{BRANCH,HEAD,DIRTY,UNTRACKED,LOCAL_ONLY,VALIDATION_HEAD}.
# VALIDATION_HEAD is every run head attributable to this copy, including a
# terminal run, "none" when no validation can own this copy, or "unreadable"
# when validation state cannot be read.
fm_custody_capture() {  # <worktree>
  local wt=$1 status nm_status run_head resolved_head
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
      run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$nm_status" head)")
      if fm_nm_run_is_pipeline_owned_active "$nm_status"; then
        [ -n "$run_head" ] \
          && CUSTODY_VALIDATION_HEAD=$run_head \
          || CUSTODY_VALIDATION_HEAD=unreadable
      elif [ -n "$run_head" ] && fm_nm_head_matches_worktree "$wt" "$run_head"; then
        resolved_head=$(fm_nm_resolve_commit "$wt" "$run_head")
        if [ -z "$resolved_head" ]; then
          CUSTODY_VALIDATION_HEAD=unreadable
        elif [ -n "$(git -C "$wt" rev-list -1 "$resolved_head" --not --remotes 2>/dev/null)" ]; then
          CUSTODY_VALIDATION_HEAD=$resolved_head
        fi
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
  if [ "$CUSTODY_VALIDATION_HEAD" != none ] && [ "${FM_CUSTODY_PRESERVE:-0}" != 1 ]; then
    echo "validation owns head $CUSTODY_VALIDATION_HEAD; rerun with FM_CUSTODY_PRESERVE=1 to keep it under a refs/fm-custody ref, or reconcile that validation result first"
    return 0
  fi
  if [ "$CUSTODY_LOCAL_ONLY" != 0 ] && [ "${FM_CUSTODY_PRESERVE:-0}" != 1 ]; then
    echo "its copy holds $CUSTODY_LOCAL_ONLY local-only commit(s) on $CUSTODY_BRANCH at $CUSTODY_HEAD; rerun with FM_CUSTODY_PRESERVE=1 to keep them under a refs/fm-custody ref, or push them first"
    return 0
  fi
  return 1
}

# Keeps every otherwise-unreachable captured commit under refs/fm-custody.
fm_custody_preserve() {  # <worktree> <task-id>
  local wt=$1 id=$2 stamp validation_full
  CUSTODY_REF=
  CUSTODY_VALIDATION_REF=
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  if [ "$CUSTODY_LOCAL_ONLY" != 0 ]; then
    CUSTODY_REF="refs/fm-custody/$id/$stamp/head"
    git -C "$wt" update-ref "$CUSTODY_REF" "$CUSTODY_HEAD" "" || return 1
  fi
  case "$CUSTODY_VALIDATION_HEAD" in
    none|unreadable) ;;
    *)
      validation_full=$(fm_nm_resolve_commit "$wt" "$CUSTODY_VALIDATION_HEAD")
      [ -n "$validation_full" ] || return 1
      if [ "$validation_full" != "$CUSTODY_HEAD" ] || [ -z "$CUSTODY_REF" ]; then
        CUSTODY_VALIDATION_REF="refs/fm-custody/$id/$stamp/validation"
        git -C "$wt" update-ref "$CUSTODY_VALIDATION_REF" "$validation_full" "" || return 1
      else
        CUSTODY_VALIDATION_REF=$CUSTODY_REF
      fi
      ;;
  esac
}

# Appends one record; earlier records for the task are never overwritten.
fm_custody_record() {  # <file>
  {
    printf 'recorded=%s\nbranch=%s\nhead=%s\ndirty=%s\nuntracked=%s\nlocal_only=%s\nvalidation_head=%s\ncustody_ref=%s\nvalidation_ref=%s\n--\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$CUSTODY_BRANCH" "$CUSTODY_HEAD" "$CUSTODY_DIRTY" \
      "$CUSTODY_UNTRACKED" "$CUSTODY_LOCAL_ONLY" "$CUSTODY_VALIDATION_HEAD" "${CUSTODY_REF:-none}" \
      "${CUSTODY_VALIDATION_REF:-none}"
  } >> "$1"
}
