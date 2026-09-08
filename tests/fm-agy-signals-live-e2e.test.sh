#!/usr/bin/env bash
# Opt-in drift guard for the installed agy interactive lifecycle.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE python3
[ -x "${AGY_BIN:-}" ] || fail "FM_AGY_SIGNALS_LIVE=1 but agy is not installed"
[ "$(uname -s)" = Darwin ] || { printf 'skip: agy adapter is verified only on macOS\n'; exit 0; }

VERSION_OUT=$("$AGY_BIN" --version 2>&1) || fail "agy --version failed: $VERSION_OUT"
printf 'BOOTSTRAP_INFO: live agy version: %s\n' "$VERSION_OUT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TRANSCRIPT=$(mktemp "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create transcript"
trap 'rm -f "$TRANSCRIPT"' EXIT

python3 - "$AGY_BIN" "$ROOT" "$TRANSCRIPT" <<'PY' || fail "agy PTY lifecycle driver failed"
import os
import fcntl
import pty
import select
import struct
import sys
import termios
import time

agy_bin, workspace, transcript_path = sys.argv[1:4]
prompt = "Run sleep 20 as a shell command. Do not modify files or respond until it completes."
pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(agy_bin, [agy_bin, "--dangerously-skip-permissions", "--mode", "accept-edits",
                         "--model", "gemini-3.8-flash-low", "--effort", "low",
                         "--prompt-interactive=" + prompt])
    os._exit(127)

out = open(transcript_path, "wb")
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
completed = False
def pump(seconds, want=None):
    deadline = time.time() + seconds
    seen = b""
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.5)
        if fd in ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out.write(chunk); out.flush(); seen += chunk
        if want and want in seen:
            return seen
    return seen

try:
    # A fresh worktree shows this exact prompt. This is the same bounded response
    # fm-spawn makes, and only after both structural strings are present.
    initial = pump(45, want=b"esc to cancel")
    if b"esc to cancel" not in initial:
        if b"Do you trust the contents of this project?" in initial and b"Yes, I trust this folder" in initial:
            os.write(fd, b"\r")
            initial += pump(45, want=b"esc to cancel")
    if b"esc to cancel" not in initial:
        raise RuntimeError("agy never rendered the verified busy footer")

    os.write(fd, b"\x1b")
    cancelled = pump(30, want=b"Interrupted")
    if b"Interrupted" not in cancelled:
        raise RuntimeError("agy did not render its interruption response after one Escape")

    pump(2)
    os.write(fd, b"/quit\r")
    for _ in range(60):
        done, _ = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            completed = True
            break
        pump(0.5)
    if not completed:
        raise RuntimeError("agy did not exit after /quit")
finally:
    out.close()
    if not completed:
        try:
            os.kill(pid, 15)
            os.waitpid(pid, 0)
        except ProcessLookupError:
            pass
PY

grep -aFq 'esc to cancel' "$TRANSCRIPT" || fail "real agy did not render its busy footer"
printf '%s\n' 'esc to cancel' | fm_busy_agy_tail_busy || fail "agy busy helper did not recognize the live footer"
pass "real agy renders the busy footer for an interactive worker turn"

grep -aFq 'Interrupted' "$TRANSCRIPT" || fail "real agy did not render interruption after one Escape"
pass "real agy interrupts one running turn with one Escape"

if tail -12 "$TRANSCRIPT" | fm_busy_agy_tail_busy; then
  fail "real agy remained busy after interruption"
fi
pass "real agy releases its busy footer after interruption"

pass "real agy exits after /quit"
