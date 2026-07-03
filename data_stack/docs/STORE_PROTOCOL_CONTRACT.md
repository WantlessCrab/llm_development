# Store Protocol Contract

## Purpose

The store layer is the persistence boundary used by `local_llm` application code. In Phase 1.5 it must expose
packet-native operations only.

The store must not expose old run/eval/report write or read authority.

## Final public store surface

The public store protocol should support these categories:

```text
corpus/source/document/chunk ingestion
postgres_fts search support
session identity/defaults
TurnPacket persistence backing
packet detail/list reads
content ref loading
metric discovery
packet group creation/membership
ProjectionService backing queries
summary/diagnostic facts
```

## Required packet write boundary

All packet-adjacent writes must be owned by `TurnRecorder`.

Allowed packet write operation:

```text
persist_turn_packet(turn_packet)
```

`persist_turn_packet` may internally write:

```text
eval.turn_packets
eval.turn_attempts
eval.turn_events
eval.turn_content_refs
eval.turn_artifacts
eval.turn_metric_facts
eval.packet_groups
eval.packet_group_members
filesystem artifact bodies through recorder-owned staging/finalization
```

No route, CLI command, session handler, provider handler, retrieval helper, prompt builder, artifact helper, or
projection serializer may write those tables directly.

## Required read boundary

All packet/group/metric aggregation must be owned by `ProjectionService`.

Projection backing operations may read:

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
local_llm.sessions
local_llm.corpora
local_llm.sources
local_llm.documents
local_llm.chunks
```

Projection backing operations must not require permanent SQL views.

## Forbidden old public methods

The final store protocol must not expose old Phase 1 active methods such as:

```text
insert_run
get_run
list_runs
insert_run_retrieval
get_run_retrievals
insert_run_artifact
get_run_artifacts
link_turn_run
create_evidence_batch
complete_evidence_batch
insert_eval_report
insert_eval_metric
insert_eval_artifact
link_run_eval_report
link_turn_eval_report
get_eval_report_for_run
get_eval_metrics_for_run
get_eval_artifacts_for_run
upsert_runtime_snapshot
upsert_model_file
insert_runtime_artifact
```

If a later UI or CLI preserves old command names as aliases, those aliases must resolve to packet/projection methods and
must not reintroduce old table authority.

## SQLite

SQLite is not part of the final Phase 1.5 runtime or forensic contract.

Do not keep a SQLite store, SQLite migration adapter, SQLite import contract, or SQLite fallback in the final
`local_llm` packet path.

## Evidence catalog

`data_stack/tools/evidence_catalog.py` is deleted. It is not a schema authority, runtime authority, import authority, or
validation command.

Future import/backfill tooling, if ever approved, must be newly scoped and packet-native. It must write final TurnPacket
form directly and must not preserve old schema form.

## Validation

The store layer is valid only when:

```text
TurnRecorder owns all packet writes
ProjectionService owns all aggregate reads
PostgresStore does not expose old run/eval/report public methods
SQLiteStore is absent or unreachable from native runtime
route/API/CLI code cannot write packet tables directly
tests prove old writer/store/run/eval paths are not called
```