#!/usr/bin/env bash
# Usage: fm-nm-quiescence.sh
# Reports HOME/RUN/GAP records and a fleet SUMMARY; coverage and settings: docs/configuration.md (Validation census). --home-only and --root-only are internal fm-on.sh modes.
# Exit bitmask: 0 complete and clear, 1 runs exist, 2 checks incomplete, 3 runs and gaps coexist.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
REG="$DATA/secondmates.md"
ON_BIN="${FM_NM_ON_BIN:-$SCRIPT_DIR/fm-on.sh}"
QUERY_TIMEOUT="${FM_NM_QUIESCENCE_TIMEOUT:-15}"
RUN_LIMIT=2147483647

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

RUN_COUNT=0
GAP_COUNT=0
HOME_RUN_COUNT=0
HOME_GAP_COUNT=0
HOME_REPOSITORIES=$'\n'
REMOTE_ERROR=
IDS=()
HOSTS=()
ROOTS=()
HOMES=()
REMOTES=()
REPOSITORY_RESULTS=$'\n'
REMOTE_SCAN=0

usage() {
  sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

sanitize_value() {
  local value=${1:-}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  printf '%.240s' "$value"
}

first_line() {
  local value=${1:-}
  value=${value%%$'\n'*}
  sanitize_value "$value"
}

emit_gap() {
  local host home clone reason detail
  host=$(sanitize_value "$1")
  home=$(sanitize_value "$2")
  clone=$(sanitize_value "$3")
  reason=$(sanitize_value "$4")
  detail=$(sanitize_value "${5:-}")
  printf 'GAP\thost=%s\thome=%s\tclone=%s\treason=%s' "$host" "$home" "$clone" "$reason"
  [ -z "$detail" ] || printf '\tdetail=%s' "$detail"
  printf '\n'
  GAP_COUNT=$((GAP_COUNT + 1))
  HOME_GAP_COUNT=$((HOME_GAP_COUNT + 1))
}

emit_home() {
  local host home path clones status
  host=$(sanitize_value "$1")
  home=$(sanitize_value "$2")
  path=$(sanitize_value "$3")
  clones=$4
  if [ "$HOME_GAP_COUNT" -gt 0 ]; then
    status=incomplete
  elif [ "$HOME_RUN_COUNT" -gt 0 ]; then
    status=busy
  else
    status=clear
  fi
  printf 'HOME\thost=%s\thome=%s\tpath=%s\tclones=%s\truns=%s\tgaps=%s\tstatus=%s\n' \
    "$host" "$home" "$path" "$clones" "$HOME_RUN_COUNT" "$HOME_GAP_COUNT" "$status"
}

timestamp_epoch() {
  local timestamp=$1
  date -j -f '%Y-%m-%d %H:%M:%S' "$timestamp:00" '+%s' 2>/dev/null \
    || date -d "$timestamp:00" '+%s' 2>/dev/null
}

format_age() {
  local seconds=$1 days hours minutes
  [ "$seconds" -ge 0 ] || return 1
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if [ "$days" -gt 0 ]; then
    printf '%dd%dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh%dm' "$hours" "$minutes"
  else
    printf '%dm' "$minutes"
  fi
}

valid_run_row() {
  local state=$1 branch=$2 head=$3 day=$4 clock=$5 pr=$6 extra=$7
  [ -n "$state" ] && [ -n "$branch" ] && [ -n "$head" ] && [ -n "$day" ] && [ -n "$clock" ] || return 1
  [ -z "$extra" ] || return 1
  case "$state" in *[!a-z_-]*|'') return 1 ;; esac
  case "$branch" in *[!A-Za-z0-9._/-]*|'') return 1 ;; esac
  case "$head" in *[!A-Fa-f0-9]*|'') return 1 ;; esac
  [ "${#head}" -ge 7 ] && [ "${#head}" -le 40 ] || return 1
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  case "$clock" in [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;; *) return 1 ;; esac
  case "$pr" in ''|https://*) ;; *) return 1 ;; esac
  return 0
}

