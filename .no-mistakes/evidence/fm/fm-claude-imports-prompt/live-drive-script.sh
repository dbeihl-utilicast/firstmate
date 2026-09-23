#!/usr/bin/env bash
# Live drive: real treehouse CLI through bin/fm-treehouse-lib.sh, as a Firstmate home would.
set -u
WT=$1
S=$(mktemp -d /tmp/fm-claudeimp.XXXX); S=$(cd "$S" && pwd -P)
echo "sandbox: $S"
mkdir -p "$S/home/projects" "$S/user" "$S/home2"
printf '@AGENTS.md\n' > "$S/home/CLAUDE.md"; echo '# agents' > "$S/home/AGENTS.md"
git init -q -b main "$S/origin" && git -C "$S/origin" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q "$S/origin" "$S/home/projects/demo"
cd "$S/home/projects/demo" || exit 1
export FM_HOME=$S/home HOME=$S/user
source "$WT/bin/fm-treehouse-lib.sh"

ancestor_claude() { local d=$1 found=none; while [ -n "$d" ] && [ "$d" != / ]; do [ -f "$d/CLAUDE.md" ] && found=$d/CLAUDE.md; d=$(dirname "$d"); done; echo "$found"; }

echo "== 1. pool root for home (CLAUDE.md = @AGENTS.md at $S/home)"
fm_treehouse_home_root
echo "== 2. fm_treehouse get (real treehouse $(treehouse --version))"
SLOT=$(fm_treehouse get --lease); echo "leased: $SLOT"
echo "spawn-typed command: $(fm_treehouse_spawn_get_command)"
echo "SLOT=$SLOT"
case "$SLOT/" in "$S/home"/*) echo "RESULT: FAIL slot inside home";; "") echo "RESULT: FAIL no slot";; *) echo "RESULT: PASS slot outside home";; esac
echo "ancestor CLAUDE.md of slot: $(ancestor_claude "$SLOT")"
echo "== 3. second home, same project name: distinct root"
FM_HOME=$S/home2 fm_treehouse_home_root
echo "== 4. adversarial: HOME inside FM_HOME"
mkdir -p "$S/home/user-home"
HOME=$S/home/user-home fm_treehouse_home_root; echo "home_root exit=$?"
HOME=$S/home/user-home fm_treehouse get; echo "get exit=$?"
echo "in-home .treehouse after refused get: $(ls "$S/home/.treehouse" 2>&1)"
echo "== 4b. adversarial: FM_HOME unset"
FM_HOME= fm_treehouse_home_root; echo "exit=$?"
echo "== 5. legacy in-home slot (old --root <home>) still returns via fm_treehouse"
treehouse get --lease --root "$S/home" </dev/null
LEG=$(ls -d "$S"/home/.treehouse/*/*/demo | head -1); echo "LEG=$LEG"
fm_treehouse return "$LEG" 2>&1; echo "legacy return exit=$?"
echo "== 6. return new slot"
fm_treehouse return "$SLOT" 2>&1; echo "return exit=$?"
fm_treehouse status 2>&1
echo "== cleanup"
cd /; rm -rf "$S"; echo removed
