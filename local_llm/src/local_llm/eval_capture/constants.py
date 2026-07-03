from __future__ import annotations

PACKET_SOURCE_KINDS = frozenset(
    {"respond", "session_turn", "experiment_replicate", "router_handoff", "backfill_import"})
PACKET_STATUSES = frozenset({"started", "completed", "partial", "failed", "imported", "cancelled"})
ATTEMPT_KINDS = frozenset({"primary", "retry", "repair", "import"})
ATTEMPT_STATUSES = frozenset(
    {"started", "completed", "partial", "failed", "skipped", "cancelled", "imported"})
CAPTURE_MODES = frozenset({"full", "privacy"})
PRIVACY_LEVELS = frozenset({"none", "standard", "strict"})
EVENT_NAMES = (
    "request_received", "plan_resolved", "rag_directives_resolved", "privacy_policy_resolved",
    "retrieval_started", "retrieval_completed", "retrieval_candidates_ranked", "context_built",
    "prompt_built", "provider_started", "provider_completed", "provider_exposed_reasoning_captured",
    "content_refs_written", "artifacts_written", "metrics_written", "runtime_evidence_captured",
    "group_membership_attached", "manifest_finalized", "packet_finalized", "failed",
)
CONTENT_OWNER_TYPES = frozenset(
    {"packet", "attempt", "event", "search", "retrieval", "context", "prompt", "provider",
     "artifact"})
CONTENT_ROLES = frozenset({
    "user_input", "retrieval_query", "retrieved_chunk_snapshot", "context_text", "prompt_messages",
    "provider_request", "provider_raw_response", "provider_exposed_reasoning", "assistant_response",
    "diagnostics", "packet_summary",
})
STORAGE_KINDS = frozenset(
    {"inline_text", "file_ref", "redacted_inline", "redacted_file", "omitted", "non_text_file"})
ARTIFACT_TYPES = frozenset({
    "request", "retrievals", "context", "prompt", "response", "provider_raw_response",
    "provider_exposed_reasoning", "diagnostics", "report", "other",
})
PAYLOAD_POLICIES = frozenset({"full_body", "redacted_body", "omitted_body", "non_text_body"})
GROUP_KINDS = frozenset({
    "experiment", "condition", "analysis_collection", "session_comparison", "manual_packet_set",
    "workflow_scope", "model_scope", "rag_scope", "prompt_scope", "privacy_scope",
})
MEMBER_TYPES = frozenset({
    "turn_packet", "session", "turn", "workflow", "model_profile", "rag_profile", "prompt_profile",
    "privacy_mode", "manual_filter",
})
MEMBER_ROLES = frozenset(
    {"baseline", "condition", "replicate", "analysis_member", "comparison_member", "excluded",
     "reference"})
METRIC_SOURCES = frozenset({"derived", "provider", "runtime", "recorder", "projection", "operator"})
METRIC_KEYS = (
    "latency.total_ms", "latency.retrieval_ms", "latency.context_build_ms",
    "latency.prompt_build_ms",
    "latency.provider_ms", "latency.artifact_write_ms", "tokens.prompt", "tokens.completion",
    "tokens.total",
    "chars.user_input", "chars.context", "chars.prompt", "chars.response", "search.candidate_count",
    "search.returned_count", "search.included_count", "search.top_k_requested",
    "retrieval.returned_count",
    "retrieval.included_count", "retrieval.unique_source_count", "retrieval.unique_document_count",
    "context.truncated", "context.char_count", "provider.finish_reason",
    "provider.prompt_per_second",
    "provider.completion_per_second", "artifact.count", "warnings.count", "privacy.text_persisted",
    "privacy.metadata_redacted", "quality.operator_score", "quality.operator_label",
)