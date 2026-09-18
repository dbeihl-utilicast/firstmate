# Verification: the `agy` crewmate/scout adapter

Audience: maintainer verification.

This record captures the evidence for the macOS tmux-only `agy` adapter and its explicit primary boundary.
The operating contract is in [the harness reference](../../.agents/skills/harness-adapters/references/harness/agy.md).

## Subject

| Field | Value |
| --- | --- |
| Version | `agy` 1.2.6 |
| Platform | macOS arm64 |
| Verified | 2026-09-18 |
| Scope | Crewmate and scout work through tmux only |

`agy --help` established print, structured output, interactive prompt, model, effort, conversation, sandbox, and permission surfaces before the live probes.
The installed CLI disproved two earlier assumptions: models are not Gemini-only, and model and effort are separate flags rather than one encoded model identifier.
`agy models` returned Gemini 3.8/3.7/3.6 and Gemini 3.1 Pro variants, `claude-sonnet-4-6`, `claude-opus-4-6-thinking`, and `gpt-oss-120b-medium` for this account.

## Launch and trust

`agy --print='<exact reply>' --output-format json --model gemini-3.8-flash-low --effort low` returned `status: SUCCESS` and the exact reply.
The CLI requires the prompt to be attached to `--print`; the superficially similar `agy --print --output-format json ...` treats the following flag as prompt text and is not the supported invocation form.
`--mode accept-edits` was accepted by the running build, but it is a second permission-affecting flag outside the approved posture, so the adapter launches with `--dangerously-skip-permissions` alone.

A real tmux worker launched with `--dangerously-skip-permissions --prompt-interactive=<brief> --model gemini-3.8-flash-low --effort low` stopped at the workspace-trust dialog.
One Enter on its affirmative item began the submitted turn and rendered the busy footer, while no persistent sandbox setting was enabled.
The post-accept settings file was `~/.gemini/antigravity-cli/settings.json` with `trustedWorkspaces` entries for `/Users/davidsair` and the verified worktree `/Users/davidsair/.treehouse/firstmate-8bf1b0/5/firstmate`.
No `enableTerminalSandbox` or `toolPermission=proceed-in-sandbox` setting appeared in that result.

## Lifecycle

The live tmux foreground process reported `agy`, and `fm_backend_agent_state tmux` classified it `alive` through the exact-name classifier.
During a real shell sleep, the current TUI footer rendered `esc to cancel` and `fm_busy_agy_tail_busy` classified the captured tail busy.
After completion, the footer lacked that line and the classifier returned idle, proving the negative direction rather than a constant busy signal.
One Escape during a longer sleep cleared the busy footer, left the `agy` process alive, and restored the idle composer.
`/quit` then removed the tmux worker endpoint.
A tool subprocess launched with both Claude and Pi primary markers retained reported the following exact safe subset and detected itself as agy:

```text
agy
ANTIGRAVITY_AGENT=1
CLAUDECODE=1
PI_CODING_AGENT=true
```

The same subprocess also carried `ANTIGRAVITY_AGENTAPI_EXE`, conversation and trajectory ids, and no `GEMINI_CLI` marker.
This proves agy does not scrub either inherited primary marker, so `bin/fm-harness.sh` tests agy's own marker first and canonical non-agy launches clear it.
A short turn settled between two half-second captures with no observable busy footer, while the submitted brief stayed echoed above the composer, so the delivery gate accepts that durable echo as well as the footer.
A 71-line brief scrolled its own opening lines out of the pane and left its closing lines adjacent to the reply, which is why the echo marker is taken from the brief's tail.
Because that tail is the same boilerplate on every worker brief, and an answered trust prompt can equally be left behind by an earlier incarnation, the gate reads both signals only below this launch's boundary: the `export FM_TASK_ID=<id>` row typed on its own line ahead of the launch command, taking its last occurrence.
It is the task's own launch-time export rather than the row adjacent to the launch: when trace context is on, an `export TRACEPARENT=<carrier>` row is typed between the two, which changes nothing because it carries no agy signal.
Scoping rather than disabling is what keeps both directions right: a reused endpoint's stale dialog draws no stray Enter, while a prompt this launch genuinely raises is still answered instead of stranding a worker that needed one Enter.
The exposure is only the window before agy takes the screen over: `tmux capture-pane -S -120` returns no earlier scrollback while an alternate-screen program is running, which agy is once its TUI starts.
That capture is taken with `-J` so a boundary tmux split across rows is still matchable on a narrow pane or a long task id.
Because the boundary is therefore observable only until agy paints, a launch whose boundary is never captured is refused with that reason and the endpoint retired, rather than reported as a brief the worker declined.
`--conversation 688ab05b-e3fd-45af-be20-e6f3eebe8a6c --print='<recall prompt>'` returned the same conversation id, `SUCCESS`, and `RESUME_918_X7`; `--continue` then selected that conversation and returned `CONTINUE_OK` after being asked to confirm the same token.
These checks establish both native resume switches in print mode; Firstmate recovery still uses relaunch from the durable brief because its control plane has no resume verb.

At idle, the plain tmux capture showed a `>` row bounded above and below by full-width `─` dividers, followed by the shortcut and model footer.
`fm_backend_composer_state` returned `empty` for that structure, `pending` after literal text was typed, and `empty` after it was cleared.
The divider pair is not proof by itself, so the rule lives behind agy's own foreground process identity in `bin/fm-tmux-lib.sh`: the shared classifier answers `unknown` for those rows, and every other harness, including a shell `>` drawn between two rules, keeps the strict posture it had before this adapter.

## Guard coverage

`tests/fm-agy-harness.test.sh` pins exact ancestry, busy and idle directions, per-launch permission posture, model and effort mapping, trust-dialog refusal, scoped secondmate refusal, Escape, and `/quit` tables without credentials.
`tests/fm-tmux-agent-liveness.test.sh` pins tmux liveness and the composer gate in a real tmux server: an agy pane reads `empty` idle and `pending` typed, while the identical screen under a non-agy process or a dead shell stays `unknown`.
`tests/fm-harness-liveness-drift-live-e2e.test.sh` includes the installed `agy` binary in the token-free process-identity drift check.
`tests/fm-agy-signals-live-e2e.test.sh` is the opt-in live lifecycle refresh guard.

## Quota routing

`quota-axi --provider agy` returned a provider row keyed `agy` with plan `Google AI Pro`, carrying `gemini_5h`, `gemini_weekly`, `claude_gpt_5h`, and `claude_gpt_weekly` windows.
That single account-scoped row is the evidence for the `agy` provider family in `bin/fm-quota-choose.sh`, rather than any inference from the model names `agy models` lists.
With Antigravity not running, the same read reported `state.status: stale` and the default snapshot carried agy only in its attention section (`stale`, `unresolved_windows`).
An agy candidate whose quota cannot be measured is ineligible in `bin/fm-quota-choose.sh`, like every other harness, so agy is selectable only while Antigravity is running and the row reports measured headroom.

## Linux availability

The [official installation page](https://antigravity.google/docs/cli/install/) gives `curl -fsSL https://antigravity.google/cli/install.sh | bash` for Linux.
It has not been run on the DGX in this verification, so those workers remain unavailable for `agy` until an attended install, sign-in, and live tmux check complete there.