emit_run() {
  local host=$1 home=$2 clone=$3 branch=$4 head=$5 state=$6 day=$7 clock=$8
  local started_epoch age_seconds age
  if started_epoch=$(timestamp_epoch "$day $clock"); then
    age_seconds=$((NOW_EPOCH - started_epoch))
    if [ "$age_seconds" -lt -60 ]; then
      age=future
    else
      [ "$age_seconds" -ge 0 ] || age_seconds=0
      age=$(format_age "$age_seconds")
    fi
  else
    age=unknown
  fi
  printf 'RUN\thost=%s\thome=%s\tclone=%s\tbranch=%s\thead=%s\tstate=%s\tage=%s\tstarted=%sT%s\n' \
    "$(sanitize_value "$host")" "$(sanitize_value "$home")" "$(sanitize_value "$clone")" \
    "$(sanitize_value "$branch")" "$(sanitize_value "$head")" "$(sanitize_value "$state")" \
    "$age" "$day" "$clock"
  RUN_COUNT=$((RUN_COUNT + 1))
  HOME_RUN_COUNT=$((HOME_RUN_COUNT + 1))
  case "$age" in
    future) emit_gap "$host" "$home" "$clone" run-started-in-future "$day $clock" ;;
    unknown) emit_gap "$host" "$home" "$clone" run-age-unavailable "$day $clock" ;;
  esac
}

