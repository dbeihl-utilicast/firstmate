#!/usr/bin/env bash
# Live chain: remote secondmate home reconcile -> parent channel log -> real
# relay (fake ssh to local entrypoint) -> main home vault catch-up.
set -u
umask 077
ROOT=${1:?repo root}
BASE_COPY=${2:-}
T=$(mktemp -d /tmp/fm-vault-e2e.XXXXXX); T=$(cd "$T" && pwd -P)
MAIN="$T/main"; REMOTE="$T/remote"; VAULT="$T/vault"; FAKE="$T/fakebin"; CLAIMS="$T/claims"
mkdir -p "$MAIN"/{state,data,config} "$REMOTE"/{state,data,config,projects} "$VAULT" "$FAKE" "$CLAIMS" "$T/rootovr"
: > "$REMOTE/AGENTS.md"
printf 'ios\n' > "$REMOTE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$REMOTE/.fm-secondmate-parent"
printf '#!/usr/bin/env bash\nprintf "state: unknown · source: fake\\n"\n' > "$FAKE/fm-crew-state.sh"
printf '#!/usr/bin/env bash\ncase "${1:-}" in list-panes|display-message) printf "%%%%1\\n";; capture-pane) printf "idle\\n> \\n";; esac\n' > "$FAKE/tmux"
for t in gh gh-axi curl; do printf '#!/usr/bin/env bash\nexit 97\n' > "$FAKE/$t"; done
cat > "$FAKE/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2;; --) shift; break;; *) exit 90;; esac; done
[ "$1" = remote-mac ] || exit 91; [ "$2" = fm-remote-entrypoint.sh ] || exit 92; shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKE"/*
old=$(date -d '@'$(( $(date +%s) - 120 )) +%Y%m%d%H%M.%S)
child() { # id project note
  local id=$1 proj=$2 note=$3
  { printf 'window=firstmate:fm-%s\nworktree=%s/projects/%s\n' "$id" "$REMOTE" "$id"
    [ -z "$proj" ] || printf 'project=%s\n' "$proj"
    printf 'harness=codex\nkind=ship\nmode=scout\nyolo=off\nspawn_gen=s%s\n' "$RANDOM"; } > "$REMOTE/state/$id.meta"
  printf 'done: %s\n' "$note" > "$REMOTE/state/$id.status"; : > "$REMOTE/state/$id.turn-ended"
  mkdir -p "$REMOTE/data/$id"; printf '# %s report\n' "$id" > "$REMOTE/data/$id/report.md"
  touch -t "$old" "$REMOTE/state/$id.meta" "$REMOTE/state/$id.status" "$REMOTE/state/$id.turn-ended"
}
# S1: project path basename names the report
child vault-summary /Users/captain/projects/spark-notes 'vault summary written'
# S2: no project on the child -> secondmate id fallback; note carries a decoy token
child orphan-task '' 'see project=decoy for context'
# S3: project with spaces/odd characters stays one safe token
child odd-name '/Users/captain/projects/My App (v2)' 'odd project written'
PATH="$FAKE:$PATH" FM_ROOT_OVERRIDE="$T/rootovr" FM_HOME="$REMOTE" FM_STATE_OVERRIDE="$REMOTE/state" \
  FM_DATA_OVERRIDE="$REMOTE/data" FM_CONFIG_OVERRIDE="$REMOTE/config" FM_INACTIVE_RECONCILE_SECS=60 \
  FM_INACTIVE_CREW_STATE_BIN="$FAKE/fm-crew-state.sh" "$ROOT/bin/fm-inactive-reconcile.sh" scan >/dev/null 2>&1
echo "== remote state/parent-replies.status (emitted by fm-inactive-reconcile.sh)"; cat "$REMOTE/state/parent-replies.status"

printf -- '- ios - iOS delivery (host: remote-mac; root: %s; home: %s; scope: iOS; projects: alpha; added 2026-08-02)\n' "$ROOT" "$REMOTE" > "$MAIN/data/secondmates.md"
printf 'window=firstmate:fm-ios\nkind=secondmate\nremote_host=remote-mac\nproject=/home/captain/git/firstmate\nmode=secondmate\n' > "$MAIN/state/ios.meta"
printf 'working: delegated\n' > "$MAIN/state/ios.status"
renv() { FM_HOME="$MAIN" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" FM_SSH_BIN="$FAKE/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" FM_REMOTE_REPLY_WAIT_SECONDS=10 "$@"; }
SID=$(renv "$ROOT/bin/fm-procevent-remote-reply.sh" source-id ios)
renv "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
renv "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1
echo; echo "== main state/ios.status after the real relay"; cat "$MAIN/state/ios.status"
printf '%s\n' "$VAULT" > "$MAIN/config/vault-path"
echo; echo "== fm-vault-copy.sh catch-up (this branch)"
FM_HOME="$MAIN" "$ROOT/bin/fm-vault-copy.sh" catch-up
echo; echo "== vault/research"; ls -1 "$VAULT/research"
if [ -n "$BASE_COPY" ]; then
  rm -rf "$VAULT"/* "$MAIN/state/vault-copied.ledger"
  echo; echo "== same state, BASE fm-vault-copy.sh (01b80335)"
  FM_HOME="$MAIN" "$BASE_COPY" catch-up
fi
renv "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
[ -f "$T/remote-jobs/worker.pid" ] && kill "$(cat "$T/remote-jobs/worker.pid")" 2>/dev/null
rm -rf "$T"
