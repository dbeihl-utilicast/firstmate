#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
# A ship task on a local-model harness (bin/fm-harness.sh is-local-model) must
# clear bin/fm-local-model-verify.sh's revert-check here first; registration is
# refused, with the verifier's own reason, when it fails or cannot run.
# When the task brief's captain intent names parseable GitHub issue numbers
# (#N or github.com/.../issues/N, ignoring quoted, backtick, and fenced-code
# examples), a GitHub PR body must close each with its own GitHub closing
# keyword. When it names none, the PR body must say so deliberately with a
# literal "No linked issue" line. Either check refuses registration rather
# than arming a merge poll: a warning that still recorded pr= would let the
# PR be treated as ready and merged with the issues still open, or with an
# omission nobody meant. The body is fetched with the same gh pr view path
# already used for pr_head, so GitLab merge requests skip both checks.
# A ready GitHub PR is also refused while bin/fm-pr-poll.sh --gate lists an
# unanswered blocking review finding on it; a draft PR is not, and neither is
# the record bin/fm-pr-merge.sh makes before it calls the forge to merge, which
# passes --merge-record so the gate never stands in front of a merge already ordered.
# Usage: fm-pr-check.sh <task-id> <pr-url> [--merge-record]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

# Unique issue numbers named in captain-intent text. Quoted, backtick, and
# fenced-code spans are skipped so examples such as "Closes #421, #431, #440"
# or a ```-fenced multi-line sample are not treated as work this PR must
# close.
fm_pr_intent_issue_numbers() {
  printf '%s\n' "$1" | awk '
    function emit(n) {
      if (n ~ /^[1-9][0-9]*$/ && length(n) <= 9 && !(n in seen)) {
        seen[n] = 1
        numbers[++count] = n
      }
    }
    {
      if ($0 ~ /^[ \t]*```/) { fence = !fence; next }
      if (fence) next
      line = $0
      out = ""
      nlen = length(line)
      q = ""
      for (i = 1; i <= nlen; i++) {
        c = substr(line, i, 1)
        if (q == "") {
          if (c == "\"" || c == "`") { q = c; continue }
          out = out c
        } else if (c == q) {
          q = ""
        }
      }
      s = out
      while (match(s, /#[1-9][0-9]*/)) {
        emit(substr(s, RSTART + 1, RLENGTH - 1))
        s = substr(s, RSTART + RLENGTH)
      }
      s = out
      while (match(s, /github\.com\/[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\/issues\/[1-9][0-9]*/)) {
        tok = substr(s, RSTART, RLENGTH)
        sub(/.*\//, "", tok)
        emit(tok)
        s = substr(s, RSTART + RLENGTH)
      }
    }
    END {
      for (i = 1; i <= count; i++) print numbers[i]
    }
  ' | LC_ALL=C sort -n -u
}

# Return 0 when stdin closes issue <n> with its own GitHub keyword.
# Inner match() calls clobber RSTART/RLENGTH, so the keyword span is saved
# and used to advance; otherwise a failed owner/repo or URL match loops.
fm_pr_body_closes_issue() {
  local n=$1
  awk -v n="$n" '
    BEGIN { found = 0 }
    {
      line = tolower($0)
      rest = line
      while (match(rest, /(close[sd]?|fix(es|ed)?|resolve[sd]?)/)) {
        kw_start = RSTART
        kw_len = RLENGTH
        if (kw_len < 1) break
        if (kw_start > 1 && substr(rest, kw_start - 1, 1) ~ /[a-z0-9_]/) {
          rest = substr(rest, kw_start + kw_len)
          continue
        }
        after = substr(rest, kw_start + kw_len)
        sub(/^[: \t]+/, "", after)
        if (after ~ "^#" n "([^0-9]|$)") { found = 1; exit }
        if (match(after, /^[a-z0-9._-]+\/[a-z0-9._-]+#[1-9][0-9]*/)) {
          ref = substr(after, RSTART, RLENGTH)
          sub(/.*#/, "", ref)
          if (ref == n) { found = 1; exit }
        } else if (match(after, /^https:\/\/github\.com\/[a-z0-9._-]+\/[a-z0-9._-]+\/issues\/[1-9][0-9]*/)) {
          ref = substr(after, RSTART, RLENGTH)
          sub(/.*\//, "", ref)
          if (ref == n) { found = 1; exit }
        }
        rest = substr(rest, kw_start + kw_len)
      }
    }
    END { exit found ? 0 : 1 }
  '
}

MERGE_RECORD=0
if [ "$#" -eq 3 ] && [ "$3" = --merge-record ]; then
  MERGE_RECORD=1
  set -- "$1" "$2"
fi
if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

TASK_KIND=$(grep '^kind=' "$META" | tail -1 | cut -d= -f2- || true)
TASK_HARNESS=$(grep '^harness=' "$META" | tail -1 | cut -d= -f2- || true)
if [ "$TASK_KIND" = ship ] && "$SCRIPT_DIR/fm-harness.sh" is-local-model "$TASK_HARNESS"; then
  "$SCRIPT_DIR/fm-local-model-verify.sh" "$ID" 1>&2 || exit 1
fi

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
BRIEF="$DATA/$ID/brief.md"
intent=
intent_recorded=0
if [ -f "$BRIEF" ] && [ ! -L "$BRIEF" ] && [ -r "$BRIEF" ]; then
  intent=$(fm_brief_task_heading_body "$BRIEF" "## Captain's intent" || true)
  fm_brief_task_heading_present "$BRIEF" "## Captain's intent" && intent_recorded=1
fi
issues=$(fm_pr_intent_issue_numbers "$intent")
if [ "$PROVIDER" = github ] && { [ -n "$issues" ] || [ "$intent_recorded" = 1 ]; }; then
  body_rc=0
  PR_BODY=
  if [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
    PR_BODY=$(cd "$WT" && gh pr view "$URL" --json body -q .body 2>/dev/null) || body_rc=$?
  else
    body_rc=1
  fi
  if [ -n "$issues" ]; then
    issue_list=
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      issue_list="${issue_list:+$issue_list }#$n"
    done <<EOF
$issues
EOF
    if [ "$body_rc" -ne 0 ]; then
      echo "error: could not read PR body to verify closing keywords for issues named in captain's intent: $issue_list" >&2
      exit 1
    fi
    missing=
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      if ! printf '%s\n' "$PR_BODY" | fm_pr_body_closes_issue "$n"; then
        missing="${missing:+$missing }#$n"
      fi
    done <<EOF
$issues
EOF
    if [ -n "$missing" ]; then
      echo "error: PR body does not close issues named in captain's intent: $missing (each named issue needs its own closing keyword, e.g. Closes #N)" >&2
      exit 1
    fi
  else
    if [ "$body_rc" -ne 0 ]; then
      echo "error: could not read PR body to verify the no-linked-issue marker" >&2
      exit 1
    fi
    body_lc=$(printf '%s' "$PR_BODY" | tr '[:upper:]' '[:lower:]')
    case "$body_lc" in
      *"no linked issue"*) ;;
      *)
        echo "error: captain's intent names no issue, and the PR body does not say so deliberately (add a literal 'No linked issue' line)" >&2
        exit 1
        ;;
    esac
  fi
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
# bin/fm-pr-merge.sh reads a GitLab head live at merge time for the same reason,
# and treats a recorded value that disagrees as stale rather than authoritative.
# The same GitHub view now also returns isDraft, and a GitLab view returns
# draft, so registration can say draft instead of ready.
PR_HEAD=
PR_DRAFT=0
PR_DRAFT_READ_OK=0
view_head=
{
  IFS=$'\t' read -r PR_DRAFT PR_DRAFT_READ_OK view_head
} <<EOF
$(fm_pr_read_draft "$URL" "$WT")
EOF
[ -z "$view_head" ] || PR_HEAD=$view_head

# A ready PR must not carry an unanswered blocking review finding. The scan is
# live rather than read from the watcher's handled record, because a finding
# stays blocking after it was raised until someone answers it.
if [ "$PROVIDER" = github ] && [ "$MERGE_RECORD" != 1 ] \
  && ! { [ "${PR_DRAFT_READ_OK:-0}" = 1 ] && [ "${PR_DRAFT:-0}" = 1 ]; }; then
  gate_rc=0
  gate_config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  gate_rows=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$gate_config" \
    "$SCRIPT_DIR/fm-pr-poll.sh" --gate "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" 2>/dev/null) || gate_rc=$?
  if [ "$gate_rc" -eq 2 ]; then
    echo "error: PR has more review threads than one page reads, so unanswered blocking findings cannot be ruled out: $URL. Mark the PR draft or resolve threads until they fit." >&2
    exit 1
  elif [ "$gate_rc" -eq 3 ]; then
    echo "error: review data on $URL has a shape this gate does not understand, so unanswered blocking findings cannot be ruled out; it is not registered ready. Inspect the PR's review threads, or mark the PR draft." >&2
    exit 1
  elif [ "$gate_rc" -ne 0 ]; then
    echo "error: could not read review threads to check for unanswered blocking findings on $URL, so it is not registered ready. Retry, or mark the PR draft." >&2
    exit 1
  elif [ -n "$gate_rows" ]; then
    gate_thread=$(printf '%s\n' "$gate_rows" | while IFS=$'\t' read -r gate_id gate_author gate_kind; do
      if [ "$gate_kind" = thread ]; then printf '%s (by %s), ' "$gate_id" "$gate_author"; fi
    done)
    gate_review=$(printf '%s\n' "$gate_rows" | while IFS=$'\t' read -r gate_id gate_author gate_kind; do
      if [ "$gate_kind" = review ]; then printf '%s (by %s), ' "$gate_id" "$gate_author"; fi
    done)
    if [ -n "$gate_thread" ]; then
      echo "error: PR has unanswered blocking review findings: ${gate_thread%, }. Answer each by resolving its thread or replying beneath it as someone other than its author (a fix explanation or a reasoned disagreement both count); a push alone does not answer a finding." >&2
    fi
    if [ -n "$gate_review" ]; then
      echo "error: PR has standing change-request reviews: ${gate_review%, }. Each stands until its reviewer dismisses it or submits a newer review; ask them to, or dismiss it yourself if you can." >&2
    fi
    exit 1
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
# In a secondmate home the registration itself is a captain-facing fact:
# publish the child's PR line with the canonical URL just recorded, so it
# reaches the parent whether or not the mate model appends anything
# (bin/fm-parent-channel-lib.sh). A draft PR says draft; an open PR says
# ready; a view that could not be read at all says draft status unknown, so a
# transient forge failure never gets announced as ready. A main home has no
# channel and this is a silent no-op there. The poll is armed either way; a
# channel that cannot be written is reported as actionable, and
# bin/fm-inactive-reconcile.sh still delivers the child's own ready line on
# the next supervision poll.
if [ "${PR_DRAFT_READ_OK:-0}" != 1 ]; then
  READY_LINE="done [key=child-pr-$ID]: child $ID PR draft status unknown, verify before treating as ready: $URL"
elif [ "${PR_DRAFT:-0}" = 1 ]; then
  READY_LINE="done [key=child-pr-$ID]: child $ID PR draft: $URL"
else
  READY_LINE="done [key=child-pr-$ID]: child $ID PR ready: $URL"
fi
PR_MODE=$(grep '^mode=' "$META" | tail -1 | cut -d= -f2- || true)
PR_YOLO=$(grep '^yolo=' "$META" | tail -1 | cut -d= -f2- || true)
[ -z "$PR_MODE" ] || READY_LINE="$READY_LINE mode=$(fm_parent_channel_clean_note "$PR_MODE")"
[ -z "$PR_YOLO" ] || READY_LINE="$READY_LINE yolo=$(fm_parent_channel_clean_note "$PR_YOLO")"
READY_RC=0
fm_parent_channel_report "$FM_HOME" "$STATE" "$READY_LINE" || READY_RC=$?
case "$READY_RC" in
  0|1) ;;
  *) printf 'actionable: PR %s is registered but its parent-channel line did not reach the parent (rc=%s)\n' "$URL" "$READY_RC" >&2 ;;
esac
printf 'armed: state/%s.check.sh\n' "$ID"
