#!/usr/bin/env bash
# Portable classifier for Codex first-run dialogs that spawn dismisses so a
# secondmate can begin its turn. Live turn completion is recorded in
# docs/verification/codex-secondmate.md.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-codex-startup-lib.sh"

trust_pane='
> You are in /tmp/example

  Do you trust the contents of this directory? Working with untrusted contents comes with
  higher risk of prompt injection. Trusting the directory allows project-local config, hooks,
  and exec policies to load.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
'

hooks_pane='
  Hooks need review
  4 hooks are new or changed.
  Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won'\''t run)

  Press enter to confirm or esc to go back
'

working_pane='
• Working (1s • esc to interrupt)

› Ask Codex to do anything
'

got=$(fm_codex_startup_dialog_action "$trust_pane")
[ "$got" = trust-enter ] || fail "directory trust pane classified as '$got', expected trust-enter"
got=$(fm_codex_startup_dialog_action "$hooks_pane")
[ "$got" = hooks-down-enter ] || fail "hooks review pane classified as '$got', expected hooks-down-enter"
got=$(fm_codex_startup_dialog_action "$working_pane")
[ "$got" = none ] || fail "working pane classified as '$got', expected none"
got=$(fm_codex_startup_dialog_action "")
[ "$got" = none ] || fail "empty pane classified as '$got', expected none"

# Hooks must win when both strings somehow appear, because Enter on the hooks
# dialog wedges the pane on "Review hooks".
both="$trust_pane
$hooks_pane"
got=$(fm_codex_startup_dialog_action "$both")
[ "$got" = hooks-down-enter ] || fail "combined pane classified as '$got', expected hooks-down-enter"

pass "Codex startup dialog classifier: trust Enter, hooks Down-then-Enter, working is none"
echo "# all fm-codex-harness tests passed"
