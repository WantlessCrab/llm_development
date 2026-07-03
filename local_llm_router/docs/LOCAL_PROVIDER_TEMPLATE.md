# Local provider onboarding contract

## Purpose

Add a future local model to `local_llm_router` through a provider contract instead of router-specific code.

Supported no-code path:

```text
local model runtime
→ HTTP endpoint proof
→ local_llm_http provider config
→ provider probe
→ queued user draft
→ manual provider dispatch
→ generated FormatCapture response
→ generated local draft
```

Provider onboarding does not grant lifecycle ownership. Docker-owned vLLM and llama.cpp runtimes remain
Docker/Portainer-owned. Host-local `local_llm` and `local_llm_router` daemons remain Supervisor/code-svc-owned.

## Runtime authority

```text
Source tree:
  /home/wantless/PycharmProjects/automation/local_llm_router

Active runtime config:
  ~/.config/local-llm-router/config.yaml

Latest installed example:
  ~/.config/local-llm-router/config.example.yaml.new

Daemon:
  http://127.0.0.1:8015

Draft inbox:
  http://127.0.0.1:8015/draft-inbox

Discovery reports:
  ~/.cache/local-llm-router/provider_discovery
```

`config.example.yaml` and `config.example.yaml.new` are examples. The daemon reads
`~/.config/local-llm-router/config.yaml`.

## Provider contract

A local model can be added without code when its endpoint satisfies one supported `local_llm_http` request/response
contract.

Required provider identity:

```text
provider_id
provider_type=local_llm_http
label
enabled
availability
capabilities
```

Required HTTP contract:

```text
base_url
health_endpoint
models_endpoint
chat_endpoint
method
request_format
response_format
response_text_path when response_format=custom_json_path
api_key or authorization when required
model
timeout_seconds
stream=false for current manual dispatch path
temperature
max_tokens
```

Current first-class validated class:

```text
OpenAI-compatible HTTP server:
  health: GET /health
  models: GET /v1/models
  chat: POST /v1/chat/completions
  request_format: openai_chat_compatible
  response_format: openai_chat_compatible
  response text: choices[0].message.content
```

## Generic OpenAI-compatible provider template

```yaml
  local_MODEL_KEY:
    provider_id: "local_MODEL_KEY"
    provider_type: "local_llm_http"
    label: "Local MODEL_LABEL"
    enabled: true
    availability: "ready"
    capabilities:
      can_capture: true
      can_receive: true
      can_insert_draft: false
      can_manual_send: true
      can_dispatch_request: true
      can_return_response: true
      supports_browser_session: false
      supports_http_session: true
      supports_streaming: false
      supports_queue_groups: true
      supports_manual_review: true
    config:
      base_url: "http://127.0.0.1:PORT/v1"
      health_endpoint: "../health"
      models_endpoint: "models"
      chat_endpoint: "chat/completions"
      method: "POST"
      request_format: "openai_chat_compatible"
      response_format: "openai_chat_compatible"
      response_text_path: null
      api_key: "not-needed"
      model: "SERVED_MODEL_ID"
      timeout_seconds: 300
      stream: false
      system_prompt: null
      temperature: 0.2
      max_tokens: 384
```

## vLLM provider pattern

Discovery reads vLLM candidates from runtime files such as `.env` and `docker-compose*.yml`.

Expected signals:

```text
VLLM_SERVED_MODEL_NAME
VLLM_API_KEY
host port mapped to container port 8000
```

Example validated endpoint:

```text
base_url: http://127.0.0.1:8021/v1
health:   http://127.0.0.1:8021/health
models:   http://127.0.0.1:8021/v1/models
chat:     http://127.0.0.1:8021/v1/chat/completions
model:    local-small
```

## llama.cpp provider pattern

Discovery reads llama.cpp candidates from runtime files such as `.env`, `docker-compose*.yml`, and registration/config
files.

Expected signals:

```text
HOST_PORT
LLAMA_ARG_ALIAS
host port mapped to container port 8000
```

Example validated endpoint:

```text
base_url: http://127.0.0.1:8023/v1
health:   http://127.0.0.1:8023/health
models:   http://127.0.0.1:8023/v1/models
chat:     http://127.0.0.1:8023/v1/chat/completions
model:    local-qwen36-35b-q4-llamacpp
```

## Optional provider discovery

Discovery is disabled by default and does not overwrite active config.

Manual discovery:

```bash
local-llm-router discover-providers --probe --include-offline --write-report
```

Manual post-startup live apply:

```bash
local-llm-router discover-providers --probe --include-offline --apply-runtime
```

Script form:

```bash
python3 scripts/discover_local_providers.py --probe --include-offline --write-report
python3 scripts/discover_local_providers.py --api-apply --include-offline
```

## Candidate classifications

```text
ready:
  health endpoint reachable, models endpoint reachable, served model ID present

already_configured:
  candidate provider_id already exists; active config/registry remains authoritative

offline:
  static contract inferred, endpoint not currently reachable

misaligned:
  endpoint reachable, configured served model ID missing from /v1/models

incomplete:
  missing required static facts such as host port or served model ID

error:
  unexpected discovery or probe failure
```

## Validation sequence

After adding or discovering a provider:

```bash
local-llm-router config-check
local-llm-router providers PROVIDER_ID --probe
python3 scripts/provider_dispatch_smoke.py --provider-id PROVIDER_ID
```

Expected smoke result:

```text
provider probe ok
manual_confirmation_required block confirmed
confirmed dispatch returns response_received
generated assistant response creates queued local draft
cleanup marks generated draft handled
failed=0 and dispatching=0 after cleanup
```

## Failure interpretation

```text
missing_config:
  provider block lacks required dispatch keys

connection refused:
  runtime is not listening on the inferred host port

served_model_found=false:
  runtime is up but model alias does not match provider config

manual_confirmation_required:
  expected guard; proves dispatch cannot silently auto-fire

dispatch_not_supported:
  provider_type does not implement dispatch

empty_response:
  endpoint returned JSON but no extractable assistant text
```

## Rule for future local models

No router code is required when the new runtime can satisfy one supported `local_llm_http` contract. New router code is
reserved for unsupported transports, unsupported authentication/session handshakes, streaming-only APIs, multipart/file
inputs, or response structures not expressible by the current response extraction formats.

## Route-action integration

Configured or discovered providers with `capabilities.can_dispatch_request=true` become selectable local-provider
targets in the route-action UI and backend route-action API. Provider onboarding remains separate from automatic
routing: adding a provider does not automatically dispatch captured messages to it.