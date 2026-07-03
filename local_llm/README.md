# local_llm

`local_llm` is a host-local source-grounded LLM backend. Phase 1.5 uses packet-native evidence capture: every native
turn is represented by one `TurnPacket`, persisted by `TurnRecorder`, and inspected or compared through
`ProjectionService`.

## Authority

Source tree:

```text
/home/wantless/PycharmProjects/automation/local_llm
```

Runtime config:

```text
~/.config/local-llm/config.yaml
```

Runtime password env:

```text
~/.config/local-llm/local-llm.env
```

PostgreSQL database:

```text
llm_database on 127.0.0.1:8032
```

Artifact root:

```text
~/.local/share/local-llm/artifacts
```

HTTP service:

```text
http://127.0.0.1:8020
```

`data_stack` is the PostgreSQL schema authority. The final active storage form is:

```text
local_llm.corpora
local_llm.sources
local_llm.documents
local_llm.chunks
local_llm.sessions

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

Old run/eval/report/model_runtime/SQLite forms are not active and are not preserved as compatibility surfaces.

## Runtime flow

```text
TurnExecutionRequest
→ TurnExecutionPlan
→ TurnExecutionService
→ retrieval/context/prompt/provider execution
→ in-memory TurnPacket
→ TurnRecorder.persist(turn_packet)
→ PostgreSQL packet rows + filesystem artifacts
→ PacketSummaryEnvelope
→ ProjectionService inspection/comparison
```

## Capture modes

### Full mode

Full mode persists inspectable turn-layer evidence when policy allows: user input, selected context, prompt, provider
request/response, assistant response, content refs, artifacts, metric facts, events, timings, runtime links, privacy
decisions, and group membership.

### Privacy mode

Privacy mode returns the live answer but suppresses private body text before persistence. It stores safe operational
facts and explicit omitted/redacted markers.

Privacy mode does not persist:

```text
private user text
private assistant text
private prompt/context/provider message body
private artifact bodies
raw retrieval chunk text
raw document paths
raw source titles
joinable private retrieval identities
content-revealing metadata forbidden by policy
```

## Retrieval

Phase 1.5 active retrieval is PostgreSQL full-text search only:

```text
postgres_fts
```

Vector, hybrid, and rerank methods are not active. Any config attempting to activate those methods is invalid in Phase
1.5.

## Core commands

```bash
local-llm doctor --skip-provider
local-llm doctor
local-llm ingest primary_local_corpus
local-llm search project_basic "provider contract"
local-llm respond default_rag_answer "Explain the project structure and cite retrieved sources."
local-llm respond default_rag_answer "Private diagnostic request" --privacy-mode --privacy-level strict
local-llm packet list
local-llm packet show <turn_packet_id>
local-llm packet content <content_ref_id>
local-llm metrics
local-llm group show <packet_group_id>
local-llm projection --packet-group-id <packet_group_id>
local-llm db-summary
```

There are no native `run` commands in the Phase 1.5 cutover.

## HTTP endpoints

```text
GET  /health
GET  /api/v1/doctor
GET  /api/v1/config/summary
POST /api/v1/corpora/{corpus_id}/ingest
POST /api/v1/search
POST /api/v1/respond
GET  /api/v1/sessions
POST /api/v1/sessions
GET  /api/v1/sessions/{session_id}
PATCH /api/v1/sessions/{session_id}
POST /api/v1/sessions/{session_id}/archive
GET  /api/v1/sessions/{session_id}/turns
POST /api/v1/sessions/{session_id}/turns
GET  /api/v1/packets
GET  /api/v1/packets/{turn_packet_id}
GET  /api/v1/content/{content_ref_id}
GET  /api/v1/metrics
GET  /api/v1/groups/{packet_group_id}
POST /api/v1/projection
GET  /api/v1/groups/{packet_group_id}/projection
POST /api/v1/experiments/run-matrix
POST /api/v1/analysis/compare-sessions
GET  /api/v1/admin/summary
```

## Experiment use case

A baseline-vs-variable RAG test is represented with packet groups:

```text
experiment parent group
→ baseline condition group
  → five replicate TurnPackets
→ variable condition group
  → five replicate TurnPackets
```

Each replicate is a separate packet. Retry attempts do not count as replicates. `ProjectionService` computes
condition-level metric rows from packet group membership and `turn_metric_facts`.

## Validation

```bash
cd /home/wantless/PycharmProjects/automation/local_llm
PYTHONPATH=src python3 -m compileall -q src/local_llm
PYTHONPATH=src python3 -m pytest -q
```

PostgreSQL integration requires the `data_stack` database and password env:

```bash
set -a; source /home/wantless/PycharmProjects/automation/data_stack/.env; set +a
export LOCAL_LLM_POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
```