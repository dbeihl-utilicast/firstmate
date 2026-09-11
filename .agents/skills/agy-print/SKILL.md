---
name: agy-print
description: >-
  Agent-only playbook for Firstmate's one-shot Antigravity print path.
  Load before using `agy` for a review or second-reading task.
  Owns the helper invocation, the isolated-cwd contract, and the boundary
  that this is not a verified worker runtime.
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

Call the helper.
Its header and `--help` own the exact flags.

```sh
bin/fm-agy-print.sh --prompt '<prompt>' --model <id> --effort low|medium|high --cwd <isolated-dir> [--json-schema <string-or-path>] [--print-timeout <bound>]
```

Pass an explicit model id from `agy models`.
Pass an explicit effort.
Name an isolated cwd that already exists.
When the result must be structured, pass `--json-schema` and gate on the helper's exit.
Empty `structured_output` is a failure even if `agy` exits 0 with `status: SUCCESS`.
The helper prints the compact JSON envelope on stdout and nothing else on success.
Treat a non-zero exit as failure.
Do not scrape a pane for a second signal.

## After the envelope

Read the envelope fields you asked for.
Relay the review or second-reading outcome in the captain's terms.
Do not invent a worker lifecycle around the process that already exited.
