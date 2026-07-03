# PostgreSQL FTS Contract — active retrieval behavior

## Purpose

Define `postgres_fts` retrieval semantics for Phase 1.5 and the packet evidence that must be captured for every
retrieval-using turn.

## Active method

```text
postgres_fts
```

Only active retrieval method in Phase 1.5.

## Schema substrate

```text
local_llm.chunks.text
local_llm.chunks.search_vector
idx_chunks_search_vector
```

`search_vector` uses:

```text
to_tsvector('simple', text)
```

## Query behavior

Stage 1:

```text
websearch_to_tsquery('simple', normalized full query)
```

Stage 2 fallback:

```text
only if Stage 1 returns no rows
sanitize meaningful tokens
build OR query
pass to to_tsquery('simple', fallback_query)
```

## Security

Rules:

```text
user text is passed as SQL parameter
fallback tokens are sanitized
user query is never string-formatted into SQL
fallback query construction must use only sanitized token vocabulary
```

## Ranking

```text
ts_rank_cd
score DESC
normalized_score = null unless explicitly implemented later
```

## Packet capture requirement

Every retrieval-using turn must capture retrieval behavior into:

```text
eval.turn_packets.search_observation_json
eval.turn_packets.retrieval_summary_json
eval.turn_events
eval.turn_metric_facts
eval.turn_content_refs when query/content refs are persisted
```

Minimum `search_observation_json` facts:

```text
retrieval_method=postgres_fts
backend=postgresql
search_config=simple
stage_1_query_shape
stage_2_fallback_query_shape when used
fallback_used
fallback_reason
top_k_requested
candidate_count
returned_count
included_count
timing_ms
warning_codes
privacy_behavior
```

Minimum metrics:

```text
search.candidate_count
search.returned_count
search.included_count
search.top_k_requested
retrieval.returned_count
retrieval.included_count
retrieval.unique_source_count
retrieval.unique_document_count
latency.retrieval_ms
```

## Privacy behavior

Retrieval behavior does not change for privacy mode.

Persistence changes after retrieval.

Privacy mode may use real retrieved chunks during live response generation, but persisted packet evidence must suppress
private text and joinable identities when privacy policy requires it.

Privacy-mode persisted retrieval evidence must not expose chunk text, raw query text, joinable chunk/document/source
IDs, document path, source title, or source version.

Allowed privacy-safe facts include counts, timings, fallback_used, top_k, warning codes, non-content hashes, redaction
markers, omission markers, and nonjoinable placeholders.

## Non-goals

Not active in Phase 1.5:

```text
embeddings
vector search
hybrid search
reranker
pg_trgm
unaccent
fuzzy search
score normalization
embedding tables
vector indexes
```

The `vector` extension may be installed as inert future substrate but is not active retrieval behavior.

## Acceptance gates

`postgres_fts` is accepted when:

```text
search returns results from local_llm.chunks.search_vector
retrieval semantics match the two-stage query behavior
TurnPacket captures query shape, counts, timings, warnings, and privacy behavior
privacy-mode retrieval persistence contains no private text or forbidden joinable identities
no vector/hybrid/rerank code path is active
```