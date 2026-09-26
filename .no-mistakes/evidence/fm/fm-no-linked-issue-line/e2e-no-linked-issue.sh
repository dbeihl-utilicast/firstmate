#!/usr/bin/env bash
# End-to-end: real fm-brief.sh -> fm-spawn.sh launch brief -> authorized --intent
# used verbatim as PR body -> real fm-pr-check.sh (fake gh returns that body).
set -u
export FM_GATE_REFUSE_BYPASS=1  # isolated temp FM_HOME, fake tmux; no fleet touched
ROOT=${1:?repo root}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-e2e-nli.XXXXXX")
trap 'rm -rf "$T"' EXIT
home=$T/home; proj=$T/proj; fb=$T/bin; fr=$T/root
mkdir -p "$home/data" "$home/state" "$home/config" "$proj" "$fb" "$fr/bin" "$T/wt"
git -C "$proj" init -q
printf '#!/bin/sh\nexit 1\n' > "$fb/tmux"
printf '#!/bin/sh\nexit 0\n' > "$fr/bin/fm-guard.sh"
cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -q .body "*) cat "$FM_E2E_BODY_FILE"; exit 0 ;;
  *headRefOid*) echo 0123456789abcdef0123456789abcdef01234567; exit 0 ;;
esac
exit 0
SH
chmod +x "$fb/tmux" "$fr/bin/fm-guard.sh" "$fb/gh"

run_case() {  # <id> <intent> <pr-body-mode: authorized|stripped>
  local id=$1 words=$2 mode=$3 authorized rc out
  echo "=== case $id ($mode) ==="
  echo "--- captain intent:"; printf '%s\n' "$words"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" proj --mode no-mistakes >/dev/null 2>&1 || { echo "brief scaffold failed"; return 1; }
  python3 - "$home/data/$id/brief.md" "$words" <<'PY'
import sys
p, w = sys.argv[1], sys.argv[2]
s = open(p).read().replace('{TASK}', w).replace('{FIRSTMATE_SPEC}', 'Firstmate spec text.')
open(p, 'w').write(s)
PY
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$T/none" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_BACKEND=tmux PATH="$fb:$PATH" "$ROOT/bin/fm-spawn.sh" "$id" "$proj" claude --mode no-mistakes --yolo off > "$T/spawn.out" 2>&1 || true; [ -f "$home/data/$id/launch-brief.md" ] || { echo "spawn:"; cat "$T/spawn.out"; }
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { e=1; next } e { print }' "$home/data/$id/launch-brief.md")
  echo "--- authorized --intent from launch-brief.md:"; printf '%s\n' "$authorized"
  if [ "$mode" = stripped ]; then
    printf '%s\n' "$authorized" | grep -v '^No linked issue$' > "$T/body"
  else
    printf '%s\n' "$authorized" > "$T/body"
  fi
  printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nspawn_gen=1\n' \
    "$id" "$id" "$T/wt" "$proj" > "$home/state/$id.meta"
  out=$(FM_ROOT_OVERRIDE="$fr" FM_HOME="$home" FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_E2E_BODY_FILE="$T/body" \
    PATH="$fb:/usr/bin:/bin:/usr/sbin:/sbin" "$ROOT/bin/fm-pr-check.sh" "$id" https://github.com/o/r/pull/7 2>&1); rc=$?
  echo "--- fm-pr-check.sh rc=$rc"; printf '%s\n' "$out"
  grep '^pr=' "$home/state/$id.meta" || echo "(no pr= recorded)"
  echo
}

run_case nli-plain 'Stop requiring an extra round trip before a PR registers as ready.' authorized
run_case nli-stripped 'Stop requiring an extra round trip before a PR registers as ready.' stripped
run_case nli-quoted 'Keep examples like "Closes #421" and `#9` out of scope.' authorized
run_case issue-named 'Fix the delivery contract regression in #73.' authorized
