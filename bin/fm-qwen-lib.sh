#!/usr/bin/env bash
# Qwen Code process identity and launch preflight.
# Sourced by bin/backends/tmux.sh, bin/fm-spawn.sh, and bin/fm-control.sh. This
# file is sourced by scripts and has no side effects on source.
#
# Why one owner: Qwen Code 0.23.0 ships as a node bundle, so a live qwen pane
# presents as an interpreter and nothing about its command NAME says qwen.
# Measured on qwen 0.23.0 with Node v26.7.0 on Linux, one worker's foreground
# process group read:
#
#   comm  : node-MainThread
#   argv0 : node  (or /home/<user>/.hermes/node/bin/node)
#   args  : node /home/<user>/.local/bin/qwen -y
#           or node .../@qwen-code/qwen-code/cli.js -y
#
# `comm` is node-MainThread because modern Node renames its main thread, and
# argv[0] is the interpreter. Only the script argument carries the identity, so
# the liveness classifier has to read the arguments rather than the name. This
# is the same hazard bin/fm-gemini-lib.sh exists to close for gemini-cli, and
# the rule here is deliberately the same shape: structural only, no subprocess,
# because probing a stranger's binary during a liveness poll is exactly what
# must not happen.
#
# Detection of firstmate's OWN harness uses these structural rules for the
# ancestry fallback. The QWEN_CODE=1 environment marker in bin/fm-harness.sh
# remains the load-bearing path for tool subprocesses; hook processes inherit
# QWEN_CODE_CLI but not QWEN_CODE=1 (verified, qwen 0.23.0).

fm_qwen_auth_preflight() {
  if [ "${QWEN_DEFAULT_AUTH_TYPE:-}" != openai ]; then
    echo "error: qwen-auth-unavailable: QWEN_DEFAULT_AUTH_TYPE must be openai for the verified non-interactive credential path" >&2
    return 1
  fi
  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "error: qwen-auth-unavailable: OPENAI_API_KEY is required for the verified non-interactive credential path" >&2
    return 1
  fi
  return 0
}

fm_qwen_resolve_executable() {
  local candidate dir
  candidate=$(type -P -- qwen 2>/dev/null) || return 1
  [ -x "$candidate" ] || return 1
  case "$candidate" in
    /*) printf '%s\n' "$candidate" ;;
    *)
      dir=$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P) || return 1
      printf '%s/%s\n' "$dir" "$(basename "$candidate")"
      ;;
  esac
}

fm_qwen_platform_preflight() {
  local os
  os=$(uname -s 2>/dev/null) || os=
  if [ "$os" != Linux ]; then
    echo "error: qwen-platform-unsupported: the qwen adapter is verified on Linux only (this host reports '${os:-unknown}'); its process-identity liveness needs /proc argv boundaries, so select a different verified harness" >&2
    return 1
  fi
}

fm_qwen_launch_preflight() {
  fm_qwen_platform_preflight || return 1
  fm_qwen_auth_preflight || return 1
  if ! fm_qwen_resolve_executable; then
    echo "error: qwen-executable-unavailable: qwen executable not found on PATH; install Qwen Code or select a different verified harness" >&2
    return 1
  fi
}

# True when path $1 carries Qwen Code's own structural evidence: the file is
# named qwen, or it sits inside the published @qwen-code/qwen-code package
# tree. A directory component merely named `qwen` is never enough on its own,
# and a bare interpreter is always rejected.
fm_qwen_path_is_qwen() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    qwen) return 0 ;;
  esac
  case "$path" in
    */@qwen-code/qwen-code/*) return 0 ;;
  esac
  return 1
}

# True when process $1 has Qwen Code's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves a script path containing spaces
# that `ps -o args=` necessarily flattens into an ambiguous string.
fm_qwen_pid_is_qwen() {  # <pid>
  local pid=$1 token argv0='' index=0
  [ -r "/proc/$pid/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    if [ "$index" -eq 0 ]; then
      argv0=$token
      fm_qwen_path_is_qwen "$argv0" && return 0
      case "${argv0##*/}" in
        node|node-*|node[0-9]*|MainThread) ;;
        *) return 1 ;;
      esac
    else
      case "$token" in
        -*) ;;
        *) fm_qwen_path_is_qwen "$token" && return 0; return 1 ;;
      esac
    fi
    index=$((index + 1))
  done < "/proc/$pid/cmdline"
  return 1
}

# True when the whitespace-separated command line $1 is a Qwen Code process.
#
# Accepted: a command whose own argv[0] is qwen (a future natively-named
# binary), and an interpreter whose first non-flag argument is Qwen's script
# or package path.
#
# Rejected: a bare interpreter with no qwen argument, and any command line
# whose only mention of qwen is a later flag value, a working directory, or a
# prompt string - only argv[0] and the script argument are ever consulted, so
# an unrelated command that merely TALKS about qwen never matches.
fm_qwen_args_are_qwen() {  # <args>
  local args=$1 argv0 rest token
  [ -n "$args" ] || return 1
  args=${args#"${args%%[![:space:]]*}"}
  argv0=${args%%[[:space:]]*}
  fm_qwen_path_is_qwen "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  rest=${args#"$argv0"}
  # The first non-flag token after the interpreter is the script it runs.
  # Node's own options are skipped so `node --expose-gc <script>` - the exact
  # shape the installed launcher execs - still resolves.
  while [ -n "$rest" ]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    [ -n "$rest" ] || break
    token=${rest%%[[:space:]]*}
    rest=${rest#"$token"}
    case "$token" in
      -*) continue ;;
    esac
    fm_qwen_path_is_qwen "$token" && return 0
    return 1
  done
  return 1
}
