#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE to
#       "perl" or "bash" to force either fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
#       Sets FM_RUN_TIMED_KILL_TARGET (global, reset on every call) to a `kill`
#       argument that tears down the bounded command's whole tree on demand -
#       a caller that is itself killed before fm_run_timed returns can forward
#       that same signal to this target from its own trap so the bounded
#       command does not silently outlive it.
#
#       Sets FM_RUN_TIMED_EXPIRED (global, reset on every call) to 1 only when
#       the bound itself fired, so a caller can tell that apart from a command
#       that exited 124 on its own.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid.
set -u

fm_timeout_mechanism() {
  case "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" in
    bash|perl) printf '%s\n' "$FM_TIMEOUT_MECHANISM_OVERRIDE"; return ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

fm_run_bash_timeout() {
  local seconds=$1 deadline_status coordinator_pid coordinator_rc monitor_was_on=0
  shift
  deadline_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-deadline.XXXXXX" 2>/dev/null) || return 124
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    coordinator_pid=${BASHPID:-$(exec sh -c 'printf "%s\n" "$PPID"')}
    trap 'trap "" HUP INT TERM; kill -TERM -- "-$coordinator_pid" 2>/dev/null || true; sleep 0.2; kill -KILL -- "-$coordinator_pid" 2>/dev/null || true' HUP INT TERM
    sleep "$seconds" &
    timer_pid=$!
    ( command_rc=0; "$@" || command_rc=$?; kill -TERM "$timer_pid" 2>/dev/null || true; exit "$command_rc" ) <&0 &
    command_pid=$!
    if wait "$timer_pid"; then
      printf 'expired\n' > "$deadline_status"
      trap '' HUP INT TERM
      kill -TERM -- "-$coordinator_pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$coordinator_pid" 2>/dev/null || true
    fi
    command_rc=0
    wait "$command_pid" || command_rc=$?
    exit "$command_rc"
  ) <&0 &
  coordinator_pid=$!
  FM_RUN_TIMED_KILL_TARGET="$coordinator_pid"
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$coordinator_pid" 2>/dev/null; then
    coordinator_rc=0
  else
    coordinator_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    coordinator_rc=124
    FM_RUN_TIMED_EXPIRED=1
  fi
  rm -f "$deadline_status" 2>/dev/null || true
  return "$coordinator_rc"
}

fm_run_perl_timeout() {
  local seconds=$1 deadline_status coordinator_pid coordinator_rc monitor_was_on=0
  shift
  deadline_status=$(mktemp "${TMPDIR:-/tmp}/fm-perl-timeout-deadline.XXXXXX" 2>/dev/null) || return 124
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  perl -e '
    my $t = shift;
    my $deadline = shift;
    setpgrp(0, 0);
    my $group = getpgrp(0);
    my $stop = sub {
      $SIG{HUP} = $SIG{INT} = $SIG{TERM} = $SIG{ALRM} = "IGNORE";
      kill "KILL", -$group;
    };
    local $SIG{HUP} = $stop;
    local $SIG{INT} = $stop;
    local $SIG{TERM} = $stop;
    local $SIG{ALRM} = sub { open my $fh, ">", $deadline or exit 124; print {$fh} "expired\n"; close $fh; $stop->() };
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { exec @ARGV }
    alarm $t;
    waitpid $pid, 0;
    alarm 0;
    my $status = $?;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$seconds" "$deadline_status" "$@" <&0 &
  coordinator_pid=$!
  FM_RUN_TIMED_KILL_TARGET="$coordinator_pid"
  [ "$monitor_was_on" -eq 1 ] || set +m
  if wait "$coordinator_pid" 2>/dev/null; then
    coordinator_rc=0
  else
    coordinator_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    coordinator_rc=124
    FM_RUN_TIMED_EXPIRED=1
  fi
  rm -f "$deadline_status" 2>/dev/null || true
  return "$coordinator_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  #
  # Without job control active (the ordinary case for a sourced, non-interactive
  # caller), bash silently substitutes /dev/null for an asynchronous command's
  # stdin unless that exact command carries its own redirection - so a caller
  # that redirected fm_run_timed's own stdin (a file, a payload pipe) would
  # otherwise lose it here even though nothing about this call looks wrong.
  # The explicit <&0 duplicates whatever stdin this function actually has,
  # which both suppresses that substitution and is a no-op when the caller
  # left stdin alone.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    status_file=$1
    shift
    "$@"
    command_rc=$?
    printf "%s\n" "$command_rc" > "$status_file"
    exit "$command_rc"
  ' _ "$status_file" "$@" <&0 &
  runner_pid=$!
  # GNU/BSD timeout's own pid doubles as the process-group id of the command
  # it launched (confirmed by this library's own kill -KILL -- "-$runner_pid"
  # cleanup below), and timeout forwards a signal it receives itself to that
  # group before exiting - so a plain kill of runner_pid is enough for a
  # caller's trap to tear down everything underneath it.
  FM_RUN_TIMED_KILL_TARGET="$runner_pid"
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      FM_RUN_TIMED_EXPIRED=1
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  # shellcheck disable=SC2034 # Sourceable API consumed by callers, not this function.
  FM_RUN_TIMED_KILL_TARGET=
  # shellcheck disable=SC2034 # Sourceable API consumed by callers, not this function.
  FM_RUN_TIMED_EXPIRED=0
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl) fm_run_perl_timeout "$seconds" "$@" ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
