## Live validation

Validated candidate `68379d4fe6f481f91162c976cd752e377b1ad409` on 2026-09-14 against fm-spark's real no-mistakes v1.72.0 daemon. The census detected parked runs `fm/fix-257-preflight-verify-backport` (`edfc71b9`, age `11h6m`) and `fm/fix-393-salvage-controls` (`cf3dbddd`, age `11h9m`). Independent `axi status --run` calls confirmed both were parked at `review/fix_review`. Their ledger state is `running`; census ages measure time since the ledger timestamp.

The selected-home census returned `busy-incomplete`, three runs and one unregistered-home gap, exit 3. The registered root returned busy/1. Empty and terminal-only ledgers returned clear/0. Shared-root and inherited-worktree cases preserved busy HOME outcomes without duplicate RUN records. Local unregistered repositories, project overrides, inaccessible inventories, malformed registry rows, unsafe project entries and refused SSH connections all returned explicit coverage gaps. The focused quiescence regression passed; no source changes were needed.

### Method and limits

- Candidate source and its two current helper libraries were streamed over the existing fm-spark SSH alias for in-memory execution. The two source directives were replaced by their exact library contents. No remote files were installed and no run was created, started or changed.
- Normal fm-on routing and complete multi-host aggregation remain untested: this worktree has no remote-home registry and the remote root lacks the unlanded command. Recheck through the existing registration after the owner deploys the candidate and makes that registry available to this worktree. The SSH checks do not establish complete fleet coverage.
- A parked run in a distinct home repository was unavailable; the sampled plugins home is unregistered. Root and project detection passed. Recheck when an existing home repository has a real run; none was manufactured.
- Separately registered linked worktrees and shared-ledger query failures remain portable-regression coverage only. The observed real linked worktree inherits a successful root ledger. An existing separate registration or naturally failing shared ledger is needed for live proof.
- Signal-killed and malformed live ledger responses remain portable-regression coverage only. Real read-only queries succeeded; no daemon was interrupted or replaced. Recheck against an existing reproducing dependency failure or an explicitly authorized isolated fault environment.

Green supports the observed parked-run detection and exercised safety boundaries. It does not establish full fleet quiescence, deployed remote routing, the untested failure modes, or CI readiness. The outer executor owns the PR and CI phases.

Evidence: [live CLI transcript](live-transcript.txt), [actual parked-run status](parked-run-status.txt), [ledger baseline](ledger-baseline.txt), [local boundary transcript](local-boundaries-transcript.txt), [read-only reproduction commands](drive-readonly.sh).
