# Qwen Code

Verified 2026-09-15 on Qwen Code 0.23.0 (hooks, detection) and re-verified the same day on 0.23.4 (supervised TUI dispatch) for crewmate/scout work only.
Not verified as a secondmate or primary: `../../../../../docs/supervision-protocols/` carries no qwen wake protocol, and this adapter verified only the crewmate-side launch, busy state, interrupt key, composer-clear, and exit command.
The router owns that task-kind boundary.
The adapter is Linux-only: `../../../../../bin/fm-qwen-lib.sh` refuses a canonical spawn or relaunch on any other host as `qwen-platform-unsupported` before anything is provisioned or stopped, because Node-bundle liveness reads argv boundaries from `/proc` and a flattened `ps` string cannot keep a script path containing whitespace intact.

## Operating facts

| Fact | Value |
|---|---|
| Platform | Linux only. Non-Linux spawn and relaunch refuse as `qwen-platform-unsupported`. |
| Binary | `qwen` on `PATH`; the installed launcher is a node bundle (`~/.local/bin/qwen` -> `@qwen-code/qwen-code/cli-entry.js`). |
| Launch | `--prompt-interactive <brief>` plus `-y` / `--yolo`. A positional prompt is one-shot headless and exits. |
| Models | `--model <model>`; discover from the in-session `/model` dialog or the host's model provider. There is no `qwen models` subcommand. |
| Busy | Semantic `qwen-hook`: `UserPromptSubmit` opens a turn; `Stop`, `StopFailure`, and `SessionEnd` close it. |
| Turn end | `Stop` fires once per completed turn (verified, 0.23.0). `SessionEnd` was not observed on a natural headless exit, so `Stop` is the load-bearing close. |
| Exit | `/quit` (alias `/exit`), one Enter. |
| Interrupt | Single Escape, then Ctrl-U. Escape restores the cancelled prompt as bright composer text; Ctrl-U clears it so the next line cannot concatenate onto it. |
| Skill | `/<skill>`, the Claude or Grok form. |
| Autonomy | `-y` / `--yolo`. `--approval-mode yolo` is the equivalent long form. |
| Trust | Folder trust is disabled by default (`security.folderTrust.enabled` defaults false). A fresh worktree does not show a trust dialog unless that setting is on. |
| Marker | `QWEN_CODE=1` on tool subprocesses. `QWEN_CODE_CLI` is a path, not an identity flag. `GEMINI_CLI` is not set. |
| Resume | Native CLI: `--resume <session-id>` or `-c` / `--continue`. Firstmate control has no `resume` verb; use `relaunch`. |
| Effort | None on the CLI. `/effort` exists as an in-session slash command (`low\|medium\|high\|xhigh\|max`) and is not a verified spawn axis, so `references/common/model-and-effort.md`'s record-and-omit contract applies. |

## Detection

`QWEN_CODE=1` is load-bearing rather than a fast path, so `../../../../../bin/fm-harness.sh` checks it BEFORE `CLAUDECODE` and `GROK_AGENT`.
Qwen does not clear those inherited markers, so a qwen worker under a grok or claude primary carries both and whichever is tested first wins; the spawn additionally clears the foreign markers at the launch boundary.

Ancestry cannot cover the installed bundle on modern Node/Linux.
The live process reports `comm=node-MainThread` and `argv0=node`, so neither the command-name arm nor a naive interpreter arm matches without reading the script argument.
`../../../../../bin/fm-qwen-lib.sh` owns the narrow structural rule: identity comes from argv[1], accepted only when it is named `qwen` or lives under `@qwen-code/qwen-code/`.
A natively-named `qwen` binary is still detected by the comm-name arm.

Do not promote `QWEN_CODE_CLI` to a marker.
It is the launcher path, present on hook processes that lack `QWEN_CODE=1`, and a leaked path in a multiplexer environment would misidentify an unrelated pane.

`GEMINI_CLI` must never be treated as qwen identity.
Qwen is a Gemini-CLI fork but does not set that flag (verified, 0.23.0).

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task settings file at `state/<id>.qwen-settings.json` with four hooks bound to the minted busy generation, and the launch reaches it through `QWEN_CODE_SYSTEM_SETTINGS_PATH`.
This wiring belongs only to the canonical exact `qwen` adapter template.
A raw Qwen-shaped launch is an unverified escape hatch: it receives no busy-state wiring or turn-end hook and therefore has no trusted busy state.
It is deliberately NOT the worktree's `.qwen/settings.json`: that path is the PROJECT's own settings file, so writing it would clobber a project's configuration and retiring it would delete a tracked file.
`../../../../../bin/fm-teardown.sh` removes the firstmate-owned file.

`UserPromptSubmit` records busy, `Stop` records idle and keeps the `state/<id>.turn-ended` touch as the watcher NOTIFICATION, and `StopFailure` plus `SessionEnd` record idle so an abnormal end cannot strand a busy record.
Each hook command prints the empty JSON object the hook contract accepted and tolerates a refused event, so a stale-generation writer can never break Qwen's own lifecycle.

Busy state is this semantic source, never a rendered spinner.
A local model can think for minutes without drawing a footer firstmate already trusts, so inferring busy from the pane would read as a wedged worker.

## Auth

A Qwen worker needs a credential it can use without a dialog, and firstmate does not invent one.
The verified non-interactive path accepts `QWEN_DEFAULT_AUTH_TYPE=openai` plus `OPENAI_API_KEY` and an optional `OPENAI_BASE_URL` at spawn time.
`../../../../../bin/fm-qwen-lib.sh` preflights that shape and resolves the Qwen executable before a fresh spawn provisions anything and before a relaunch stops the running worker.
`../../../../../bin/fm-spawn.sh` writes the selected type and provider environment into the mode-0600 firstmate-owned per-task settings file.
The launch command carries only that settings path, so the credential is absent from process arguments and recorded commands.
An unavailable or unsupported shape refuses as `qwen-auth-unavailable`.
Local Ollama is one such operator-supplied OpenAI-compatible provider.

Do NOT give a worker an isolated `QWEN_HOME`.
It hides `~/.qwen` skills and stored auth the way an isolated `GEMINI_CLI_HOME` hides Gemini user skills.

## Model selection

Harness identity is independent of the model provider.
`harness=qwen` with a local Ollama model is still Qwen Code, not Pi or omp.

On a host whose Ollama inventory includes the Qwen 3 family, the measured split is:

- `qwen3-coder:30b` for well-specified coding work that needs tools.
- `qwen3.8` for general, vision, or thinking-capable turns.
- `qwen3.6` as a larger general alternative.
- `qwen2.5vl:7b` for vision-only work; it has no tools capability.

Advertised context on the coder and 3.8/3.6 tags is 262144.
Qwen Code's live OpenAI-compatible request on this host loaded `qwen3-coder:30b` at context 131072, not the advertised maximum.
The `qwen-probe-coder-64k` and `qwen-probe-38-64k` aliases are the same blobs with `PARAMETER num_ctx 65536`, so every load is capped at 64k regardless of what the client asks.
Use the 64k aliases when a predictable context ceiling matters more than the client's requested window.
`../../../../../docs/verification/qwen.md` owns the measured commands.

## Primary integration

Unsupported and unverified.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.

## False success

The fleet never treats Qwen's process exit, `subtype: success`, or prose claim as acceptance.
A change is judged by the repository tests, checks, and selected delivery path.
`../../../../../docs/verification/qwen.md` owns the live negative: a tiny failing test Qwen could not honestly fix, an explicit request to print DONE, no success claim, and the test gate still red.
