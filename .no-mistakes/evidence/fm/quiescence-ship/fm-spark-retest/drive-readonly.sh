#!/bin/bash
set -eu
cd /Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M2GT7AXS7BMKDKVEKPZCG3NP
EVIDENCE=/Users/davidsair/.no-mistakes/evidence/01M2GT7AXS7BMKDKVEKPZCG3NP/fm-spark-retest
REMOTE_ROOT=/home/dbeihl/git/utilicast/firstmate
SSH_ARGS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no -o ClearAllForwardings=yes -o 'SendEnv=-*' -o ConnectTimeout=10)

drive() {
  local label=$1 home=$2 expected=$3 rc=0
  shift 3
  {
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    printf 'export FM_ROOT_OVERRIDE=%q FM_HOME=%q\n' "$REMOTE_ROOT" "$home"
    printf 'set --'; printf ' %q' "$@"; printf '\n'
    cat bin/fm-secondmate-registry-lib.sh bin/fm-nm-run-lib.sh
    sed '/^\. "\$SCRIPT_DIR\/fm-secondmate-registry-lib.sh"$/d; /^\. "\$SCRIPT_DIR\/fm-nm-run-lib.sh"$/d' bin/fm-nm-quiescence.sh
  } | ssh "${SSH_ARGS[@]}" fm-spark bash /dev/stdin > "$EVIDENCE/$label.txt" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$EVIDENCE/$label.exit"
  printf '\nCASE %s\n' "$label"
  cat "$EVIDENCE/$label.txt"
  printf 'EXIT %s (expected %s)\n' "$rc" "$expected"
  [ "$rc" -eq "$expected" ]
}

date -u '+%Y-%m-%dT%H:%M:%SZ'
git rev-parse HEAD
shasum -a 256 bin/fm-nm-quiescence.sh bin/fm-nm-run-lib.sh bin/fm-secondmate-registry-lib.sh
drive root-busy "$REMOTE_ROOT" 1 --root-only root@fm-spark fm-spark
drive parked-projects /home/dbeihl/git/utilicast/fm-homes/plugins-spark 3 --home-only plugins-spark fm-spark
drive empty-ledger /home/dbeihl/git/utilicast/fm-homes/azure-ops-mate/projects/utilicast-streamlit 0 --home-only empty-project fm-spark
drive terminal-ledger /home/dbeihl/git/utilicast/fm-homes/plugins-spark/projects/unlimited-power 0 --home-only terminal-project fm-spark
drive shared-root-home "$REMOTE_ROOT" 1
cache=$(awk -F '\t' '$1 == "REPO" {sub(/^REPO\t/, ""); print}' "$EVIDENCE/root-busy.txt")
drive inherited-worktree /home/dbeihl/.treehouse/firstmate-1d7d78/5/firstmate 1 --home-only inherited-worktree fm-spark $'\n'"$cache"$'\n'
drive selected-home-census /home/dbeihl/git/utilicast/fm-homes/plugins-spark 3
