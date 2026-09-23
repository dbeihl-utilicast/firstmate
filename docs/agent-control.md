# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The one thing this file owns that is not a pure table is the [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) below, which does run backend reads; sourcing the file is still free.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. An endpoint reading `missing` goes through the same [absence proof](#reclaiming-a-task-whose-endpoint-is-gone) the reclaim uses before anything is claimed about it, and only Herdr can supply one: proven gone reports `endpoint-gone` (the agent went with it, and the endpoint this verb normally preserves did not survive), a pane that turns out to be there and idle is the ordinary `already-stopped`, one whose agent is back takes the ordinary interrupt-then-exit path. A tmux `missing` always refuses rather than claim a stop it cannot see. |
| `relaunch` | Replace the running agent with a new one in the same worktree - and the same endpoint whenever that endpoint still exists - on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

An interrupt is not complete until the composer is empty.
Muse and Qwen restore the cancelled prompt back into the composer as real text, so their interrupt key is followed by a Ctrl+U clear; without it the next submitted line - including this plane's own exit command - would concatenate onto the restored prompt and submit both as one line.
The clear is refused before anything is sent when the recorded backend cannot deliver it.

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex and grok resume only from a session id printed at exit, and claude, pi, pi-signed, and agy have no verified pane-resume contract.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` is the only verb that changes durable records, so it runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise every task kind preserves its recorded harness, model, and effort, so a fleet-wide default change cannot silently move a deliberately selected runtime during restart.
   Move one second mate deliberately with explicit profile flags on `fm-secondmate-restart.sh`, which keeps the persist, inheritance, readiness, and placement checks around the relaunch.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
2. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its branch, head, dirty and untracked state, and any attributable validation head are recorded.
   A canonical-copy custody lock serializes this capture and recovery with every pooled-copy reset, even when two task records name the same path through different aliases.
   A positively missing endpoint is recoverable in its exact copy without moving HEAD or bytes, even when dirty or validation-owned; the custody record captures both, and pool reset or reallocation still refuses dirty bytes, local-only commits, and attributable active validation heads and terminal validation heads not reachable from any remote-tracking ref until the commits are preserved under `refs/fm-custody`.
   Unreadable validation state, unreadable or ambiguous endpoint reads never authorize recovery.
   Before replacement, every task record naming the same physical copy is checked under the custody lock, and an unreadable, empty, symlinked, non-regular, or unparsable record, or one with no worktree line or a worktree that cannot be resolved, counts as occupying it and refuses until the operator repairs or inspects that record; a remote-routed record (`remote_host` or `window=remote:*`) or one whose absolute worktree no longer exists on this host does not claim the copy; another live or unreadable endpoint, or an unreconciled replacement endpoint journal, refuses recovery so two task records cannot sequentially start two workers in one copy.
   A fresh spawn refuses every copy still claimed by another task record, even if its endpoint is stale, and holds that copy's reservation from the pre-refresh check through worker publication so fresh spawn and recovery cannot cross in flight.
   The backend then creates a replacement endpoint (a tmux window or a Herdr pane) against the recorded copy and branch.
   Its identity is journaled immediately, retried recovery reconciles that journal before creating anything else, and the old durable task record remains authoritative until replacement publication.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which adopts an existing agent-free endpoint or recreates a positively missing endpoint in the recorded worktree, clears the previous harness's per-task wiring, and arms a fresh busy generation.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Reclaiming a task whose endpoint is gone

A Herdr pane or workspace can be destroyed out from under a live task by churn or a session restart.
The task's worktree, branch, commits, and uncommitted changes all survive that; only its terminal does not.

On Herdr a `missing` endpoint is reclaimed only after the absence proof below.
On tmux, `exit` refuses a `missing` endpoint, while `relaunch` recreates it in place in the exact recorded copy under the copy custody lock, the copy-claim check, and the replacement-endpoint journal described above, rather than under an absence proof.

Two endpoint verdicts are agent-free, and both license a relaunch:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted, so the launch owner **creates one fresh endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step, because the classifier's `missing` is not one state: it conflates *the endpoint was destroyed* with *the endpoint is unreachable from here right now*.
An unreachable endpoint can still hold the live agent a rebind would duplicate, so absence is proven and never inferred from a failed read - and whether it is provable at all is a property of the backend:

- **Herdr can prove it.** Every read goes through the adapter's `--session <session>` CLI, so the recheck starts and reads the session the *record* names, through that session's own socket.
  It starts that server (only the server: no workspace and no tab are created) and **re-reads the recorded pane**.
  `dead` means the pane survived the restart and is adopted after all, with no second tab; `alive` means the agent came back and refuses; only a second `missing` proves the pane itself did not survive ([`docs/herdr-backend.md`](herdr-backend.md) "Restart and liveness behavior").
  That server start is a real side effect, and the parenthetical above does not cover it: when the recorded session's server no longer exists at all, the probe stands a fresh empty one up in order to ask, and nothing afterwards uses it.
  So in that state `exit` - which otherwise reads as a read-only inspection - leaves an idle herdr server behind.
- **tmux cannot.** `list-windows -a` describes only the tmux server the *current process* addresses (its `TMUX_TMPDIR`/socket), and a task record carries no socket identity for its endpoint.
  A different but running server would answer "not anywhere" about a window it was never able to see, so a server-wide read cannot tell a destroyed window from one on a server this process cannot address.
  There is no read available that closes that gap, so tmux `exit` always refuses - for a renamed session, a moved window, a foreign socket, and a dead server alike - and tmux `relaunch` relies on the copy custody controls instead.

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

That proof has one owner for the whole control plane (`fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh`), so `exit` and `relaunch` cannot reach two different answers about one endpoint.
`exit` reports what the proof established and nothing more - see its row in the verb table above.

What a reclaim is not:

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity. The task id, its armed poll and registration, and its status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a Herdr secondmate whose pane is proven gone. That recovery already has one owner - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start liveness sweep - so relaunch refuses and names it rather than becoming a second path to the same outcome.

The re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

A refusal after the new tab is created but before the record is republished removes that exact tab through the replacement-endpoint journal, as described under failure and rollback below.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped keeps the progress note so a later recovery still has it, marks the control journal `failed:launching`, and reports plainly whether an endpoint and record remain.
  Before replacement publication, the prior record remains authoritative and a missing-endpoint replacement's endpoint journal lets cleanup remove or retry that exact endpoint without creating another.
- After replacement publication, a reused endpoint keeps the new record because removing it would leave an existing endpoint unowned.
- A recreated Codex secondmate or Agy worker endpoint stays marked as such until its post-launch delivery gate succeeds.
  On delivery failure, rollback retires it, verifies it is absent, then removes its replacement record and refreshes the durable home summary; if absence cannot be verified, rollback retains the record and summary for recovery.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch` that host-side drive is `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...`, whose host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` has no such route, and `exit` is reached only through `bin/fm-secondmate-lane.sh stop <id>`, which also records the stopped marker the startup liveness sweep honors and treats a missing recorded endpoint as already complete.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Qwen is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free or positively missing, so a replacement can never join a live agent.
  A missing endpoint records custody and follows the safe-checkpoint recovery above; unreadable validation state refuses.
  It also requires the shell to be in the recorded worktree: tmux refuses immediately when it is not, while Herdr sends one `cd` to the recorded path and refuses unless a subsequent path read confirms the move.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, rollback after a failed launch, and the endpoint-absence proof both verbs share - the Herdr reclaim of a destroyed endpoint - and tmux in-place recovery of a missing endpoint under copy custody.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
