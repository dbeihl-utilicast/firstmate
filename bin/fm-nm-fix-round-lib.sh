#!/usr/bin/env bash
# Shared per-step no-mistakes fix-round counter and cap.
#
# ONE OWNER of firstmate's own tracking of auto-fix rounds on an active
# no-mistakes run. The no-mistakes product's internal auto-fix / re-review
# loop is not under firstmate's control and is not modified here.
# `no-mistakes axi status` emits TOON (not JSON). A mid-fix-round step may
# carry `active_steps[].round` as a string such as "auto-fix 1/3"; that is
# the product's own per-respond display and is not a durable per-step count
# across worker re-responds. This library never treats that field as the cap.
#
# Keyed by run id and step name. Stored at state/<task-id>.nm-fix-rounds
# (removed by teardown). Each row is:
#   <run-id><TAB><step><TAB><count><TAB><phase>
# Count is the number of times firstmate has observed that step move from
# fixing back to a re-review / re-test cycle (running, parked at a gate, or
# otherwise no longer fixing). The cap is 3: a fourth silent `fix` response
# on that step is refused. The allowed outcomes at cap are the ordinary
# approve or skip respond, or a needs-decision escalation. This file never
# invokes `no-mistakes axi respond`; the worker still owns every respond.
#
# Usage: . bin/fm-nm-fix-round-lib.sh
#   fm_nm_fix_round_observe <task-id> <toon>
#     Updates the durable counter from one axi-status TOON snapshot and sets
#     FM_NM_FR_RUN_ID, FM_NM_FR_STEP, FM_NM_FR_COUNT, FM_NM_FR_PHASE,
#     FM_NM_FR_VERDICT (allow-fix | cap | none).
#   fm_nm_fix_round_print
#     Prints the last observe result as run=/step=/count=/phase=/verdict=
#     lines, plus next= when verdict is cap.
#   fm_nm_fix_round_count <task-id> <run-id> <step>
#     Prints the integer count (0 when absent).
#   fm_nm_fix_round_guard <task-id> <action> <toon>
#     Observes, then allows approve/skip at a gate, allows fix only when
#     verdict is allow-fix, and refuses a capped fix (exit 3).
#
# FM_NM_FIX_ROUND_CAP (default 3) is the hard per-step bound. Tests may
# lower it; raising it is not a supported production override.
# shellcheck shell=bash

# shellcheck source=bin/fm-nm-run-lib.sh
. "${FM_NM_FIX_ROUND_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/fm-nm-run-lib.sh"

FM_NM_FIX_ROUND_CAP=${FM_NM_FIX_ROUND_CAP:-3}
case "$FM_NM_FIX_ROUND_CAP" in
  ''|*[!0-9]*) FM_NM_FIX_ROUND_CAP=3 ;;
esac
[ "$FM_NM_FIX_ROUND_CAP" -ge 1 ] || FM_NM_FIX_ROUND_CAP=3

FM_NM_FR_RUN_ID=
FM_NM_FR_STEP=
FM_NM_FR_COUNT=0
FM_NM_FR_PHASE=other
FM_NM_FR_VERDICT=none

fm_nm_fr_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-${FM_HOME:-.}}/state"
}

fm_nm_fr_file() {  # <task-id>
  printf '%s/%s.nm-fix-rounds' "$(fm_nm_fr_state_dir)" "$1"
}

fm_nm_fr_valid_id() {  # <token>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_nm_fr_table_rows() {  # <toon> <active_steps|steps>
  local toon=$1 kind=$2
  printf '%s\n' "$toon" | awk -v kind="$kind" '
    kind == "active_steps" && $0 ~ /^[[:space:]]*active_steps\[[0-9]+\]\{/ {
      hdr = index($0, "active_steps"); inblock = 1; next
    }
    kind == "steps" && $0 ~ /^[[:space:]]*steps\[[0-9]+\]\{/ {
      hdr = index($0, "steps"); inblock = 1; next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) { inblock = 0; next }
      match($0, /[^ \t]/)
      if (RSTART <= hdr) { inblock = 0; next }
      line = $0
      sub(/^[[:space:]]+/, "", line)
      print line
    }
  '
}

fm_nm_fr_csv_field() {  # <row> <index-1-based>
  local row=$1 idx=$2 field i=1
  row=$(fm_nm_trim "$row")
  while [ -n "$row" ]; do
    case "$row" in
      \"*)
        field=${row#\"}
        case "$field" in
          *\"*) field=${field%%\"*}; row=${row#*\"}; row=${row#*,} ;;
          *) field=$row; row= ;;
        esac
        ;;
      *)
        case "$row" in
          *,*) field=${row%%,*}; row=${row#*,} ;;
          *) field=$row; row= ;;
        esac
        ;;
    esac
    field=$(fm_nm_strip_quotes "$(fm_nm_trim "$field")")
    if [ "$i" -eq "$idx" ]; then
      printf '%s' "$field"
      return 0
    fi
    i=$((i + 1))
  done
  return 0
}

