#!/usr/bin/env bash
# fm-running-list.sh - on-demand grouped view of the open fleet backlog.
#
# This command reads. It never writes, mutates a task, answers a hold, or
# starts a daemon. It shells out to `fm-bearings-snapshot.sh --json` with the
# all-open bounds so main and registered second-mate homes are collected by
# that existing reader; it does not parse backlog files, status logs, or home
# ledgers itself. The underlying snapshot may still refresh its parent-side
# remote-ledger cache; that observational cache is the snapshot's only
# fleet-state mutation and is not owned here.
#
# If the bearings projection omits a field this view needs, the status line
# names the gap instead of inventing a second parser.
#
# Usage:
#   fm-running-list.sh        human grouped list
#   fm-running-list.sh --json the same model as JSON (schema fm-running-list.v1)
#
# Groups, in captain-scan order:
#   rotting             open rows with no date, no dependency, and nobody named
#   waiting_on_you      live and aged captain holds
#   waiting_on_outside  paused work, external holds, and non-placeholder gate reasons
#   blocked             unresolved blockers, blocker id shown
#   waiting_on_date     dated holds, until-date shown
#   moving              live in-flight work not already grouped above
#
# The rotting count is printed first. Age is shown in days when the snapshot
# supplies it (held-Nd notes); otherwise the row shows "-" and the status line
# says so. Unreadable homes are named so a dead remote does not hide the rest.
# Warning gates such as (main-inventory) are status, not open work.
#
# Output contract: `fm-running-list.v1`. No locks, reports, or cadence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEARINGS="$SCRIPT_DIR/fm-bearings-snapshot.sh"

usage() {
  cat <<'EOF'
usage: fm-running-list.sh [--json]

Group every open fleet backlog row by what the captain can act on.
Reads fm-bearings-snapshot.sh; writes nothing.
EOF
}

FORMAT=human
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-running-list: jq not found" >&2; exit 1; }

SNAP=$("$BEARINGS" --json --all-in-flight --all-queued --all-secondmates --all-unhealthy) \
  || exit $?

