#!/usr/bin/env bash
# fm-treehouse-lib.sh - home-scoped Treehouse pool root (one owner).
#
# Treehouse keys its default pool on repo identity (clone basename plus a hash),
# not on which Firstmate home asked. Two homes that clone the same project under
# the same directory name therefore share one pool under $HOME/.treehouse and
# can be handed a slot whose .git belongs to the other clone. Returning the
# lease does not re-associate that git metadata. Firstmate therefore passes a
# per-home --root on every treehouse get/status/return/prune it issues, so each
# home's slots never share a pool.
#
# That root lies OUTSIDE the home, at
# $HOME/.firstmate-pools/<home-basename>-<hash of the home's physical path>.
# A slot inside the home has the home's own CLAUDE.md (an @AGENTS.md pointer)
# in a parent directory, and Claude Code then stops every worker on its "Allow
# external CLAUDE.md file imports?" prompt; a declined answer recorded for the
# slot is not honoured, because Claude reads that answer only from the slot's
# primary checkout entry, which is the captain's own config. Placing slots
# outside the home removes the parent CLAUDE.md, so no answer is needed.
#
# Slots a home took from its old in-home pool ($FM_HOME/.treehouse/) keep
# working: treehouse return finds a slot's pool from the slot's own path, not
# from --root, so they go back to that legacy pool. Nothing new is allocated
# there, and treehouse prune --root <home> retires its clean, unused slots.
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
#       Print the absolute physical --root for this home ($FM_HOME), outside it.
#   fm_treehouse <subcommand> [args...]
#       Run `treehouse <subcommand> [args...] --root <home-root>`.
#   fm_treehouse_spawn_get_command
#       Print the pane command `treehouse get --root '<home-root>'` with the
#       root shell-quoted, for fm-spawn.sh to type into a worker pane.

fm_treehouse_home_root() {
  local home=${FM_HOME:-} phys user hash root
  [ -n "$home" ] || {
    echo "error: FM_HOME is unset; cannot scope the Treehouse pool to this home" >&2
    return 1
  }
  [ -n "${HOME:-}" ] || {
    echo "error: HOME is unset; cannot place this home's Treehouse pool outside it" >&2
    return 1
  }
  phys=$(CDPATH='' cd -- "$home" >/dev/null && pwd -P) || return 1
  user=$(CDPATH='' cd -- "$HOME" >/dev/null && pwd -P) || return 1
  hash=$(printf '%s' "$phys" | git hash-object --stdin) || return 1
  root="$user/.firstmate-pools/$(basename -- "$phys")-${hash:0:12}"
  case "$root/" in
    "$phys"/*)
      echo "error: Treehouse pool root '$root' would be inside Firstmate home '$phys', where the home's CLAUDE.md is a parent of every slot" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root"
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
