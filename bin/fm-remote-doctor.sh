#!/usr/bin/env bash
# Check, and optionally repair, one remote account's second-mate readiness.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh [--fix]
#
# Run it through fm-on.sh so the fixed entrypoint invokes this readiness owner
# over its plain SSH bootstrap. The command reports the same filesystem-composed
# PATH used by worker jobs while retaining authority to inspect and repair the
# worker itself.
#
# A remote second mate always runs on the Herdr backend in the dedicated
# fm-remote session. Its account therefore needs the Firstmate-owned Aqua Herdr
# agent plus the sibling dev.firstmate.remote-job worker that runs normal fm-on
# commands through the Aqua or Linux job-worker path. On darwin, that Herdr
# agent runs bin/fm-remote-herdr-guard.sh through the remote account's login
# shell (`-l -c`) so the server inherits the account's own environment; the
# gui/<uid> launchd domain it is bootstrapped into, not the shell, is what
# gives the server and its panes the Aqua audit session and login-keychain
# access. The guard execs the server in the foreground under launchd, leaves an
# Aqua-born server alone, and takes the session over from a server born
# outside that session (an SSH remote attach wins the socket at boot), because
# such a server's panes cannot read the login keychain;
# bin/fm-remote-herdr-owner-lib.sh owns that birth test. Doctor remains
# invokable over the plain-SSH bootstrap path to inspect and repair that worker.
# SSH cannot create an Aqua session, so a host with no GUI login is a human
# gap rather than something --fix attempts to bypass.
#
# Line protocol, one fact per line, stable for script consumers:
#   mode=check|fix
#   path=<the child PATH this command inherited>
#   entrypoint=yes|no
#   platform=darwin|linux|<uname -s>|unknown
#   required <tool>=<path>|MISSING
#   optional <tool>=<path>|absent
#   fix <check>=applied: <what changed>       (--fix only)
#   fix <check>=failed: <why the repair did not land>   (--fix only)
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=fixable: <gap --fix can close>
#   check <check>=human: <gap only a person at that machine can close>
#   action: <check>: <the exact step to take>
# Every check line is authoritative for the moment it printed: under --fix it is
# the state after the repair attempt, so a human gap is never presented as
# fixed. Any remaining fixable or human gap, and any missing required tool,
# exits non-zero.
#
# --fix is idempotent and closes only automatable gaps: it writes and reloads
# both Firstmate-owned Aqua agents, starts the Linux workers where no Aqua agent
# applies, recreates the entrypoint symlink, may add an owned ~/.local/bin
# wrapper for a required tool it can discover under nvm, asdf, or mise, and may
# register or install only the Claude Code marketplaces and plugins named in
# the optional gitignored config/host-plugins.json catalogue (schema:
# docs/configuration.md). It never installs Claude Code itself, never adds a
# marketplace or plugin that is not in that catalogue, never supplies
# credentials, never installs required-tool packages, never creates a login
# session, writes an auto-login password, changes FileVault, stores an account
# password, or replaces a non-Firstmate wrapper; those remain reported gaps.
set -eu

# Resolve this script's directory with builtins only: a host missing a required
# tool must still reach the report that names it, not die on a bare PATH.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"
REQUIRED_TOOLS=(git jq herdr tasks-axi treehouse)
HARNESS_TOOLS=(claude codex opencode pi pi-signed grok kimi)
OPTIONAL_TOOLS=(tmux no-mistakes gh)
LAUNCH_AGENT_LABEL=dev.firstmate.herdr.fm-remote
# The dedicated remote-secondmate session. The user's interactive Herdr work
# remains in the separate default session, which this readiness check never
# requires or changes.
HERDR_SESSION_NAME=fm-remote
LAUNCH_AGENT_DIR="${HOME:-}/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_LOG_DIR="${HOME:-}/Library/Logs"
LAUNCH_AGENT_LOG="$LAUNCH_AGENT_LOG_DIR/$LAUNCH_AGENT_LABEL.log"
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=check
case "${1:-}" in
  '') ;;
  --fix) MODE=fix; shift ;;
  --worker-tool-probe)
    [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || { printf 'error: worker tool probe requires the remote job worker\n' >&2; exit 64; }
    MODE='worker-tool-probe'
    shift
    ;;
  *) usage ;;
esac
[ "$#" -eq 0 ] || usage

PLATFORM=$(fm_remote_job_platform)
UID_NUM=$(id -u 2>/dev/null) || UID_NUM=

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

