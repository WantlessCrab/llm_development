# Storage Contract

## Purpose

Storage defines where durable bytes and durable references live.

Phase 1.5 separates body storage from evidence indexing:

```text
PostgreSQL
  packet identity
  packet JSONB facets
  content refs
  artifact refs
  metric facts
  packet group membership
  manifest metadata

filesystem
  raw artifact bodies when policy permits body persistence
```

## PostgreSQL authority

PostgreSQL stores final packet-native records only.

Active evidence tables:

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

PostgreSQL does not store:

```text
old run artifact rows
old eval report rows
old eval metric rows
old eval artifact rows
old model_runtime rows
raw artifact blobs by default
```

## Filesystem authority

Filesystem artifact bodies are written only through recorder-owned staging/finalization.

Required artifact write flow:

```text
write temporary file
compute sha256
compute size_bytes
atomic rename into final location
insert eval.turn_artifacts row
optionally insert eval.turn_content_refs row
record manifest outcome
```

If final indexing fails after body write, the recorder must preserve an orphan-manifest fact so cleanup can identify the
file. Silent orphaning is invalid.

## Privacy

Privacy mode must not persist private body text or private artifact bodies.

Privacy mode may persist:

```text
safe counts
safe timings
safe status facts
safe metric facts
redacted/omitted content refs
privacy policy facts
nonjoinable identifiers
```

Privacy mode must not persist:

```text
private user input
private assistant response text
private prompt/context/provider message content
private artifact bodies
joinable source/document/chunk IDs when policy forbids them
content-revealing source titles/paths when policy forbids them
```

Privacy enforcement happens before persistence.

## Import/backfill

There is no current import/backfill implementation in `data_stack`, and no pre-Phase-1.5 data is required for Phase 1.5
success.

If future import/backfill is approved, it must be packet-native:

```text
source_system='phase1_backfill'
capture_status='imported'
is_imported=true
source_record_id set when available
```

It must not preserve or depend on old run/eval/report schema form.

## Deleted legacy form

The final storage contract excludes:

```text
local_llm.runs
local_llm.run_retrievals
local_llm.run_artifacts
local_llm.turns as separate evidence table
eval.eval_reports
eval.eval_metrics
eval.eval_artifacts
eval.evidence_batches
eval.comparison_groups
model_runtime.*
old eval views
tools/evidence_catalog.py
```