#!/usr/bin/env bash
# Round-2 live lab: re-drive terminal-lane protection and fm-control error-line reporting.
set -u
ROOT=/home/dbeihl/.no-mistakes/worktrees/4962ffbf57ea/01M3AT3XHQK8YT3NF28T6DYVYH
EV=/home/dbeihl/.no-mistakes/evidence/01M3AT3XHQK8YT3NF28T6DYVYH
L=/tmp/fmu2
HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIG_PATH=$PATH
rm -rf "$L/home" "$L/fakebin" "$L/qbin" "$L/proj" "$L/wt-idle1"
mkdir -p "$L/home/config" "$L/home/state" "$L/fakebin" "$L/qbin" "$L/proj"
git -C "$L/proj" init -q && git -C "$L/proj" commit -q --allow-empty -m init
cp /bin/sleep "$L/fakebin/codex"
cp /bin/sleep "$L/fakebin/claude"

SESSION=$("$HELPER" name usager2)
export SESSION HELPER ORIG_PATH
teardown() { env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION"; echo "teardown rc=$?"; }
trap teardown EXIT
"$HELPER" provision "$SESSION" || exit 1

cat > "$L/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for a in "$@"; do case "$a" in --session|--session=*) exit 9 ;; esac; done
exec env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"
SH
chmod +x "$L/fakebin/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }

CREATE=$(lab workspace create --cwd "$L/proj" --label usage-r2 --no-focus)
WS=$(jq -r '.result.workspace.workspace_id' <<< "$CREATE")
declare -A PANE TAB
first=1
for id in cdone1 cblk1 cidle1 idle1; do
  if [ $first = 1 ]; then P=$(jq -r '.result.root_pane.pane_id' <<< "$CREATE"); T=$(jq -r '.result.root_pane.tab_id // .result.tab.tab_id // empty' <<< "$CREATE"); first=0
  else R=$(lab tab create --workspace "$WS" --cwd "$L/proj" --label "fm-$id" --no-focus); P=$(jq -r '.result.root_pane.pane_id // .result.pane.pane_id' <<< "$R"); T=$(jq -r '.result.tab.tab_id // empty' <<< "$R"); fi
  PANE[$id]=$P; TAB[$id]=$T
done

meta() {  # id harness model
  {
    echo "window=$SESSION:${PANE[$1]}"; echo "endpoint_task_id=$1"; echo "worktree=$L/proj"; echo "project=$L/proj"
    echo "harness=$2"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "model=$3"; echo "effort=default"
    echo "backend=herdr"; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WS"; echo "herdr_tab_id=${TAB[$1]}"; echo "herdr_pane_id=${PANE[$1]}"
  } > "$L/home/state/$1.meta"
}
for id in cdone1 cblk1 cidle1; do meta "$id" codex gpt-5.6-terra; lab pane run "${PANE[$id]}" "$L/fakebin/codex 3600" >/dev/null; done
git -C "$L/proj" worktree add -q "$L/wt-idle1" -b fm/idle1; mkdir -p "$L/home/data/idle1"; printf '# Task\n\n## Captain'"'"'s intent\nLab task for the usage gate.\n\n## Firstmate spec\nPrint hello and stop.\n' > "$L/home/data/idle1/brief.md"
meta idle1 claude sonnet; sed -i "s#^worktree=.*#worktree=$L/wt-idle1#" "$L/home/state/idle1.meta"
printf 'done: finished the task, PR opened\n' > "$L/home/state/cdone1.status"
printf 'blocked: waiting on the captain for a scope call\n' > "$L/home/state/cblk1.status"
printf '%s\n' '{"schema_version":2,"default":[{"harness":"codex","model":"gpt-5.6-terra"},{"harness":"claude","model":"sonnet"}]}' > "$L/home/config/crew-dispatch.json"
sleep 4

qaxi() {  # snapshot
  cat > "$L/qbin/quota-axi" <<SH
#!/usr/bin/env bash
case "\${1-}" in --version) exec $ORIG_PATH_QAXI --version ;; esac
cat "$1"
SH
  chmod +x "$L/qbin/quota-axi"
}
ORIG_PATH_QAXI=$(command -v quota-axi)