# Classify one axi-status TOON snapshot into run id, step, and phase.
# Phase is fixing, gate, running, or other. The product's "auto-fix N/3"
# round string is used only as a fixing-phase signal, never as the count.
fm_nm_fr_parse() {  # <toon>
  local toon=$1 status gate gate_step gate_status row step st first_fixing first_running first_gate first_active
  FM_NM_FR_RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$toon" id)")
  FM_NM_FR_STEP=
  FM_NM_FR_PHASE=other
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$toon" status)")
  gate=$(fm_nm_strip_quotes "$(fm_nm_field "$toon" gate)")
  gate_step=$(printf '%s\n' "$toon" \
    | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  gate_step=$(fm_nm_strip_quotes "$gate_step")
  gate_status=$(printf '%s\n' "$toon" \
    | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*status:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  gate_status=$(fm_nm_strip_quotes "$gate_status")
  [ -n "$gate" ] || gate=$gate_step

  first_active=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    step=$(fm_nm_fr_csv_field "$row" 1)
    [ -n "$first_active" ] || first_active=$step
    case "$row" in
      *auto-fix*|*fixing*)
        FM_NM_FR_PHASE=fixing
        FM_NM_FR_STEP=$step
        return 0
        ;;
    esac
  done <<EOF
$(fm_nm_fr_table_rows "$toon" active_steps)
EOF

  first_fixing=
  first_running=
  first_gate=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    step=$(fm_nm_fr_csv_field "$row" 1)
    st=$(fm_nm_fr_csv_field "$row" 2)
    case "$st" in
      fixing)
        [ -n "$first_fixing" ] || first_fixing=$step
        ;;
      running)
        [ -n "$first_running" ] || first_running=$step
        ;;
      fix_review|awaiting_approval)
        [ -n "$first_gate" ] || first_gate=$step
        ;;
    esac
  done <<EOF
$(fm_nm_fr_table_rows "$toon" steps)
EOF

  if [ "$status" = fixing ] || [ -n "$first_fixing" ]; then
    FM_NM_FR_PHASE=fixing
    FM_NM_FR_STEP=$first_fixing
    [ -n "$FM_NM_FR_STEP" ] || FM_NM_FR_STEP=$first_active
    [ -n "$FM_NM_FR_STEP" ] || FM_NM_FR_STEP=$gate
    return 0
  fi

  if [ -n "$gate" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] \
      || [ "$gate_status" = awaiting_approval ] || [ "$gate_status" = fix_review ] \
      || [ -n "$first_gate" ]; then
    FM_NM_FR_PHASE=gate
    FM_NM_FR_STEP=$gate
    [ -n "$FM_NM_FR_STEP" ] || FM_NM_FR_STEP=$first_gate
    return 0
  fi

  if [ "$status" = running ] || [ -n "$first_running" ]; then
    FM_NM_FR_PHASE=running
    FM_NM_FR_STEP=$first_running
    [ -n "$FM_NM_FR_STEP" ] || FM_NM_FR_STEP=$first_active
    return 0
  fi

  FM_NM_FR_PHASE=other
  FM_NM_FR_STEP=$first_active
  return 0
}

