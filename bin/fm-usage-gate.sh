#!/usr/bin/env bash
# fm-usage-gate.sh - the deterministic usage check for a launch profile, and the
# replacement it selects when that profile's model is exhausted.
#
# Usage:
#   fm-usage-gate.sh select --kind <ship|scout|secondmate>
#                           (--harness <h> [--model <m>] [--effort <e>] | --config-pin)
#                           [--tie-break <strict|declared>] [--snapshot <file>]
#
# select   Read ONE quota-axi --json snapshot (or --snapshot <file>) and answer
#          whether the profile can be launched. Output (stdout):
#            usage-gate:
#              status: keep | replace | none
#              current: <harness>:<model> provider=.. scope=.. remaining=..% ... -> <verdict>
#              candidate: <harness>:<model> ... -> eligible | eligible, unranked: .. | not eligible: ..
#              reason: <why none>
#              profile: --harness <h> [--model <m>] [--effort <e>]     (replace only)
#          keep     the profile is not exhausted, or its quota cannot be measured
#                   (uncertainty stays launchable and is disclosed, never assumed
#                   exhausted).
#          replace  the profile is exhausted and exactly one best declared alternate
#                   is eligible; pass the profile line to the launch.
#          none     the profile is exhausted and no alternate is eligible: no
#                   alternate is declared, none passed its gates, nothing could be
#                   ranked, or a genuine spendPriority tie.
#          A tie is reported (every tied candidate is printed) so an attended
#          caller chooses, exactly as quota-array-dispatch requires. --tie-break
#          declared is for an unattended caller with nobody to choose, where a
#          stalled lane is worse than an equal-quota pick: the first tied
#          candidate in declared order replaces it, with a note.
#          Exit 0 for keep and replace, 1 for none, 2 for a usage or configuration
#          error (an unreadable or malformed config file or snapshot).
#
#          Exhausted means an applicable quota row reads exhausted_now or a known
#          0% remaining, judged by the shared candidate verdict in
#          bin/fm-quota-axi-lib.sh (the same one bin/fm-dispatch-resolve.sh applies).
#          A declared profile floor is a selection gate for alternates only; it
#          never turns the current profile into an exhausted one.
#
#          Alternates are only ever declared ones, so the captain's reasoning-class
#          policy is preserved and nothing is invented:
#            ship, scout  config/crew-dispatch.json. Siblings of the profile in the
#                         array that lists it (rule `use` or `default`), restricted
#                         to profiles every array listing it also lists. A profile
#                         listed nowhere has no alternate.
#            secondmate   config/secondmate-harness. The first non-comment line is
#                         the pin; each later line is an ordered alternate in the
#                         same `<harness> [<model>] [<effort>]` form. Only harnesses
#                         verified for a secondmate with one quota provider family
#                         can be selected.
#          --config-pin takes the secondmate profile the way bin/fm-spawn.sh would
#          resolve it (bin/fm-harness.sh secondmate, secondmate-model,
#          secondmate-effort) instead of --harness/--model/--effort.
#
# Environment:
#   FM_USAGE_GATE=off         skip the check; every profile is kept
#   FM_USAGE_GATE_TIMEOUT     seconds bound on the quota-axi call (20)
#
# Authority: this tool never replaces firstmate's judgment or quota-array-dispatch
# at intake; it is the mechanism behind them, called by the launch owners
# (bin/fm-spawn.sh, bin/fm-control.sh) so an exhausted model is never launched.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
}

command -v jq >/dev/null 2>&1 || die "jq required"

TIMEOUT=${FM_USAGE_GATE_TIMEOUT:-20}
case "$TIMEOUT" in ''|*[!0-9]*|0) die "FM_USAGE_GATE_TIMEOUT must be a positive integer: $TIMEOUT" ;; esac

# A model of "default" or "-" means the profile names no model.
normal_axis() { case "$1" in default|-) printf '' ;; *) printf '%s' "$1" ;; esac; }

PMAP=$(fm_quota_single_provider_table | jq -Rn '[inputs | split(" ") | {(.[0]): .[1]}] | add')

