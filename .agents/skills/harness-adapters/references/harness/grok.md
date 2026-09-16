# Grok Build

The xAI `grok` TUI is Claude-Code-compatible.
Verified initially on 2026-06-29 with 0.2.73, slash submission on 2026-07-03 with 0.2.82, effort on 2026-07-13 with 0.2.99, and exit on 2026-07-19 with 0.2.103.
Launch shape: `grok --always-approve "$(cat <brief>)"`.

## Operating facts

| Fact       | Value                                                                                                                                                                                                                                      |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Busy state | The last rendered-tail fallback, isolated to Grok pending a semantic source: ASCII mid-turn `Ctrl+c:cancel`, absent from idle bar `Shift+Tab:mode │ Ctrl+.:shortcuts`, never the locale-fragile braille spinner.                           |
| Exit       | `/exit` prints `Resume this session with: grok --resume <session-id>`; fallback is `Ctrl+Q` twice within 1000ms, `Ctrl+D` quits in VS Code-family terminals, and `Ctrl+C` interrupts.                                                      |
| Interrupt  | Single `Ctrl+C`; Escape only focuses scrollback.                                                                                                                                                                                           |
| Skill      | `/<skill>`, for example `/no-mistakes`, with end-to-end user-skill discovery, invocation, and real `no-mistakes axi run` evidence; the popup may consume Enter and fill an argument placeholder, requiring a real second Enter.            |
| Autonomy   | `--always-approve`, footer `· always-approve`, verified unattended; `--permission-mode bypassPermissions` is stronger equivalent.                                                                                                          |
| Marker     | `GROK_AGENT=1` on child or tool processes in 0.2.73 and no `CLAUDECODE`; a 1.0.0 hook instead had `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` without `GROK_AGENT`, so ancestry guarantees identity. |
| Resume     | `grok --resume <session-id>`, or `grok -c` / `--continue` for cwd latest; `--fork-session` creates a new id.                                                                                                                               |
| Model      | `--model <model>`; discover current account models with `grok models`.                                                                                                                                                                     |
| Effort     | `--reasoning-effort <low\|medium\|high>`, alias `--effort`; version 0.2.99 rejects `xhigh` and `max` with `use one of: high, medium, low`; `references/common/model-and-effort.md` owns fallback and unsupported-value handling.           |

Reliable Grok rules must account for hook markers as well as the child fast path.
`../../../docs/turnend-guard.md` under "Harness integrations" owns the marker contract.

## Submission and startup

Slash autocomplete can turn the first Enter into selection plus an argument hint, including `/no-mistakes`'s optional task argument or `/compact compaction instructions`, without submission.
The shared classifier keeps that text pending, and retry sends the second Enter on both verified backends; Herdr may also prove a turn through native state.

On 2026-07-03 two Grok 0.2.82 Herdr workers left `/no-mistakes` typed for minutes while send returned success.
Old Herdr logic treated any pane delta as submission, including popup closure and placeholder fill.
Tmux and Herdr now route captures through `../../../bin/fm-composer-lib.sh`, which classifies real text on every proven content row.
`../../../docs/herdr-backend.md` owns the boundary and `../../../tests/fm-backend-herdr.test.sh` covers it.

The "Run Grok Build in a project directory?" picker appears only outside a project, such as home, Desktop, Downloads, or `/tmp`.
For unavoidable non-project launch, `[hints] project_picker_disabled = true` in `~/.grok/config.toml` suppresses the picker.

## Folder trust

