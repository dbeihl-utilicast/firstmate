#!/bin/bash
set -eu
ROOT=/Users/davidsair/.no-mistakes/worktrees/2f2b4426b91c/01M2GT7AXS7BMKDKVEKPZCG3NP
EVIDENCE=/Users/davidsair/.no-mistakes/evidence/01M2GT7AXS7BMKDKVEKPZCG3NP/fm-spark-retest
WORK="$ROOT/.quiescence-live-test"
[ ! -e "$WORK" ] || { printf 'Refusing to reuse %s\n' "$WORK" >&2; exit 1; }
mkdir -p "$WORK/data" "$WORK/projects" "$WORK/tmp"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
unset FM_ROOT_OVERRIDE FM_HOME FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_NM_ON_BIN FM_NM_QUIESCENCE_NOW_EPOCH FM_NM_QUIESCENCE_TIMEOUT FM_SSH_BIN
export FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_DATA_OVERRIDE="$WORK/data" FM_PROJECTS_OVERRIDE="$WORK/projects"
CHECK="$ROOT/bin/fm-nm-quiescence.sh"

capture() {
  local name=$1 code
  shift
  printf '\nSCENARIO %s\n' "$name"
  printf 'COMMAND'; printf ' %q' "$@"; printf '\n'
  code=0
  "$@" > "$EVIDENCE/$name.txt" 2>&1 || code=$?
  cat "$EVIDENCE/$name.txt"
  printf 'EXIT %s\n' "$code"
  [ "$code" -eq 2 ] || { printf 'Unexpected exit: %s\n' "$code" >&2; exit 1; }
}
require_record() {
  local file=$1 kind=$2 host=$3 home=$4 field=$5 value=$6
  awk -F '\t' -v kind="$kind" -v host="$host" -v home="$home" -v field="$field" -v value="$value" '
    $1 == kind {
      delete v
      for (i=2; i<=NF; i++) { n=index($i,"="); v[substr($i,1,n-1)]=substr($i,n+1) }
      if ((host == "" || v["host"] == host) && (home == "" || v["home"] == home) && v[field] == value) found=1
    }
    END {exit !found}
  ' "$EVIDENCE/$file.txt"
}
new_repo() { mkdir -p "$1"; git -C "$1" init -q --template= -b main; }

printf 'Installed dependency: '; no-mistakes --version
printf 'Target: '; git -C "$ROOT" rev-parse HEAD
capture unconfigured-local "$CHECK"
require_record unconfigured-local GAP local root@local reason validation-not-configured
require_record unconfigured-local HOME local main status incomplete
require_record unconfigured-local SUMMARY '' '' result incomplete

CHILD="$WORK/projectless-home"
new_repo "$CHILD"
printf -- '- child - projectless home (home: %s; scope: verification; projects: none; added 2026-09-14)\n' "$CHILD" > "$WORK/data/secondmates.md"
capture registered-projectless-home "$CHECK"
require_record registered-projectless-home GAP local child clone projectless-home
require_record registered-projectless-home GAP local child reason validation-not-configured
require_record registered-projectless-home HOME local child status incomplete

new_repo "$WORK/alternate-projects/override-project"
new_repo "$CHILD/projects/child-project"
capture projects-override env FM_PROJECTS_OVERRIDE="$WORK/alternate-projects" "$CHECK"
require_record projects-override GAP local main clone override-project
require_record projects-override GAP local child clone child-project
require_record projects-override HOME local child status incomplete

chmod u-x "$CHILD"
capture inaccessible-home "$CHECK"
chmod u+x "$CHILD"
require_record inaccessible-home GAP local child reason home-unreachable
require_record inaccessible-home HOME local child status incomplete

for inventory in data projects; do
  for permission in u-r u-x; do
    name="inaccessible-$inventory-$permission"
    chmod "$permission" "$WORK/$inventory"
    capture "$name" "$CHECK"
    chmod u+rx "$WORK/$inventory"
    case "$inventory" in data) reason=registry-unavailable ;; projects) reason=projects-unreachable ;; esac
    require_record "$name" GAP local main reason "$reason"
  done
done

for inventory in data projects; do
  mkdir -p "$WORK/hidden/$inventory"
  chmod u-x "$WORK/hidden"
  case "$inventory" in data) variable=FM_DATA_OVERRIDE; reason=registry-unavailable ;; projects) variable=FM_PROJECTS_OVERRIDE; reason=projects-unreachable ;; esac
  capture "hidden-$inventory-ancestor" env "$variable=$WORK/hidden/$inventory" "$CHECK"
  chmod u+x "$WORK/hidden"
  require_record "hidden-$inventory-ancestor" GAP local main reason "$reason"
done

ln -s "$CHILD" "$WORK/projects/symlink-project"
capture unsafe-project-entry "$CHECK"
require_record unsafe-project-entry GAP local main clone symlink-project
require_record unsafe-project-entry GAP local main reason unsafe-project-entry
rm "$WORK/projects/symlink-project"

printf -- '- invalid registry row\n' > "$WORK/data/secondmates.md"
capture malformed-registry "$CHECK"
require_record malformed-registry GAP local main reason malformed-registry-entry

cat > "$WORK/ssh-config" <<EOF
Host quiescence-unreachable
    HostName 127.0.0.1
    Port 1
    BatchMode yes
    ConnectTimeout 2
    ConnectionAttempts 1
    UserKnownHostsFile /dev/null
    GlobalKnownHostsFile /dev/null
    StrictHostKeyChecking yes
    ControlMaster no
    ControlPath none
    IdentitiesOnly yes
    IdentityAgent none
EOF
cat > "$WORK/ssh-client" <<'EOF'
#!/bin/bash
exec /usr/bin/ssh -F "$QUIESCENCE_SSH_CONFIG" "$@"
EOF
chmod +x "$WORK/ssh-client"
for label in alpha beta; do
  printf -- '- %s - unreachable test home (host: quiescence-unreachable; root: %s; home: %s; scope: verification; projects: none; added 2026-09-14)\n' "$label" "$ROOT" "$WORK/$label"
done > "$WORK/data/secondmates.md"
capture unreachable-ssh env FM_SSH_BIN="$WORK/ssh-client" QUIESCENCE_SSH_CONFIG="$WORK/ssh-config" "$CHECK"
for label in root@quiescence-unreachable alpha beta; do
  require_record unreachable-ssh GAP quiescence-unreachable "$label" reason host-unreachable
done
require_record unreachable-ssh SUMMARY '' '' result incomplete
printf '\nAll exercised live failure boundaries returned incomplete with the required attribution.\n'
