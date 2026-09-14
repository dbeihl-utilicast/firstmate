#!/usr/bin/env bash
# Local pre-push refusal of the unguarded delivery route.
# Usage: fm-origin-push-guard.sh install [repo]
#        fm-origin-push-guard.sh   (git pre-push hook: <remote-name> <remote-url>)
#
# When this checkout has a `no-mistakes` remote, refuse `git push` to any other
# remote and print `git push no-mistakes`. A checkout without that remote is
# unchanged, including the public template.
# Git's `pre-push` protocol is the public interface: two arguments (destination
# name and URL) plus ref lines on stdin. Session-start bootstrap installs this
# script into the checkout's effective hooks directory when that directory is
# inside the clone, chaining any existing `pre-push` rather than replacing it.
# It never writes outside the clone, never sets `core.hooksPath`, and never
# changes GitHub repository settings.
# Deliberate escapes: `git push --no-verify` skips every local hook, including
# this one; `FM_ALLOW_UNGUARDED_PUSH=1` skips only this refusal and still runs
# a chained pre-push.
# FIRSTMATE_ORIGIN_PUSH_GUARD_V1
set -u

SELF=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")
MARKER='FIRSTMATE_ORIGIN_PUSH_GUARD_V1'
PREV_NAME=pre-push.fm-prev

usage() {
  echo "usage: fm-origin-push-guard.sh install [repo]" >&2
  echo "       invoked by git as a pre-push hook with <remote-name> <remote-url>" >&2
}

die() {
  printf 'fm-origin-push-guard: %s\n' "$*" >&2
  exit 1
}

abs_parent() {
  local path=$1
  (cd "$(dirname -- "$path")" && pwd -P) || return 1
}

path_is_inside() {
  local path=$1 root=$2 abs_path abs_root base
  abs_root=$(cd "$root" && pwd -P) || return 1
  abs_path=$(abs_parent "$path") || return 1
  base=$(basename -- "$path")
  abs_path="$abs_path/$base"
  case "$abs_path" in
    "$abs_root"|"$abs_root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

git_abs_path() {
  local repo=$1 spec=$2 resolved
  resolved=$(git -C "$repo" rev-parse --git-path "$spec") || return 1
  case "$resolved" in
    /*) printf '%s\n' "$resolved" ;;
    *) printf '%s/%s\n' "$repo" "$resolved" ;;
  esac
}

git_abs_common_dir() {
  local repo=$1 resolved
  resolved=$(git -C "$repo" rev-parse --git-common-dir) || return 1
  case "$resolved" in
    /*) printf '%s\n' "$resolved" ;;
    *) printf '%s/%s\n' "$repo" "$resolved" ;;
  esac
}

is_our_hook() {
  local path=$1
  [ -f "$path" ] && grep -F -q -- "$MARKER" "$path"
}

normalize_url() {
  local url=$1
  url=${url%/}
  printf '%s\n' "$url"
}

urls_equal() {
  local a b
  a=$(normalize_url "$1")
  b=$(normalize_url "$2")
  [ -n "$a" ] && [ "$a" = "$b" ]
}

no_mistakes_url() {
  git config --get remote.no-mistakes.url 2>/dev/null || true
}

no_mistakes_pushurl() {
  git config --get remote.no-mistakes.pushurl 2>/dev/null || true
}

destination_is_no_mistakes() {
  local name=$1 url=$2 nm_url nm_push
  [ "$name" = no-mistakes ] && return 0
  nm_url=$(no_mistakes_url)
  nm_push=$(no_mistakes_pushurl)
  [ -n "$nm_url" ] && { urls_equal "$name" "$nm_url" || urls_equal "$url" "$nm_url"; } && return 0
  [ -n "$nm_push" ] && { urls_equal "$name" "$nm_push" || urls_equal "$url" "$nm_push"; } && return 0
  return 1
}

allow_unguarded_override() {
  case "${FM_ALLOW_UNGUARDED_PUSH:-}" in
    1|yes|YES|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

run_chained_hook() {
  local prev=$1
  shift
  [ -n "$prev" ] && [ -x "$prev" ] || return 0
  "$prev" "$@"
}

print_refusal() {
  local dest=$1
  printf 'fm-origin-push-guard: refused push to %s\n' "$dest" >&2
  printf 'This checkout has a no-mistakes remote; use: git push no-mistakes\n' >&2
  printf 'Deliberate override: git push --no-verify  or  FM_ALLOW_UNGUARDED_PUSH=1 git push ...\n' >&2
}

run_hook() {
  local name=${1-} url=${2-}
  local input prev rc=0 nm_url dest
  local hook_dir
  hook_dir=$(cd "$(dirname -- "$0")" && pwd)
  prev="$hook_dir/$PREV_NAME"
  input=$(mktemp "${TMPDIR:-/tmp}/fm-origin-push-guard.XXXXXX") || die "cannot create stdin temp"
  cat > "$input"
  nm_url=$(no_mistakes_url)
  if [ -z "$nm_url" ] || destination_is_no_mistakes "$name" "$url" || allow_unguarded_override; then
    run_chained_hook "$prev" "$@" < "$input" || rc=$?
    rm -f "$input"
    return "$rc"
  fi
  rm -f "$input"
  dest=$name
  [ -n "$dest" ] || dest=$url
  [ -n "$dest" ] || dest='(unknown remote)'
  print_refusal "$dest"
  return 1
}

write_hook() {
  local dest=$1
  cp -- "$SELF" "$dest" || die "cannot write $dest"
  chmod 755 "$dest" || die "cannot chmod $dest"
}

install_into() {
  local repo=$1
  local hooks_dir common toplevel pre_push prev
  [ -d "$repo" ] || die "not a directory: $repo"
  repo=$(cd "$repo" && pwd)
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  hooks_dir=$(git_abs_path "$repo" hooks) || die "cannot resolve hooks directory"
  common=$(git_abs_common_dir "$repo") || die "cannot resolve git common dir"
  toplevel=$(git -C "$repo" rev-parse --show-toplevel) || die "cannot resolve toplevel"
  if ! path_is_inside "$hooks_dir" "$common" && ! path_is_inside "$hooks_dir" "$toplevel"; then
    printf 'fm-origin-push-guard: skipped install: core.hooksPath is outside this clone\n' >&2
    return 0
  fi
  mkdir -p "$hooks_dir" || die "cannot create $hooks_dir"
  pre_push="$hooks_dir/pre-push"
  prev="$hooks_dir/$PREV_NAME"
  if [ -e "$pre_push" ] || [ -L "$pre_push" ]; then
    if is_our_hook "$pre_push"; then
      write_hook "$pre_push"
      return 0
    fi
    if [ -e "$prev" ] || [ -L "$prev" ]; then
      die "cannot install: $pre_push and $prev both exist"
    fi
    mv -- "$pre_push" "$prev" || die "cannot preserve existing pre-push"
    chmod +x "$prev" 2>/dev/null || true
  fi
  write_hook "$pre_push"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,18{s/^# \{0,1\}//;p;}' "$SELF"
  exit 0
fi

if [ "${1:-}" = install ]; then
  [ "$#" -le 2 ] || { usage; exit 2; }
  install_into "${2:-.}"
  exit 0
fi

run_hook "$@"
exit $?
