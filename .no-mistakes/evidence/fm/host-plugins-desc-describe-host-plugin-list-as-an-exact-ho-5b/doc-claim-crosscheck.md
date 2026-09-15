# host-plugins.json description: claim-to-behaviour cross-check

Change under test: c093293 (AGENTS.md layout entry and docs/configuration.md "Host Claude Code plugins" opening). Docs-only; no runtime code changed.

| New description claim | Where the behaviour lives | Exercised by (stub claude CLI, not live) |
| --- | --- | --- |
| Readiness check registers named marketplaces | bin/fm-remote-doctor.sh:1494 `plugin marketplace add` | "marketplace-add failures redact sources", "a marketplace is bound to its configured source" |
| Installs and enables named plugins at user scope | bin/fm-remote-doctor.sh:1533 `plugin enable --scope user`, :1545 `plugin install --scope user` | test line 373 asserts `plugin install --scope user -- example-core@example-plugins` |
| Refuses while any reported unnamed plugin is installed, at any scope | bin/fm-remote-doctor.sh:1297-1319, no scope filter on rows | "installed plugins outside the configured catalogue are reported": a project-scope disabled plugin and a foreign-marketplace plugin are both named in the refusal |
| Refusal blocks a remote second-mate launch | bin/fm-spawn.sh readiness gate ("launch refused"); host-plugins runs in the post-inheritance pass per bin/fm-remote-readiness-lib.sh header | "a configured plugin load error refuses launch" |
| Host-wide: user-scope plugins belong to the host account | doctor converges the account's effective Claude store (CLAUDE_CONFIG_DIR), not a per-home store | "the doctor uses CLAUDE_CONFIG_DIR as the effective Claude store" |

Result: every behavioural claim in the new wording matches the doctor and spawn code; tests/fm-remote-doctor-host-plugins.test.sh exited 0 (transcript: host-plugins-doctor-test.log).
