# Verification: the `agy` crewmate/scout adapter

Audience: maintainer verification.

This record captures the evidence for the macOS tmux-only `agy` adapter and its explicit primary boundary.
The operating contract is in [the harness reference](../../.agents/skills/harness-adapters/references/harness/agy.md).

## Subject

| Field | Value |
| --- | --- |
| Version | `agy` 1.1.27 |
| Platform | macOS arm64 |
| Verified | 2026-09-08 |
| Scope | Crewmate and scout work through tmux only |

`agy --help` established print, structured output, interactive prompt, model, effort, conversation, sandbox, and permission surfaces before the live probes.
The installed CLI disproved two earlier assumptions: models are not Gemini-only, and model and effort are separate flags rather than one encoded model identifier.
`agy models` returned Gemini 3.8/3.7/3.6 and Gemini 3.1 Pro variants, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium` for this account.

## Launch and trust

`agy --print='<exact reply>' --output-format json --model gemini-3.8-flash-low --effort low` returned `status: SUCCESS` and the exact reply.
The CLI requires the prompt to be attached to `--print`; the superficially similar `agy --print --output-format json ...` treats the following flag as prompt text and is not the supported invocation form.
`--mode accept-edits` was accepted by the running build.

A real tmux worker launched with `--dangerously-skip-permissions --prompt-interactive=<brief> --model gemini-3.8-flash-low --effort low` stopped at the workspace-trust dialog.
One Enter on its affirmative item began the submitted turn and rendered the busy footer, while no persistent sandbox setting was enabled.
The post-accept settings file was `~/.gemini/antigravity-cli/settings.json` with `trustedWorkspaces` entries for `/Users/davidsair` and the verified worktree `/Users/davidsair/.treehouse/firstmate-8bf1b0/5/firstmate`.
No `enableTerminalSandbox` or `toolPermission=proceed-in-sandbox` setting appeared in that result.

## Lifecycle

The live tmux foreground process reported `agy`, and `fm_backend_agent_state tmux` classified it `alive` through the exact-name classifier.
During a real shell sleep, the current TUI footer rendered `esc to cancel` and `fm_busy_agy_tail_busy` classified the captured tail busy.
After completion, the footer lacked that line and the classifier returned idle, proving the negative direction rather than a constant busy signal.
One Escape during a longer sleep rendered the interruption response, left the `agy` process alive, and restored the idle composer.
`/quit` then removed the tmux worker endpoint.
`--conversation <recorded-id> --prompt-interactive=<exact reply>` restored the conversation and completed a new interactive turn, establishing deterministic resume.

At idle, the plain tmux capture showed a `>` row bounded above and below by full-width `─` dividers, followed by the shortcut and model footer.
`fm_backend_composer_state` returned `empty` for that structure, `pending` after literal text was typed, and `empty` after it was cleared.
The shared composer classifier still rejects a bare shell `>` without the two dividers.

## Guard coverage

`tests/fm-agy-harness.test.sh` pins exact ancestry, tmux liveness, busy and idle directions, composer safety, per-launch permission posture, model and effort mapping, trust-dialog refusal, scoped secondmate refusal, Escape, and `/quit` tables without credentials.
`tests/fm-harness-liveness-drift-live-e2e.test.sh` includes the installed `agy` binary in the token-free process-identity drift check.
`tests/fm-agy-signals-live-e2e.test.sh` is the opt-in live lifecycle refresh guard.

## Linux availability

The [official installation page](https://antigravity.google/docs/cli/install/) gives `curl -fsSL https://antigravity.google/cli/install.sh | bash` for Linux.
It has not been run on the DGX in this verification, so those workers remain unavailable for `agy` until an attended install, sign-in, and live tmux check complete there.
