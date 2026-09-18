# Fork adapter set

This public fork of `kunchenguid/firstmate` carries only the worker and primary harness adapters this fleet runs.
This page is the single owner of that deletion list so a later upstream merge is not tribal knowledge.

## Current adapters

Keep, and keep dispatching:

- `claude`
- `codex` and `codex-foundry-luna`
- `cursor`
- `grok`
- `pi` and `pi-signed`
- `qwen` (crewmate and scout only; local-model red-first contract)
- `agy` (crewmate and scout only; tmux; the Gemini-backed worker)

## Retired adapters

Do not dispatch, document, or test these as supported workers:

- `kimi`
- `muse`
- `omp`
- `opencode`
- `rovo`
- `gemini` (the Gemini CLI adapter; `agy` is how this fleet reaches Gemini and Google-billed capacity)

Spark live records at the trim showed claude, grok, qwen, codex, and pi only.
Cursor and agy stay because this fleet still runs them even when a given snapshot has no live pane.

## What stays after a deletion

Harness detection in `bin/fm-harness.sh` still names a retired adapter when its marker or process name appears, so a leaked identity cannot be misread as a kept harness.
Launch-boundary scrubbing still unsets retired markers when launching a kept adapter, including `GEMINI_CLI`, `ANTIGRAVITY_AGENT`, `ATLASSIAN_AGENT_TYPE`, `ROVODEV_CLI`, and `FM_OMP_HARNESS`.
Do not drop a scrub marker just because its adapter is gone unless nothing can still set it.
Teardown still removes leftover retired-adapter files (`.fm-kimi-turnend`, `state/<id>.muse-session`, `state/<id>.gemini-settings.json`, `state/<id>.omp-ext.ts`, `.opencode/plugins/fm-busy-state.js`) so an old pane can be cleaned up.

`bin/fm-gemini-lib.sh` remains as detection identity for Gemini CLI processes.
Gemini and Antigravity launch-boundary scrub markers remain even though `gemini` is not a dispatched adapter.

## Deleted surfaces (upstream sync will restore these)

A future merge from `kunchenguid/firstmate` will conflict on, or reintroduce, at least:

- Adapter references: `.agents/skills/harness-adapters/references/harness/{kimi,muse,omp,opencode,rovo,gemini}.md` and their rows in the `harness-adapter-routing-v1` map
- Dedicated tests: `tests/fm-{kimi,muse,omp,rovo,gemini}-harness.test.sh`, `tests/fm-muse-signals-live-e2e.test.sh`, `tests/fm-rovo-signals-live-e2e.test.sh`, `tests/fm-omp-primary-live-e2e.test.sh`, `tests/fm-opencode-primary-live-e2e.test.sh`
- Primary trees: `.omp/` and `.opencode/`
- Dispatch: launch templates, binary resolvers, hook installers, and busy-state writers in `bin/fm-spawn.sh`; `bin/fm-kimi-turnend-hook.sh`
- Protocols: `docs/supervision-protocols/{omp,opencode}.md`
- Verification: `docs/verification/{muse,rovo}.md` and retired-adapter sections in `docs/verification/runtime-backends.md`
- README and operator docs that list omp, OpenCode, Kimi, Muse, Rovo, or Gemini CLI as supported workers
- Verified-adapter allowlists in `bin/fm-control-lib.sh`, `bin/fm-bootstrap.sh`, and remote-secondmate spawn

When that merge arrives, keep this fork's allowlist and scrub set, and re-delete the restored dispatch surfaces rather than re-verifying them as workers.

## Adding an adapter back

Treat it as a new adapter: detection, launch template, busy and control tables, portable regression, live guard, and a harness reference must land together.
An adapter used once in a reachable home is a keep.
