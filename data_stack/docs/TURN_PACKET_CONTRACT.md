# TurnPacket Contract — Phase 1.5 packet-native evidence authority

## Purpose

Define the final Phase 1.5 evidence contract for one native `local_llm` turn.

A `TurnPacket` is the single complete evidence object for one accepted turn. It exists in two forms:

```text
in-memory TurnPacket:
  assembled during execution before persistence

durable TurnPacket:
  persisted by TurnRecorder into PostgreSQL packet rows, packet-owned content/artifact refs, metric facts, and packet group membership
```

The contract replaces Phase 1 run/eval/report/artifact form. Old row forms are not active authority.

## Immutable authority path

```text
external entrypoint
→ TurnExecutionRequest
→ TurnExecutionPlan
→ TurnExecutionService.execute()
→ TurnPacket
→ TurnRecorder.persist(turn_packet)
→ PacketSummaryEnvelope

read/query/export/UI
→ ProjectionService
→ ProjectionResult
→ serializer or renderer
```

Only three implementation authorities are sanctioned:

```text
TurnPacket:
  complete staged and persisted turn evidence object

TurnRecorder:
  only write boundary for packet-adjacent evidence

ProjectionService:
  only read/aggregation boundary for packet, group, metric, chart, export, and UI views
```

All other components are adapters, helpers, serializers, renderers, or private SQL helpers.

## Final schema boundary

Final active packet tables:

```text
eval.turn_packets
eval.turn_attempts
eval.turn_events
eval.turn_content_refs
eval.turn_artifacts
eval.metric_registry
eval.turn_metric_facts
eval.packet_groups
eval.packet_group_members
```

Final active local_llm substrate tables:

```text
local_llm.corpora
local_llm.sources
local_llm.documents
local_llm.chunks
local_llm.sessions
```

Forbidden active Phase 1 form:

```text
local_llm.runs
local_llm.run_retrievals
local_llm.run_artifacts
local_llm.turns as separate evidence table
eval.evidence_batches
eval.comparison_groups
eval.eval_reports
eval.eval_metrics
eval.eval_artifacts
model_runtime.*
old eval views
old report summary views
```

Useful concepts may survive only as packet-native data categories, never as old SQL/code form.

## Required per-turn evidence breadth

Every native turn-producing path must capture every relevant available layer of the turn:

```text
request intake:
  source kind, request id, idempotency key, idempotency scope hash,
  source_record_id when available, operator metadata, request labels

session / turn identity:
  session id, turn id when needed, turn ordinal when known, session defaults/locks

workflow/config resolution:
  workflow id/kind, model profile, RAG profile, prompt profile, corpus, retrieval method,
  config snapshot hash, effective config hash, resolved config snapshot JSON

RAG/search behavior:
  RAG directives, retrieval backend, query shape, top_k, fallback behavior, candidate count,
  returned count, included count, retrieval timing, warning codes

retrieval evidence:
  ranked candidates, scores, included/excluded status, source/document/chunk identities where privacy allows,
  privacy-safe placeholders where privacy mode applies

context construction:
  selected context count, character/token estimates, truncation status, truncation reason,
  source/document counts, context content refs

prompt construction:
  message count, prompt chars/tokens, prompt hashes, prompt content refs,
  system/user/context hash facts

provider request/response:
  provider type, safe base URL, served model, request metadata, raw response ref,
  assistant response ref, finish reason, token counts, throughput, latency, errors

exposed provider reasoning:
  only provider-returned/exposed reasoning or intermediate-response fields,
  never hidden model reasoning and never invented reasoning

artifacts:
  request, retrievals, context, prompt, response, provider raw response,
  diagnostics, reports, and other filesystem-backed outputs when produced

runtime evidence:
  runtime identity, endpoint facts, served model id, runtime root refs, model manifest refs,
  safe `/v1/models` metadata where available

timing and sequence:
  ordered event timeline, phase timings, attempt timing, artifact timing,
  recorder/manifest finalization timing

required event vocabulary:
  request_received
  plan_resolved
  rag_directives_resolved
  privacy_policy_resolved
  retrieval_started
  retrieval_completed
  retrieval_candidates_ranked
  context_built
  prompt_built
  provider_started
  provider_completed
  provider_exposed_reasoning_captured
  content_refs_written
  artifacts_written
  metrics_written
  runtime_evidence_captured
  group_membership_attached
  manifest_finalized
  packet_finalized
  failed

warnings/errors:
  warning codes, failure types, failure messages safe for current privacy mode,
  partial/failure status

privacy decisions:
  capture mode, privacy level, text_persisted, metadata_redacted,
  redaction policy version, payload policy, omitted/redacted markers

metrics:
  latency, token, char, retrieval/search, provider, artifact, warning, privacy,
  quality/operator metrics where present

group membership:
  experiment, condition, replicate, session comparison, manual packet set, analysis scope,
  included/excluded state and exclusion reason

manifest/outcome:
  write ledger, artifact outcomes, omissions, redactions, deferred links, failures
```

