# Local service control

## Purpose

Local service control reports and controls only host-local Supervisor-owned daemons used by the local LLM workflow.

## Lifecycle authority

Host-local daemon lifecycle authority is Supervisor through the user-level `code-svc` wrapper.

```text
local_llm:
  Supervisor name: code-host:local-llm
  health:          http://127.0.0.1:8020/health

local_llm_router:
  Supervisor name: code-host:local-llm-router
  health:          http://127.0.0.1:8015/health
```

The app-specific systemd units `local-llm.service` and `local-llm-router.service` are legacy diagnostics only. Normal
lifecycle control must not use them because they can create split-authority port conflicts.

## Managed targets

```text
local_llm
local_llm_router
```

## Explicit non-targets

```text
data_stack PostgreSQL
llama.cpp Docker runtime
vLLM Docker runtime
Portainer
any Docker Compose group
arbitrary host processes
```

## Canonical commands

```bash
code-svc status
code-svc restart code-host:local-llm
code-svc restart code-host:local-llm-router
```

Router CLI bridge:

```bash
local-llm-router local-services status
local-llm-router local-services restart --target local_llm_router
```

## Do not use for normal runtime

```bash
local-llm-router serve
local-llm serve
systemctl --user start local-llm.service
systemctl --user restart local-llm.service
systemctl --user start local-llm-router.service
systemctl --user restart local-llm-router.service
./scripts/install.sh --enable-service
```

## Safety rules

```text
Use code-svc for host-local daemon lifecycle.
Use health endpoints to report actual runtime state.
Do not call app-specific systemd units for normal start/restart.
Do not kill arbitrary PIDs.
Do not manage Docker containers through this controller.
```

## Smoke

```bash
python3 scripts/local_services_smoke.py
python3 scripts/local_services_smoke.py --api
python3 scripts/local_services_smoke.py --target local_llm_router --api
```