scan_repository() {
  local host=$1 home=$2 clone=$3 repo=$4 rc metadata identity key cached runs gaps extra result
  local before_runs=$RUN_COUNT before_gaps=$GAP_COUNT
  rc=0
  metadata=$(fm_nm_run_bounded "$repo" "$QUERY_TIMEOUT" axi 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$metadata" in
      *"repo not initialized"*) emit_gap "$host" "$home" "$clone" validation-not-configured ;;
      *) emit_gap "$host" "$home" "$clone" validation-identity-query-failed "$(first_line "$metadata")" ;;
    esac
    return
  fi
  identity=$(fm_nm_strip_quotes "$(printf '%s\n' "$metadata" | sed -n 's/^repo:[[:space:]]*//p')")
  case "$identity" in
    *$'\t'*|*$'\r'*|*$'\n'*) emit_gap "$host" "$home" "$clone" invalid-repository-identity; return ;;
    /*) ;;
    *) emit_gap "$host" "$home" "$clone" invalid-repository-identity; return ;;
  esac
  key=$host$'\t'$identity
  list_has "$key" "$HOME_REPOSITORIES" && return
  HOME_REPOSITORIES+="$key"$'\n'
  case "$REPOSITORY_RESULTS" in
    *$'\n'"$key"$'\t'*)
      cached=${REPOSITORY_RESULTS#*$'\n'"$key"$'\t'}
      cached=${cached%%$'\n'*}
      IFS=$'\t' read -r runs gaps extra <<< "$cached"
      if [[ ! "$runs" =~ ^[0-9]+$ ]] || [[ ! "$gaps" =~ ^[0-9]+$ ]] || [ -n "$extra" ]; then
        emit_gap "$host" "$home" "$clone" invalid-repository-result
        return
      fi
      HOME_RUN_COUNT=$((HOME_RUN_COUNT + 10#$runs))
      HOME_GAP_COUNT=$((HOME_GAP_COUNT + 10#$gaps))
      return
      ;;
  esac
  scan_ledger "$host" "$home" "$clone" "$repo"
  result=$key$'\t'$((RUN_COUNT - before_runs))$'\t'$((GAP_COUNT - before_gaps))
  REPOSITORY_RESULTS+="$result"$'\n'
  [ "$REMOTE_SCAN" -eq 0 ] || printf 'REPO\t%s\n' "$result"
}

scan_ledger() {
  local host=$1 home=$2 clone=$3 repo=$4 ledger rc row state branch head day clock pr extra
  rc=0
  ledger=$(fm_nm_run_bounded "$repo" "$QUERY_TIMEOUT" runs --limit "$RUN_LIMIT" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$ledger" in
      *"repo not initialized"*) emit_gap "$host" "$home" "$clone" validation-not-configured ;;
      *) emit_gap "$host" "$home" "$clone" validation-query-failed "$(first_line "$ledger")" ;;
    esac
    return
  fi
  ledger=$(printf '%s\n' "$ledger" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d')
  case "$ledger" in
    'no runs yet. Push through the gate to start a pipeline:'$'\n''git push no-mistakes <branch>') return ;;
    '') emit_gap "$host" "$home" "$clone" empty-ledger-response; return ;;
  esac
  while IFS= read -r row || [ -n "$row" ]; do
    row=$(fm_nm_trim "$row")
    [ -n "$row" ] || continue
    state=
    branch=
    head=
    day=
    clock=
    pr=
    extra=
    IFS=$' \t' read -r state branch head day clock pr extra <<< "$row"
    if ! valid_run_row "$state" "$branch" "$head" "$day" "$clock" "$pr" "$extra"; then
      emit_gap "$host" "$home" "$clone" unparseable-ledger-row "$(first_line "$row")"
      continue
    fi
    case "$state" in
      completed|failed|cancelled) ;;
      running) emit_run "$host" "$home" "$clone" "$branch" "$head" "$state" "$day" "$clock" ;;
      *)
        emit_run "$host" "$home" "$clone" "$branch" "$head" "$state" "$day" "$clock"
        emit_gap "$host" "$home" "$clone" unknown-run-state "$state"
        ;;
    esac
  done <<< "$ledger"
}

canonical_dir() {
  CDPATH='' cd -- "$1" 2>/dev/null && pwd -P
}

can_inspect_directory() {
  local path=$1
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    path=$(dirname -- "$path")
  done
  [ -d "$path" ] && [ -r "$path" ] && [ -x "$path" ]
}

scan_root() {
  local host=$1 home=$2 root=$3 root_real git_root
  HOME_RUN_COUNT=0
  HOME_GAP_COUNT=0
  HOME_REPOSITORIES=$'\n'
  if [ ! -d "$root" ] || [ -L "$root" ]; then
    emit_gap "$host" "$home" - root-unreachable
    emit_home "$host" "$home" "$root" 0
    return
  fi
  root_real=$(canonical_dir "$root") || {
    emit_gap "$host" "$home" - root-unreachable
    emit_home "$host" "$home" "$root" 0
    return
  }
  git_root=$(git -C "$root_real" rev-parse --show-toplevel 2>/dev/null) || {
    emit_gap "$host" "$home" - root-not-git
    emit_home "$host" "$home" "$root_real" 1
    return
  }
  if [ "$(canonical_dir "$git_root")" != "$root_real" ]; then
    emit_gap "$host" "$home" - root-not-primary-git-directory
    emit_home "$host" "$home" "$root_real" 1
    return
  fi
  scan_repository "$host" "$home" "$(basename "$root_real")" "$root_real"
  emit_home "$host" "$home" "$root_real" 1
}

scan_home() {
  local host=$1 home_id=$2 home_path=$3
  local projects project_path clone_count=0 project_real git_root
  HOME_RUN_COUNT=0
  HOME_GAP_COUNT=0
  HOME_REPOSITORIES=$'\n'
  if [ ! -d "$home_path" ] || [ -L "$home_path" ] || ! can_inspect_directory "$home_path"; then
    emit_gap "$host" "$home_id" - home-unreachable
    emit_home "$host" "$home_id" "$home_path" 0
    return
  fi
  if git_root=$(git -C "$home_path" rev-parse --show-toplevel 2>/dev/null); then
    if git_root=$(canonical_dir "$git_root"); then
      clone_count=$((clone_count + 1))
      scan_repository "$host" "$home_id" "$(basename "$git_root")" "$git_root"
    else
      emit_gap "$host" "$home_id" - home-repository-unreachable
    fi
  elif [ -e "$home_path/.git" ] || [ -L "$home_path/.git" ]; then
    emit_gap "$host" "$home_id" - home-repository-unreachable
  fi
  projects=${4:-"$home_path/projects"}
  if ! can_inspect_directory "$projects"; then
    emit_gap "$host" "$home_id" - projects-unreachable
    emit_home "$host" "$home_id" "$home_path" "$clone_count"
    return
  fi
  if [ ! -e "$projects" ] && [ ! -L "$projects" ]; then
    emit_home "$host" "$home_id" "$home_path" "$clone_count"
    return
  fi
  if [ ! -d "$projects" ] || [ -L "$projects" ]; then
    emit_gap "$host" "$home_id" - projects-unreachable
    emit_home "$host" "$home_id" "$home_path" "$clone_count"
    return
  fi
  if ! find -P "$projects" -mindepth 1 -maxdepth 1 -print >/dev/null 2>&1; then
    emit_gap "$host" "$home_id" - projects-unreachable
    emit_home "$host" "$home_id" "$home_path" "$clone_count"
    return
  fi
  for project_path in "$projects"/* "$projects"/.[!.]* "$projects"/..?*; do
    [ -e "$project_path" ] || [ -L "$project_path" ] || continue
    clone_count=$((clone_count + 1))
    if [ ! -d "$project_path" ] || [ -L "$project_path" ]; then
      emit_gap "$host" "$home_id" "$(basename "$project_path")" unsafe-project-entry
      continue
    fi
    project_real=$(canonical_dir "$project_path") || {
      emit_gap "$host" "$home_id" "$(basename "$project_path")" clone-unreachable
      continue
    }
    git_root=$(git -C "$project_real" rev-parse --show-toplevel 2>/dev/null) || {
      emit_gap "$host" "$home_id" "$(basename "$project_real")" not-a-git-clone
      continue
    }
    if [ "$(canonical_dir "$git_root")" != "$project_real" ]; then
      emit_gap "$host" "$home_id" "$(basename "$project_real")" nested-git-worktree
      continue
    fi
    scan_repository "$host" "$home_id" "$(basename "$project_real")" "$project_real"
  done
  emit_home "$host" "$home_id" "$home_path" "$clone_count"
}

safe_absolute_path() {
  local path=$1
  case "$path" in /*) ;; *) return 1 ;; esac
  case "/$path/" in */../*|*/./*) return 1 ;; esac
  case "$path" in *'//'*|*$'\t'*|*$'\r'*|*$'\n'*) return 1 ;; esac
  return 0
}

load_registry() {
  local line line_number=0
  if ! can_inspect_directory "$DATA"; then
    emit_gap local main - registry-unavailable "$DATA"
    return
  fi
  [ -e "$REG" ] || [ -L "$REG" ] || return
  if [ ! -f "$REG" ] || [ -L "$REG" ] || [ ! -r "$REG" ]; then
    emit_gap local main - registry-unavailable "$REG"
    return
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then
      emit_gap local main - malformed-registry-entry "line=$line_number"
      continue
    fi
    if ! safe_absolute_path "$SECONDMATE_REGISTRY_HOME"; then
      emit_gap "${SECONDMATE_REGISTRY_HOST:-local}" "$SECONDMATE_REGISTRY_ID" - unsafe-home-path
      continue
    fi
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      case "$SECONDMATE_REGISTRY_HOST" in ''|-*|*[!A-Za-z0-9._-]*)
        emit_gap unknown "$SECONDMATE_REGISTRY_ID" - unsafe-host-alias
        continue
        ;;
      esac
      if ! safe_absolute_path "$SECONDMATE_REGISTRY_ROOT"; then
        emit_gap "$SECONDMATE_REGISTRY_HOST" "$SECONDMATE_REGISTRY_ID" - unsafe-root-path
        continue
      fi
    fi
    IDS+=("$SECONDMATE_REGISTRY_ID")
    HOSTS+=("${SECONDMATE_REGISTRY_HOST:-local}")
    ROOTS+=("$SECONDMATE_REGISTRY_ROOT")
    HOMES+=("$SECONDMATE_REGISTRY_HOME")
    REMOTES+=("$SECONDMATE_REGISTRY_REMOTE")
  done < "$REG"
}

remote_output_records() {
  local output=$1 line saw_home=0 bad=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      REPO$'\t'*) REPOSITORY_RESULTS+="${line#*$'\t'}"$'\n' ;;
      RUN$'\t'*) printf '%s\n' "$line"; RUN_COUNT=$((RUN_COUNT + 1)) ;;
      GAP$'\t'*) printf '%s\n' "$line"; GAP_COUNT=$((GAP_COUNT + 1)) ;;
      HOME$'\t'*) printf '%s\n' "$line"; saw_home=1 ;;
      '') ;;
      *) [ -n "$bad" ] || bad=$(first_line "$line") ;;
    esac
  done <<< "$output"
  [ -z "$bad" ] || emit_gap remote remote - invalid-remote-output "$bad"
  [ "$saw_home" -eq 1 ]
}

run_remote() {
  local route=$1 mode=$2 label=$3 host=$4 output rc=0
  REMOTE_ERROR=
  output=$("$ON_BIN" "$route" fm-nm-quiescence.sh "$mode" "$label" "$host" "$REPOSITORY_RESULTS" 2>&1) || rc=$?
  case "$rc" in
    0|1|2|3)
      if ! remote_output_records "$output"; then
        emit_gap "$host" "$label" - missing-remote-home-result
      fi
      ;;
    255)
      REMOTE_ERROR=$(first_line "$output")
      return 255
      ;;
    *)
      emit_gap "$host" "$label" - remote-check-failed "$(first_line "$output")"
      ;;
  esac
  return 0
}

list_has() {
  local needle=$1 list=$2
  case "$list" in *$'\n'"$needle"$'\n'*) return 0 ;; esac
  return 1
}

exit_with_summary() {
  local result rc
  if [ "$RUN_COUNT" -gt 0 ] && [ "$GAP_COUNT" -gt 0 ]; then
    result=busy-incomplete
    rc=3
  elif [ "$RUN_COUNT" -gt 0 ]; then
    result=busy
    rc=1
  elif [ "$GAP_COUNT" -gt 0 ]; then
    result=incomplete
    rc=2
  else
    result=clear
    rc=0
  fi
  printf 'SUMMARY\tresult=%s\truns=%s\tgaps=%s\n' "$result" "$RUN_COUNT" "$GAP_COUNT"
  exit "$rc"
}

case "${1:-}" in
  '')
    ;;
  --help|-h)
    usage
    ;;
  --home-only)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
    REMOTE_SCAN=1
    REPOSITORY_RESULTS=${4:-$'\n'}
    NOW_EPOCH="${FM_NM_QUIESCENCE_NOW_EPOCH:-$(date +%s)}"
    scan_home "$3" "$2" "$FM_HOME" "$PROJECTS"
    if [ "$HOME_RUN_COUNT" -gt 0 ] && [ "$HOME_GAP_COUNT" -gt 0 ]; then exit 3; fi
    if [ "$HOME_RUN_COUNT" -gt 0 ]; then exit 1; fi
    if [ "$HOME_GAP_COUNT" -gt 0 ]; then exit 2; fi
    exit 0
    ;;
  --root-only)
    [ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
    REMOTE_SCAN=1
    REPOSITORY_RESULTS=${4:-$'\n'}
    NOW_EPOCH="${FM_NM_QUIESCENCE_NOW_EPOCH:-$(date +%s)}"
    scan_root "$3" "$2" "$FM_ROOT"
    if [ "$HOME_RUN_COUNT" -gt 0 ] && [ "$HOME_GAP_COUNT" -gt 0 ]; then exit 3; fi
    if [ "$HOME_RUN_COUNT" -gt 0 ]; then exit 1; fi
    if [ "$HOME_GAP_COUNT" -gt 0 ]; then exit 2; fi
    exit 0
    ;;
  *)
    usage
    ;;
esac

case "$QUERY_TIMEOUT" in ''|*[!0-9]*|0) printf 'error: FM_NM_QUIESCENCE_TIMEOUT must be a positive integer\n' >&2; exit 2 ;; esac
NOW_EPOCH="${FM_NM_QUIESCENCE_NOW_EPOCH:-$(date +%s)}"
case "$NOW_EPOCH" in ''|*[!0-9]*) printf 'error: FM_NM_QUIESCENCE_NOW_EPOCH must be a nonnegative integer\n' >&2; exit 2 ;; esac

scan_root local root@local "$FM_ROOT"
scan_home local main "$FM_HOME" "$PROJECTS"
load_registry

for i in "${!IDS[@]}"; do
  [ "${REMOTES[$i]}" -eq 0 ] || continue
  scan_home local "${IDS[$i]}" "${HOMES[$i]}"
done

seen_roots=$'\n'
unreachable_hosts=$'\n'
unreachable_details=$'\n'
for i in "${!IDS[@]}"; do
  [ "${REMOTES[$i]}" -eq 1 ] || continue
  host=${HOSTS[$i]}
  root_key=$host$'\t'${ROOTS[$i]}
  list_has "$root_key" "$seen_roots" && continue
  seen_roots+="$root_key"$'\n'
  if ! run_remote "${IDS[$i]}" --root-only "root@$host" "$host"; then
    detail=$REMOTE_ERROR
    unreachable_hosts+="$host"$'\n'
    unreachable_details+="$host"$'\t'"$detail"$'\n'
    emit_gap "$host" "root@$host" - host-unreachable "$detail"
  fi
done

for i in "${!IDS[@]}"; do
  [ "${REMOTES[$i]}" -eq 1 ] || continue
  host=${HOSTS[$i]}
  if list_has "$host" "$unreachable_hosts"; then
    detail=$(printf '%s' "$unreachable_details" | awk -F '\t' -v wanted="$host" '$1 == wanted { sub(/^[^\t]*\t/, ""); print; exit }')
    emit_gap "$host" "${IDS[$i]}" - host-unreachable "$detail"
    continue
  fi
  if ! run_remote "${IDS[$i]}" --home-only "${IDS[$i]}" "$host"; then
    detail=$REMOTE_ERROR
    unreachable_hosts+="$host"$'\n'
    unreachable_details+="$host"$'\t'"$detail"$'\n'
    emit_gap "$host" "${IDS[$i]}" - host-unreachable "$detail"
  fi
done

exit_with_summary