Grok gates a repository it has never seen behind an interactive "Do you trust the contents of this directory?" dialog, the same shape as Claude's workspace-trust dialog and the same rule applies: never send it a key.
The gate only fires for a directory carrying project-level automation content such as `AGENTS.md` or a `.grok/hooks/*.json` file, which every task worktree carries, so every fresh project hits it.
Trust lives in `${GROK_HOME:-$HOME/.grok}/trusted_folders.toml` and is a property of a git repository's identity rather than a filesystem path: an entry for a repository's PRIMARY checkout (the worktree whose own git directory is not a pointer file) is inherited by every linked worktree of that same repository, but the reverse does not hold and neither does plain directory containment.
Every spawn, secondmate launches included, therefore pre-registers the project's primary checkout, never the ephemeral task worktree, and the dialog does not appear for that worktree or any future one of the same project.
`../../../bin/fm-grok-trust.sh` resolves and validates the primary checkout for both plain and linked spawning roots, including leased secondmate homes.
`../../../bin/fm-spawn.sh` reads the destination's effective home paths after launch-environment filtering, registers trust synchronously, and binds that resolved Grok home to the worker command.
A registration failure refuses dispatch before publishing a task record or moving its backlog item In flight.
A raw grok launch command carrying its own `HOME` or `GROK_HOME` assignment is refused, because the pane-resolved home is the one Firstmate registers and binds.
The helper serializes Firstmate registrations per store through read, replace, and readback.
Only the regular `trusted_folders.toml` in that Grok home is supported; a symlinked trust file is refused.
`../../../docs/verification/runtime-backends.md` "Grok folder trust" owns the dated evidence for the inheritance rule.

## Composer

Fresh placeholder `Type a message...` uses dark 24-bit TRUECOLOR, not SGR-2.
`fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` drops dim or faint and truecolor below `FM_COMPOSER_GHOST_LUMA_MAX`, default 128.
On Grok 0.2.93, real input `38;2;224;222;244` measured about 225 luminance, while borders and placeholder ranged from `38;2;50;47;70` through `38;2;110;106;134`, about 51-110, and were dropped.
The truecolor rule assumes the fleet's dark theme; SGR-2 is theme-independent.
Coverage is `../../../tests/fm-composer-ghost.test.sh` and `../../../tests/fm-backend-herdr.test.sh`.

Tmux `#{cursor_y}` may point at the pristine composer's bottom border.
The shared classifier locates the full box and all content rows, so border cursor and multi-row composers require no adapter offsets.

## Worker turn-end hook

Grok fires `Stop` each turn.
Project hooks require the folder trust the "Folder trust" section above owns; global `${GROK_HOME:-$HOME/.grok}/hooks/` is always trusted regardless of it.
The spawn installs guarded global `fm-turn-end.json` and `fm-turn-end.sh` under `hooks/` in the Grok home it resolved from the destination pane, which is the same home the "Folder trust" section above registers and binds.
They act only when workspace `.fm-grok-turnend` matches the registry in `fm-turn-end.d/` beside them, then touch the task's `state/<id>.turn-ended` through always-set `GROK_WORKSPACE_ROOT`, which equals the worktree.
This stays outside the worktree, needs no trust grant, and writes only Firstmate files.
`../../../bin/fm-teardown.sh` removes the gitignored pointer before pooling.
Secondmates skip it because idle is healthy and ordinary stale-pane detection does not apply.

## Primary integration

Verified on 2026-07-28 with 0.2.112 and genuine pre-native 0.2.73.
`.grok/hooks/fm-primary-turnend-guard.json` invokes `../../../bin/fm-turnend-guard-grok.sh`.
The exact running Stop payload selects same-process continuation on 0.2.112; 0.2.73 omits that capability and needs one guarded `grok --resume`.
`../../../docs/turnend-guard.md` owns adaptive and malformed-input behavior.

Grok also loads Claude project settings, so Claude entries for Grok-covered events stand down under `GROK_AGENT` or `GROK_HOOK_EVENT`; that owner records the exact set and why `GROK_SESSION_ID` is excluded.
Project-local hooks require launch-time `--trust`; without it the guard steps aside and `../../../bin/fm-guard.sh` is the next-command alarm.
Watcher supervision remains tracked background notification around `../../../bin/fm-watch-arm.sh`, not Pi-style extension ownership.
PreToolUse blocks directly, but every `$VAR` in a hook command needs inline `:-default` or Grok refuses the hook.
