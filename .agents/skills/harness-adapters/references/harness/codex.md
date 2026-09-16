# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh>"'`, verified on codex-cli 0.142.1 whose installed schema contains `model_reasoning_effort`, active config uses it, and bundled catalog advertises only these four values while omitting `max`. |
| Model discovery | Open the current interactive session's `/model` picker. |

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.

## codex-foundry-luna

`codex-foundry-luna` is this same codex binary, repointed at the Azure AI Foundry `gpt-5.6-luna` deployment (account `aih-utilicast-ftiek`) instead of OpenAI's own API.
Everything above (exit command, skill popup, resume, primary integration) applies unchanged; only model/provider selection differs, so it is a crewmate/scout-only bare adapter name in `bin/fm-spawn.sh`, never a secondmate.
`bin/fm-spawn.sh`'s launch template runs `bin/fm-foundry-luna-proxy.py run -- codex -c ...`: that script binds a loopback-only gateway on a port it picks itself, substitutes that port for the literal `__FOUNDRYLUNAPORT__` in codex's argv, then runs codex as its child with `-c model=`, `model_provider=`, `model_providers.<id>.base_url=`, and `model_providers.<id>.wire_api="responses"` overrides, never `--model`.
`wire_api = "responses"` is required on codex-cli 0.153.4; `"chat"` fails config load with "no longer supported" even though Foundry's own `/openai/v1/chat/completions` route works fine for a direct HTTP client (verified 2026-09-16).
`env_key` points codex at `FM_FOUNDRY_LUNA_SECRET`, a fresh random value `bin/fm-spawn.sh` mints per spawn and assigns on the launch command, so codex's own Authorization header carries that secret and nothing else; the gateway admits only that value and supplies the real AAD bearer token itself, fetched fresh via `az account get-access-token` and refreshed before its ~1-hour expiry.
The gateway also refuses any request whose `model` is not exactly `gpt-5.6-luna`, so a caller cannot repoint it at another deployment on the same account.
`bin/fm-spawn.sh` refuses a `--model` other than `gpt-5.6-luna` at spawn time too, and refuses `--secondmate` outright; see that script's `codex-foundry-luna` case and guards.
`gpt-5.6-luna` rejects the legacy chat-completions `max_tokens` field with a 400 naming `max_completion_tokens` (verified live 2026-09-16); the `responses` wire API sends `max_output_tokens`, so the dispatched path never hits it and the gateway does not translate it.
