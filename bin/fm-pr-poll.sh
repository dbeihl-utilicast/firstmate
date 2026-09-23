#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits one validated state line for a merged PR/MR or a behind/conflicting
# open GitHub PR, plus one review line while an open GitHub PR carries review
# findings not yet raised, stays silent on errors, and never moves
# a branch itself. It also never writes: bin/fm-watch.sh records the findings a
# review line raised. A finding is a review thread whose first comment neither
# the forge reports outdated or detached, nor a resolved thread, nor a comment
# with a reply from anyone other than its author. It blocks only when the forge
# marks it a change request or its body holds a literal marker configured for
# the repository in config/review-blocking-markers ("owner/repo marker" lines);
# nothing keys on a reviewer's name. With no markers a review line says
# not-gating for the reviewers it reports. "--gate" prints the blocking
# findings still unanswered as "id author kind", for bin/fm-pr-check.sh, and exits 1 when the
# threads cannot be read or 2 when they exceed one page.
# Provider identity remains uninterpolated data and these bytes stay task-static.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# A registered poll is a byte-static snapshot under state/, while fm-watch
# executes this canonical template after validating that snapshot, so the
# helper is sourced from beside this script or from the firstmate root.
GH_AUTH_LIB="$SCRIPT_DIR/fm-gh-auth-lib.sh"
[ -r "$GH_AUTH_LIB" ] || GH_AUTH_LIB="$FM_ROOT/bin/fm-gh-auth-lib.sh"
if [ ! -r "$GH_AUTH_LIB" ]; then
  echo "fm-pr-poll: cannot read fm-gh-auth-lib.sh in $SCRIPT_DIR or $FM_ROOT/bin" >&2
  exit 1
fi
# shellcheck source=bin/fm-gh-auth-lib.sh
. "$GH_AUTH_LIB"

mode=poll
if [ "$#" -eq 6 ] && [ "$1" = --gate ]; then
  mode=gate
  shift
  set -- --validated "$@"