MODEL=$(printf '%s' "$SNAP" | jq '
  def nonempty($v): ($v != null) and ($v != "") and ($v != "-");
  def dash($v): if nonempty($v) then $v else "-" end;
  def owner_of($id; $fallback):
    if nonempty($fallback) then $fallback
    elif ($id | type == "string") and ($id | contains("/")) then ($id | split("/")[0])
    else "(main)" end;
  def held_days($reason):
    if (($reason // "") | test("^held [0-9]+d")) then
      (($reason // "") | capture("^held (?<d>[0-9]+)d") | .d | tonumber)
    else null end;
  def until_date($reason):
    if (($reason // "") | test("^until ")) then
      (($reason // "") | capture("^until (?<d>[^:[:space:]]+)") | .d)
    else null end;
  def is_warning($id):
    ($id | type == "string") and ($id | startswith("("));
  def is_unreadable($m):
    ($m.freshness == "unavailable")
    or ($m.freshness == "unknown")
    or ($m.state == "unknown")
    or ($m.provenance == "unknown");
  def row($id; $title; $owner; $age; $wait):
    {id:$id, title:dash($title), owner:owner_of($id; $owner),
     age_days:$age, wait:dash($wait)};
  def by_age_then_id:
    sort_by([(.age_days == null), -(.age_days // 0), .id]);
  def mark($st; $id): $st + {seen: ($st.seen + {($id): true})};
  def unseen($st; $id): ($id | type == "string") and ($st.seen[$id] | not);

  . as $snap
  | ($snap.decisions_open // []) as $decisions
  | ($snap.gates // []) as $gates
  | ($snap.in_flight // []) as $inflight
  | ($snap.secondmates // []) as $mates
  | ($snap.omitted // []) as $omitted
  | {
      seen: {},
      waiting_on_you: [],
      waiting_on_outside: [],
      blocked: [],
      waiting_on_date: [],
      moving: [],
      rotting: [],
      warnings: [],
      unreadables: []
    }
  | reduce $decisions[] as $d (.;
      (held_days($d.summary) // null) as $age
      | .waiting_on_you += [row($d.id; $d.summary; $d.owner; $age; $d.summary)]
      | mark(.; $d.id))
  | reduce $inflight[] as $t (.;
      if ($t.state == "paused") and unseen(.; $t.id) then
        .waiting_on_outside += [row($t.id; $t.doing; null; null; $t.doing)]
        | mark(.; $t.id)
      else . end)
  | reduce $gates[] as $g (.;
      if is_warning($g.id) then
        .warnings += [{id:$g.id, title:dash($g.title), reason:dash($g.reason)}]
        | mark(.; $g.id)
      elif unseen(.; $g.id) and nonempty(until_date($g.reason)) then
        .waiting_on_date += [row($g.id; $g.title; $g.owner; null; until_date($g.reason))]
        | mark(.; $g.id)
      elif unseen(.; $g.id) and nonempty($g.blocked_by) then
        .blocked += [row($g.id; $g.title; $g.owner; held_days($g.reason); $g.blocked_by)]
        | mark(.; $g.id)
      elif unseen(.; $g.id) and (held_days($g.reason) != null) then
        .waiting_on_you += [row($g.id; $g.title; $g.owner; held_days($g.reason); $g.reason)]
        | mark(.; $g.id)
      elif unseen(.; $g.id) and nonempty($g.reason) then
        .waiting_on_outside += [row($g.id; $g.title; $g.owner; null; $g.reason)]
        | mark(.; $g.id)
      elif unseen(.; $g.id) then
        .rotting += [row($g.id; $g.title; $g.owner; null; $g.title)]
        | mark(.; $g.id)
      else . end)
  | reduce $inflight[] as $t (.;
      if unseen(.; $t.id) then
        .moving += [row($t.id; $t.doing; null; null; $t.doing)]
        | mark(.; $t.id)
      else . end)
  | reduce $mates[] as $m (.;
      if is_unreadable($m) then
        .unreadables += [{id:$m.id, reason:dash($m.reason // $m.doing)}]
      elif ($m.state == "externally_held") and unseen(.; $m.id) then
        .waiting_on_outside += [row($m.id; $m.doing; $m.id; null; $m.doing)]
        | mark(.; $m.id)
      else . end)
  | . as $st
  | ([.waiting_on_you[], .waiting_on_outside[], .blocked[], .waiting_on_date[],
      .moving[], .rotting[]] | any(.age_days == null)) as $age_missing
  | {
      schema: "fm-running-list.v1",
      home: ($snap.home // "-"),
      generated: ($snap.generated // "-"),
      nothing_brings_them_back: ($st.rotting | length),
      rotting: ($st.rotting | by_age_then_id),
      waiting_on_you: ($st.waiting_on_you | by_age_then_id),
      waiting_on_outside: ($st.waiting_on_outside | by_age_then_id),
      blocked: ($st.blocked | by_age_then_id),
      waiting_on_date: ($st.waiting_on_date | by_age_then_id),
      moving: ($st.moving | by_age_then_id),
      unreadables: $st.unreadables,
      warnings: $st.warnings,
      missing: (
        [ if $age_missing then "age in days except held-Nd notes" else empty end,
          "named outside waiters use gate reason and paused state; hold_kind is not in the snapshot" ]
        + [ $omitted[]
            | select((.surface // "") | test("unstructured|in_flight showing|gates showing|decisions_open showing"))
            | .surface ]
      )
    }
') || { echo "fm-running-list: grouping failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

printf '%s' "$MODEL" | jq -r '
  def age_col:
    if .age_days == null then "-"
    else "\(.age_days)d" end;
  def item:
    "  \(age_col)  \(.id)  \(.wait)  \(.owner)";
  def section($title; $rows):
    "\($title) (\($rows | length))",
    (if ($rows | length) == 0 then empty else ($rows[] | item) end);
  [
    "\(.home)  \(.generated)",
    "",
    "\(.nothing_brings_them_back) with nothing that will bring them back",
    (if (.rotting | length) == 0 then empty else (.rotting[] | item) end),
    "",
    section("Waiting on you"; .waiting_on_you),
    "",
    section("Waiting on someone outside"; .waiting_on_outside),
    "",
    section("Blocked on other work"; .blocked),
    "",
    section("Waiting on a date"; .waiting_on_date),
    "",
    section("Moving"; .moving),
    (if (.unreadables | length) == 0 then empty
     else "", ("Homes that could not be read: " + ([.unreadables[].id] | join(", ")))
     end),
    (if (.warnings | length) == 0 then empty
     else "", ("Warnings: " + ([.warnings[] | .id + " " + .reason] | join("; ")))
     end),
    (if (.missing | length) == 0 then empty
     else "", ("Snapshot cannot supply: " + (.missing | join("; ")))
     end)
  ] | .[]
'