record() { # <name> <value> [operator-action]
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>; prints the recorded value, empty when unrecorded
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

set_check() { # <name> <value> [operator-action]
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      CHECK_VALUES[i]=$2
      CHECK_ACTIONS[i]=${3:-}
      return 0
    fi
    i=$((i + 1))
  done
  record "$@"
}

herdr_cli_available() {
  local herdr_bin jq_bin
  herdr_bin=$(command -v herdr 2>/dev/null || true)
  jq_bin=$(command -v jq 2>/dev/null || true)
  [ -n "$herdr_bin" ] && [ -x "$herdr_bin" ] && [ -n "$jq_bin" ] && [ -x "$jq_bin" ]
}

# The herdr adapter is the single owner of session-scoped herdr invocation and
# of starting a server, so read and start through it rather than restating
# either here. Sourced only when both tools resolve, so a bare host still
# reports its gaps instead of failing to load.
herdr_adapter_load() {
  [ -z "${FM_REMOTE_DOCTOR_HERDR_LOADED:-}" ] || return 0
  herdr_cli_available || return 1
  [ -f "$SCRIPT_DIR/fm-backend.sh" ] && [ -f "$SCRIPT_DIR/backends/herdr.sh" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh" || return 1
  fm_backend_source herdr || return 1
  FM_REMOTE_DOCTOR_HERDR_LOADED=1
}

herdr_server_status_json() {
  herdr_adapter_load || return 1
  fm_backend_herdr_cli "$HERDR_SESSION_NAME" status --json 2>/dev/null
}

herdr_server_running() {
  local running
  running=$(herdr_server_status_json | jq -r '.server.running // false' 2>/dev/null) || return 1
  [ "$running" = true ]
}

# Birth of the process serving the session, as the guard classifies it:
# prints "<birth> <pid>" (launchd, worker, ssh, or unknown), "unproven" when
# no herdr process can be shown to hold the socket, or "nolsof" when lsof does
# not resolve. bin/fm-remote-herdr-owner-lib.sh owns the markers.
herdr_server_birth() {
  local socket owner rc birth
  socket=$(herdr_server_status_json | jq -r '.server.socket // empty' 2>/dev/null) || socket=
  owner=$(fm_remote_herdr_socket_owner "$socket"); rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'nolsof\n'
    return 0
  fi
  if [ -z "$owner" ]; then
    printf 'unproven\n'
    return 0
  fi
  birth=$(fm_remote_herdr_owner_birth "$owner")
  printf '%s %s\n' "$birth" "$owner"
}

# On darwin the session is ready only when its server was born in the Aqua
# login session; elsewhere any running server is.
herdr_server_aqua_owned() {
  local birth
  herdr_server_running || return 1
  [ "$PLATFORM" = darwin ] || return 0
  birth=$(herdr_server_birth)
  fm_remote_herdr_birth_is_aqua "${birth%% *}"
}

launch_agent_is_aqua() {
  local stripped
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  stripped=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  case "$stripped" in
    *'<key>LimitLoadToSessionType</key><string>Aqua</string>'*) return 0 ;;
  esac
  return 1
}

launch_agent_shell_quote() { # <value>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

launch_agent_xml_escape() { # <value>
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Directory Services UserShell is the account's real login shell on darwin
# (bash, fish, zsh, ...). Fall back without failing the render: $SHELL, then
# /bin/sh. Separate -l and -c so fish accepts the flags.
resolve_launch_agent_shell() {
  local user raw shell
  if [ -n "${FM_LAUNCH_AGENT_SHELL:-}" ] && [ -x "$FM_LAUNCH_AGENT_SHELL" ]; then
    printf '%s' "$FM_LAUNCH_AGENT_SHELL"
    return 0
  fi
  user=$(id -un 2>/dev/null || true)
  if [ -n "$user" ] && command -v dscl >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
    raw=$(perl -e '$SIG{ALRM} = sub { exit 124 }; alarm 2; exec @ARGV' \
      dscl . -read "/Users/$user" UserShell 2>/dev/null || true)
    shell=$(printf '%s\n' "$raw" | awk '
      /^UserShell:[[:space:]]+/ {
        sub(/^UserShell:[[:space:]]+/, "")
        if (length) { print; exit }
      }
    ')
    if [ -n "$shell" ] && [ -x "$shell" ]; then
      printf '%s' "$shell"
      return 0
    fi
  fi
  if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then
    printf '%s' "$SHELL"
    return 0
  fi
  printf '%s' /bin/sh
}

# Login-shell command that execs the Firstmate-owned guard, which in turn execs
# the resolved herdr so launchd keeps one foreground process in the Aqua
# session, or exits 0 when an Aqua-born server already owns the session.
# KeepAlive={SuccessfulExit=false} is load-bearing for that exit: an
# unconditional KeepAlive would respawn the job every throttle interval
# forever while a foreign server holds the socket, exactly the loop this guard
# replaces, and would never let the guard's "nothing to do" verdict rest.
launch_agent_guard_path() {
  printf '%s/bin/fm-remote-herdr-guard.sh' "$FM_ROOT"
}

launch_agent_exec_command() { # <resolved-herdr-path>
  printf 'exec %s %s %s' \
    "$(launch_agent_shell_quote "$(launch_agent_guard_path)")" \
    "$(launch_agent_shell_quote "$1")" \
    "$(launch_agent_shell_quote "$HERDR_SESSION_NAME")"
}

render_launch_agent() { # <resolved-herdr-path> <resolved-login-shell>
  local herdr_bin=$1 shell=$2 exec_cmd shell_xml
  shell_xml=$(launch_agent_xml_escape "$shell")
  exec_cmd=$(launch_agent_exec_command "$herdr_bin")
  cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LAUNCH_AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$shell_xml</string>
		<string>-l</string>
		<string>-c</string>
		<string>$exec_cmd</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>StandardOutPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
	<key>StandardErrorPath</key>
	<string>$LAUNCH_AGENT_LOG</string>
</dict>
</plist>
XML
}

launch_agent_contract_matches() { # <resolved-login-shell>
  local shell=$1 herdr_bin actual expected
  [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ] || return 1
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  actual=$(tr -d ' \t\r\n' < "$LAUNCH_AGENT_PLIST" 2>/dev/null) || return 1
  expected=$(render_launch_agent "$herdr_bin" "$shell" | tr -d ' \t\r\n') || return 1
  [ "$actual" = "$expected" ]
}

launch_agent_loaded_contract_matches() { # <resolved-login-shell>
  local shell=$1 loaded herdr_bin exec_compact shell_compact plist_compact log_compact args
  herdr_bin=$(command -v herdr 2>/dev/null) || return 1
  loaded=$(launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>/dev/null) || return 1
  loaded=$(printf '%s' "$loaded" | tr -d ' \t\r\n') || return 1
  exec_compact=$(launch_agent_exec_command "$herdr_bin" | tr -d ' \t\r\n') || return 1
  shell_compact=$(printf '%s' "$shell" | tr -d ' \t\r\n') || return 1
  plist_compact=$(printf '%s' "$LAUNCH_AGENT_PLIST" | tr -d ' \t\r\n') || return 1
  log_compact=$(printf '%s' "$LAUNCH_AGENT_LOG" | tr -d ' \t\r\n') || return 1
  args="arguments={${shell_compact}-l-c${exec_compact}}"
  [[ "$loaded" == *"path=$plist_compact"* ]] || return 1
  [[ "$loaded" == *"program=$shell_compact"* ]] || return 1
  [[ "$loaded" == *"$args"* ]] || return 1
  [[ "$loaded" == *"stdoutpath=$log_compact"* ]] || return 1
  [[ "$loaded" == *"stderrpath=$log_compact"* ]] || return 1
  # launchd renders KeepAlive={SuccessfulExit=false} as a successful-exit
  # semaphore rather than a keepalive property.
  [[ "$loaded" == *'successfulexit=>0'* ]] || return 1
  [[ "$loaded" == *'properties=runatload'* ]] || return 1
}

# --- remote job and tool checks ---------------------------------------------

remote_job_existing_state() {
  local root
  root=${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}
  root=$(fm_remote_job_canonical_existing_dir "$root") || return 1
  fm_remote_job_canonical_existing_dir "$root/jobs" >/dev/null || return 1
  # shellcheck disable=SC2034 # The sourceable worker helpers consume the validated state root.
  FM_REMOTE_JOB_STATE=$root
}

remote_job_probe_ok() {
  local ready mtime now
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_existing_state || return 1
  ready="$FM_REMOTE_JOB_STATE/worker.ready"
  [ -f "$ready" ] && [ ! -L "$ready" ] || return 1
  mtime=$(fm_remote_job_path_mtime "$ready" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

remote_job_identity_ok() {
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_probe_ok || return 1
  fm_remote_job_worker_identity_matches "$FM_ROOT" "${HOME:-}"
}

check_remote_job_worker() {
  local worker
  worker="$FM_ROOT/bin/fm-remote-job-worker.sh"
  if [ ! -f "$worker" ] || [ -L "$worker" ] || [ ! -x "$worker" ]; then
    record remote-job-worker "human: the configured Firstmate code root has no safe remote job worker" \
      "update the remote Firstmate checkout, then rerun this command with --fix"
    record remote-job-worker-loaded "skip: no worker executable is available"
    record remote-job-probe "skip: no worker executable is available"
    return 0
  fi
  if [ "$PLATFORM" = darwin ]; then
    fm_remote_job_launchagent_paths "${HOME:-}"
    if fm_remote_job_launchagent_contract_matches "$FM_ROOT" "${HOME:-}"; then
      record remote-job-worker "ok: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST matches the Firstmate-owned Aqua worker contract"
    else
      record remote-job-worker "fixable: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST does not match the Firstmate-owned Aqua worker contract" \
        "rerun this command with --fix to write dev.firstmate.remote-job"
    fi
    if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
      record remote-job-worker-loaded "human: the remote job worker cannot be inspected without launchctl and an account uid" \
        "restore launchctl and a readable account uid, then rerun this command"
    elif fm_remote_job_launchagent_loaded "$FM_ROOT" "${HOME:-}" "$UID_NUM"; then
      record remote-job-worker-loaded "ok: $FM_REMOTE_JOB_LABEL is loaded in gui/$UID_NUM"
    elif check_is_ok gui-session; then
      record remote-job-worker-loaded "fixable: $FM_REMOTE_JOB_LABEL is not loaded in gui/$UID_NUM" \
        "rerun this command with --fix to bootstrap the worker"
    else
      record remote-job-worker-loaded "human: $FM_REMOTE_JOB_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
        "close the login-session gap first; SSH cannot create an Aqua session"
    fi
  else
    local pid
    pid=$(cat "${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}/worker.pid" 2>/dev/null || true)
    if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] ||
      { remote_job_existing_state && case "$pid" in ''|*[!0-9]*) false ;; *) kill -0 "$pid" 2>/dev/null ;; esac; }; then
      record remote-job-worker "ok: the Linux remote job worker is running"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    else
      record remote-job-worker "fixable: the Linux remote job worker is not running" \
        "rerun this command with --fix to start it"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    fi
  fi
  if ! remote_job_probe_ok; then
    record remote-job-probe "fixable: the remote job worker has not reported a fresh probe" \
      "rerun this command with --fix to restart the worker, then rerun through fm-on.sh"
  elif ! remote_job_identity_ok; then
    set_check remote-job-worker "fixable: the running remote job worker does not match the current Firstmate code" \
      "rerun this command with --fix to reload the current worker"
    record remote-job-probe "fixable: the remote job worker identity is stale, so its runtime cannot be probed" \
      "rerun this command with --fix to reload the current worker"
  else
    record remote-job-probe "ok: the remote job worker published a fresh heartbeat"
  fi
}

report_required_tools() {
  local tool resolved harness
  MISSING=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      if [ "$tool" = tasks-axi ] && ! fm_tasks_axi_compatible; then
        printf 'required tasks-axi=MISSING (incompatible)\n'
        MISSING+=(tasks-axi)
      else
        printf 'required %s=%s\n' "$tool" "$resolved"
      fi
    else
      printf 'required %s=MISSING\n' "$tool"
      MISSING+=("$tool")
    fi
  done
  for harness in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$harness" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      printf 'required harness=%s:%s\n' "$harness" "$resolved"
      return 0
    fi
  done
  printf 'required harness=MISSING\n'
  MISSING+=(harness)
}

report_required_tools_from_worker() {
  local job_id probe_stdout probe_stderr probe_exit line fact name value
  local expected=6 count=0 valid=1 seen=' '
  if ! job_id=$(fm_remote_job_stage "${HOME:-}" "$FM_ROOT" "${FM_HOME:-}" \
    fm-remote-doctor.sh --worker-tool-probe </dev/null); then
    set_check remote-job-probe "fixable: the remote job worker could not accept the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  if ! fm_remote_job_wait "${HOME:-}" "$job_id"; then
    fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
    set_check remote-job-probe "fixable: the remote job worker did not complete the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  probe_stdout=$FM_REMOTE_JOB_STDOUT
  probe_stderr=$FM_REMOTE_JOB_STDERR
  probe_exit=$FM_REMOTE_JOB_EXIT
  MISSING=()
  while IFS= read -r line; do
    case "$line" in required\ *=*) ;; *) valid=0; continue ;; esac
    fact=${line#required }
    name=${fact%%=*}
    value=${fact#*=}
    case "$name" in git|jq|herdr|tasks-axi|treehouse|harness) ;; *) valid=0; continue ;; esac
    case "$seen" in *" $name "*) valid=0; continue ;; esac
    seen="$seen$name "
    count=$((count + 1))
    case "$value" in MISSING*) MISSING+=("$name") ;; '') valid=0 ;; esac
  done < "$probe_stdout"
  [ "$count" -eq "$expected" ] || valid=0
  [ ! -s "$probe_stderr" ] || valid=0
  case "$probe_exit:${#MISSING[@]}" in 0:0|1:[1-9]*) ;; *) valid=0 ;; esac
  if [ "$valid" -eq 1 ]; then
    cat "$probe_stdout"
    set_check remote-job-probe "ok: the remote job worker completed the required-tool probe"
  else
    set_check remote-job-probe "fixable: the remote job worker returned an invalid required-tool probe result" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
  fi
  fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
}

