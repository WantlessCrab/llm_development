# Projection Service Contract — read and aggregation boundary

## Purpose

Define `ProjectionService` as the only read, aggregation, comparison, chart/table preparation, and export-data boundary
for packet-native evidence.

`ProjectionService` replaces old eval/report views as active read authority.

## Non-negotiable rule

UI, CLI, Markdown export, CSV export, JSON export, HTML report, and future dashboards may render or serialize
`ProjectionResult`.

They must not compute authoritative averages, deltas, replicate counts, included/excluded counts, privacy eligibility,
metric definitions, ranking direction, or baseline comparison math.

## Public operations

Required operation families:

```text
packet_detail(turn_packet_id)
packet_list(filters)
packet_group_detail(packet_group_id)
packet_group_comparison(packet_group_id, metric_keys=None, pivot=None)
available_metrics(scope=None)
content_payload(content_ref_id)
```

Optional convenience names may wrap these, but all read/aggregation logic must remain inside `ProjectionService`.

## ProjectionResult shape

A `ProjectionResult` must contain:

```text
ok
projection_kind
scope
filters
query_metadata
privacy_summary
metric_registry_snapshot
rows
columns
chart_payload
drilldown_links
warnings
errors
```

For packet detail:

```text
packet
attempts
events
content_refs
artifacts
metric_facts
group_memberships
manifest
available_actions
```

For group comparison:

```text
group
members
conditions
replicate_counts
included_count
excluded_count
failed_count
partial_count
metric_rows
aggregate_rows
baseline_group_id
deltas
chart_payload
drilldown_links
```

## Packet detail projection

Packet detail must show packet identity, source kind, capture status, capture mode, privacy level, session identity,
workflow/model/RAG/prompt ids, config hashes, search/retrieval/context/prompt/provider summaries, runtime links,
attempts, ordered event timeline, content refs, artifact refs, metric facts, group membership, manifest outcomes, and
warnings/errors.

Privacy mode returns unavailable markers instead of private text.

## Packet list projection

Packet list supports filters by:

```text
created_at range
capture status
capture mode
privacy level
session id
workflow id
model profile id
rag profile id
prompt profile id
corpus id
packet group id
metric key presence
source kind
```

Packet list must not open artifact files to compute core list facts.

## Group comparison projection

Group comparison must use:

```text
eval.packet_groups
eval.packet_group_members
eval.turn_packets
eval.turn_metric_facts
eval.metric_registry
```

It must not use old eval views or old run/report tables.

Aggregate math uses included packet members, registry aggregation defaults, privacy-safe facts for privacy-restricted
output, and replicate rows, not attempt rows.

Required counts:

```text
included_packet_count
excluded_packet_count
failed_packet_count
partial_packet_count
replicate_count
attempt_count
```

## Metric discovery

Metric discovery comes from `eval.metric_registry`.

Projection output must include enough metric metadata for clients to display data without recomputing semantics.

## Content loading

`content_payload(content_ref_id)` returns one of:

```text
inline text
file-backed text
redacted marker
omitted marker
non-text file marker
missing file marker
policy unavailable marker
```

Callers do not inspect storage kind directly except for display.

## Privacy projection

ProjectionService enforces privacy at read time in addition to write-time redaction.

ProjectionService must suppress or mark unavailable private body text, private prompt/context/provider message content,
private retrieval snapshots, content-revealing metadata, joinable private retrieval identities, and private artifact
body paths where policy forbids disclosure.

ProjectionService may expose packet ids, counts, timings, status, workflow/model/RAG/prompt ids, safe hashes, safe
warning codes, safe metrics, and privacy policy markers.

## Chart/table payloads

Chart/table payloads are derived from `ProjectionResult`.

They must include:

```text
source projection id
metric key
aggregation method
grouping/pivot
rows
columns
privacy summary
drilldown packet ids
```

No chart/export payload is a durable table family.

## SQL helper allowance

Private SQL helpers are allowed inside the store/projection layer.

Forbidden permanent read surfaces:

```text
new packet summary view
new packet detail view
new experiment aggregate view
new chart payload table
new export payload table
new report table
old eval report summary view as active dependency
```

A SQL view may be added only after a concrete implementation blocker proves it is required for correctness or
performance.

## Acceptance gates

ProjectionService is accepted when:

```text
packet detail works from packet tables only
packet list works from packet tables only
group comparison works from packet groups only
metric discovery works from metric registry
serializer tests prove no external aggregate math
privacy tests prove unavailable markers replace private content
old eval/report views are absent or unused
```