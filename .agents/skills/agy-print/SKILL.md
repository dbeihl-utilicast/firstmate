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

## Scout-report second reading

Before a scout report reaches the captain, run `bin/fm-agy-second-read.sh` against the report and write the verdict beside it as `data/<task-id>/second-reading.json`.
Pass `--model gemini-3.8-flash --effort low` explicitly for this routine read: Flash keeps a mandatory read cheap enough for every report, while Gemini supplies a different model family from the usual worker.
Read the verdict before presenting the report: a `concerns` verdict requires the report to be corrected or its finding to be carried forward, and an `inconclusive` verdict requires its stated missing evidence to be carried forward.
The script header owns its arguments, prompt, schema validation, isolated-copy handling, and the rule that its output only informs a reader and never authorizes an action.
`second-reading.schema.json` is the sole owner of the `agy-second-reading.v1` verdict format.

## Invoke

Call `bin/fm-agy-print.sh` with a caller-created isolated cwd when no more specific path owns the use case.
Its header and `--help` own the exact invocation, output, and gating contract.
Relay the review or second-reading outcome in the captain's terms.
Do not invent a worker lifecycle around the process that already exited.