run() {  # label cmd...
  echo "\$ $*"
  env -u NO_MISTAKES_GATE PATH="$L/qbin:$L/fakebin:$ORIG_PATH" FM_HOME="$L/home" HERDR_SESSION="$SESSION" "$@" 2>&1
  echo "exit $?"
}

OUT1=$EV/round2-lab-terminal-codex-lanes-held.txt
{
  echo "## Herdr lab $SESSION (herdr $(herdr --version 2>/dev/null)), FM_HOME=$L/home"
  echo "## quota-axi on PATH serves today's real host snapshot with codex all_models edited to exhausted_now (claude untouched)"
  echo "## crew-dispatch default = [codex:gpt-5.6-terra, claude:sonnet]; cdone1/cblk1/cidle1 are live codex panes"
  echo; for id in cdone1 cblk1 cidle1; do echo "\$ herdr agent get $id (${PANE[$id]})"; lab agent get "${PANE[$id]}" | jq -c '{agent: .result.agent.agent, status: .result.agent.agent_status}'; done
  for id in cdone1 cblk1; do echo "\$ cat state/$id.status"; cat "$L/home/state/$id.status"; done
  echo; qaxi "$L/snap-codex.json"
  for id in cdone1 cblk1 cidle1; do run "$ROOT/bin/fm-crew-state.sh" "$id" | sed -n 1,2p; done
  echo; run "$ROOT/bin/fm-usage-gate.sh" sweep
  echo; echo "## cidle1 marked stopped so --relaunch only sees the finished and blocked lanes"
  printf 'stopped test\n' > "$L/home/state/cidle1.stopped"
  echo; run env FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-usage-gate.sh" sweep --relaunch
  for id in cdone1 cblk1; do echo "\$ grep harness/model state/$id.meta after"; grep -E '^(harness|model)=' "$L/home/state/$id.meta"; ls "$L/home/state/$id.control-relaunch" 2>/dev/null || echo "(no $id.control-relaunch record: fm-control was never invoked)"; done
  echo "\$ herdr agent get cdone1 after"; lab agent get "${PANE[cdone1]}" | jq -c '{agent: .result.agent.agent, status: .result.agent.agent_status}'
} > "$OUT1" 2>&1
rm -f "$L/home/state/cidle1.stopped"
for id in cdone1 cblk1 cidle1; do printf 'stopped test\n' > "$L/home/state/$id.stopped"; done

OUT2=$EV/round2-lab-idle-exhausted-lane-relaunched.txt
qaxi "$L/snap-claude.json"
{
  echo "## same lab; quota-axi now serves claude all_models exhausted_now; codex lanes marked stopped"
  echo "## idle1: claude:sonnet lane whose agent already exited at its limit (pane shell remains), no status line; relaunch target codex:gpt-5.6-terra; task worktree and brief exist; the pane shell resolves the REAL codex binary"
  run "$ROOT/bin/fm-crew-state.sh" idle1 | sed -n 1,2p
  cp "$L/home/state/idle1.meta" "$L/idle1.meta.bak"
  echo; run env FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-usage-gate.sh" sweep --relaunch
  echo "\$ state/idle1.meta after"; grep -E '^(harness|model|effort|herdr_pane_id)=' "$L/home/state/idle1.meta"
  echo "\$ state/idle1.control-relaunch"; cat "$L/home/state/idle1.control-relaunch" 2>/dev/null | grep -E '^phase=' || ls "$L/home/state/" | grep idle1
  echo "\$ herdr agent get idle1 after"; lab agent get "$(sed -n 's/^herdr_pane_id=//p' "$L/home/state/idle1.meta")" | jq -c '{agent: .result.agent.agent, status: .result.agent.agent_status}'
  echo "\$ herdr pane read idle1, last lines"; lab pane read "$(sed -n 's/^herdr_pane_id=//p' "$L/home/state/idle1.meta")" 2>/dev/null | jq -r '.result.text // .result.content // .' 2>/dev/null | grep -v '^\s*$' | tail -15
} > "$OUT2" 2>&1