fi
if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# One tab-separated row per unanswered review thread on the pull request:
# first comment id, author, whether the forge marks it a change request, kind
# (thread or review), body.
# A resolved or outdated thread, a comment whose line is gone, and a thread with
# a reply from anyone but the first comment's author never appear. More threads
# than one page holds is an unreadable answer rather than a partial one. A
# review whose state is CHANGES_REQUESTED and that carries no inline comment is
# a finding of its own, so a change request needs no marker in a body; it stays
# blocking until the forge dismisses it or its reviewer's latest review moves on.
review_rows() {
  # shellcheck disable=SC2016  # GraphQL variables and jq bindings, not shell expansions.
  fm_gh_run "$owner" gh api graphql --hostname "$host" \
    -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{id isResolved isOutdated comments(first:50){nodes{id author{login} body path line pullRequestReview{state}}}}} latestReviews(first:50){nodes{id state author{login} body comments(first:1){totalCount}}}}}}' \
    -f owner="$owner" -f name="$repo" -F number="$number" --jq '
      .data.repository.pullRequest as $pr
      | (
          $pr.reviewThreads
          | if .pageInfo.hasNextPage then error("truncated") else .nodes end
          | .[]
          | select((.isResolved | not) and (.isOutdated | not))
          | .comments.nodes as $c
          | select(($c | length) > 0 and $c[0].line != null and $c[0].path != null)
          | select(all($c[1:][]; .author.login == $c[0].author.login))
          | [$c[0].id, ($c[0].author.login // "unknown"), ($c[0].pullRequestReview.state == "CHANGES_REQUESTED"), "thread", ($c[0].body // "" | gsub("[\t\r\n]"; " "))]
          | @tsv
        ), (
          ($pr.latestReviews.nodes // [])[]
          | select(.state == "CHANGES_REQUESTED" and (.comments.totalCount // 0) == 0)
          | [.id, (.author.login // "unknown"), true, "review", (.body // "" | gsub("[\t\r\n]"; " "))]
          | @tsv
        )'
}

# The literal severity markers configured for this repository, one per line.
review_markers_load() {
  local line cfg
  REVIEW_MARKERS=''
  cfg=${FM_CONFIG_OVERRIDE:-}
  [ -n "$cfg" ] || { [ -z "${FM_HOME:-}" ] || cfg=$FM_HOME/config; }
  cfg=$cfg/review-blocking-markers
  if [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$path "?*) REVIEW_MARKERS="$REVIEW_MARKERS${line#"$path "}"$'\n' ;;
      esac
    done < "$cfg"
  fi
}

# Reads review_rows output and prints "id<TAB>author<TAB>b|n<TAB>kind" for each valid
# row, and "!<TAB>reason" for each row whose shape it does not understand.
review_classify() {
  local cid author cr kind body blocking marker
  while IFS=$'\t' read -r cid author cr kind body; do
    [ -n "$cid$author$cr$kind$body" ] || continue
    case "$cid" in ''|*[!A-Za-z0-9_-]*) printf '!\tid\n'; continue ;; esac
    case "$author" in ''|*[!A-Za-z0-9_.[\]-]*) printf '!\tauthor\n'; continue ;; esac
    case "$cr" in true|false) ;; *) printf '!\tflag\n'; continue ;; esac
    case "$kind" in thread|review) ;; *) printf '!\tkind\n'; continue ;; esac
    blocking=n
    [ "$cr" != true ] || blocking=b
    if [ "$blocking" = n ] && [ -n "$REVIEW_MARKERS" ]; then
      while IFS= read -r marker; do
        [ -n "$marker" ] || continue
        case "$body" in *"$marker"*) blocking=b; break ;; esac
      done <<< "$REVIEW_MARKERS"
    fi
    printf '%s\t%s\t%s\t%s\n' "$cid" "$author" "$blocking" "$kind"
  done
}

review_handled() {  # <comment id>
  local file hid _rest
  file=${FM_STATE_OVERRIDE:-}
  [ -n "$file" ] || { [ -z "${FM_HOME:-}" ] || file=$FM_HOME/state; }
  [ -n "$file" ] || return 1
  file=$file/review-handled/${path%%/*}__${path#*/}__$number
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS=' ' read -r hid _rest; do
    [ "$hid" = "$1" ] && return 0
  done < "$file"
  return 1
}

review_report() {  # <head>
  local rows cid author blocking kind ids='' login_list='' blocking_n=0 total=0 seen='' unparsed=0
  rows=$(review_rows 2>/dev/null) || return 0
  review_markers_load
  rows=$(printf '%s\n' "$rows" | review_classify)
  while IFS=$'\t' read -r cid author blocking kind; do
    [ -n "$cid" ] || continue
    if [ "$cid" = '!' ]; then
      unparsed=$((unparsed + 1))
      continue
    fi
    review_handled "$cid" && continue
    total=$((total + 1))
    ids="${ids:+$ids,}$cid:$blocking"
    if [ "$blocking" = b ]; then
      blocking_n=$((blocking_n + 1))
    else
      case ",$seen," in *",$author,"*) ;; *) seen="$seen,$author"; login_list="${login_list:+$login_list,}$author" ;; esac
    fi
  done <<< "$rows"
  if [ "$unparsed" -gt 0 ] && ! review_handled "unparsed-$unparsed"; then
    ids="${ids:+$ids,}unparsed-$unparsed:n"
    total=$((total + 1))
  fi
  [ "$total" -gt 0 ] || return 0
  printf 'review %s blocking=%s reported=%s' "$1" "$blocking_n" "$total"
  [ "$unparsed" -eq 0 ] || printf ' unparsed=%s' "$unparsed"
  [ -n "$REVIEW_MARKERS" ] || [ -z "$login_list" ] || printf ' not-gating=%s' "$login_list"
  printf ' ids=%s\n' "$ids"
}

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    if [ "$mode" = gate ]; then
      gate_err=$(mktemp) || exit 1
      rows=$(review_rows 2>"$gate_err") || {
        if grep -q truncated "$gate_err"; then
          gate_rc=2
        elif grep -qiE 'HTTP 401|bad credentials|gh auth login|not logged in' "$gate_err"; then
          gate_rc=4
        else
          gate_rc=1
        fi
        rm -f "$gate_err"
        exit "$gate_rc"
      }
      rm -f "$gate_err"
      review_markers_load
      classified=$(printf '%s\n' "$rows" | review_classify)
      ! printf '%s\n' "$classified" | grep -q '^!' || exit 3
      printf '%s\n' "$classified" | while IFS=$'\t' read -r cid author blocking kind; do
        [ "$blocking" = b ] && printf '%s\t%s\t%s\n' "$cid" "$author" "$kind"
      done
      exit 0
    fi
    raw=$(fm_gh_run "$owner" gh pr view "$url" --json state,mergeStateStatus,mergeable,headRefOid,baseRefName \
      -q '[.state, .mergeStateStatus, .mergeable, .headRefOid, .baseRefName, (.baseRefName | @uri)] | @tsv' 2>/dev/null) || exit 0
    case "$raw" in ''|*$'\n'*) exit 0 ;; esac
    IFS=$'\t' read -r state merge_state mergeable head base_name base_ref extra <<< "$raw"
    [ -z "${extra:-}" ] || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    [ "$state" = OPEN ] || exit 0
    case "$head" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
      *) exit 0 ;;
    esac
    case "${#head}" in 40|64) ;; *) exit 0 ;; esac
    case "$head" in *[!0-9a-f]*) exit 0 ;; esac
    review_report "$head"
    if [ "$mergeable" = CONFLICTING ] || [ "$merge_state" = DIRTY ]; then
      printf 'conflict %s\n' "$head"
    else
      case "$base_name" in
        ''|-*) exit 0 ;;
      esac
      git check-ref-format "refs/heads/$base_name" 2>/dev/null || exit 0
      [ -n "$base_ref" ] || exit 0
      strict=$(fm_gh_run "$owner" gh api --hostname "$host" "repos/$path/branches/$base_ref/protection/required_status_checks" \
        --jq '.strict == true and (((.checks // []) + (.contexts // [])) | length > 0)' 2>/dev/null) || strict=
      if [ "$strict" != true ]; then
        strict=$(fm_gh_run "$owner" gh api --hostname "$host" "repos/$path/rules/branches/$base_ref" --paginate \
          --jq '.[] | select(.type == "required_status_checks" and .parameters.strict_required_status_checks_policy == true and ((.parameters.required_status_checks // []) | length > 0)) | "true"' \
          2>/dev/null) || exit 0
      fi
      printf '%s\n' "$strict" | grep -qx true || exit 0
      behind=$(fm_gh_run "$owner" gh api --hostname "$host" "repos/$path/compare/$base_ref...$head" \
        --jq '.behind_by' 2>/dev/null) || exit 0
      case "$behind" in ''|*[!0-9]*) exit 0 ;; esac
      [ "$behind" -gt 0 ] 2>/dev/null && printf 'behind %s\n' "$head"
    fi
    ;;
  gitlab)
    [ "$mode" = poll ] || exit 0
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
