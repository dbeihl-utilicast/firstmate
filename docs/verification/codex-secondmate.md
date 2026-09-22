# Verification: Codex as a secondmate runtime on gpt-5.6-sol

Active empirical evidence that the existing `codex` adapter, with only `--model gpt-5.6-sol`, can run a secondmate through a completed turn.
The operating contract is in [the Codex harness reference](../../.agents/skills/harness-adapters/references/harness/codex.md).
`codex-foundry-luna` remains crewmate and scout only; this record is OpenAI Codex, not Azure Foundry.

## Subject

| Field | Value |
| --- | --- |
| Binary | `codex` 0.153.4 (`codex-cli`) |
| Model | `gpt-5.6-sol` via `--model`, provider `openai` |
| Platform | Linux aarch64, Herdr 0.7.3 isolated `fm-lab-` session |
| Verified | 2026-09-21 |
| Scope | Secondmate launch, first-run dialogs, one completed turn, interrupt, exit |

No live fleet home was pinned, restarted, or reconfigured.
The proof used a disposable parent home, a disposable secondmate home, and `bin/fm-herdr-lab.sh` with a non-default session name.

## Model path

`codex exec --model gpt-5.6-sol --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox 'Reply with the single word pong and nothing else.'` reported `model: gpt-5.6-sol`, `provider: openai`, and the assistant reply `pong`.
The same model flag is the secondmate launch: `codex --model 'gpt-5.6-sol' --dangerously-bypass-approvals-and-sandbox "$(bin/fm-operational-input.sh encode launch-brief < data/charter.md)"`.
That command does not start `bin/fm-foundry-luna-proxy.py`.

## First-run dialogs

A fresh secondmate clone painted two dialogs, in order.

Directory trust:

```text
  Do you trust the contents of this directory? Working with untrusted contents comes with
  higher risk of prompt injection. Trusting the directory allows project-local config, hooks,
  and exec policies to load.

› 1. Yes, continue
  2. No, quit

  Press enter to continue
```

Enter accepts option 1.

Hooks review, because the firstmate-shaped home ships `.codex/hooks.json`:

```text
  Hooks need review
  4 hooks are new or changed.
  Hooks can run outside the sandbox after you trust them.

› 1. Review hooks
  2. Trust all and continue
  3. Continue without trusting (hooks won't run)

  Press enter to confirm or esc to go back
```

Enter on option 1 opens the review UI and leaves the unattended pane idle with no turn.
Down then Enter selects option 2.
`bin/fm-spawn.sh` dismisses both after launch and publishes the home summary only after the verified ready prompt; the Codex harness reference owns that contract.
A reused endpoint receives a unique launch boundary before Codex starts, so a ready prompt left in earlier scrollback cannot satisfy the current relaunch.
Failed fresh or recreated launches remove their record only after endpoint absence is verified; an endpoint that cannot be proven absent keeps its record and durable summary for recovery.
`tests/fm-codex-harness.test.sh` pins the classifier.
`tests/fm-secondmate-harness.test.sh` pins the readiness, launch-boundary, endpoint, record, and summary outcomes.
`tests/fm-control-relaunch.test.sh` pins the control-plane rollback report.

## Completed turn

`config/secondmate-harness` containing `codex gpt-5.6-sol` spawned:

```text
spawned sol-lab harness=codex kind=secondmate mode=secondmate yolo=off
```

Metadata recorded `harness=codex`, `kind=secondmate`, `model=gpt-5.6-sol`, `backend=herdr`.
Herdr `agent get` moved `unknown` (dialog) → `idle` (dialog) → `working` for seven polls → `idle`.
The idle capture after that working interval contained the assistant line `• PONG-SOL` and `Token usage: total=31,432 input=31,242 (+ 11,008 cached) output=190 (reasoning 180)`.

On Herdr, native `agent get` reported `working` / `idle` for that turn; that status is not a firstmate semantic busy source.

## Interrupt and exit

`bin/fm-control.sh <id> interrupt` printed `interrupt-delivered ... harness=codex backend=herdr verified=agent-alive cancel=unconfirmed` and left `agent get` at `idle`.
`bin/fm-control.sh <id> exit` printed `stopped ... harness=codex`, `agent get` became empty, and the pane returned to a shell prompt with `codex resume 01a0c52f-e396-7783-9fad-409bca0411a4`.

## Guard coverage

```sh
bin/fm-test-run.sh tests/fm-codex-harness.test.sh tests/fm-bootstrap.test.sh tests/fm-secondmate-harness.test.sh
```

This live proof is not an opt-in CI guard because it spends a Codex turn.
