# Architecture

## Components

```text
Browser content adapter
  Detects browser provider/session.
  Extracts latest assistant or user message.
  Infers a readable ChatGPT conversation label.
  Serializes message content through FormatCapture.
  Inserts draft text into the composer when requested.
  Shows local overlay controls.

Browser extension popup
  Main multi-session operator UI.
  Discovers live ChatGPT tabs through the service worker.
  Merges live tab state with daemon provider-session/group state.
  Presents source → target → Route with readable session names.
  Provides session alias, group assignment, queue, provider, and service status controls.

Service worker
  Injects/refreshes content scripts.
  Lists live ChatGPT tabs.
  Bridges messages to a specific live tab by tab_id.
  Does not own durable state.

Daemon
  FastAPI app on 127.0.0.1:8015.
  Owns config, route decisions, validation, provider registry, storage, local service status/action APIs, session labels, and draft inbox.

SQLite store
  Durable authority for sessions, session labels, queue groups, messages, deliveries, statuses, and audit records.

Local draft inbox
  Browser-accessible local review target.
  Displays routed drafts and generated provider responses.
  Supports copy, mark handled, queue filtering, provider selection, provider probe, and manual provider dispatch.

Provider registry
  Builds provider connectors from config.
  Uses provider_type to select connector implementation.
  Supports runtime upsert for opt-in discovered providers.

Local HTTP provider connector
  Probes local model endpoints.
  Builds provider request bodies.
  Dispatches manually confirmed queued drafts.
  Extracts response text.
  Returns generated FormatCapture responses.

Route-action layer
  Defines the backend contract for direct source → target operations.
  Executes daemon-owned routes such as capture-to-local-draft and draft-to-local-provider.
  Leaves browser composer insertion to the content script because DOM authority lives in the browser.

Prompt wrapper engine
  Loads ~/.config/local-llm-router/prompt_wrappers.yaml.
  Applies named before/after/line-prefix transforms only to outbound routed text.
  Does not mutate original captured messages, FormatCapture source records, queue groups, or route identity.

Local service controller
  Reports and controls only host-local Supervisor programs for local_llm and local_llm_router.
  Uses code-svc as the lifecycle authority.
  Shows Supervisor state and health endpoint state separately.
  Never manages Docker, Portainer, data_stack, vLLM runtime, or llama.cpp runtime.
```

## Session naming contract

```text
Stable route identity:
  source_session_id
  provider
  conversation_id
  gizmo_id
  tab_id for live browser targets

Mutable display identity:
  manual alias
  inferred label
  label source
```

Manual aliases are stored by the daemon and override inferred labels. Inferred labels are browser-provided convenience
metadata and may not overwrite a user-saved alias. Session names are never used as routing keys.

## Manual route family

```text
ChatGPT latest user/assistant
→ FormatCapture
→ daemon capture
→ queue group resolution
→ local draft delivery
→ optional local provider dispatch
→ generated provider response
→ generated local draft delivery
→ manual browser insertion into selected ChatGPT tab
→ user reviews and sends manually
```

## Queue source modes

```text
all_insertable
  FIFO across all queued local draft deliveries in the active queue group.

chatgpt_captures
  Queued draft deliveries whose provider is chatgpt.

provider_responses
  Queued generated responses whose provider is a local provider.
```

## Manual-review boundary

```text
Provider dispatch: explicit user action
Browser insertion: explicit user action
Browser send: user-only action
```

## Lifecycle authority boundary

```text
local_llm.authority = Supervisor/code-svc
local_llm_router.authority = Supervisor/code-svc
llm_postgres.authority = Docker/Portainer
llamacpp_qwen36.authority = Docker/Portainer
vllm_rocm.authority = Docker/Portainer
```