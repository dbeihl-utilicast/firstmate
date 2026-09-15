#!/usr/bin/env bash
# Execute one tracked Firstmate command in a configured remote secondmate home.
#
# Usage:
#   fm-on.sh [--stdin] <secondmate-id|unambiguous-ssh-alias> <fm-command> [args...]
#
# Routes come only from remote records in data/secondmates.md. A record names an
# SSH config alias, remote Firstmate code root, and remote FM_HOME. A host alias
# may be used directly only when exactly one record selects it; an ambiguous
# alias is refused. The command must be a genuine executable in this checkout's
# bin/fm-*.sh namespace. No per-command table exists.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# fm-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps normal public-key and strict host-key policy in ~/.ssh.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. FM_SSH_ALIVE_INTERVAL and FM_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
#
# ServerAlive only catches a dead peer, never a live one whose remote command
# stopped making progress - a wedge that cannot be distinguished from slow
# work is exactly what a hung remote job, a stale worker, or a pre-migration
# host with no bounded job queue at all looks like from here. So the whole
# ssh call is itself wrapped in fm_run_timed (bin/fm-timeout-lib.sh), the
# repo's one hard-bound runner, rather than trusting every remote to return.
# FM_ON_TIMEOUT overrides the default; a bound this wide only fires after the
# remote job system's own worst-case wait (queue + execution + grace, capped
# at 750s by default) has already had room to finish on its own. A caller
# sees this as exit 124, distinct from ssh's own exit codes (0-255, never
# 124), with a diagnostic on stderr naming the host and the bound - never a
# silent hang. Exit 255 keeps meaning what it always has: unavailable
# transport or unknown remote completion, reconciled by the semantic caller.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ON_TIMEOUT=${FM_ON_TIMEOUT:-900}
case "$ON_TIMEOUT" in ''|*[!0-9]*|0) printf 'error: %s\n' "FM_ON_TIMEOUT must be a positive integer: $ON_TIMEOUT" >&2; exit 1 ;; esac

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
REG="$DATA/secondmates.md"
PROTOCOL=1

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
if [ "${1:-}" = --stdin ]; then
  STDIN_MODE=caller
  shift
fi
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe secondmate id or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  fm-*.sh) ;;
  *) die "remote command must be a basename in the fm-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$FM_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Firstmate checkout: $COMMAND"
git -C "$FM_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Firstmate checkout: $COMMAND"
[ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"

MATCHES=0
HOST=
ROOT=
HOME_PATH=
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '- '*) ;; *) continue ;; esac
  secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
  if [ "$SECONDMATE_REGISTRY_ID" = "$ROUTE" ] || [ "$SECONDMATE_REGISTRY_HOST" = "$ROUTE" ]; then
    MATCHES=$((MATCHES + 1))
    HOST=$SECONDMATE_REGISTRY_HOST
    ROOT=$SECONDMATE_REGISTRY_ROOT
    HOME_PATH=$SECONDMATE_REGISTRY_HOME
  fi
done < "$REG"
[ "$MATCHES" -gt 0 ] || die "no remote secondmate or SSH alias matches '$ROUTE'"
[ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured secondmates; use a secondmate id"
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${FM_SSH_BIN:-ssh}
ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" fm-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
# fm_run_timed no longer lets this process exec into ssh in place, so this
# process's own pid no longer IS the ssh connection the way it did before the
# bound was added. A caller that kills this process (the remote job system's
# own disconnect handling does exactly that when its staging caller goes away)
# must still bring the ssh call down with it, not leave it running unnoticed:
# forward the same signal to FM_RUN_TIMED_KILL_TARGET, then re-deliver it to
# this process so the caller still observes the conventional 128+signal exit.
# shellcheck disable=SC2329 # Invoked through the trap registrations below.
fm_on_forward_signal() {
  sig=$1
  [ -z "${FM_RUN_TIMED_KILL_TARGET:-}" ] || kill -s "$sig" "$FM_RUN_TIMED_KILL_TARGET" 2>/dev/null || true
  trap - "$sig"
  kill -s "$sig" "$$" 2>/dev/null || exit 1
}
trap 'fm_on_forward_signal TERM' TERM
trap 'fm_on_forward_signal INT' INT
trap 'fm_on_forward_signal HUP' HUP

# A caller that goes away without ever signaling this process directly (the
# common shape: this ran as a backgrounded shell function, so the process a
# caller actually tracks and kills is that function's own subshell, one layer
# above this script) still needs the ssh call brought down. Mirror the same
# parent-liveness self-check bin/fm-remote-entrypoint.sh already uses on the
# far end of this same call: watch this process's own ppid, and if it changes
# - the recorded parent is gone and this process has been reparented - signal
# itself so the trap above tears the call down instead of leaving it running
# unnoticed. Explicitly closed off from the caller's own stdio so this poller
# can never hold a captured pipe open past this call's own completion.
ORIGINAL_PPID=$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')
PPID_WATCH_PID=
case "$ORIGINAL_PPID" in
  ''|*[!0-9]*) ;;
  *)
    (
      while :; do
        sleep 1
        current=$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')
        [ "$current" = "$ORIGINAL_PPID" ] || { kill -TERM "$$" 2>/dev/null || true; break; }
      done
    ) < /dev/null > /dev/null 2>&1 &
    PPID_WATCH_PID=$!
    ;;
esac

rc=0
if [ "$STDIN_MODE" = caller ]; then
  fm_run_timed "$ON_TIMEOUT" "$SSH_BIN" "${SSH_ARGS[@]}" || rc=$?
else
  fm_run_timed "$ON_TIMEOUT" "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null || rc=$?
fi
if [ -n "$PPID_WATCH_PID" ]; then
  kill -TERM "$PPID_WATCH_PID" 2>/dev/null || true
  wait "$PPID_WATCH_PID" 2>/dev/null || true
fi
if [ "$rc" -eq 124 ]; then
  # 124 also covers a remote job system reporting its own bounded timeout
  # verbatim through ssh's exit status; either way the call did not complete
  # productively within this bound, so the host is named either way.
  printf 'error: remote command did not complete within %ss talking to %s: %s\n' \
    "$ON_TIMEOUT" "$HOST" "$COMMAND" >&2
fi
exit "$rc"
