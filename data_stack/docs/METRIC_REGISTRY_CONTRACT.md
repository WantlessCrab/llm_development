# Metric Registry Contract

## Purpose

`eval.metric_registry` defines metric keys, display semantics, value types, aggregation defaults, privacy safety, and
source-layer meaning.

`eval.turn_metric_facts` stores actual packet/group/session metric values.

Metrics are registry-backed so experiments, session comparisons, UI tables, CLI output, and exports can discover
available metrics without hardcoded per-report math.

## Tables

```text
eval.metric_registry
eval.turn_metric_facts
```

Old `eval.eval_metrics` form is deleted and not a compatibility surface.

## Metric key shape

Metric keys are stable dotted strings:

```text
latency.total_ms
tokens.prompt
search.top_k_requested
retrieval.unique_source_count
privacy.text_persisted
quality.operator_score
```

Metric keys are not display labels. Display labels live in `metric_registry.display_name`.

## Required registry fields

```text
metric_key
namespace
display_name
description
unit
value_type
aggregation_default
higher_is_better
privacy_safe
source_layer
active
metadata_json
```

## Required fact fields

```text
metric_fact_id
turn_packet_id
turn_attempt_id
owner_type
owner_id
metric_key
metric_value_num
metric_value_text
metric_json
unit
privacy_safe
source
created_at
```

## Allowed fact sources

```text
derived
provider
runtime
recorder
projection
operator
```

`quality` is not a source. It is a namespace. Operator quality labels use:

```text
metric_key='quality.operator_score'
source='operator'
```

## Required namespaces

```text
latency
tokens
chars
search
retrieval
context
provider
artifact
warning
privacy
quality
```

## Required search/RAG metrics

```text
search.candidate_count
search.returned_count
search.included_count
search.top_k_requested
retrieval.returned_count
retrieval.included_count
retrieval.unique_source_count
retrieval.unique_document_count
context.truncated
context.char_count
```

These support RAG variable experiments without introducing separate search-stage tables.

## Required quality readiness

```text
quality.operator_score
quality.operator_label
```

These provide future manual tuning labels without creating a separate quality table.

## Prior concept-name mapping

Some old concept names may map to final metric keys for developer orientation and app-code producer migration.

This is not a legacy data import path.

No old `eval_metrics` rows are preserved. No pre-Phase-1.5 metric data is required. Any producer that once emitted an
old metric name must emit final registry keys directly.

## Projection authority

`ProjectionService` owns metric discovery and aggregate preparation.

No UI, CLI, export, report, or serializer layer may compute authoritative averages, deltas, replicate counts, metric
definitions, or privacy eligibility independently.