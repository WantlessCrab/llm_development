# data_stack Impact Ledger

## Current authority

`data_stack` is the PostgreSQL schema, migration, and contract-test authority for Phase 1.5.

Final active database shape:

```text
core
  schema metadata
  migration records
  boot checks

local_llm
  corpora
  sources
  documents
  chunks
  sessions
  postgres_fts search_vector substrate

eval
  turn_packets
  turn_attempts
  turn_events
  turn_content_refs
  turn_artifacts
  metric_registry
  turn_metric_facts
  packet_groups
  packet_group_members
```

## Clean-cutover decision

Phase 1.5 does not preserve pre-Phase-1.5 database data or legacy schema form.

Deleted or excluded forms:

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
old eval summary/read views
tools/evidence_catalog.py
```

Useful concepts may survive only as packet-native categories:

```text
TurnPacket facets
content refs
artifact refs
metric facts
packet groups
packet group members
runtime links/facets
events
attempts
manifest state
```

## Implemented Phase 1.5 data_stack batches

### Batch 1 — schema replacement

Final active schema migration:

```text
data_stack/db/migrations/010_final_phase_1_5_schema.sql
```

Old active migrations removed from active path:

```text
010_local_llm_schema.sql
020_postgres_fts.sql
030_eval_runtime_catalog.sql
040_always_on_eval_capture.sql
050_turn_packet_core.sql
```

### Batch 2 — contract docs

Final contract docs:

```text
TURN_PACKET_CONTRACT.md
PACKET_GROUP_CONTRACT.md
METRIC_REGISTRY_CONTRACT.md
PROJECTION_SERVICE_CONTRACT.md
STORE_PROTOCOL_CONTRACT.md
STORAGE_CONTRACT.md
LOCAL_LLM_SCHEMA_CONTRACT.md
POSTGRES_FTS_CONTRACT.md
RUNTIME_CONTRACT.md
IMPACT_LEDGER.md
```

### Batch 3 — contract tests and tooling cleanup

Final packet-native test set:

```text
test_apply_migrations.py
test_turn_packet_contract.py
test_privacy_turn_packet_contract.py
test_packet_group_contract.py
test_metric_registry_contract.py
```

Deleted Phase 1 tests/tooling:

```text
test_always_on_eval_capture_contract.py
test_eval_capture_views_contract.py
test_eval_runtime_catalog_contract.py
test_privacy_capture_contract.py
test_evidence_catalog_helpers.py
tools/evidence_catalog.py
```

## Current validation target

```bash
cd /home/wantless/PycharmProjects/automation/data_stack
python3 -m compileall -q tools tests
python3 -m pytest -q
```

Expected result after this cleanup pass:

```text
active migration path contains only 010_final_phase_1_5_schema.sql
old Phase 1 migrations are absent
old Phase 1 tests/tooling are absent
SQL has no token-split casts
packet source_kind excludes retry
attempt_kind includes retry
old run/eval/report/model_runtime tables are absent
old eval views are absent
metric registry contains search/RAG/provider/privacy/quality keys
packet groups represent experiments, conditions, replicates, comparisons, and manual sets
```

## Next project batch

After `data_stack` validation passes, the next active work moves to `local_llm` application code:

```text
TurnPacket
TurnExecutionRequest
TurnExecutionPlan
TurnExecutionService
TurnRecorder
ProjectionService
packet groups
experiments
analysis/session comparison
packet-native StoreProtocol/PostgresStore
```

The `local_llm` refactor must align to this `data_stack` authority rather than recreating old run/eval/report sprawl.