wrapper_is_firstmate_owned() { # <path>
  local path=$1 first second
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r first < "$path" || return 1
  IFS= read -r second < <(tail -n +2 "$path") || return 1
  [ "$first" = '#!/usr/bin/env bash' ] && [ "$second" = '# Firstmate remote tool wrapper v1' ]
}

repair_tool_wrapper() { # <tool>
  local tool=$1 target wrapper tmp
  local resolved
  resolved=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$resolved" ] && [ -x "$resolved" ] && return 0
  target=$(fm_remote_job_manager_tool "${HOME:-}" "$tool" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  wrapper="${HOME:-}/.local/bin/$tool"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    if ! wrapper_is_firstmate_owned "$wrapper"; then
      fix_report "required-$tool" failed "$wrapper exists and is not Firstmate-owned"
      return 1
    fi
  else
    if ! mkdir -p "${HOME:-}/.local/bin" 2>/dev/null || [ -L "${HOME:-}/.local/bin" ]; then
      fix_report "required-$tool" failed "cannot create ${HOME:-}/.local/bin"
      return 1
    fi
  fi
  tmp="${HOME:-}/.local/bin/.$tool.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Firstmate remote tool wrapper v1'
    printf 'exec %q "$@"\n' "$target"
  } > "$tmp" || { rm -f -- "$tmp"; fix_report "required-$tool" failed "cannot write $wrapper"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp"
    fix_report "required-$tool" failed "cannot publish $wrapper"
    return 1
  fi
  fix_report "required-$tool" applied "linked the discoverable version-manager tool at $wrapper"
}

repair_required_wrappers() {
  local tool resolved
  for tool in "${REQUIRED_TOOLS[@]}"; do
    repair_tool_wrapper "$tool" || true
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    [ -z "$resolved" ] || [ ! -x "$resolved" ] || return 0
  done
  for tool in "${HARNESS_TOOLS[@]}"; do
    fm_remote_job_manager_tool "${HOME:-}" "$tool" >/dev/null 2>&1 || continue
    repair_tool_wrapper "$tool" && return 0
  done
}

fix_remote_job_worker() {
  if fm_remote_job_ensure_worker "$FM_ROOT" "${HOME:-}"; then
    [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ] || fix_report remote-job-worker applied "installed or reloaded $FM_REMOTE_JOB_LABEL"
    return 0
  fi
  fix_report remote-job-worker failed "${FM_REMOTE_JOB_ERROR:-the remote job worker could not start}"
  return 1
}

# --- checks -----------------------------------------------------------------

check_herdr() {
  local resolved selected
  if resolved=$(command -v herdr 2>/dev/null) && [ -x "$resolved" ]; then
    if herdr_adapter_load; then
      fm_backend_herdr_client_select "$HERDR_SESSION_NAME"
      selected=$(fm_backend_herdr_bin)
      if [ "$selected" != herdr ] && [ "$selected" != "$resolved" ]; then
        record herdr "ok: $selected (bypassing $resolved)"
        return 0
      fi
    fi
    record herdr "ok: $resolved"
    return 0
  fi
  record herdr "human: the herdr CLI does not resolve on the remote runtime PATH" \
    "install herdr from https://herdr.dev on that account, or add a ~/.local/bin wrapper for it; a remote second mate always runs on the Herdr backend"
}

check_gui_session() {
  if [ "$PLATFORM" != darwin ]; then
    record gui-session "skip: no Aqua login session applies on $PLATFORM"
    return 0
  fi
  if [ -z "$UID_NUM" ]; then
    record gui-session "human: the account uid could not be read, so its login session cannot be inspected" \
      "run 'id -u' on that account and report the failure; Firstmate cannot address gui/<uid> without it"
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    record gui-session "human: launchctl does not resolve, so the login session cannot be inspected" \
      "restore /bin/launchctl on that macOS account; without it no launch agent can be inspected or loaded"
    return 0
  fi
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    record gui-session "ok: gui/$UID_NUM"
    return 0
  fi
  record gui-session "human: no Aqua login session exists for uid $UID_NUM" \
    "log that account in once at the console, and enable automatic login in System Settings > Users & Groups if the machine runs headless; SSH cannot create a GUI session, and Firstmate never writes an auto-login password or changes FileVault"
}

check_launch_agent() { # <resolved-login-shell>
  local shell=$1
  if [ "$PLATFORM" != darwin ]; then
    record launchagent "skip: launch agents apply only on darwin"
    record launchagent-scope "skip: launch agents apply only on darwin"
    record launchagent-loaded "skip: launch agents apply only on darwin"
    return 0
  fi
  if [ -f "$LAUNCH_AGENT_PLIST" ] && [ ! -L "$LAUNCH_AGENT_PLIST" ]; then
    if launch_agent_contract_matches "$shell"; then
      record launchagent "ok: $LAUNCH_AGENT_PLIST matches the Firstmate-owned contract"
    else
      record launchagent "fixable: $LAUNCH_AGENT_PLIST does not match the current Firstmate-owned contract" \
        "rerun this command with --fix to rewrite its label, program arguments, session scope, restart policy, and log paths"
    fi
    if launch_agent_is_aqua; then
      record launchagent-scope "ok: LimitLoadToSessionType=Aqua"
    else
      record launchagent-scope "fixable: $LAUNCH_AGENT_PLIST is not scoped to the Aqua login session" \
        "rerun this command with --fix to rewrite it with LimitLoadToSessionType=Aqua"
    fi
  else
    record launchagent "fixable: no Firstmate herdr launch agent at $LAUNCH_AGENT_PLIST" \
      "rerun this command with --fix to install it"
    record launchagent-scope "skip: no launch agent is installed yet"
  fi
  check_launch_agent_loaded "$shell"
}

check_launch_agent_loaded() { # <resolved-login-shell>
  local shell=$1
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    record launchagent-loaded "human: the launch agent domain gui/<uid> cannot be inspected on this account" \
      "restore launchctl and a readable account uid, then rerun this command"
    return 0
  fi
  if launchctl print "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1; then
    if launch_agent_loaded_contract_matches "$shell"; then
      record launchagent-loaded "ok: gui/$UID_NUM/$LAUNCH_AGENT_LABEL matches the effective contract"
    else
      record launchagent-loaded "fixable: gui/$UID_NUM/$LAUNCH_AGENT_LABEL does not match the effective Firstmate-owned contract" \
        "rerun this command with --fix to replace the loaded job with the current launch-agent contract"
    fi
    return 0
  fi
  if check_is_ok gui-session; then
    record launchagent-loaded "fixable: $LAUNCH_AGENT_LABEL is not loaded into gui/$UID_NUM" \
      "rerun this command with --fix to bootstrap and start it"
    return 0
  fi
  record launchagent-loaded "human: $LAUNCH_AGENT_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
    "close the login-session gap first; a launch agent can only be bootstrapped into an existing GUI session"
}

check_herdr_server() {
  if ! herdr_cli_available; then
    record herdr-server "human: herdr server status cannot be read without both herdr and jq on the runtime PATH" \
      "install the missing tool reported above, then rerun this command"
    return 0
  fi
  if herdr_server_running; then
    if [ "$PLATFORM" != darwin ]; then
      record herdr-server "ok: session $HERDR_SESSION_NAME is running"
      return 0
    fi
    local birth
    birth=$(herdr_server_birth)
    case "$birth" in
      launchd\ *|worker\ *)
        record herdr-server "ok: session $HERDR_SESSION_NAME is running in the Aqua login session (pid ${birth#* }, ${birth%% *})"
        ;;
      nolsof)
        record herdr-server "human: session $HERDR_SESSION_NAME is running but lsof does not resolve, so its server's birth cannot be proven" \
          "install lsof on that account so the launch agent and this check can tell an Aqua-born server from one started over SSH"
        ;;
      unproven)
        record herdr-server "fixable: session $HERDR_SESSION_NAME is running but no herdr process can be shown to own its socket, so its birth cannot be proven" \
          "rerun this command with --fix so the launch agent takes the session over (its current panes close and the parent firstmate relaunches its mates)"
        ;;
      *)
        record herdr-server "fixable: session $HERDR_SESSION_NAME is served by pid ${birth#* } born outside the Aqua login session (${birth%% *}), so its panes cannot reach the login keychain" \
          "rerun this command with --fix so the launch agent takes the session over (its current panes close and the parent firstmate relaunches its mates)"
        ;;
    esac
    return 0
  fi
  if [ "$PLATFORM" = darwin ] && ! check_is_ok gui-session; then
    record herdr-server "human: the herdr server for session $HERDR_SESSION_NAME is not running and there is no GUI login session to start it in" \
      "close the login-session gap first; a server started over SSH would not belong to an Aqua session"
    return 0
  fi
  record herdr-server "fixable: the herdr server for session $HERDR_SESSION_NAME is not running" \
    "rerun this command with --fix to start it"
}

