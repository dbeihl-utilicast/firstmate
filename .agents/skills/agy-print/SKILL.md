---
name: agy-print
description: >-
  Agent-only playbook for Firstmate's one-shot Antigravity print path.
  Load before using `agy` for a review or second-reading task.
  Routes to the helper contract and owns the boundary that this is not a
  verified worker runtime.
user-invocable: false
metadata:
  internal: true
---

# agy-print

Load this before using Antigravity `agy` for a one-shot review or second-reading.
This is a helper invocation, not a crewmate, scout, secondmate, or primary runtime.

## Boundary

Do not add `agy` to the verified runtime list, crew-dispatch profiles, or quota routing.
Do not spawn a TUI, scrape a pane, classify busy or idle, steer, interrupt, relaunch, or resume `agy` as a worker.
Do not pass `--dangerously-skip-permissions` as a standing setting.
The interactive TUI adapter is a separate later change.
The captain-machine document-review wrapper at `~/.agents/skills/agy-delegate` is a different tool.
Do not replace it, and do not copy it into this repo.

## Invoke

Call `bin/fm-agy-print.sh` with a caller-created isolated cwd.
Its header and `--help` own the exact invocation, output, and gating contract.
Relay the review or second-reading outcome in the captain's terms.
Do not invent a worker lifecycle around the process that already exited.