# ---- the one quota snapshot ------------------------------------------------------
QSNAP=
QSNAP_WHY=
load_snapshot() {  # [<snapshot-file>]
  local file=${1:-} raw
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || die "snapshot is not a readable file: $file"
    raw=$(cat -- "$file")
    printf '%s\n' "$raw" | fm_quota_json_valid || die "snapshot is not a valid quota-axi --json snapshot: $file"
    QSNAP=$raw
    return 0
  fi
  if [ "${FM_USAGE_GATE:-}" = off ]; then
    QSNAP_WHY="disabled by FM_USAGE_GATE=off"
    return 0
  fi
  if ! command -v quota-axi >/dev/null 2>&1; then
    QSNAP_WHY="quota-axi is missing"
    return 0
  fi
  if ! fm_quota_axi_compatible "$TIMEOUT"; then
    QSNAP_WHY="quota-axi is below the compatibility floor ($FM_QUOTA_AXI_MIN) or did not answer --version"
    return 0
  fi
  if ! raw=$(fm_run_timed "$TIMEOUT" quota-axi --json 2>/dev/null </dev/null); then
    QSNAP_WHY="quota-axi --json failed or timed out after ${TIMEOUT}s"
    return 0
  fi
  if ! printf '%s\n' "$raw" | fm_quota_json_valid; then
    QSNAP_WHY="quota-axi --json returned an invalid snapshot"
    return 0
  fi
  QSNAP=$raw
}