check_entrypoint_link() {
  local want
  if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
    record entrypoint-link "skip: this run did not come through the fixed remote entrypoint"
    return 0
  fi
  want="$FM_ROOT_OVERRIDE/bin/fm-remote-entrypoint.sh"
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record entrypoint-link "ok: $ENTRYPOINT_LINK"
    return 0
  fi
  if [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record entrypoint-link "human: $ENTRYPOINT_LINK exists but is not the symlink to $want" \
      "inspect that path yourself and replace it with 'ln -sfn $want $ENTRYPOINT_LINK' if it is stale; Firstmate never overwrites a file it did not create there"
    return 0
  fi
  record entrypoint-link "fixable: no entrypoint symlink at $ENTRYPOINT_LINK" \
    "rerun this command with --fix to create it"
}

# Optional Claude Code plugin catalogue from gitignored config/host-plugins.json.
# Absent, unreadable-as-absent, or empty of work is skip/ok; the schema is owned
# by docs/configuration.md. HOST_PLUGINS_AUTH_ITEMS remembers marketplace names
# or plugin@marketplace ids whose --fix clone or install failed on authentication
# so the post-repair re-check reports a human gap instead of a loop of fixable.
HOST_PLUGINS_AUTH_ITEMS=

host_plugins_config_path() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s/host-plugins.json' "${FM_CONFIG_OVERRIDE%/}"
    return 0
  fi
  [ -n "${FM_HOME:-}" ] || return 1
  printf '%s/config/host-plugins.json' "${FM_HOME%/}"
}

