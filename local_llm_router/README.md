# local_llm_router

`local_llm_router` is a host-local LLM session routing app for Linux Mint Cinnamon/X11. It connects a real logged-in
ChatGPT browser session, a local daemon, configured local HTTP model providers, and a manual review queue.

## Current route family

```text
ChatGPT active browser page
→ manual capture of latest assistant or user message
→ local daemon
→ SQLite store
→ configured wrapper
→ local draft inbox
→ optional direct manual route to configured local HTTP provider
→ generated provider response captured as FormatCapture
→ generated local draft inbox item
→ user manually inserts/sends/marks handled
```

The manual-review boundary is intentional. The router does not auto-send browser messages and does not auto-dispatch
provider calls without an explicit operator action.

## Authority model

```text
Source/dev authority:
  /home/wantless/PycharmProjects/automation/local_llm_router

Runtime config:
  ~/.config/local-llm-router/config.yaml

Runtime database:
  ~/.local/share/local-llm-router/router.sqlite

Daemon:
  http://127.0.0.1:8015

Draft inbox:
  http://127.0.0.1:8015/draft-inbox

Browser adapter:
  Chrome/Chromium unpacked extension from ./extension

Host-local daemon lifecycle:
  Supervisor via code-svc
```

## Install/update

```bash
cd /home/wantless/PycharmProjects/automation/local_llm_router
./scripts/install.sh
code-svc restart code-host:local-llm-router
code-svc status code-host:local-llm-router
curl -fsS http://127.0.0.1:8015/health; echo
```

Do not enable or start `local-llm-router.service`. The app-specific systemd unit path is legacy cleanup context only.
Runtime lifecycle authority is Supervisor through `code-svc`.

## Load extension

```text
chrome://extensions
→ Developer mode ON
→ Load unpacked
→ /home/wantless/PycharmProjects/automation/local_llm_router/extension
```

Open ChatGPT. The `LLMR` overlay should appear.

## Core commands

```bash
local-llm-router doctor
local-llm-router status
local-llm-router db-summary
local-llm-router config-check
local-llm-router providers
local-llm-router providers PROVIDER_ID --probe
local-llm-router discover-providers --probe --include-offline
local-llm-router local-services status
local-llm-router local-services restart --target local_llm_router
local-llm-router open config
local-llm-router open inbox
local-llm-router logs --follow
```

`local-services` is the host-local lifecycle command group. It controls only configured Supervisor-owned host-local
services: `local_llm` and `local_llm_router`.

## Explicit non-targets

```text
data_stack PostgreSQL
llama.cpp Docker runtime
vLLM Docker runtime
Portainer
Docker Compose groups
arbitrary host processes
```

Those remain Docker/Compose/Portainer-owned unless deliberately migrated.

## Unified route actions

The operator model is:

```text
source → target → Route
```

Supported source concepts:

```text
latest user message
latest assistant response
selected queued item
generated provider response through selected queued item/provider-response mode
```

Supported target concepts:

```text
local draft inbox
configured local HTTP provider
ChatGPT active composer
```

Browser insertion remains content-script-owned because only the browser adapter can access the ChatGPT composer. Backend
route-action APIs support daemon-owned actions such as capture-to-local-draft and selected/captured draft dispatch to
local providers.

## Local service control

Managed host-local services:

```text
local_llm         → code-host:local-llm
local_llm_router  → code-host:local-llm-router
```

Status reports both Supervisor state and health endpoint state because process authority and application health are
separate facts.

```bash
local-llm-router local-services status
python3 scripts/local_services_smoke.py --api
code-svc status
```

## Local provider onboarding

Use the provider contract for future local models:

```text
docs/LOCAL_PROVIDER_TEMPLATE.md
```

Minimum validation:

```bash
local-llm-router config-check
local-llm-router providers PROVIDER_ID --probe
python3 scripts/provider_dispatch_smoke.py --provider-id PROVIDER_ID
```

## Provider discovery

Discovery is disabled by default. It can scan local runtime roots, infer provider blocks for OpenAI-compatible
vLLM/llama.cpp runtimes, probe endpoints, classify candidates, and optionally add ready non-duplicate providers to the
live registry.

Read-only discovery:

```bash
local-llm-router discover-providers --probe --include-offline --write-report
```

Manual live apply through the running daemon:

```bash
local-llm-router discover-providers --probe --include-offline --apply-runtime
```

Active `config.yaml` is not overwritten by discovery.

## Validation

```bash
local-llm-router config-check
local-llm-router doctor
local-llm-router local-services status
python3 scripts/local_services_smoke.py --api
python3 scripts/provider_dispatch_smoke.py --provider-id local_llamacpp_qwen36_35b_q4
python3 scripts/route_action_smoke.py --provider-id local_llamacpp_qwen36_35b_q4
```

## Success definition

```text
1. Daemon health endpoint returns ok.
2. Draft inbox loads.
3. Extension detects ChatGPT.
4. ChatGPT overlay appears.
5. Latest assistant and latest user captures both create local draft deliveries.
6. Intentional duplicate captures create traceable requeued deliveries.
7. Manual provider dispatch blocks without manual confirmation.
8. Confirmed provider dispatch creates generated assistant local draft.
9. Provider-response queue mode can find generated local responses.
10. Browser insertion remains manual and never auto-sends.
11. local-services status reports local_llm and local_llm_router through Supervisor without touching Docker/Portainer.
12. State survives daemon restart.
```

## Prompt wrappers

Prompt wrappers are optional route-time text transforms selected from the overlay or popup. They are configured in:

```text
~/.config/local-llm-router/prompt_wrappers.yaml
```

Source example:

```text
prompt_wrappers.example.yaml
```

Prompt wrappers are user-facing workflow framing. They are distinct from internal route wrappers such as
`source_attribution_default`.