## Packet JSONB facet minimums

JSONB facets are structured contracts, not arbitrary blobs. They must preserve enough structured evidence for
`ProjectionService` to compare retrieval, context, prompt, provider behavior, timings, warnings, and privacy behavior
without opening artifact files.

### `request_summary_json`

```text
input_content_ref_id or input_hash
input_chars
request_metadata_keys
operator_labels
source_kind
source_adapter
```

Privacy rule: do not store raw user text in privacy mode.

### `search_observation_json`

```text
retrieval_method
backend
corpus_id
query_content_ref_id or query_hash
query_shape
top_k_requested
candidate_count
returned_count
included_count
fallback_used
fallback_reason
timing_ms
warning_codes
privacy_behavior
```

### `retrieval_summary_json`

```text
returned_count
included_count
unique_source_count
unique_document_count
ranked_items
score_fields_present
included_excluded_status
exclusion_reasons
overlap_ready_ids_where_privacy_permits
privacy_placeholder_policy
```

### `context_summary_json`

```text
included_count
context_chars
context_token_estimate
truncated
truncation_reason
unique_source_count
unique_document_count
content_ref_ids
```

### `prompt_summary_json`

```text
message_count
prompt_chars
prompt_token_estimate
content_ref_ids
system_hash
user_hash
context_hash
prompt_profile_id
```

### `provider_summary_json`

```text
provider_type
safe_base_url
model
served_model_id
status
finish_reason
prompt_tokens
completion_tokens
total_tokens
prompt_per_second
completion_per_second
latency_ms
error_type
error_message_safe
raw_response_content_ref_id
assistant_response_content_ref_id
exposed_reasoning_content_ref_id when present
```

### `runtime_links_json`

```text
runtime_id
runtime_root
endpoint_base_url_safe
models_payload_ref_or_hash
served_model_ids
runtime_manifest_path
model_manifest_path
runtime_probe_status
```

### `privacy_json`

```text
capture_mode
privacy_level
text_persisted
metadata_redacted
redaction_policy_version
payload_policy_by_role
identity_policy_by_layer
redaction_markers
omission_markers
```

### `manifest_json`

```text
write_status
attempt_count
content_ref_count
artifact_count
metric_fact_count
group_membership_count
artifact_outcomes
omissions
redactions
deferred_links
failures
finalized_at
```

`manifest_json` is a write ledger, not a duplicate evidence store.

## Attempts, retries, and replicates

A **replicate** is one independent `TurnPacket` intentionally created for an experiment condition. Replicates are the
rows used for baseline averages, variable-condition averages, deltas, rankings, and comparison charts.

An **attempt** is one execution try inside a `TurnPacket`. Attempts record runtime behavior such as provider failures,
retries, partial completions, repair attempts, artifact-write failures, and timing instability.

Rules:

```text
a five-run baseline = five independent baseline TurnPackets
a retry inside one packet = an additional turn_attempts row
a retry is not a new datapoint
experiment aggregates use included replicate packet memberships
failed packets remain inspectable
replacement requires explicit exclusion of the failed packet and inclusion of the replacement packet
```

