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
#       Sets FM_RUN_TIMED_KILL_TARGET (reset on every call) to a `kill` target a
#       caller's own signal trap can forward to, so the bounded command never
#       silently outlives a killed caller.
#
#       Sets FM_RUN_TIMED_EXPIRED (reset on every call) to 1 only when the bound
#       itself fired, so a caller can tell that apart from a command that exited
#       124 on its own.
#
#       With FM_RUN_TIMED_FOREGROUND set, timeout/gtimeout run the command in the
#       caller's process group and signal only its own pid, never its descendants;
#       perl and bash keep their group and end the call once it stops for input.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# Except foreground timeout/gtimeout, every mechanism terminates the whole process
# GROUP so a hung grandchild cannot outlive the bound: timeout without --foreground,
# perl via setpgrp, and bash via monitor mode.
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

fm_record_fallback_outcome() {  # <outcome-file>
  case "$(cat "$1" 2>/dev/null)" in
    expired) FM_RUN_TIMED_EXPIRED=1 ;;
    stopped) FM_RUN_TIMED_STOPPED=1 ;;
    *) rm -f "$1" 2>/dev/null || true; return 1 ;;
  esac
  rm -f "$1" 2>/dev/null || true
}

fm_run_bash_timeout() {
  local seconds=$1 deadline_status coordinator_pid coordinator_rc monitor_was_on=0
  local foreground=${FM_RUN_TIMED_FOREGROUND:-}
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
    outcome=
    if [ -n "$foreground" ]; then
      while kill -0 "$timer_pid" 2>/dev/null; do
        if ps -A -o pgid=,stat= | awk -v g="$coordinator_pid" '$1 == g && $2 ~ /^[Tt]/ { f = 1 } END { exit !f }'; then
          outcome=stopped
          break
        fi
        sleep 0.2
      done
    fi
    if [ -z "$outcome" ] && wait "$timer_pid"; then
      outcome=expired
    fi
    if [ -n "$outcome" ]; then
      printf '%s\n' "$outcome" > "$deadline_status"
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
  fm_record_fallback_outcome "$deadline_status" && coordinator_rc=124
  return "$coordinator_rc"
}

fm_run_perl_timeout() {
  local seconds=$1 deadline_status coordinator_pid coordinator_rc monitor_was_on=0
  shift
  deadline_status=$(mktemp "${TMPDIR:-/tmp}/fm-perl-timeout-deadline.XXXXXX" 2>/dev/null) || return 124
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  perl -e '
    use POSIX ":sys_wait_h";
    my ($t, $deadline, $foreground) = splice @ARGV, 0, 3;
    setpgrp(0, 0);
    my $group = getpgrp(0);
    my $mark = sub { open my $fh, ">", $deadline or return; print {$fh} "$_[0]\n"; close $fh };
    my $stop = sub {
      $SIG{HUP} = $SIG{INT} = $SIG{TERM} = $SIG{ALRM} = "IGNORE";
      kill "TERM", -$group;
      select undef, undef, undef, 0.2;
      kill "KILL", -$group;
    };
    local $SIG{HUP} = $stop;
    local $SIG{INT} = $stop;
    local $SIG{TERM} = $stop;
    local $SIG{ALRM} = sub { $mark->("expired"); $stop->() };
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { exec @ARGV }
    alarm $t;
    waitpid $pid, ($foreground ? WUNTRACED : 0);
    if ($foreground && WIFSTOPPED(${^CHILD_ERROR_NATIVE})) { $mark->("stopped"); $stop->() }
    alarm 0;
    my $status = $?;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$seconds" "$deadline_status" "${FM_RUN_TIMED_FOREGROUND:-}" "$@" <&0 &
  coordinator_pid=$!
  FM_RUN_TIMED_KILL_TARGET="$coordinator_pid"
  [ "$monitor_was_on" -eq 1 ] || set +m
  if wait "$coordinator_pid" 2>/dev/null; then
    coordinator_rc=0
  else
    coordinator_rc=$?
  fi
  fm_record_fallback_outcome "$deadline_status" && coordinator_rc=124
  return "$coordinator_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc start=$SECONDS
  shift 2
  if [ -n "${FM_RUN_TIMED_FOREGROUND:-}" ]; then
    # No process group here, so the command runs as timeout's own child: timeout
    # then signals its pid directly, with -k escalation, on expiry or a forwarded signal.
    "$runner" --foreground -k 1 "$seconds" "$@" <&0 &
    runner_pid=$!
    FM_RUN_TIMED_KILL_TARGET="$runner_pid"
    runner_rc=0
    wait "$runner_pid" || runner_rc=$?
    case "$runner_rc" in
      124|137)
        if [ "$((SECONDS - start))" -ge "${seconds%%.*}" ] 2>/dev/null; then
          FM_RUN_TIMED_EXPIRED=1
          return 124
        fi
        ;;
    esac
    return "$runner_rc"
  fi
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # The explicit <&0 keeps the caller's stdin: without job control bash would
  # otherwise give this asynchronous command /dev/null.
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
  # timeout forwards a signal it receives to its command before exiting.
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
  # shellcheck disable=SC2034 # Sourceable API consumed by callers, not this function.
  FM_RUN_TIMED_STOPPED=0
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl) fm_run_perl_timeout "$seconds" "$@" ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
