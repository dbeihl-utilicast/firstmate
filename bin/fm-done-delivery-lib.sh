# shellcheck shell=bash
# Single owner of "may this claimed terminal done be accepted as a finished
# ship delivery?"
#
# Workers append `done:` to the status file themselves, so a helper they could
# skip is not a control. This library is sourced by the readers that would
# otherwise treat that line as finished work:
#   - bin/fm-crew-state.sh, when the status-log fallback would report done
#   - bin/fm-inactive-reconcile.sh, when a child's ledger-first parent delivery
#     would publish a terminal done
#
# fm_done_delivery_accept <meta-file> <status-line> <worktree>
#   Return 0 to accept. Print nothing.
#   Return 1 to refuse. Print one line:
#     done refused: missing recorded PR; unpushed head
#   naming exactly the artifacts that are absent (semicolon-separated).
#
# A ship task in no-mistakes or direct-PR, or a ship with no recorded mode
# (intake's default is no-mistakes), is refused when it has neither a recorded
# PR nor a pushed head. Recorded PR is a nonempty pr= field in the task meta,
# or a GitHub `/pull/<n>` or GitLab `/-/merge_requests/<n>` URL on the done
# line (the same shapes bin/fm-inactive-reconcile.sh already extracts). Pushed
# head is an empty `git log HEAD --not --remotes` in the worktree; a missing
# or non-git worktree cannot prove a push and counts as unpushed.
# kind=scout, kind=secondmate, and mode=local-only stay accepted: a scout
# report and a local-only ready branch are the deliverable, so a done with
# no PR is correct.
# A non-done status line is not this check's concern and is accepted.

_FM_DONE_DELIVERY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_DONE_DELIVERY_LIB_DIR="."

type status_line_verb >/dev/null 2>&1 || {
  # shellcheck source=bin/fm-classify-lib.sh
  # shellcheck disable=SC1091
  . "$_FM_DONE_DELIVERY_LIB_DIR/fm-classify-lib.sh"
}

_fm_done_delivery_meta_value() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when <worktree> cannot prove HEAD is on a remote.
_fm_done_delivery_head_unpushed() {  # <worktree>
  local wt=$1 log
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  log=$(git -C "$wt" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 0
  [ -n "$log" ]
}

# 0 when meta pr= is nonempty or the status line carries a PR or MR URL.
_fm_done_delivery_has_recorded_pr() {  # <meta-file> <status-line>
  local meta=$1 line=$2 value
  value=$(_fm_done_delivery_meta_value "$meta" pr)
  [ -n "$value" ] && return 0
  printf '%s' "$line" | grep -Eq 'https://[^[:space:])"]+/pull/[0-9]+' && return 0
  printf '%s' "$line" | grep -Eq 'https://[^[:space:])"]+/-/merge_requests/[0-9]+' && return 0
  return 1
}

fm_done_delivery_accept() {  # <meta-file> <status-line> <worktree>
  local meta=$1 line=$2 wt=$3 kind mode missing=''
  [ "$(status_line_verb "$line")" = "done" ] || return 0
  [ -f "$meta" ] || return 0
  kind=$(_fm_done_delivery_meta_value "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship) ;;
    *) return 0 ;;
  esac
  mode=$(_fm_done_delivery_meta_value "$meta" mode)
  case "$mode" in
    local-only) return 0 ;;
    no-mistakes|direct-PR|'') ;;
    *) return 0 ;;
  esac
  _fm_done_delivery_has_recorded_pr "$meta" "$line" || missing='missing recorded PR'
  if _fm_done_delivery_head_unpushed "$wt"; then
    if [ -n "$missing" ]; then
      missing="$missing; unpushed head"
    else
      missing='unpushed head'
    fi
  fi
  # Refuse only the incident shape: neither artifact is present. A recorded
  # PR or a pushed head is enough for this reader to accept the claimed done.
  case "$missing" in
    'missing recorded PR; unpushed head')
      printf 'done refused: %s\n' "$missing"
      return 1
      ;;
  esac
  return 0
}
