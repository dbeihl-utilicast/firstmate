#!/usr/bin/env bash
# Opt-in drift guard for the installed agy interactive lifecycle.
#
# It drives a REAL agy worker through a REAL tmux server on a private socket
# (`-L`) and asks the production classifiers about the pane captures tmux
# returns, because that capture is the only screen supervision ever reads. A
# raw PTY is not a substitute: agy queries terminal capabilities at startup and
# falls back to a static, footer-less render when nothing answers, so a PTY
# driver observes neither busy footer nor interruption no matter what the
# worker is really doing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE tmux git
[ -x "${AGY_BIN:-}" ] || fail "FM_AGY_SIGNALS_LIVE=1 but agy is not installed"
[ "$(uname -s)" = Darwin ] || { printf 'skip: agy adapter is verified only on macOS\n'; exit 0; }

VERSION_OUT=$("$AGY_BIN" --version 2>&1) || fail "agy --version failed: $VERSION_OUT"
printf 'BOOTSTRAP_INFO: live agy version: %s\n' "$VERSION_OUT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
# The driver runs a permission-bypassed agent that is told to execute shell
# commands, so it never gets the repository checkout as its workspace: it gets a
# throwaway git workspace, the same isolation the rovo and muse live drivers use.
# A fresh workspace also keeps the trust-dialog branch below live on every run
# instead of dead against an already-trusted path.
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  # A server that already exited with its last session leaves the socket behind,
  # so every run would otherwise litter one dead entry in tmux's socket dir.
  rm -f -- "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  [ -n "${LAB:-}" ] && rm -rf -- "$LAB"
}
trap cleanup_all EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated agy workspace"
BUSY_FRAME="$LAB/busy-pane.txt"
IDLE_FRAME="$LAB/idle-pane.txt"

tmux_() { "$REAL_TMUX" -L "$SOCKET" "$@"; }
capture() { tmux_ capture-pane -p -J -t "$SESSION" -S -120 2>/dev/null; }

PROMPT='Without using tools, write the integers from 1 through 10000, one per line, and do not stop early.'
tmux_ new-session -d -s "$SESSION" -x 140 -y 40 -c "$WORKSPACE" \
  "cd $WORKSPACE && exec $AGY_BIN --dangerously-skip-permissions --model gemini-3.8-flash-low --effort low --prompt-interactive='$PROMPT'" \
  || fail "could not start the live agy tmux worker"

# The same bounded response fm-spawn makes, and only once both structural
# strings of the verified dialog are on the screen at the same time.
trusted=0
for _ in $(seq 1 60); do
  sleep 1
  pane=$(capture)
  case $pane in *'esc to cancel'*) break ;; esac
  if [ "$trusted" = 0 ] \
    && case $pane in *'Do you trust the contents of this project?'*) true ;; *) false ;; esac \
    && case $pane in *'Yes, I trust this folder'*) true ;; *) false ;; esac; then
    tmux_ send-keys -t "$SESSION" Enter
    trusted=1
  fi
done
case $pane in
  *'esc to cancel'*) ;;
  *) fail "agy never rendered the verified busy footer"$'\n'"$pane" ;;
esac
printf '%s\n' "$pane" > "$BUSY_FRAME"

printf '%s\n' "$pane" | fm_busy_agy_tail_busy \
  || fail "agy busy helper did not classify the live mid-turn pane busy"$'\n'"$pane"
pass "real agy renders the busy footer for an interactive worker turn"

tmux_ send-keys -t "$SESSION" Escape
interrupted=0
for _ in $(seq 1 15); do
  sleep 1
  pane=$(capture)
  case $pane in *'esc to cancel'*) ;; *) interrupted=1; break ;; esac
done
[ "$interrupted" = 1 ] || fail "agy did not clear its busy footer after one Escape"$'\n'"$pane"
tmux_ has-session -t "$SESSION" 2>/dev/null || fail "agy exited instead of returning interactive after one Escape"
pass "real agy interrupts one running turn with one Escape and remains interactive"

# The busy case above proves the same helper's negative result is meaningful.
sleep 3
capture > "$IDLE_FRAME"
[ -s "$IDLE_FRAME" ] || fail "the live driver captured no post-interrupt pane to classify"
if fm_busy_agy_tail_busy < "$IDLE_FRAME"; then
  fail "real agy remained busy after interruption"$'\n'"$(cat "$IDLE_FRAME")"
fi
pass "real agy releases its busy footer after interruption"

# The launch flags are separate model and effort flags, and the running worker
# is the only thing that can say they resolved.
grep -qF 'Gemini 3.8 Flash (Low)' "$IDLE_FRAME" \
  || fail "the live worker did not resolve the requested model and effort"$'\n'"$(cat "$IDLE_FRAME")"
pass "real agy resolves the separate --model and --effort flags it was launched with"

tmux_ send-keys -t "$SESSION" -l '/quit'
tmux_ send-keys -t "$SESSION" Enter
gone=0
for _ in $(seq 1 30); do
  sleep 1
  tmux_ has-session -t "$SESSION" 2>/dev/null || { gone=1; break; }
done
[ "$gone" = 1 ] || fail "agy did not exit after /quit"$'\n'"$(capture)"
pass "real agy exits after /quit"
