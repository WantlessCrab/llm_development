# Packet Group Contract — experiments, comparisons, and analysis scopes

## Purpose

Define `eval.packet_groups` and `eval.packet_group_members` as the only physical organization model for experiments,
conditions, replicates, session comparisons, manual packet sets, and workflow/model/RAG/prompt/privacy scopes.

This replaces old comparison-group forms and avoids separate experiment, condition, replicate, analysis collection, and
analysis member table families.

## Physical tables

```text
eval.packet_groups
eval.packet_group_members
```

No separate physical table families are allowed for:

```text
experiments
experiment_conditions
experiment_replicates
analysis_collections
analysis_collection_members
session_comparison_members
manual_packet_sets
```

## Group kinds

Allowed `group_kind` values:

```text
experiment
condition
analysis_collection
session_comparison
manual_packet_set
workflow_scope
model_scope
rag_scope
prompt_scope
privacy_scope
```

Meaning:

```text
experiment:
  top-level planned experiment, usually baseline plus variable conditions

condition:
  child group under an experiment; represents baseline or one variable setting

analysis_collection:
  user-defined collection of packets/sessions/scopes for inspection

session_comparison:
  packet group representing one or more sessions to compare

manual_packet_set:
  explicit selected packet set

workflow_scope:
  scope for a workflow id

model_scope:
  scope for a model profile

rag_scope:
  scope for a RAG profile or RAG variable setting

prompt_scope:
  scope for a prompt profile or prompt variable setting

privacy_scope:
  scope for privacy/capture-mode comparisons
```

## Condition parent rule

A `condition` group must have a parent group with `group_kind='experiment'`.

Invalid:

```text
condition without parent
condition with session_comparison parent
condition with manual_packet_set parent
condition parent equal to itself
```

## Baseline rule

A baseline condition is represented as a child `packet_groups` row with:

```text
group_kind='condition'
parent_group_id=<experiment packet_group_id>
member_role='baseline' on relevant packet_group_members rows
```

The experiment or condition may also use `baseline_group_id` to identify the comparison baseline for projection.

## Member types

Allowed `member_type` values:

```text
turn_packet
session
turn
workflow
model_profile
rag_profile
prompt_profile
privacy_mode
manual_filter
```

Concrete identity rules:

```text
member_type='turn_packet':
  turn_packet_id is required
  member_id equals turn_packet_id

member_type='session':
  session_id is required
  member_id equals session_id

member_type='turn':
  turn_id is required
  member_id equals turn_id

workflow/model/rag/prompt/privacy/manual_filter:
  member_id contains the stable scope identity
```

## Member roles

Allowed `member_role` values:

```text
baseline
condition
replicate
analysis_member
comparison_member
excluded
reference
```

## Replicate counting

A replicate is one independent `TurnPacket` intentionally created for an experiment condition.

Rules:

```text
member_role='replicate' requires turn_packet_id
member_role='replicate' requires replicate_index
attempt rows never count as replicates
five baseline replicates = five packet_group_members rows pointing to five different packets
included replicate uniqueness is enforced per group and replicate_index
retries do not create new replicate membership
```

## Replacement and exclusion

If a failed packet should be replaced:

```text
failed packet remains inspectable
failed packet member row has include_in_aggregate=false
failed packet member row has exclusion_reason
replacement packet receives included replicate membership
ProjectionService aggregate math uses included replicate packets only
```

## Session comparison

A four-session comparison may be represented as:

```text
packet_group:
  group_kind='session_comparison'

packet_group_members:
  member_type='session'
  member_role='comparison_member'
```

`ProjectionService` expands session members into packet metrics at read time.

Do not create session-specific comparison tables.

## Analysis/manual sets

Manual and analysis sets use the same group/member model.

Allowed forms:

```text
manual selected packets:
  packet_group.group_kind='manual_packet_set'
  members are turn_packet rows

operator analysis:
  packet_group.group_kind='analysis_collection'
  members may be packets, sessions, or scope identities
```

## Aggregate eligibility

`include_in_aggregate` controls aggregate inclusion.

Rules:

```text
excluded rows require exclusion_reason
aggregate rows must ignore include_in_aggregate=false
failed packets may be included only if explicitly desired by final policy
ProjectionService must report included_count, excluded_count, failed_count, and partial_count
```

## Privacy

Packet group metadata must not leak private content.

Privacy-safe group metadata may include labels, condition ids, workflow ids, model/RAG/prompt ids, replicate counts,
privacy level, capture mode, metric policy, and non-content hashes.

Forbidden in privacy-sensitive group metadata:

```text
raw prompts
raw queries
raw context
raw user text
raw assistant text
content-revealing source titles/paths
```

## No free-form dumping ground

The generic group model must be strict.

Required validation:

```text
group_kind constrained
member_type constrained
member_role constrained
condition parent validated
replicate packet identity validated
included replicate uniqueness protected
included packet-role duplication protected
```

Packet groups are an anti-sprawl consolidation mechanism