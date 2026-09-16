# Verification: the codex-foundry-luna crewmate/scout adapter

Active empirical evidence for firstmate's codex-foundry-luna adapter, which is codex itself repointed at the Azure AI Foundry `gpt-5.6-luna` deployment through the local token-refreshing gateway `bin/fm-foundry-luna-proxy.py`.
The skill tree rooted at [`.agents/skills/harness-adapters/references/harness/codex.md`](../../.agents/skills/harness-adapters/references/harness/codex.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | codex-cli `0.153.4` |
| Verified | 2026-09-16 |
| Binary | `codex`, launched as a child of `bin/fm-foundry-luna-proxy.py run --` |
| Platform | Linux, Python 3 standard library only |
| Model host | Azure AI Foundry account `aih-utilicast-ftiek`, deployment `gpt-5.6-luna` |
| Auth | AAD bearer, audience `https://cognitiveservices.azure.com/.default`, fetched inline by the gateway with `az account get-access-token` |

The live section below ran against the real account with a real az-issued token, in a throwaway scratch directory, with no fleet pane involved.
No credential value was read, printed, copied, or stored at any point, and the only thing the gateway ever writes is a request status line, to the file `FM_FOUNDRY_LUNA_LOG` names.
The subscription id and tenant live in `bin/fm-foundry-luna-proxy.py` and are not restated here.

## The route the dispatched worker actually uses

The launch template in `bin/fm-spawn.sh` pins `model_providers.fm_foundry_luna.base_url` to `http://127.0.0.1:__FOUNDRYLUNAPORT__/openai/v1` and `wire_api` to `responses`, and the gateway replaces that placeholder with the port it has bound before it execs codex.
Captured against a local recording server, codex 0.153.4 with that configuration issues exactly two routes:

```text
POST /openai/v1/responses
GET  /openai/v1/models?client_version=0.153.4
```

`POST /openai/v1/responses` is the only route the gateway relays.
The user intent's proven-facts block covered `<host>/openai/v1/chat/completions` and the versioned deployments path, which is the route codex cannot use: `wire_api = "chat"` fails config load on 0.153.4 with "no longer supported".
The Responses route was therefore unverified against this deployment until the live run below, and is now verified.

## Live end-to-end run

A real `bin/fm-foundry-luna-proxy.py run -- codex ...` invocation carrying the launch template's exact `model`, `model_provider`, `model_providers.fm_foundry_luna.name`, `base_url`, `wire_api`, and `model_reasoning_effort` values, against the real account, with a real az-issued AAD token:

```text
$ fm-foundry-luna-proxy.py run -- codex -c model=\"gpt-5.6-luna\" -c model_provider=\"fm_foundry_luna\" -c model_providers.fm_foundry_luna.name=\"Azure-AI-Foundry-gpt-5.6-luna\" -c model_providers.fm_foundry_luna.base_url=\"http://127.0.0.1:__FOUNDRYLUNAPORT__/openai/v1\" -c model_providers.fm_foundry_luna.wire_api=\"responses\" -c model_reasoning_effort=\"high\" --dangerously-bypass-approvals-and-sandbox exec --skip-git-repo-check "<one-line prompt>"
[exit 0]
```

The gateway writes nothing to stdout or stderr, because in a dispatched pane it shares a tty with the worker's TUI and a stray line there displaces the footer firstmate's busy detection scrapes.
Naming a file in `FM_FOUNDRY_LUNA_LOG` appends each request's status line to that file instead, which is how this evidence was captured.
The access log recorded exactly one relayed request:

```text
fm-foundry-luna-proxy: "POST /openai/v1/responses HTTP/1.1" 200 -
```

codex reported `model: gpt-5.6-luna`, `provider: fm_foundry_luna`, `reasoning effort: high`, completed the turn with a non-empty assistant reply of 4 characters, and printed a token-usage total.
Neither the gateway's access log nor codex's own output contained a bearer token, an `accessToken` field, or a JWT-shaped string.
Reply text, request headers, and response bodies are deliberately not recorded here.

## Who may reach the gateway

The gateway holds the operator's own AAD token, so a loopback bind alone would let any local process spend the captain's Foundry budget under that identity.
`bin/fm-spawn.sh` mints a fresh random secret per spawn, hands it to the worker as an explicit `FM_FOUNDRY_LUNA_SECRET=` assignment on the launch command, and points codex at it with `model_providers.fm_foundry_luna.env_key`.
The gateway refuses to start at all without that variable, and answers 401 to any request whose `Authorization` header is not exactly this task's secret, before a route check, a deployment check, or a token fetch.
The secret never leaves the host: `_forward` strips the caller's `Authorization` header and replaces it with the gateway's own fetched token.

## The deployment allowlist

The captain authorizes `gpt-5.6-luna` only, and Foundry names the deployment in two independent places.

`bin/fm-foundry-luna-proxy.py` pins both.
The JSON body's `model` must be exactly `gpt-5.6-luna`.
The request path must be exactly `/openai/v1/responses`, so a deployment-scoped URL such as `/openai/deployments/gpt-5.6-terra/chat/completions?api-version=...` carrying an authorized body model is refused locally, before a token is fetched and before any byte leaves the host.
`bin/fm-spawn.sh` refuses a `--model` other than `gpt-5.6-luna` at spawn time as well.

`tests/fm-foundry-luna-proxy.test.sh` drives the real gateway against a fake `az` and a fake upstream for every one of these.
Its fake upstream serves `/openai/v1/responses` and answers 404 on any other path, so a gateway that relayed a different route turns the suite red.

## Supervision and control

codex-foundry-luna carries no supervision mechanics of its own.
It inherits codex's turn-end hook and busy detection through the `codex*` family match in `bin/fm-control-lib.sh` and `bin/fm-busy-lib.sh`.
It is the first adapter whose recorded harness name differs from its control family, so `bin/fm-control.sh` resolves a relaunch target from the recorded name whenever that name is itself a verified adapter, and keeps the explicit-`--harness` refusal for a genuine raw-command basename such as `grok-2`.
The pane runs the gateway as the foreground process with codex as its child in the same process group, so tmux agent-liveness still classifies the pane through codex's own process identity.

The gateway picks its own loopback port, by binding `127.0.0.1:0` and serving that same socket; `bin/fm-spawn.sh` selects no port.
Two gateways dispatched back to back therefore cannot be handed the same number, which a probe-and-close port choice in `fm-spawn` could do in the window before either gateway binds.

## Not verified

codex-foundry-luna as a primary or secondmate runtime is unverified, and `bin/fm-spawn.sh` refuses `--secondmate` on it.
The gateway serves POST only.
codex's startup `GET /openai/v1/models` therefore returns 501 and codex logs a non-fatal `failed to refresh available models` error before proceeding; the turn completes normally and the model catalog is not used by the pinned single-deployment configuration.
The gateway itself stays silent about that 501 unless `FM_FOUNDRY_LUNA_LOG` is set.
Relaying that route is deliberately not implemented, because widening the gateway's relayed surface is what the single-deployment allowlist exists to prevent.
The live turn above was captured while the gateway still took its port from `bin/fm-spawn.sh` as `run --port <n>` and before the per-task client secret existed; the command is shown in the form the dispatched worker uses now.
Both changes are covered by `tests/fm-foundry-luna-proxy.test.sh` against a fake `az` and a fake upstream, and neither has been re-run against the real account.
Streaming was proven against a fake chunked upstream rather than a live streamed Foundry turn.
Token refresh across a real expiry boundary was proven with a fake `az` that mints a distinct nonsecret value per call; no real token was held to expiry.
A supervised fleet pane on this adapter has not been run.

## Refreshing this record

```
bin/fm-test-run.sh tests/fm-foundry-luna-proxy.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-control-relaunch.test.sh
az account get-access-token --subscription <id> --resource https://cognitiveservices.azure.com -o none
FM_FOUNDRY_LUNA_SECRET=<a throwaway nonsecret string> FM_FOUNDRY_LUNA_LOG=<access-log-path> bin/fm-foundry-luna-proxy.py run -- codex -c model=\"gpt-5.6-luna\" -c model_provider=\"fm_foundry_luna\" -c model_providers.fm_foundry_luna.name=\"Azure-AI-Foundry-gpt-5.6-luna\" -c model_providers.fm_foundry_luna.base_url=\"http://127.0.0.1:__FOUNDRYLUNAPORT__/openai/v1\" -c model_providers.fm_foundry_luna.wire_api=\"responses\" --dangerously-bypass-approvals-and-sandbox exec --skip-git-repo-check "<one-line prompt>"
```

The live step needs an in-tenant az login with access to the account and bills the turn to Azure.
`FM_FOUNDRY_LUNA_LOG` is what makes the relayed status line observable; without it the gateway relays silently.
The portable counterparts run in ordinary CI with a fake `az` and a fake upstream, and never touch the real account.
