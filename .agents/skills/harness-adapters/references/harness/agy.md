# Antigravity CLI (`agy`)

Verified 2026-09-08 on `agy` 1.1.27 for macOS arm64 crewmate and scout work through tmux only.
It is not a primary or secondmate runtime because it has no verified Firstmate turn-end hook or primary supervision protocol.
`bin/fm-spawn.sh` must refuse it outside this scope rather than presenting an unsupervised worker as dispatchable.

## Operating facts

| Fact | Value |
| --- | --- |
| Binary and identity | `agy`; its live interactive process and tmux foreground `comm` are exactly `agy`, so `bin/fm-harness.sh` and `bin/backends/tmux.sh` match only that exact name. |
| Launch | `agy --dangerously-skip-permissions --mode accept-edits --model <model> --effort <low\|medium\|high> --prompt-interactive=<brief>`; `--prompt-interactive`, not `--print`, starts the supervised interactive turn. |
| Permission posture | `--dangerously-skip-permissions` is a per-launch worker flag approved for this fleet task, never a persistent Antigravity setting. The adapter does not pass `--sandbox`, and it must never set a persistent `proceed-in-sandbox` policy. |
| Trust | A new worktree stops at `Do you trust the contents of this project?` with `Yes, I trust this folder`; `agy_wait_for_delivery` sends one Enter only when both strings are visible, then requires the busy footer. |
| Busy and turn end | The current bottom footer is `esc to cancel` during a running turn and is absent once the turn settles or is interrupted. `fm_busy_agy_tail_busy` checks only the last twelve nonblank rows, so the affirmative and absent directions classify `busy agy-regex` and `idle agy-regex`. |
| Steering | The idle TUI composer is a `>` row between two full-width `─` divider rows. `fm_composer_classify_agy_divider_pair` requires that structure and the tmux cursor row before it returns `empty`; typed text returns `pending`, while an unstructured shell `>` remains `unknown`. |
| Interrupt and exit | One Escape interrupts a running turn and leaves the process interactive; `/quit` exits it. |
| Resume | `--conversation <conversation-id> --prompt-interactive=<prompt>` restored a recorded session and accepted a new turn. `--continue` also resumes, but selects the most recent conversation and is not the deterministic recovery path. |
| Model and effort | `agy models` is account-specific and includes Gemini, Claude, and GPT-OSS entries on the verified account. `--model` and `--effort` are separate flags; effort accepts only `low`, `medium`, or `high`, while `xhigh` and `max` stay in task metadata and are omitted at launch. |

## Trust persistence

Accepting the prompt persisted workspace trust in `~/.gemini/antigravity-cli/settings.json` under `trustedWorkspaces`.
The resulting file contained `/Users/davidsair` and `/Users/davidsair/.treehouse/firstmate-8bf1b0/5/firstmate`, so the worktree is an explicit entry rather than an adapter-maintained blanket policy.
No `enableTerminalSandbox` or `toolPermission=proceed-in-sandbox` field was written during the verification.
Treat each new worktree as potentially requiring its own prompt and record a newly observed settings shape before broadening this behavior.

## Linux

Antigravity's [official installation page](https://antigravity.google/docs/cli/install/) publishes a Linux installer: `curl -fsSL https://antigravity.google/cli/install.sh | bash`.
On the DGX, run it in an attended terminal, complete its interactive sign-in, and then re-run the live tmux verification before adding `agy` to a Linux home's dispatch configuration.
The installer answer removes the platform-availability blocker for the three DGX workers, but no DGX installation or verification is claimed by this adapter record.
