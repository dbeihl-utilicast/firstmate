#!/usr/bin/env bash
# fm-vault-copy.sh - copy finished task reports into the configured captain vault.
#
# Usage:
#   fm-vault-copy.sh catch-up
#
# The primary home owns this operation. It reads the optional config/vault-path
# from that home, scans finished local work and mirrored remote reports, and
# copies only data/<task>/report.md documents. A destination is never replaced
# by different bytes; a content-addressed suffix preserves both documents. A
# private state ledger of source path plus content hash makes each report copy
# once, even if the vault copy is later edited, moved, or renamed. A remote
# report is named by the project= on its offering status line, else by the
# secondmate id, never by the secondmate's own recorded project.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
VAULT_CONFIG="$CONFIG/vault-path"
LEDGER="$STATE/vault-copied.ledger"

# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  printf 'Usage: fm-vault-copy.sh catch-up\n' >&2
  exit 2
}

meta_field() { # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

configured_vault() {
  local value
  [ -f "$VAULT_CONFIG" ] && [ ! -L "$VAULT_CONFIG" ] || return 1
  value=$(sed -n '1p' "$VAULT_CONFIG") || return 1
  [ -n "$value" ] || return 1
  case "$value" in /*) ;; *) return 1 ;; esac
  case "$value" in
    *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  printf '%s\n' "${value%/}"
}

safe_task_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

safe_regular_report() {
  local path=$1 component=$1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  while [ "$component" != / ]; do
    [ ! -L "$component" ] || return 1
    component=${component%/*}
    [ -n "$component" ] || component=/
  done
}

slug() {
  local value=${1%/}
  value=${value##*/}
  value=$(printf '%s' "$value" | sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-*//; s/-*$//')
  [ -n "$value" ] || value=unknown
  printf '%s' "$value"
}

vault_destination() { # <vault> <project> <task> <source>
  local vault=$1 project=$2 task=$3 source=$4 date digest candidate suffix n=2
  date=$(date +%F)
  project=$(slug "$project")
  task=$(slug "$task")
  candidate="$vault/research/$date-$project-$task.md"
  if [ ! -e "$candidate" ] && [ ! -L "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  if cmp -s "$source" "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  digest=$(sha256_file "$source") || return 1
  suffix=${digest:0:16}
  candidate="$vault/research/$date-$project-$task-$suffix.md"
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    cmp -s "$source" "$candidate" && { printf '%s\n' "$candidate"; return 0; }
    candidate="$vault/research/$date-$project-$task-$suffix-$n.md"
    n=$((n + 1))
  done
  printf '%s\n' "$candidate"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

copy_report() { # <vault> <source> <project> <task>
  local vault=$1 source=$2 project=$3 task=$4 destination parent tmp entry
  safe_task_id "$task" || return 1
  safe_regular_report "$source" || return 0
  entry="$(sha256_file "$source") $source" || return 1
  if [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] && grep -Fqx -- "$entry" "$LEDGER"; then
    return 0
  fi
  destination=$(vault_destination "$vault" "$project" "$task" "$source") || return 1
  if [ -f "$destination" ] && [ ! -L "$destination" ] && cmp -s "$source" "$destination"; then
    record_copied "$entry"
    return 0
  fi
  parent=$(dirname "$destination")
  mkdir -p "$parent" || return 1
  [ ! -L "$vault" ] && [ ! -L "$parent" ] || return 1
  tmp=$(umask 077; mktemp "$parent/.vault-report.XXXXXX") || return 1
  if ! cp "$source" "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    rm -f -- "$tmp"
    return 1
  fi
  record_copied "$entry"
  printf 'copied: %s\n' "$destination"
}

record_copied() { # <entry>
  [ ! -L "$LEDGER" ] || return 1
  (umask 077; printf '%s\n' "$1" >> "$LEDGER")
}

finished_status() { # <status-file>
  local line
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  line=$(last_status_line "$1")
  case "$(status_line_verb "$line")" in
    done|failed) return 0 ;;
    *) return 1 ;;
  esac
}

copy_main_reports() {
  local vault=$1 meta id project
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(meta_field "$meta" kind)" != secondmate ] || continue
    id=$(basename "$meta" .meta)
    safe_task_id "$id" || continue
    finished_status "$STATE/$id.status" || continue
    project=$(meta_field "$meta" project)
    copy_report "$vault" "$DATA/$id/report.md" "$project" "$id" || true
  done
}

copy_local_secondmate_reports() {
  local vault=$1 meta mate_home child id project
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(meta_field "$meta" kind)" = secondmate ] || continue
    [ -z "$(meta_field "$meta" remote_host)" ] || continue
    mate_home=$(meta_field "$meta" home)
    [ -n "$mate_home" ] && [ -d "$mate_home" ] && [ ! -L "$mate_home" ] || continue
    for child in "$mate_home/state"/*.meta; do
      [ -f "$child" ] && [ ! -L "$child" ] || continue
      [ "$(meta_field "$child" kind)" != secondmate ] || continue
      id=$(basename "$child" .meta)
      safe_task_id "$id" || continue
      finished_status "$mate_home/state/$id.status" || continue
      project=$(meta_field "$child" project)
      copy_report "$vault" "$mate_home/data/$id/report.md" "$project" "$id" || true
    done
  done
}

# Parse each status file once without subprocesses per line.
remote_report_offers() { # <status-file>
  LC_ALL=C awk '
    {
      line = $0
      colon = index(line, ":")
      v = (colon > 0) ? substr(line, 1, colon - 1) : line
      bracket = index(v, "[")
      if (bracket > 0) v = substr(v, 1, bracket - 1)
      gsub(/^[ \t]+/, "", v)
      gsub(/[ \t]+$/, "", v)
      if (index(v, "corr=") > 0) {
        n = split(v, words, /[ \t]+/)
        out = words[1]
        for (i = 2; i <= n; i++) {
          if (words[i] ~ /^corr=[0-9A-Fa-f]{16}$/) continue
          out = out " " words[i]
        }
      } else {
        out = v
      }
      if (out != "done" && out != "failed") next
      report = ""
      project = ""
      for (i = 1; i <= NF; i++) {
        if (project == "" && $i ~ /^project=[A-Za-z0-9._-]+$/) project = substr($i, 9)
        if (report == "" && $i ~ /^report=data\/remote-secondmates\/[^\/][^\/]*\/data\/[A-Za-z0-9._-][A-Za-z0-9._-]*\/report[.]md$/) {
          report = $i
          sub(/^report=/, "", report)
        }
      }
      if (report == "") next
      task = report
      sub(/^data\/remote-secondmates\/[^\/]*\/data\//, "", task)
      sub(/\/report\.md$/, "", task)
      if (task == report) next
      printf "%s\t%s\t%s\n", report, task, project
    }
  ' "$1"
}

# Check all offers against the ledger in one scan.
copy_remote_reports() {
  local vault=$1 meta id status report task offered source hash batch matches i
  local -a sources tasks projects entries
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(meta_field "$meta" kind)" = secondmate ] || continue
    [ -n "$(meta_field "$meta" remote_host)" ] || continue
    id=$(basename "$meta" .meta)
    status="$STATE/$id.status"
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    sources=()
    tasks=()
    projects=()
    entries=()
    while IFS=$'\t' read -r report task offered || [ -n "$report" ]; do
      [ -n "$report" ] || continue
      safe_task_id "$task" || continue
      source="$FM_HOME/$report"
      safe_regular_report "$source" || continue
      hash=$(sha256_file "$source") || continue
      sources+=("$source")
      tasks+=("$task")
      projects+=("${offered:-$id}")
      entries+=("$hash $source")
    done < <(remote_report_offers "$status")
    [ "${#entries[@]}" -gt 0 ] || continue
    matches=
    if [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ]; then
      batch=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-vault-copy-batch.XXXXXX") || continue
      printf '%s\n' "${entries[@]}" > "$batch"
      matches=$(grep -Fxf "$batch" "$LEDGER" 2>/dev/null || true)
      rm -f -- "$batch"
    fi
    matches=$'\n'"$matches"$'\n'
    i=0
    while [ "$i" -lt "${#entries[@]}" ]; do
      case "$matches" in
        *$'\n'"${entries[$i]}"$'\n'*) ;;
        *) copy_report "$vault" "${sources[$i]}" "${projects[$i]}" "${tasks[$i]}" || true ;;
      esac
      i=$((i + 1))
    done
  done
}

catch_up() {
  local vault
  vault=$(configured_vault 2>/dev/null) || return 0
  [ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || return 0
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || return 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  [ -d "$vault" ] && [ ! -L "$vault" ] || return 0
  copy_main_reports "$vault"
  copy_local_secondmate_reports "$vault"
  copy_remote_reports "$vault"
}

[ "${1:-}" = catch-up ] && [ "$#" -eq 1 ] || usage
catch_up
