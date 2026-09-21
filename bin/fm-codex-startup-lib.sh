#!/usr/bin/env bash
# Codex first-run dialog classifier used by bin/fm-spawn.sh.
# Sourced by spawn and by tests. No side effects on source.
#
# A fresh Codex repository root can stop before the launch brief runs:
#   1. directory trust: "Do you trust the contents of this directory?"
#      Option 1 "Yes, continue" is focused; Enter accepts it.
#   2. hooks review, when the repo ships .codex/hooks.json:
#      "Hooks need review" with option 2 "Trust all and continue".
#      Option 1 "Review hooks" is focused; Enter there wedges the pane.
#      Down then Enter selects option 2.
# Both decisions persist for that repository root. Later worktrees skip them.
#
# Prints exactly one of: hooks-down-enter | trust-enter | none

fm_codex_startup_dialog_action() {  # <pane-text>
  local pane=${1-}
  if printf '%s\n' "$pane" | grep -Fq 'Hooks need review' \
     && printf '%s\n' "$pane" | grep -Fq 'Trust all and continue'; then
    printf 'hooks-down-enter'
    return 0
  fi
  if printf '%s\n' "$pane" | grep -Fq 'Do you trust the contents of this directory?'; then
    printf 'trust-enter'
    return 0
  fi
  printf 'none'
}