host_plugins_auth_failure() { # <text>
  printf '%s' "$1" | grep -qiE 'auth(enticat|orization)|permission denied|could not read (username|password)|terminal prompts disabled|denied \(publickey\)|(^|[[:space:]])(401|403)([[:space:]]|$)'
}

host_plugins_in_auth_items() { # <id>
  local id=$1 item
  for item in $HOST_PLUGINS_AUTH_ITEMS; do
    [ "$item" = "$id" ] && return 0
  done
  return 1
}

host_plugins_note_auth() { # <id>
  host_plugins_in_auth_items "$1" && return 0
  HOST_PLUGINS_AUTH_ITEMS="${HOST_PLUGINS_AUTH_ITEMS:+$HOST_PLUGINS_AUTH_ITEMS }$1"
}

host_plugins_parse_catalogue() { # <path>
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print("ERROR cannot parse JSON: %s" % exc)
    sys.exit(0)
if not isinstance(data, dict):
    print("ERROR catalogue must be a JSON object")
    sys.exit(0)
if "marketplaces" not in data or "plugins" not in data:
    print("ERROR catalogue must contain marketplaces and plugins arrays")
    sys.exit(0)
if not isinstance(data["marketplaces"], list) or not isinstance(data["plugins"], list):
    print("ERROR marketplaces and plugins must be arrays")
    sys.exit(0)
seen_mp = set()
for index, marketplace in enumerate(data["marketplaces"]):
    if not isinstance(marketplace, dict):
        print("ERROR marketplaces[%d] must be an object" % index)
        sys.exit(0)
    name = marketplace.get("name")
    source = marketplace.get("source")
    if not isinstance(name, str) or not name.strip() or not isinstance(source, str) or not source.strip():
        print("ERROR marketplaces[%d] needs nonempty name and source strings" % index)
        sys.exit(0)
    name = name.strip()
    source = source.strip()
    if any(char in name or char in source for char in "\n\r\t"):
        print("ERROR marketplaces[%d] name or source contains a control character" % index)
        sys.exit(0)
    if name in seen_mp:
        print("ERROR duplicate marketplace name: %s" % name)
        sys.exit(0)
    seen_mp.add(name)
    print("MARKETPLACE\t%s\t%s" % (name, source))
seen_plugin = set()
for index, plugin in enumerate(data["plugins"]):
    if not isinstance(plugin, str):
        print("ERROR plugins[%d] must be a plugin@marketplace string" % index)
        sys.exit(0)
    plugin = plugin.strip()
    if plugin.count("@") != 1:
        print("ERROR plugins[%d] must be plugin@marketplace" % index)
        sys.exit(0)
    name, marketplace = plugin.split("@", 1)
    if not name or not marketplace:
        print("ERROR plugins[%d] must be plugin@marketplace" % index)
        sys.exit(0)
    if marketplace not in seen_mp:
        print("ERROR plugin %s names marketplace %s which is not in marketplaces" % (plugin, marketplace))
        sys.exit(0)
    if plugin in seen_plugin:
        print("ERROR duplicate plugin: %s" % plugin)
        sys.exit(0)
    seen_plugin.add(plugin)
    print("PLUGIN\t%s\t%s" % (name, marketplace))
print("OK")
PY
}