Packet `source_kind` must not use retry as a final SQL/domain value. Normal retry behavior belongs only in
`eval.turn_attempts.attempt_kind='retry'`.

Final allowed packet source kinds:

```text
respond
session_turn
experiment_replicate
router_handoff
backfill_import
```

Contract tests must fail if `eval.turn_packets.source_kind` permits `retry`. Replacement runs are represented as new
packets with packet-group exclusion/replacement membership; they are not packet-level retry rows.

## Content refs

`eval.turn_content_refs` is the unified access contract for text or content-like payloads.

Supported content roles:

```text
user_input
retrieval_query
retrieved_chunk_snapshot
context_text
prompt_messages
provider_request
provider_raw_response
provider_exposed_reasoning
assistant_response
diagnostics
packet_summary
```

Supported storage kinds:

```text
inline_text
file_ref
redacted_inline
redacted_file
omitted
non_text_file
```

Callers ask for a `content_ref_id` and receive content or a structured unavailable marker. Callers must not need to know
whether the content is inline, file-backed, redacted, omitted, or non-text.

## Exposed provider reasoning boundary

The system may capture provider-exposed reasoning or intermediate-response fields only when the provider response
actually includes those fields.

Allowed:

```text
OpenAI-compatible response fields explicitly returned by the endpoint
llama.cpp/vLLM provider raw-response fields explicitly returned by the endpoint
provider-visible intermediate content or reasoning_content when present
metadata indicating exposed reasoning was absent
```

Forbidden:

```text
invented reasoning
hidden chain-of-thought reconstruction
model-internal state not returned by the provider
UI-only speculation about how an answer was produced
```

Privacy rules apply before persistence.

## Artifact refs

`eval.turn_artifacts` indexes filesystem-backed outputs. Raw artifact bodies remain filesystem authority.

Artifact outcomes are recorded in packet manifest:

```text
not_written
written_unindexed
written_indexed
omitted_by_policy
redacted
failed_hash_mismatch
failed_db_insert
orphaned_file
```

Artifact writes must follow:

```text
write temp file
hash temp file
atomic rename to final path
verify final hash
insert artifact row only after final file exists and hash matches
record failure/orphan status in manifest_json
```

## Privacy-before-persistence

Privacy enforcement applies before persistence to:

```text
packet JSONB facets
event payloads
content refs
artifact refs
metric facts
packet group metadata
manifest metadata
projection outputs
```

Privacy mode may store safe counts, timings, hashes when non-content-revealing, safe warning codes, policy versions,
redaction markers, omission markers, and nonjoinable placeholders.

Privacy mode must not store private user text, private assistant text, private prompt/context/provider message content,
private artifact bodies, content-revealing source titles/paths, joinable source/document/chunk IDs when strict privacy
blocks them, freeform private metadata, or topic summaries derived from private text.

## Idempotency

If `idempotency_key` is supplied, `idempotency_scope_hash` must also be supplied.

The same source/request/scope must resolve to the existing packet or fail safely. It must not silently create another
experimental replicate.

## Import/backfill

`backfill_import` exists only for explicitly approved packet-native imports.

Rules:

```text
not required for Phase 1.5 success
must write into TurnPacket form
must set source_system='phase1_backfill'
must set source_record_id when source identity exists
must set capture_status='imported'
must set is_imported=true
must not preserve old SQL form
must not preserve old run/eval/report identity as authority
must not validate or replace native capture behavior
```

## Acceptance gates

Phase 1.5 TurnPacket implementation is accepted only when:

```text
respond path creates a packet
session turn path creates a packet
experiment replicate path creates one independent packet per replicate
retry creates an attempt, not a replicate
privacy mode persists no private text
full mode persists maximal relevant evidence
ProjectionService reads packet detail without old views
ProjectionService compares packet groups without UI/export math
old run/eval/report table families are absent
old writer paths are not called
vector behavior remains inactive
```