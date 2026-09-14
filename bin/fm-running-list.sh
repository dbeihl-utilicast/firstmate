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
#   rotting             open rows with no viable continuation, including proven-dead copies
#   waiting_on_you      captain-hold items, including dated holds (the date is
#                       the way back, not the owner of the wait)
#   waiting_on_outside  paused work, undated external holds, and named gate reasons
#   blocked             unresolved blockers and in-flight work with blocked or unknown state
#   waiting_on_date     time-gated work that is not a captain hold
#   moving              in-flight work whose current state is working
#
# The rotting count is printed first. Age is shown in days when the snapshot
# supplies a structured hold age; otherwise the row shows "-" and the status line
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

SNAP=$("$BEARINGS" --json --all-in-flight --all-decisions --all-queued \
  --all-secondmates --all-unhealthy) \
  || exit $?

MODEL=$(printf '%s' "$SNAP" | jq '
  def nonempty($v): ($v != null) and ($v != "") and ($v != "-");
  def dash($v): if nonempty($v) then $v else "-" end;
  def owner_of($id; $fallback):
    if nonempty($fallback) then $fallback
    elif ($id | type == "string") and ($id | contains("/")) then ($id | split("/")[0])
    else "(main)" end;
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
    sort_by([(.age_days == null), -(.age_days // 0), .id, .owner]);
  def identity($id; $fallback):
    owner_of($id; $fallback) as $owner
    | if $owner == "(main)" then ($owner + "/" + $id)
      elif ($id | startswith($owner + "/")) then $id
      else ($owner + "/" + $id) end;
  def mark($st; $id; $owner):
    $st + {seen: ($st.seen + {(identity($id; $owner)): true})};
  def unseen($st; $id; $owner):
    ($id | type == "string") and ($st.seen[identity($id; $owner)] | not);
  def endpoint_dead($dead; $id): (($dead | index($id)) != null);
  def state_wait($t):
    if nonempty($t.doing) then $t.doing else ("state " + ($t.state // "unknown")) end;
  def open_work_omission:
    (.surface // "") as $surface
    | ($surface | test("^main (in-flight|unstructured current)"))
      or ($surface | test("^in_flight showing "))
      or ($surface | test("^secondmate .* (active children|decisions_open|queued) omitted by snapshot bound:"))
      or ($surface | test("^secondmates showing "))
      or ($surface | test("^registered secondmates omitted by snapshot bound:"))
      or ($surface | test("^secondmate registry (input truncated|records omitted|unavailable:)"));

  . as $snap
  | ($snap.decisions_open // []) as $decisions
  | ($snap.gates // []) as $gates
  | ($snap.in_flight // []) as $inflight
  | ($snap.secondmates // []) as $mates
  | ($snap.omitted // []) as $omitted
  | (($snap.unhealthy_endpoints // []) | map(.id | strings)) as $dead_ids
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
      (if nonempty($d.hold_until) then ("until " + $d.hold_until)
       else $d.summary end) as $wait
      | .waiting_on_you += [row($d.id; $d.summary; $d.owner;
                                ($d.hold_age_days // null); $wait)]
      | mark(.; $d.id; $d.owner))
  | reduce $gates[] as $g (.;
      if is_warning($g.id) then
        .warnings += [{id:$g.id, title:dash($g.title), reason:dash($g.reason)}]
        | mark(.; $g.id; $g.owner)
      elif unseen(.; $g.id; $g.owner) and ($g.hold_kind == "captain") then
        .waiting_on_you += [row($g.id; $g.title; $g.owner;
                                ($g.hold_age_days // null);
                                (if nonempty($g.hold_until) then ("until " + $g.hold_until)
                                 else $g.reason end))]
        | mark(.; $g.id; $g.owner)
      elif unseen(.; $g.id; $g.owner) and nonempty($g.blocked_by) then
        .blocked += [row($g.id; $g.title; $g.owner;
                         ($g.hold_age_days // null); $g.blocked_by)]
        | mark(.; $g.id; $g.owner)
      elif unseen(.; $g.id; $g.owner) and nonempty($g.hold_until) then
        .waiting_on_date += [row($g.id; $g.title; $g.owner;
                                 ($g.hold_age_days // null);
                                 ("until " + $g.hold_until))]
        | mark(.; $g.id; $g.owner)
      elif unseen(.; $g.id; $g.owner) and nonempty($g.reason) then
        .waiting_on_outside += [row($g.id; $g.title; $g.owner; null; $g.reason)]
        | mark(.; $g.id; $g.owner)
      elif unseen(.; $g.id; $g.owner) then
        .rotting += [row($g.id; $g.title; $g.owner; null; $g.title)]
        | mark(.; $g.id; $g.owner)
      else . end)
  | reduce $inflight[] as $t (.;
      if unseen(.; $t.id; null) and endpoint_dead($dead_ids; $t.id) then
        .rotting += [row($t.id; ($t.doing // $t.id); null; null; state_wait($t))]
        | mark(.; $t.id; null)
      elif unseen(.; $t.id; null) and ($t.state == "working") then
        .moving += [row($t.id; $t.doing; null; null; $t.doing)]
        | mark(.; $t.id; null)
      elif unseen(.; $t.id; null) and ($t.state == "paused" or $t.state == "parked") then
        .waiting_on_outside += [row($t.id; $t.doing; null; null; state_wait($t))]
        | mark(.; $t.id; null)
      elif unseen(.; $t.id; null) and ($t.state == "blocked" or $t.state == "unknown") then
        .blocked += [row($t.id; ($t.doing // $t.id); null; null; state_wait($t))]
        | mark(.; $t.id; null)
      elif unseen(.; $t.id; null) then
        .rotting += [row($t.id; $t.doing // $t.id; null; null; $t.doing // $t.id)]
        | mark(.; $t.id; null)
      else . end)
  | reduce $mates[] as $m (.;
      if is_unreadable($m) then
        .unreadables += [{id:$m.id, reason:dash($m.reason // $m.doing)}]
      elif ($m.state == "externally_held") and unseen(.; $m.id; $m.id) then
        .waiting_on_outside += [row($m.id; $m.doing; $m.id; null; $m.doing)]
        | mark(.; $m.id; $m.id)
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
        [ if $age_missing then "age in days where the snapshot has no structured age" else empty end ]
        + [ $omitted[] | select(open_work_omission) | .surface ]
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
    section("Blocked or state unclear"; .blocked),
    (if (.waiting_on_date | length) == 0 then empty
     else "", section("Waiting on a date"; .waiting_on_date)
     end),
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