host_plugins_claude() {
  GIT_TERMINAL_PROMPT=0 command claude "$@" </dev/null
}

host_plugins_marketplace_names() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if isinstance(item, dict):
        name = item.get("name") or ""
        if name:
            print(name)
'
}

host_plugins_plugin_rows() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if not isinstance(item, dict):
        continue
    pid = item.get("id") or ""
    if not pid:
        continue
    enabled = "1" if item.get("enabled") is True else "0"
    scope = item.get("scope") or ""
    print("%s\t%s\t%s" % (pid, enabled, scope))
'
}

host_plugins_first_skill() {
  python3 -c '
import re, sys
text = sys.stdin.read()
match = re.search(r"(?im)^\s*Skills\s*\((\d+)\)\s*(.*)$", text)
if not match or int(match.group(1)) < 1:
    sys.exit(1)
names = [name.strip() for name in match.group(2).split(",") if name.strip()]
if not names:
    sys.exit(1)
print(names[0])
'
}

host_plugins_user_plugin_state() { # <plugin@marketplace> <rows> -> prints enabled|disabled|missing
  local id=$1 rows=$2 line pid enabled scope
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=${line%%$'\t'*}
    rest=${line#*$'\t'}
    enabled=${rest%%$'\t'*}
    scope=${rest#*$'\t'}
    [ "$pid" = "$id" ] || continue
    [ "$scope" = user ] || continue
    if [ "$enabled" = 1 ]; then
      printf 'enabled\n'
    else
      printf 'disabled\n'
    fi
    return 0
  done <<EOF
$rows
EOF
  printf 'missing\n'
}

check_host_plugins() {
  local path parsed line name source plugin marketplace claude_bin rest id
  local mp_json mp_names plugin_json plugin_rows state details i
  local missing_mp=() missing_plugin=() disabled_plugin=() unresolved=() auth_human=()
  local -a marketplaces_n=() marketplaces_s=() plugins_n=() plugins_m=()
  if ! path=$(host_plugins_config_path); then
    record host-plugins "skip: no host plugin catalogue is configured"
    return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    record host-plugins "skip: no host plugin catalogue is configured"
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    record host-plugins "human: $path exists but is not a regular file" \
      "replace it with a regular config/host-plugins.json; Firstmate never follows a symlink there"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    record host-plugins "human: python3 does not resolve, so the host plugin catalogue cannot be read" \
      "install python3 on that account, then rerun this command"
    return 0
  fi
  parsed=$(host_plugins_parse_catalogue "$path") || parsed="ERROR cannot parse the host plugin catalogue"
  case "$parsed" in
    ERROR*)
      record host-plugins "human: $path is not a usable host plugin catalogue (${parsed#ERROR })" \
        "correct config/host-plugins.json against docs/configuration.md, then rerun this command"
      return 0
      ;;
  esac
  case "$parsed" in
    OK|*$'\n'OK) ;;
    *)
      record host-plugins "human: $path is not a usable host plugin catalogue" \
        "correct config/host-plugins.json against docs/configuration.md, then rerun this command"
      return 0
      ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      MARKETPLACE$'\t'*)
        rest=${line#MARKETPLACE$'\t'}
        name=${rest%%$'\t'*}
        source=${rest#*$'\t'}
        marketplaces_n+=("$name")
        marketplaces_s+=("$source")
        ;;
      PLUGIN$'\t'*)
        rest=${line#PLUGIN$'\t'}
        plugin=${rest%%$'\t'*}
        marketplace=${rest#*$'\t'}
        plugins_n+=("$plugin")
        plugins_m+=("$marketplace")
        ;;
    esac
  done <<EOF
$parsed
EOF
  if [ "${#marketplaces_n[@]}" -eq 0 ] && [ "${#plugins_n[@]}" -eq 0 ]; then
    record host-plugins "ok: host plugin catalogue is empty"
    return 0
  fi
  claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -z "$claude_bin" ] || [ ! -x "$claude_bin" ]; then
    record host-plugins "human: the claude CLI does not resolve, so the configured plugin catalogue cannot be checked" \
      "install Claude Code on that account so its plugin CLI is on PATH; Firstmate does not install Claude Code"
    return 0
  fi
  if ! mp_json=$(host_plugins_claude plugin marketplace list --json 2>/dev/null); then
    record host-plugins "human: claude plugin marketplace list --json failed, so configured marketplaces cannot be checked" \
      "repair the claude CLI on that account, then rerun this command"
    return 0
  fi
  if ! mp_names=$(printf '%s' "$mp_json" | host_plugins_marketplace_names); then
    record host-plugins "human: claude plugin marketplace list --json was not usable JSON" \
      "repair the claude CLI on that account, then rerun this command"
    return 0
  fi
  if ! plugin_json=$(host_plugins_claude plugin list --json 2>/dev/null); then
    record host-plugins "human: claude plugin list --json failed, so configured plugins cannot be checked" \
      "repair the claude CLI on that account, then rerun this command"
    return 0
  fi
  if ! plugin_rows=$(printf '%s' "$plugin_json" | host_plugins_plugin_rows); then
    record host-plugins "human: claude plugin list --json was not usable JSON" \
      "repair the claude CLI on that account, then rerun this command"
    return 0
  fi
  local i=0
  while [ "$i" -lt "${#marketplaces_n[@]}" ]; do
    name=${marketplaces_n[$i]}
    case $'\n'"$mp_names"$'\n' in
      *$'\n'"$name"$'\n'*) ;;
      *)
        if host_plugins_in_auth_items "$name"; then
          auth_human+=("marketplace $name")
        else
          missing_mp+=("$name")
        fi
        ;;
    esac
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt "${#plugins_n[@]}" ]; do
    plugin=${plugins_n[$i]}
    marketplace=${plugins_m[$i]}
    id="$plugin@$marketplace"
    state=$(host_plugins_user_plugin_state "$id" "$plugin_rows")
    case "$state" in
      missing)
        if host_plugins_in_auth_items "$id"; then
          auth_human+=("plugin $id")
        else
          missing_plugin+=("$id")
        fi
        ;;
      disabled) disabled_plugin+=("$id") ;;
      enabled)
        if details=$(host_plugins_claude plugin details -- "$id" 2>/dev/null) &&
          printf '%s' "$details" | host_plugins_first_skill >/dev/null; then
          :
        else
          unresolved+=("$id")
        fi
        ;;
    esac
    i=$((i + 1))
  done
  if [ "${#auth_human[@]}" -gt 0 ]; then
    record host-plugins "human: configured Claude Code plugins could not be registered because git authentication failed (${auth_human[*]})" \
      "authenticate git access to the configured marketplace source on that account without supplying credentials to Firstmate, then rerun this command with --fix"
    return 0
  fi
  if [ "${#missing_mp[@]}" -gt 0 ]; then
    record host-plugins "fixable: configured marketplace is not registered (${missing_mp[*]})" \
      "rerun this command with --fix to register the configured marketplace"
    return 0
  fi
  if [ "${#missing_plugin[@]}" -gt 0 ]; then
    record host-plugins "fixable: configured plugin is not installed (${missing_plugin[*]})" \
      "rerun this command with --fix to install the configured plugin"
    return 0
  fi
  if [ "${#disabled_plugin[@]}" -gt 0 ]; then
    record host-plugins "fixable: configured plugin is installed but disabled (${disabled_plugin[*]})" \
      "rerun this command with --fix to enable the configured plugin"
    return 0
  fi
  if [ "${#unresolved[@]}" -gt 0 ]; then
    record host-plugins "human: configured plugin is installed but no skill resolves (${unresolved[*]}); a skill present but not resolving is the same as absent" \
      "inspect claude plugin details for each named plugin on that account; Firstmate does not treat install success as proof"
    return 0
  fi
  record host-plugins "ok: configured Claude Code plugins resolve on this host"
}

