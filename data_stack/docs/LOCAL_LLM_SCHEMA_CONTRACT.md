# Local LLM Schema Contract — final Phase 1.5 active database shape

## Purpose

Define the final active PostgreSQL schema used by `local_llm` after Phase 1.5.

This document replaces Phase 1 local_llm run/eval/report compatibility contracts.

## Final active schemas

```text
core
local_llm
eval
```

Not active:

```text
model_runtime
```

Runtime evidence is packet-owned through `eval.turn_packets.runtime_links_json`,
`eval.turn_attempts.provider_evidence_json`, `eval.turn_events`, and `eval.turn_metric_facts`.

## Final local_llm substrate

Active tables:

```text
local_llm.corpora
local_llm.sources
local_llm.documents
local_llm.chunks
local_llm.sessions
```

Purpose:

```text
corpora:
  configured corpus identities and config snapshots

sources:
  source units included in corpora

documents:
  indexed document versions

chunks:
  retrievable text chunks and postgres_fts search_vector

sessions:
  UI/API session identities and default capture/privacy settings
```

`local_llm` owns app/retrieval substrate only. Turn evidence is owned by `eval.turn_packets`.

## Final eval packet substrate

Active tables:

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

## Deleted active forms

These forms are deleted, replaced, or excluded from the final active schema:

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
model_runtime.runtime_snapshots
model_runtime.model_files
model_runtime.runtime_artifacts
old eval views
old report views
```

Any useful prior concept survives only if re-expressed inside TurnPacket form.

## Turn identity

Turn identity belongs to `eval.turn_packets`.

Allowed turn identity fields on packet:

```text
session_id
turn_id
turn_ordinal
source_kind
request_id
idempotency_key
idempotency_scope_hash
```

Final allowed `source_kind` values:

```text
respond
session_turn
experiment_replicate
router_handoff
backfill_import
```

`retry` is not a packet source kind. Retry behavior is attempt-level evidence in `eval.turn_attempts`.

A separate `local_llm.turns` table is not active in Phase 1.5 unless a later final requirement proves that session
transcript identity cannot be represented through packets.

## Retrieval substrate

`local_llm.chunks.search_vector` is the active PostgreSQL FTS substrate.

Search config:

```text
simple
```

Final retrieval method:

```text
postgres_fts
```

No active vector, hybrid, rerank, `pg_trgm`, or unaccent retrieval behavior exists in Phase 1.5.

## Privacy state

Privacy state belongs to packet evidence.

Primary fields:

```text
eval.turn_packets.capture_mode
eval.turn_packets.privacy_level
eval.turn_packets.text_persisted
eval.turn_packets.metadata_redacted
eval.turn_packets.redaction_policy_version
eval.turn_content_refs.capture_mode
eval.turn_content_refs.privacy_level
eval.turn_content_refs.body_persisted
eval.turn_content_refs.payload_policy
eval.turn_artifacts.capture_mode
eval.turn_artifacts.privacy_level
eval.turn_artifacts.body_persisted
eval.turn_artifacts.payload_policy
```

## Session defaults

`local_llm.sessions` may store:

```text
default_workflow_id
default_model_profile
default_rag_profile
default_prompt_profile
default_capture_mode
default_privacy_level
privacy_locked
```

Session defaults must be attached to `TurnExecutionRequest` before provider execution.

## Final migration authority

Final active schema migration:

```text
data_stack/db/migrations/010_final_phase_1_5_schema.sql
```

Old active migration chain is removed from active path:

```text
010_local_llm_schema.sql
020_postgres_fts.sql
030_eval_runtime_catalog.sql
040_always_on_eval_capture.sql
```

## Verification queries

Required final table presence:

```sql
SELECT table_schema, table_name
FROM information_schema.tables
WHERE table_schema IN ('local_llm', 'eval')
ORDER BY table_schema, table_name;
```

Forbidden old table absence:

```sql
SELECT table_schema, table_name
FROM information_schema.tables
WHERE (table_schema = 'local_llm' AND table_name IN ('runs', 'run_retrievals', 'run_artifacts', 'turns'))
   OR (table_schema = 'eval' AND table_name IN ('evidence_batches', 'comparison_groups', 'eval_reports', 'eval_metrics', 'eval_artifacts'))
   OR table_schema = 'model_runtime'
ORDER BY table_schema, table_name;
```

Expected result for forbidden query:

```text
zero rows
```

Final schema migration proof:

```sql
SELECT migration_id
FROM core.applied_migrations
WHERE migration_id = '010_final_phase_1_5_schema';
```