fm_nm_fr_load_row() {  # <file> <run-id> <step> -> count<TAB>phase on stdout
  local file=$1 run=$2 step=$3 line r s c p
  [ -f "$file" ] || { printf '0\t'; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r r s c p <<EOF
$line
EOF
    if [ "$r" = "$run" ] && [ "$s" = "$step" ]; then
      printf '%s\t%s' "${c:-0}" "${p:-}"
      return 0
    fi
  done < "$file"
  printf '0\t'
}

fm_nm_fr_store_row() {  # <file> <run-id> <step> <count> <phase>
  local file=$1 run=$2 step=$3 count=$4 phase=$5 dir tmp line r s c p
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp="${file}.tmp.$$"
  : > "$tmp"
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      IFS=$'\t' read -r r s c p <<EOF
$line
EOF
      if [ "$r" = "$run" ] && [ "$s" = "$step" ]; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$r" "$s" "$c" "$p" >> "$tmp"
    done < "$file"
  fi
  printf '%s\t%s\t%s\t%s\n' "$run" "$step" "$count" "$phase" >> "$tmp"
  mv -f "$tmp" "$file"
}

fm_nm_fix_round_observe() {  # <task-id> <toon>
  local task=$1 toon=$2 file old_count old_phase rest
  FM_NM_FR_RUN_ID=
  FM_NM_FR_STEP=
  FM_NM_FR_COUNT=0
  FM_NM_FR_PHASE=other
  FM_NM_FR_VERDICT=none
  fm_nm_fr_valid_id "$task" || return 2
  fm_nm_fr_parse "$toon"
  fm_nm_fr_valid_id "$FM_NM_FR_RUN_ID" || {
    FM_NM_FR_VERDICT=none
    return 0
  }
  file=$(fm_nm_fr_file "$task")
  old_count=0
  old_phase=
  if fm_nm_fr_valid_id "$FM_NM_FR_STEP"; then
    rest=$(fm_nm_fr_load_row "$file" "$FM_NM_FR_RUN_ID" "$FM_NM_FR_STEP")
    old_count=${rest%%$'\t'*}
    old_phase=${rest#*$'\t'}
    case "$old_count" in ''|*[!0-9]*) old_count=0 ;; esac
    if [ "$old_phase" = fixing ] && [ "$FM_NM_FR_PHASE" != fixing ]; then
      FM_NM_FR_COUNT=$((old_count + 1))
    else
      FM_NM_FR_COUNT=$old_count
    fi
    fm_nm_fr_store_row "$file" "$FM_NM_FR_RUN_ID" "$FM_NM_FR_STEP" \
      "$FM_NM_FR_COUNT" "$FM_NM_FR_PHASE"
  else
    FM_NM_FR_COUNT=0
  fi
  if [ "$FM_NM_FR_PHASE" = gate ]; then
    if [ "$FM_NM_FR_COUNT" -ge "$FM_NM_FIX_ROUND_CAP" ]; then
      FM_NM_FR_VERDICT=cap
    else
      FM_NM_FR_VERDICT=allow-fix
    fi
  else
    FM_NM_FR_VERDICT=none
  fi
  return 0
}

fm_nm_fix_round_print() {
  printf 'run=%s\n' "$FM_NM_FR_RUN_ID"
  printf 'step=%s\n' "$FM_NM_FR_STEP"
  printf 'count=%s\n' "$FM_NM_FR_COUNT"
  printf 'phase=%s\n' "$FM_NM_FR_PHASE"
  printf 'verdict=%s\n' "$FM_NM_FR_VERDICT"
  if [ "$FM_NM_FR_VERDICT" = cap ]; then
    printf 'next=approve-or-skip-or-escalate\n'
    printf 'escalation_key=nm-%s-%s-fix-cap\n' "$FM_NM_FR_RUN_ID" "$FM_NM_FR_STEP"
  fi
}

fm_nm_fix_round_count() {  # <task-id> <run-id> <step>
  local rest
  rest=$(fm_nm_fr_load_row "$(fm_nm_fr_file "$1")" "$2" "$3")
  printf '%s\n' "${rest%%$'\t'*}"
}

# Observe <toon>, then allow or refuse <action> (approve|fix|skip).
# Exit 0 allowed, 2 usage, 3 capped fix.
fm_nm_fix_round_guard() {  # <task-id> <action> <toon>
  local task=$1 action=$2 toon=$3
  case "$action" in
    approve|fix|skip) ;;
    *) return 2 ;;
  esac
  fm_nm_fix_round_observe "$task" "$toon" || return 2
  if [ "$FM_NM_FR_PHASE" != gate ]; then
    return 2
  fi
  if [ "$action" = fix ] && [ "$FM_NM_FR_VERDICT" = cap ]; then
    return 3
  fi
  if [ "$action" = fix ] && [ "$FM_NM_FR_VERDICT" != allow-fix ]; then
    return 2
  fi
  return 0
}
