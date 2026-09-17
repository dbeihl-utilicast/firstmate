#!/usr/bin/env bash
# fm-treehouse-lib.sh - home-scoped Treehouse pool root (one owner).
#
# Treehouse keys its default pool on repo identity (clone basename plus a hash),
# not on which Firstmate home asked. Two homes that clone the same project under
# the same directory name therefore share one pool under $HOME/.treehouse and
# can be handed a slot whose .git belongs to the other clone. Returning the
# lease does not re-associate that git metadata. Firstmate therefore passes
# --root <this home> on every treehouse get/status/return/prune it issues, so
# each home's slots live under $FM_HOME/.treehouse/ and never share a pool.
#
# --root is Treehouse's own override (also TREEHOUSE_ROOT): it replaces $HOME as
# the parent of .treehouse/<repo>-<hash>/, independently of repo identity.
# Relative --root values resolve from the repo root; this helper always passes
# an absolute physical path so that cannot happen.
#
# Git's worktree registry names under <clone>/.git/worktrees/ are independent of
# Treehouse slot numbers (registry utilicast-triage10 can be slot 12). An offset
# between those names is expected and is not pool corruption.
#
# Usage (sourced):
#   fm_treehouse_home_root
#       Print the absolute physical --root for this home ($FM_HOME).
#   fm_treehouse <subcommand> [args...]
#       Run `treehouse <subcommand> [args...] --root <home-root>`.
#   fm_treehouse_spawn_get_command
#       Print the pane command `treehouse get --root '<home-root>'` with the
#       root shell-quoted, for fm-spawn.sh to type into a worker pane.

fm_treehouse_home_root() {
  local home=${FM_HOME:-}
  [ -n "$home" ] || {
    echo "error: FM_HOME is unset; cannot scope the Treehouse pool to this home" >&2
    return 1
  }
  CDPATH='' cd -- "$home" >/dev/null && pwd -P
}

fm_treehouse() {
  local root
  [ "$#" -ge 1 ] || {
    echo "usage: fm_treehouse <subcommand> [args...]" >&2
    return 2
  }
  root=$(fm_treehouse_home_root) || return 1
  command treehouse "$@" --root "$root"
}

fm_treehouse_spawn_get_command() {
  local root quoted
  root=$(fm_treehouse_home_root) || return 1
  quoted=$(
    printf "'"
    printf '%s' "$root" | sed "s/'/'\\\\''/g"
    printf "'"
  )
  printf 'treehouse get --root %s' "$quoted"
}
