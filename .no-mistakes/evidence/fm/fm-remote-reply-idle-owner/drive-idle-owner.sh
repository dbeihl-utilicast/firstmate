#!/usr/bin/env bash
# Live driver: arm a remote-reply source in a throwaway home, then observe owner
# state over time with (a) a live verified harness session lock, (b) a lock held
# by a live NON-harness process, (c) a lock naming a dead pid.
# Usage: drive-idle-owner.sh <repo-root> <mode: harness|nonharness|deadpid>
set -u
ROOT=$1 MODE=$2
T=$(mktemp -d /tmp/fm-drive.XXXX); chmod 700 "$T"; umask 077
PARENT=$T/parent REMOTE=$T/remote CLAIMS=$T/claims FAKE=$T/fake
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$CLAIMS" "$FAKE"
printf -- '- ios - iOS delivery (host: remote-mac; root: %s; home: %s; scope: iOS work; projects: alpha; added 2026-08-02)\n' "$ROOT" "$REMOTE" > "$PARENT/data/secondmates.md"
: > "$REMOTE/state/parent-replies.status"
printf '%s\n' '#!/usr/bin/env bash' 'while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2;; --) shift; break;; *) exit 90;; esac; done' 'shift 2' 'exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"' > "$FAKE/fake-ssh"
chmod +x "$FAKE/fake-ssh"
ln -s /bin/bash "$FAKE/claude"
ln -s /bin/bash "$FAKE/plainshell"
env_() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKE/fake-ssh" FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=1 FM_PROCEVENT_OWNER_LEASE_SECONDS=3 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 "$@"
}
owner() { env_ "$ROOT/bin/fm-procevent.sh" list | awk -v id="$SID" '$1 == id { print $3 }'; }
SID=$(env_ "$ROOT/bin/fm-procevent-remote-reply.sh" source-id ios)
env_ "$ROOT/bin/fm-procevent-remote-reply.sh" arm ios >/dev/null
case $MODE in
  harness) FM_HOME="$PARENT" "$FAKE/claude" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; while :; do sleep 1; done' & SPID=$! ;;
  nonharness) FM_HOME="$PARENT" "$FAKE/plainshell" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; while :; do sleep 1; done' & SPID=$! ;;
  deadpid) bash -c 'exit 0' & wait $!; printf '%s\n' "$!" > "$PARENT/state/.lock"; SPID= ;;
esac
sleep 0.5
echo "mode=$MODE  fm-lock status: $(FM_HOME="$PARENT" "$ROOT/bin/fm-lock.sh" status 2>&1)"
env_ "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null 2>&1
echo "t=0s   owner=$(owner)   (lease=3s, check=1s, no watcher, no firstmate turn)"
for s in 3 6 9 12; do sleep 3; echo "t=${s}s  owner=$(owner)"; done
printf 'working [key=one]: reply sent while firstmate idle\n' >> "$REMOTE/state/parent-replies.status"
sleep 5
echo "after remote reply: owner=$(owner)  mirrored=$(grep -c 'reply sent while firstmate idle' "$PARENT/state/ios.status" 2>/dev/null || echo 0)"
if [ -n "$SPID" ]; then kill "$SPID"; wait "$SPID" 2>/dev/null; echo "primary session ended"; sleep 7; echo "t=+7s after session end owner=$(owner)"; fi
env_ "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
rm -rf "$T"
