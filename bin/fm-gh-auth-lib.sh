#!/usr/bin/env bash
# Repository-scoped GitHub authentication helpers.
#
# Usage: . bin/fm-gh-auth-lib.sh
#        fm_gh_run <repository-owner> <command> [args...]
#
# config/gh-accounts maps a GitHub repository owner to the gh login that owns
# its token. Each non-comment line is either "<owner> <login>" or
# "default <login>". A caller-provided GH_TOKEN always wins. When no matching
# owner or default exists, the child inherits gh's active-account behavior.

fm_gh_config_dir() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "${FM_CONFIG_OVERRIDE%/}"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/config\n' "${FM_HOME%/}"
  fi
}

fm_gh_account_for_owner() {  # <owner>
  local owner=$1 cfg key login extra fallback='' owner_key key_key
  owner_key=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]') || return 1
  cfg=$(fm_gh_config_dir) || return 0
  [ -n "$cfg" ] && [ -f "$cfg/gh-accounts" ] && [ ! -L "$cfg/gh-accounts" ] || return 0
  while IFS=' ' read -r key login extra || [ -n "${key:-}${login:-}${extra:-}" ]; do
    key_key=$(printf '%s' "${key:-}" | tr '[:upper:]' '[:lower:]') || return 1
    case "$key_key" in
      ''|'#'*) continue ;;
      default)
        [ -n "${login:-}" ] && [ -z "${extra:-}" ] && fallback=$login
        ;;
      "$owner_key")
        [ -n "${login:-}" ] && [ -z "${extra:-}" ] && { printf '%s\n' "$login"; return 0; }
        ;;
    esac
  done < "$cfg/gh-accounts"
  [ -z "$fallback" ] || printf '%s\n' "$fallback"
}

fm_gh_run() {  # <repository-owner> <command> [args...]
  local owner=${1-} login token
  shift || return 2
  [ "$#" -gt 0 ] || return 2
  if [ -n "${GH_TOKEN:-}" ]; then
    "$@"
    return
  fi
  login=$(fm_gh_account_for_owner "$owner") || return 1
  if [ -z "$login" ]; then
    "$@"
    return
  fi
  if ! token=$(gh auth token --user "$login" 2>/dev/null) || [ -z "$token" ]; then
    printf 'error: cannot read the GitHub token for mapped login %s; authenticate it with gh auth login --user %s\n' "$login" "$login" >&2
    return 1
  fi
  GH_TOKEN=$token "$@"
}