fix_host_plugins() {
  local path parsed line name source plugin marketplace id out rc i rest
  local mp_json mp_names plugin_json plugin_rows state
  local -a marketplaces_n=() marketplaces_s=() plugins_n=() plugins_m=()
  path=$(host_plugins_config_path) || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  command -v claude >/dev/null 2>&1 || return 0
  parsed=$(host_plugins_parse_catalogue "$path") || return 0
  case "$parsed" in OK|*$'\n'OK) ;; *) return 0 ;; esac
  while IFS= read -r line; do
    case "$line" in
      MARKETPLACE$'\t'*)
        rest=${line#MARKETPLACE$'\t'}
        name=${rest%%$'\t'*}
        source=${rest#*$'\t'}
        marketplaces_n+=("$name")
        marketplaces_s+=("$source")
        ;;
      PLUGIN$'\t'*)
        rest=${line#PLUGIN$'\t'}
        plugin=${rest%%$'\t'*}
        marketplace=${rest#*$'\t'}
        plugins_n+=("$plugin")
        plugins_m+=("$marketplace")
        ;;
    esac
  done <<EOF
$parsed
EOF
  if ! mp_json=$(host_plugins_claude plugin marketplace list --json 2>/dev/null); then
    fix_report host-plugins failed "claude plugin marketplace list --json failed"
    return 1
  fi
  if ! mp_names=$(printf '%s' "$mp_json" | host_plugins_marketplace_names); then
    fix_report host-plugins failed "claude plugin marketplace list --json was not usable JSON"
    return 1
  fi
  local i=0
  while [ "$i" -lt "${#marketplaces_n[@]}" ]; do
    name=${marketplaces_n[$i]}
    source=${marketplaces_s[$i]}
    i=$((i + 1))
    case $'\n'"$mp_names"$'\n' in *$'\n'"$name"$'\n'*) continue ;; esac
    set +e
    out=$(host_plugins_claude plugin marketplace add -- "$source" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      mp_names="$mp_names"$'\n'"$name"
      fix_report host-plugins applied "registered marketplace $name"
      continue
    fi
    if host_plugins_auth_failure "$out"; then
      host_plugins_note_auth "$name"
      fix_report host-plugins failed "registering marketplace $name failed on authentication; authenticate git access to $source on that account without supplying credentials to Firstmate, then rerun this command with --fix"
      continue
    fi
    fix_report host-plugins failed "registering marketplace $name from $source failed: ${out:-no diagnostic}"
  done
  if ! plugin_json=$(host_plugins_claude plugin list --json 2>/dev/null); then
    fix_report host-plugins failed "claude plugin list --json failed"
    return 1
  fi
  if ! plugin_rows=$(printf '%s' "$plugin_json" | host_plugins_plugin_rows); then
    fix_report host-plugins failed "claude plugin list --json was not usable JSON"
    return 1
  fi
  i=0
  while [ "$i" -lt "${#plugins_n[@]}" ]; do
    plugin=${plugins_n[$i]}
    marketplace=${plugins_m[$i]}
    id="$plugin@$marketplace"
    i=$((i + 1))
    case $'\n'"$mp_names"$'\n' in *$'\n'"$marketplace"$'\n'*) ;; *) continue ;; esac
    state=$(host_plugins_user_plugin_state "$id" "$plugin_rows")
    case "$state" in
      enabled) continue ;;
      disabled)
        set +e
        out=$(host_plugins_claude plugin enable --scope user -- "$id" 2>&1)
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
          fix_report host-plugins applied "enabled $id"
        else
          fix_report host-plugins failed "enabling $id failed: ${out:-no diagnostic}"
        fi
        continue
        ;;
    esac
    set +e
    out=$(host_plugins_claude plugin install --scope user --yes -- "$id" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      plugin_rows="$plugin_rows"$'\n'"$id"$'\t'"1"$'\t'"user"
      fix_report host-plugins applied "installed $id"
      continue
    fi
    if host_plugins_auth_failure "$out"; then
      host_plugins_note_auth "$id"
      fix_report host-plugins failed "installing $id failed on authentication; authenticate git access for that marketplace on that account without supplying credentials to Firstmate, then rerun this command with --fix"
      continue
    fi
    fix_report host-plugins failed "installing $id failed: ${out:-no diagnostic}"
  done
}

run_checks() { # <resolved-login-shell>
  local shell=$1
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_herdr
  check_gui_session
  check_remote_job_worker
  check_launch_agent "$shell"
  check_herdr_server
  check_entrypoint_link
  check_host_plugins
}

# --- repairs ----------------------------------------------------------------

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

