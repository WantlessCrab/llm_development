# Runtime Contract — packet-native runtime evidence boundary

## Purpose

Define runtime authority, database/runtime boundary, and how runtime evidence is captured after the Phase 1.5 clean
cutover.

## Authority decision

Database code records runtime evidence. It does not manage runtime lifecycle.

`local_llm` owns:

```text
retrieval
context construction
prompt construction
provider calls
TurnPacket assembly
TurnRecorder persistence
ProjectionService reads
```

Model runtimes own:

```text
model server process
GPU execution
served model aliases
endpoint health
model loading
runtime logs
```

## Runtime lifecycle non-authority

Database/eval code must not manage:

```text
Docker
Docker Compose
Portainer
ROCm
GPU devices
llama.cpp process lifecycle
vLLM process lifecycle
model file placement
model download
model checksum creation
runtime startup/restart/stop
```

## Current model runtimes

Known external OpenAI-compatible runtimes include:

```text
llama.cpp qwen36_35b_q4:
  http://127.0.0.1:8023/v1

vLLM local-small:
  http://127.0.0.1:8021/v1
```

These are provider endpoints, not database-managed services.

## Runtime evidence storage

Runtime evidence is packet-owned.

Primary storage surfaces:

```text
eval.turn_packets.runtime_links_json
eval.turn_packets.provider_summary_json
eval.turn_attempts.provider_evidence_json
eval.turn_events
eval.turn_metric_facts
eval.turn_content_refs for provider raw response
eval.turn_artifacts for filesystem-backed runtime/provider artifacts when produced
```

No active `model_runtime` schema is present in Phase 1.5.

## Runtime evidence categories

Capture available runtime evidence such as:

```text
runtime_id
runtime_root
provider type
safe base URL
models endpoint status
served model ids
configured model id
runtime manifest path
model manifest path
model hash reference where available
runtime probe timestamp
provider latency
provider token counts
throughput
finish reason
provider errors
raw response ref
exposed provider reasoning ref when present
```

## Exposed reasoning

Runtime/provider evidence may include exposed reasoning only when the provider returns it.

Allowed:

```text
provider raw-response field explicitly returned by endpoint
reasoning_content returned by local endpoint
intermediate response field returned by local endpoint
absence marker when no reasoning field is returned
```

Forbidden:

```text
hidden chain-of-thought
model-internal state
assistant-side speculation
reconstructed reasoning
```

## Runtime facts as metrics

Examples:

```text
provider.finish_reason
provider.prompt_per_second
provider.completion_per_second
tokens.prompt
tokens.completion
tokens.total
latency.provider_ms
```

## Runtime privacy

Runtime evidence must not leak private prompt/context/user/assistant text in privacy mode.

Allowed privacy-safe runtime evidence:

```text
runtime id
served model id
safe endpoint identity
latency
token counts
finish reason
throughput
status codes
error class
```

Forbidden in privacy mode:

```text
raw prompt messages
raw provider request body
raw provider response body containing private answer text
content-revealing freeform metadata
```

## Vector/GPU boundary

The PostgreSQL container is CPU-only.

Do not add ROCm, PyTorch, llama.cpp, vLLM, GPU devices, model files, or embedding model files to the database container.

`vector` extension is inert database substrate only. It does not imply active vector retrieval.

## Acceptance gates

Runtime evidence contract is accepted when:

```text
provider call captures safe runtime/provider facts
raw provider response is represented by content ref or artifact ref
exposed provider reasoning is captured only when present
runtime evidence is packet-owned
no model_runtime schema/table is required
database tooling never starts/stops Docker or model runtimes
privacy mode redacts provider request/response body content before persistence
```