# ---- alternates, from the declared sources only -----------------------------------
# discover_dispatch <profile-json>: {decl, alts} from config/crew-dispatch.json.
# shellcheck disable=SC2016  # jq program text
DISCOVER_JQ='
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def same($a; $b): $a.harness == $b.harness and (($a.model // "") == ($b.model // ""));
  def dedupe: reduce .[] as $x ([]; if any(.[]; same(.; $x)) then . else . + [$x] end);
  ([(.rules // [])[] | profiles(.use)] + [profiles(.default // null)]) as $arrays
  | ($arrays | map(select(any(.[]; same(.; $p))))) as $with
  | if ($with | length) == 0 then {decl: null, alts: []}
    else
      ($with | map(select(any(.[]; same(.; $p) and ((.effort // "") == ($p.effort // "")))))) as $exact
      | (if ($exact | length) > 0 then $exact[0] else $with[0] end) as $src
      | {decl: ($src | map(select(same(.; $p))) | first),
         alts: ([$src[] | select(same(.; $p) | not)
                  | select(. as $s | all($with[]; any(.[]; same(.; $s))))] | dedupe)}
    end'

discover_dispatch() {  # <profile-json>
  local file="$CONFIG/crew-dispatch.json"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' '{"decl":null,"alts":[]}'
    return 0
  fi
  jq -c --argjson p "$1" "$DISCOVER_JQ" "$file" 2>/dev/null \
    || die "config/crew-dispatch.json is not readable JSON with rules and default profile arrays: $file"
}

# discover_secondmate <profile-json>: {decl, alts} from config/secondmate-harness.
discover_secondmate() {  # <profile-json>
  local file="$CONFIG/secondmate-harness" line harness model effort rest lines='' first=1
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' '{"decl":null,"alts":[]}'
    return 0
  fi
  [ -r "$file" ] || die "config/secondmate-harness is not readable: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    read -r harness model effort rest <<< "$line"
    [ -n "$harness" ] || continue
    lines+="$harness"$'\t'"${model:-}"$'\t'"${effort:-}"$'\n'
    first=0
  done < "$file"
  [ "$first" -eq 0 ] || { printf '%s\n' '{"decl":null,"alts":[]}'; return 0; }
  printf '%s' "$lines" | jq -Rsc --argjson p "$1" '
    def same($a; $b): $a.harness == $b.harness and (($a.model // "") == ($b.model // ""));
    def dedupe: reduce .[] as $x ([]; if any(.[]; same(.; $x)) then . else . + [$x] end);
    (split("\n") | map(select(length > 0) | split("\t"))
      | map({harness: .[0]}
            + (if (.[1] // "") != "" and .[1] != "default" then {model: .[1]} else {} end)
            + (if (.[2] // "") != "" and .[2] != "default" then {effort: .[2]} else {} end))) as $lines
    | {decl: null, alts: ($lines | map(select(same(.; $p) | not)) | dedupe)}'
}

# Keep only alternates that can actually run a secondmate.
filter_secondmate_alts() {  # <alts-json>
  local alt harness out='[]'
  while IFS= read -r alt; do
    [ -n "$alt" ] || continue
    harness=$(jq -r '.harness' <<< "$alt")
    fm_control_harness_supports_kind "$harness" secondmate || continue
    out=$(jq -c --argjson a "$alt" '. + [$a]' <<< "$out")
  done < <(jq -c '.[]' <<< "$1")
  printf '%s\n' "$out"
}

# ---- the verdict --------------------------------------------------------------------
# shellcheck disable=SC2016  # jq program text
CORE_JQ='
  ($p + (if $decl != null and ($decl.provider // null) != null then {provider: $decl.provider} else {} end)) as $cur
  | (quota_evaluate($q; $pmap; ($cur | del(.floor)))
     | if (.eligible | not) and ((.veto // "") == "") then . + {eligible: true, unranked: true} else . end) as $now
  | if ($now.veto // "") != "exhausted" then {status: "keep", current: $now, candidates: []}
    else
      ($alts | map(quota_evaluate($q; $pmap; .))) as $cands
      | quota_choose($cands) as $pick
      | if $pick.status == "clear" then {status: "replace", current: $now, candidates: $cands, chosen: $pick.chosen}
        elif $tie == "declared" and ($pick.tied // [] | length) > 0 then
          {status: "replace", current: $now, candidates: $cands, chosen: $pick.tied[0],
           note: "spendPriority tie broken by declared order"}
        else {status: "none", current: $now, candidates: $cands,
              reason: (if ($alts | length) == 0 then "no alternate profile is declared for this harness and model" else $pick.reason end)}
        end
    end'

# shellcheck disable=SC2016  # jq program text
RENDER_JQ='
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($v): ($v // "-") | flat;
  def shell_arg: flat | @sh;
  def line($label; $v):
    "  \($label): \($v.profile.harness | flat):\(show($v.profile.model))"
    + (if $v.provider then "  provider=\($v.provider | flat)" else "" end)
    + (if $v.scope then "  scope=\($v.scope | flat)  remaining=\(show($v.pct))%  spendPriority=\(show($v.spendPriority))  runway=\(show($v.runway))" else "" end)
    + "  -> "
    + (if $v.unranked then "eligible, unranked: \($v.reason | flat)"
       elif $v.eligible then "eligible"
       else "not eligible: \($v.reason | flat)" end);
  "usage-gate:",
  "  status: \(.status)",
  line("current"; .current),
  (.candidates[]? | line("candidate"; .)),
  (if .note then "  note: \(.note | flat)" else empty end),
  (if .reason then "  reason: \(.reason | flat)" else empty end),
  (if .chosen then "  profile: --harness \(.chosen.profile.harness | shell_arg)"
      + (if .chosen.profile.model then " --model \(.chosen.profile.model | shell_arg)" else "" end)
      + (if .chosen.profile.effort then " --effort \(.chosen.profile.effort | shell_arg)" else "" end) else empty end)'

# select_profile <kind> <harness> <model> <effort>: SEL_JSON is the verdict object.
SEL_JSON=
TIE_BREAK=strict
select_profile() {
  local kind=$1 harness=$2 model=$3 effort=$4 p disc alts disc_err=
  p=$(jq -nc --arg h "$harness" --arg m "$model" --arg e "$effort" \
    '{harness: $h} + (if $m != "" then {model: $m} else {} end) + (if $e != "" then {effort: $e} else {} end)')
  if [ -z "$QSNAP" ]; then
    SEL_JSON=$(jq -nc --argjson p "$p" --arg why "$QSNAP_WHY" \
      '{status: "keep", current: {profile: $p, eligible: true, unranked: true, reason: $why}, candidates: []}')
    return 0
  fi
  # An unreadable declaration file only matters once the profile is exhausted,
  # so a healthy profile is never blocked by a config error it does not need.
  case "$kind" in
    secondmate) disc=$(discover_secondmate "$p" 2>&1) || disc_err=$disc ;;
    *) disc=$(discover_dispatch "$p" 2>&1) || disc_err=$disc ;;
  esac
  [ -z "$disc_err" ] || disc='{"decl":null,"alts":[]}'
  alts=$(jq -c '.alts' <<< "$disc")
  [ "$kind" != secondmate ] || alts=$(filter_secondmate_alts "$alts")
  SEL_JSON=$(jq -nc --argjson q "$QSNAP" --argjson pmap "$PMAP" --argjson p "$p" \
    --argjson decl "$(jq -c '.decl' <<< "$disc")" --argjson alts "$alts" --arg tie "$TIE_BREAK" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$CORE_JQ") || die "usage-gate could not evaluate the snapshot"
  if [ -n "$disc_err" ] && [ "$(jq -r '.status' <<< "$SEL_JSON")" != keep ]; then
    printf '%s\n' "$disc_err" >&2
    exit 2
  fi
}

cmd_select() {
  local kind='' harness='' model='' effort='' snapshot='' config_pin=0 have_profile=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --kind)       [ "$#" -ge 2 ] || die "--kind needs a value"; kind=$2; shift 2 ;;
      --harness)    [ "$#" -ge 2 ] || die "--harness needs a value"; harness=$2; have_profile=1; shift 2 ;;
      --model)      [ "$#" -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
      --effort)     [ "$#" -ge 2 ] || die "--effort needs a value"; effort=$2; shift 2 ;;
      --snapshot)   [ "$#" -ge 2 ] || die "--snapshot needs a file"; snapshot=$2; shift 2 ;;
      --config-pin) config_pin=1; shift ;;
      --tie-break)  [ "$#" -ge 2 ] || die "--tie-break needs strict or declared"; TIE_BREAK=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case "$TIE_BREAK" in strict|declared) ;; *) die "--tie-break must be strict or declared" ;; esac
  case "$kind" in ship|scout|secondmate) ;; *) die "--kind must be ship, scout, or secondmate" ;; esac
  if [ "$config_pin" -eq 1 ]; then
    [ "$have_profile" -eq 0 ] || die "--config-pin and --harness are exclusive"
    [ "$kind" = secondmate ] || die "--config-pin applies to --kind secondmate"
    harness=$("$SCRIPT_DIR/fm-harness.sh" secondmate) || die "could not resolve the secondmate harness"
    model=$("$SCRIPT_DIR/fm-harness.sh" secondmate-model)
    effort=$("$SCRIPT_DIR/fm-harness.sh" secondmate-effort)
  fi
  [ -n "$harness" ] || die "a profile is required: --harness <h> or --config-pin"
  model=$(normal_axis "$model")
  effort=$(normal_axis "$effort")
  load_snapshot "$snapshot"
  select_profile "$kind" "$harness" "$model" "$effort"
  jq -r "$RENDER_JQ" <<< "$SEL_JSON"
  [ "$(jq -r '.status' <<< "$SEL_JSON")" != none ]
}

# The first line of a command's output that carries anything, with its "error: "
# prefix dropped: a refusal's own words are the most useful thing to report.
first_reported_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}'
}

cmd_sweep() {
  local relaunch=0 snapshot='' meta id kind recorded harness model effort line state source
  local checked=0 exhausted=0 actionable=0 relaunched=0 failed=0 held=0
  local status h2 m2 e2 reason note out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --relaunch) relaunch=1; shift ;;
      --snapshot) [ "$#" -ge 2 ] || die "--snapshot needs a file"; snapshot=$2; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -d "$STATE" ] || die "state dir '$STATE' is missing; sweep cannot resolve lanes for FM_HOME '$FM_HOME'"
  load_snapshot "$snapshot"
  echo "usage-gate sweep:"
  if [ -z "$QSNAP" ]; then
    case "$QSNAP_WHY" in
      disabled*) echo "  $QSNAP_WHY"; return 0 ;;
    esac
    echo "  quota unavailable: $QSNAP_WHY"
    return 4
  fi
  TIE_BREAK=declared
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(fm_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    case "$kind" in ship|scout|secondmate) ;; *) continue ;; esac
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    [ ! -e "$STATE/$id.stopped" ] || continue
    recorded=$(fm_meta_get "$meta" harness)
    if fm_control_harness_supported "$recorded"; then harness=$recorded
    else harness=$(fm_control_harness_family "$recorded") || continue
    fi
    model=$(normal_axis "$(fm_meta_get "$meta" model)")
    effort=$(normal_axis "$(fm_meta_get "$meta" effort)")
    checked=$((checked + 1))
    select_profile "$kind" "$harness" "$model" "$effort"
    status=$(jq -r '.status' <<< "$SEL_JSON")
    [ "$status" != keep ] || continue
    reason=$(jq -r '.current.reason' <<< "$SEL_JSON")
    if [ "$kind" != secondmate ]; then
      line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 \
        "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null </dev/null || true)
      state=$(printf '%s\n' "$line" | sed -n 's/^state: \([a-z]*\) .*/\1/p')
      source=$(printf '%s\n' "$line" | sed -n 's/.*source: \([a-z-]*\).*/\1/p')
      case "$state:$source" in
        *:run-step|done:*|parked:*|blocked:*|paused:*|failed:*)
          held=$((held + 1))
          printf '  held: %s %s %s:%s exhausted; state %s via %s\n' "$id" "$kind" "$harness" "${model:--}" "$state" "$source"
          continue
          ;;
      esac
    fi
    exhausted=$((exhausted + 1))
    actionable=$((actionable + 1))
    if [ "$status" = none ]; then
      failed=$((failed + 1))
      printf '  unresolved: %s %s %s:%s: %s\n' "$id" "$kind" "$harness" "${model:--}" "$(jq -r '.reason' <<< "$SEL_JSON")"
      continue
    fi
    h2=$(jq -r '.chosen.profile.harness' <<< "$SEL_JSON")
    m2=$(jq -r '.chosen.profile.model // ""' <<< "$SEL_JSON")
    e2=$(jq -r '.chosen.profile.effort // ""' <<< "$SEL_JSON")
    printf '  exhausted: %s %s %s:%s -> %s:%s (%s)\n' "$id" "$kind" "$harness" "${model:--}" "$h2" "${m2:--}" "$reason"
    [ "$relaunch" -eq 1 ] || continue
    note="Usage gate: ${harness}:${model:--} ran out of quota ($reason). This lane was relaunched on ${h2}:${m2:--}; continue from the local copy."
    if out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
      --harness "$h2" --model "${m2:-default}" --effort "${e2:-default}" --note "$note" 2>&1 </dev/null); then
      relaunched=$((relaunched + 1))
      printf '  relaunched: %s on %s:%s\n' "$id" "$h2" "${m2:--}"
    else
      failed=$((failed + 1))
      printf '  unreached: %s: %s\n' "$id" "$(first_reported_line "$out")"
    fi
  done
  printf '  summary: %d checked, %d exhausted (%d actionable, %d held), %d relaunched, %d failed\n' \
    "$checked" "$((exhausted + held))" "$exhausted" "$held" "$relaunched" "$failed"
  if [ "$relaunch" -eq 1 ]; then
    [ "$failed" -eq 0 ] || return 3
    return 0
  fi
  [ "$actionable" -eq 0 ] || return 1
  return 0
}

case "${1-}" in
  select)         shift; cmd_select "$@" ;;
  sweep)          shift; cmd_sweep "$@" ;;
  ''|-h|--help|help) usage; [ -n "${1-}" ] || exit 2; exit 0 ;;
  *) die "unknown command: $1" ;;
esac