write_launch_agent() { # <resolved-login-shell>
  local shell=$1 herdr_bin tmp
  if ! herdr_bin=$(command -v herdr 2>/dev/null); then
    fix_report launchagent failed "herdr does not resolve, so no launch agent was written"
    return 1
  fi
  case "$herdr_bin" in
    *'&'*|*'<'*|*'>'*|*'"'*|*"'"*)
      fix_report launchagent failed "the resolved herdr path contains characters that cannot be embedded in a property list: $herdr_bin"
      return 1
      ;;
  esac
  if ! mkdir -p "$LAUNCH_AGENT_DIR" 2>/dev/null; then
    fix_report launchagent failed "cannot create $LAUNCH_AGENT_DIR"
    return 1
  fi
  mkdir -p "$LAUNCH_AGENT_LOG_DIR" 2>/dev/null || true
  tmp="$LAUNCH_AGENT_DIR/.$LAUNCH_AGENT_LABEL.plist.tmp.$$"
  render_launch_agent "$herdr_bin" "$shell" > "$tmp"
  chmod 0644 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$LAUNCH_AGENT_PLIST" 2>/dev/null; then
    rm -f -- "$tmp"
    fix_report launchagent failed "cannot publish $LAUNCH_AGENT_PLIST"
    return 1
  fi
  fix_report launchagent applied "wrote the Aqua-scoped $LAUNCH_AGENT_LABEL launch agent running $(launch_agent_guard_path) for $herdr_bin via $shell -l -c"
}

# Reload rather than plain bootstrap so a rewritten plist replaces a stale
# in-memory copy, and kickstart so the server is running now rather than at the
# next login. Both are safe to repeat.
reload_launch_agent() { # <check-to-report-under>
  local report=$1 out
  [ -f "$LAUNCH_AGENT_PLIST" ] || {
    fix_report "$report" failed "there is no launch agent to load at $LAUNCH_AGENT_PLIST"
    return 1
  }
  if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
    fix_report "$report" failed "launchctl or the account uid is unavailable"
    return 1
  fi
  launchctl bootout "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  if ! out=$(launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT_PLIST" 2>&1); then
    fix_report "$report" failed "launchctl bootstrap gui/$UID_NUM refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! out=$(launchctl kickstart -k "gui/$UID_NUM/$LAUNCH_AGENT_LABEL" 2>&1); then
    fix_report "$report" failed "launchctl kickstart gui/$UID_NUM/$LAUNCH_AGENT_LABEL refused: ${out:-no diagnostic}"
    return 1
  fi
  if ! wait_for_herdr_server; then
    fix_report "$report" failed "the herdr server for session $HERDR_SESSION_NAME did not come up inside the Aqua launch agent within 10s"
    return 1
  fi
  fix_report "$report" applied "bootstrapped and started $LAUNCH_AGENT_LABEL in gui/$UID_NUM"
}

wait_for_herdr_server() {
  local i=0
  while [ "$i" -lt 20 ]; do
    herdr_server_aqua_owned && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

start_herdr_server() {
  if ! herdr_adapter_load; then
    fix_report herdr-server failed "herdr and jq must both resolve before the server can be started"
    return 1
  fi
  if fm_backend_herdr_server_ensure "$HERDR_SESSION_NAME" >/dev/null 2>&1; then
    fix_report herdr-server applied "started the herdr server for session $HERDR_SESSION_NAME"
    return 0
  fi
  fix_report herdr-server failed "the herdr server for session $HERDR_SESSION_NAME did not come up"
  return 1
}

link_entrypoint() {
  local want="${FM_ROOT_OVERRIDE:-}/bin/fm-remote-entrypoint.sh"
  if ! mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create $(dirname "$ENTRYPOINT_LINK")"
    return 1
  fi
  if ! ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create the symlink at $ENTRYPOINT_LINK"
    return 1
  fi
  fix_report entrypoint-link applied "linked $ENTRYPOINT_LINK to $want"
}

apply_fixes() { # <resolved-login-shell>
  local shell=$1 i name value launch_agent_written=0 launch_agent_reloaded=0 remote_job_fixed=0
  repair_required_wrappers
  i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    name=${CHECK_NAMES[$i]}
    value=${CHECK_VALUES[$i]}
    i=$((i + 1))
    case "$value" in fixable:*) ;; *) continue ;; esac
    case "$name" in
      remote-job-worker|remote-job-worker-loaded|remote-job-probe)
        [ "$remote_job_fixed" -eq 0 ] || continue
        remote_job_fixed=1
        fix_remote_job_worker || true
        ;;
      launchagent|launchagent-scope)
        [ "$launch_agent_written" -eq 0 ] || continue
        launch_agent_written=1
        write_launch_agent "$shell" || continue
        # A freshly written plist runs nothing until it is (re)loaded, and only
        # an existing GUI session can hold it.
        check_is_ok gui-session || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      launchagent-loaded)
        [ "$launch_agent_reloaded" -eq 0 ] || continue
        launch_agent_reloaded=1
        reload_launch_agent launchagent-loaded || true
        ;;
      herdr-server)
        # On darwin the launch agent owns the server, so restart it through
        # launchd rather than starting a stray one outside the Aqua session. A
        # reload earlier in this same pass has already done that.
        if [ "$PLATFORM" = darwin ] && [ -f "$LAUNCH_AGENT_PLIST" ] && check_is_ok gui-session; then
          [ "$launch_agent_reloaded" -eq 0 ] || continue
          launch_agent_reloaded=1
          reload_launch_agent herdr-server || true
          continue
        fi
        start_herdr_server || true
        ;;
      entrypoint-link) link_entrypoint || true ;;
      host-plugins) fix_host_plugins || true ;;
    esac
  done
}

# --- report -----------------------------------------------------------------

if [ "$MODE" = worker-tool-probe ]; then
  report_required_tools
  [ "${#MISSING[@]}" -eq 0 ]
  exit
fi

printf 'mode=%s\n' "$MODE"
printf 'path=%s\n' "${PATH:-}"
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi
printf 'platform=%s\n' "$PLATFORM"

LAUNCH_AGENT_SHELL=
if [ "$PLATFORM" = darwin ]; then
  LAUNCH_AGENT_SHELL=$(resolve_launch_agent_shell)
fi
run_checks "$LAUNCH_AGENT_SHELL"
if [ "$MODE" = fix ]; then
  apply_fixes "$LAUNCH_AGENT_SHELL"
  # Re-derive every check from the host itself, so what prints below is the
  # state after repair rather than the intent of a repair.
  run_checks "$LAUNCH_AGENT_SHELL"
fi

if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || ! remote_job_identity_ok; then
  report_required_tools
else
  report_required_tools_from_worker
fi
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in
    fixable:*|human:*) GAPS+=("$i") ;;
  esac
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
fi
if [ "${#MISSING[@]}" -gt 0 ] || [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in ${GAPS[@]+"${GAPS[@]}"}; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'error: this host is not ready for a remote second mate%s\n' "${NAMES:+; unresolved: $NAMES}" >&2
  exit 1
fi
printf 'ok: remote second-mate readiness confirmed on this host\n'
