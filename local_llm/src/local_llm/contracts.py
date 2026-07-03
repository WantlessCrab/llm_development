from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator

CaptureModeName = Literal["full", "privacy"]
PrivacyLevelName = Literal["none", "standard", "strict"]
PacketSourceKind = Literal[
    "respond",
    "session_turn",
    "experiment_replicate",
    "router_handoff",
    "backfill_import",
]
PacketStatus = Literal["started", "completed", "partial", "failed", "imported", "cancelled"]


class WarningItem(BaseModel):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


class HealthResponse(BaseModel):
    status: str
    app: str
    version: str
    storage_backend: str
    database_label: str
    artifact_dir: str
    configured_models: list[str]
    configured_rag_profiles: list[str]
    configured_workflows: list[str]


class DoctorCheck(BaseModel):
    name: str
    ok: bool
    detail: str = ""


class DoctorResponse(BaseModel):
    ok: bool
    checks: list[DoctorCheck]


class IngestResponse(BaseModel):
    ok: bool
    corpus_id: str
    sources_seen: int
    sources_indexed: int
    sources_skipped: int
    documents_indexed: int
    chunks_indexed: int
    duration_ms: int
    warnings: list[WarningItem] = Field(default_factory=list)


class SearchRequest(BaseModel):
    rag_profile: str
    query: str
    top_k: int | None = None


class RetrievalResult(BaseModel):
    rank: int
    method: str
    chunk_id: str
    document_id: str
    source_id: str
    document_path: str
    source_title: str
    source_version: str | None = None
    score: float
    raw_score: float | None = None
    normalized_score: float | None = None
    text: str


class SearchObservationResponse(BaseModel):
    retrieval_method: str = "postgres_fts"
    backend: str = "postgresql"
    search_config: str = "simple"
    rag_profile_id: str | None = None
    corpus_id: str | None = None
    query_hash: str | None = None
    normalized_query_hash: str | None = None
    normalized_query: str | None = None
    query_text_allowed: bool = True
    stage_1_query_shape: dict[str, Any] = Field(default_factory=dict)
    stage_2_fallback_query_shape: dict[str, Any] = Field(default_factory=dict)
    fallback_terms: list[str] = Field(default_factory=list)
    fallback_available: bool = False
    fallback_used: bool = False
    fallback_reason: str | None = None
    top_k_requested: int = 0
    candidate_count: int = 0
    returned_count: int = 0
    included_count: int = 0
    latency_ms: int = 0
    warning_codes: list[str] = Field(default_factory=list)
    privacy_behavior: dict[str, Any] = Field(default_factory=dict)


class SearchResponse(BaseModel):
    ok: bool
    query: str
    rag_profile: str
    results: list[RetrievalResult]
    warnings: list[WarningItem] = Field(default_factory=list)
    observation: SearchObservationResponse | None = None


class RespondRequest(BaseModel):
    workflow_id: str
    input: str
    metadata: dict[str, Any] = Field(default_factory=dict)
    capture_mode: CaptureModeName | None = None
    eval_capture_mode: CaptureModeName | None = None
    privacy_mode: bool | None = None
    privacy_level: PrivacyLevelName | None = None
    idempotency_key: str | None = None
    idempotency_scope_hash: str | None = None


class SupportMetadata(BaseModel):
    retrieval_used: bool
    source_count: int
    document_count: int
    chunk_count: int
    grounding_mode: str


class PacketIdentity(BaseModel):
    turn_packet_id: str
    source_kind: PacketSourceKind
    session_id: str | None = None
    turn_id: str | None = None
    turn_ordinal: int | None = None
    workflow_id: str
    created_at: str | None = None


class PacketStatusSummary(BaseModel):
    capture_status: PacketStatus
    capture_mode: CaptureModeName
    privacy_level: PrivacyLevelName
    text_persisted: bool
    metadata_redacted: bool
    redaction_policy_version: int | None = None
    warning_count: int = 0
    error_count: int = 0


class PacketSummaryEnvelope(BaseModel):
    ok: bool
    turn_packet_id: str
    source_kind: PacketSourceKind
    capture_status: PacketStatus
    workflow_id: str
    workflow_kind: str
    model_profile: str
    rag_profile: str
    prompt_profile: str
    created_at: str | None = None
    session_id: str | None = None
    turn_id: str | None = None
    turn_ordinal: int | None = None
    response_text: str = ""
    latency_ms: int = 0
    capture_mode: CaptureModeName = "full"
    privacy_level: PrivacyLevelName = "none"
    text_persisted: bool = True
    metadata_redacted: bool = False
    redaction_policy_version: int | None = None
    warnings: list[WarningItem] = Field(default_factory=list)
    error_json: dict[str, Any] = Field(default_factory=dict)
    manifest_json: dict[str, Any] = Field(default_factory=dict)


class PacketEventResponse(BaseModel):
    event_id: str
    turn_packet_id: str | None = None
    turn_attempt_id: str | None = None
    event_order: int
    event_name: str
    event_status: str
    started_at: str | None = None
    completed_at: str | None = None
    latency_ms: int | None = None
    payload_json: dict[str, Any] = Field(default_factory=dict)
    failure_json: dict[str, Any] = Field(default_factory=dict)
    privacy_safe: bool = True
    created_at: str | None = None


class PacketAttemptResponse(BaseModel):
    turn_attempt_id: str
    turn_packet_id: str | None = None
    attempt_index: int
    attempt_kind: str
    attempt_status: str
    is_primary: bool = False
    started_at: str | None = None
    completed_at: str | None = None
    latency_total_ms: int | None = None
    phase_timings_json: dict[str, Any] = Field(default_factory=dict)
    provider_evidence_json: dict[str, Any] = Field(default_factory=dict)
    failure_json: dict[str, Any] = Field(default_factory=dict)
    metadata_json: dict[str, Any] = Field(default_factory=dict)


class PacketContentRefResponse(BaseModel):
    content_ref_id: str
    turn_packet_id: str
    turn_attempt_id: str | None = None
    owner_type: str
    owner_id: str | None = None
    content_role: str
    storage_kind: str
    body_text: str | None = None
    file_path: str | None = None
    sha256: str | None = None
    size_bytes: int | None = None
    mime_type: str | None = None
    capture_mode: CaptureModeName
    privacy_level: PrivacyLevelName
    body_persisted: bool
    metadata_redacted: bool
    payload_policy: str
    metadata_json: dict[str, Any] = Field(default_factory=dict)
    created_at: str | None = None


class PacketArtifactResponse(BaseModel):
    artifact_id: str
    turn_packet_id: str
    turn_attempt_id: str | None = None
    artifact_type: str
    path: str
    sha256: str
    size_bytes: int
    mime_type: str | None = None
    body_persisted: bool
    payload_policy: str
    capture_mode: CaptureModeName
    privacy_level: PrivacyLevelName
    metadata_json: dict[str, Any] = Field(default_factory=dict)
    created_at: str | None = None


class PacketMetricFactResponse(BaseModel):
    metric_fact_id: str
    turn_packet_id: str
    turn_attempt_id: str | None = None
    owner_type: str
    owner_id: str | None = None
    metric_key: str
    metric_value_num: float | None = None
    metric_value_text: str | None = None
    metric_json: dict[str, Any] = Field(default_factory=dict)
    unit: str | None = None
    privacy_safe: bool
    source: str
    created_at: str | None = None


class PacketDetailResponse(BaseModel):
    summary: PacketSummaryEnvelope
    attempts: list[PacketAttemptResponse] = Field(default_factory=list)
    events: list[PacketEventResponse] = Field(default_factory=list)
    content_refs: list[PacketContentRefResponse] = Field(default_factory=list)
    artifacts: list[PacketArtifactResponse] = Field(default_factory=list)
    metric_facts: list[PacketMetricFactResponse] = Field(default_factory=list)
    groups: list[dict[str, Any]] = Field(default_factory=list)


class PacketListRequest(BaseModel):
    session_id: str | None = None
    workflow_id: str | None = None
    group_id: str | None = None
    capture_mode: CaptureModeName | None = None
    limit: int = 50


class PacketListResponse(BaseModel):
    packets: list[PacketSummaryEnvelope]


class MetricDefinitionResponse(BaseModel):
    metric_key: str
    namespace: str
    display_name: str
    description: str
    unit: str | None = None
    value_type: str
    aggregation_default: str
    higher_is_better: bool | None = None
    privacy_safe: bool
    source_layer: str
    active: bool = True
    metadata_json: dict[str, Any] = Field(default_factory=dict)


class MetricAvailabilityResponse(BaseModel):
    metrics: list[MetricDefinitionResponse]


class ProjectionPrivacySummary(BaseModel):
    contains_private_packets: bool = False
    full_packet_count: int = 0
    privacy_packet_count: int = 0
    text_persisted_count: int = 0
    text_omitted_count: int = 0
    warnings: list[WarningItem] = Field(default_factory=list)


class ProjectionTablePayload(BaseModel):
    columns: list[dict[str, Any]] = Field(default_factory=list)
    rows: list[dict[str, Any]] = Field(default_factory=list)


class ProjectionChartPayload(BaseModel):
    chart_type: str = "table"
    series: list[dict[str, Any]] = Field(default_factory=list)


class ProjectionRequest(BaseModel):
    packet_ids: list[str] = Field(default_factory=list)
    packet_group_id: str | None = None
    session_ids: list[str] = Field(default_factory=list)
    metric_keys: list[str] = Field(default_factory=list)


class ProjectionResult(BaseModel):
    request: ProjectionRequest
    table: ProjectionTablePayload = Field(default_factory=ProjectionTablePayload)
    chart: ProjectionChartPayload = Field(default_factory=ProjectionChartPayload)
    privacy: ProjectionPrivacySummary = Field(default_factory=ProjectionPrivacySummary)
    drilldown: list[dict[str, Any]] = Field(default_factory=list)
    metrics: list[MetricDefinitionResponse] = Field(default_factory=list)


class PacketGroupRequest(BaseModel):
    group_kind: str
    label: str
    purpose: str | None = None
    parent_group_id: str | None = None
    baseline_group_id: str | None = None
    workflow_id: str | None = None
    capture_mode: CaptureModeName | None = None
    privacy_level: PrivacyLevelName | None = None
    plan_json: dict[str, Any] = Field(default_factory=dict)
    condition_json: dict[str, Any] = Field(default_factory=dict)
    metadata_json: dict[str, Any] = Field(default_factory=dict)


class PacketGroupResponse(PacketGroupRequest):
    packet_group_id: str
    status: str = "planned"


class PacketGroupMemberRequest(BaseModel):
    packet_group_id: str
    member_type: str
    member_id: str
    member_role: str
    turn_packet_id: str | None = None
    turn_attempt_id: str | None = None
    session_id: str | None = None
    turn_id: str | None = None
    member_label: str | None = None
    replicate_index: int | None = None
    include_in_aggregate: bool = True
    exclusion_reason: str | None = None
    ordinal: int | None = None
    metadata_json: dict[str, Any] = Field(default_factory=dict)


class PacketGroupMemberResponse(PacketGroupMemberRequest):
    packet_group_member_id: str


class ExperimentConditionRequest(BaseModel):
    label: str
    config_overlay: dict[str, Any] = Field(default_factory=dict)
    replicate_count: int | None = Field(default=None, ge=1)


class ExperimentRunMatrixRequest(BaseModel):
    workflow_id: str
    input: str
    baseline: ExperimentConditionRequest
    variables: list[ExperimentConditionRequest]
    capture_mode: CaptureModeName = "full"
    privacy_level: PrivacyLevelName = "none"
    operator_labels: dict[str, Any] = Field(default_factory=dict)


class ResolvedExperimentCondition(BaseModel):
    label: str
    role: Literal["baseline", "variable"]
    config_overlay: dict[str, Any] = Field(default_factory=dict)
    replicate_count: int = Field(ge=1)


class ResolvedExperimentRunMatrixRequest(BaseModel):
    workflow_id: str
    input: str
    baseline: ResolvedExperimentCondition
    variables: list[ResolvedExperimentCondition]
    capture_mode: CaptureModeName = "full"
    privacy_level: PrivacyLevelName = "none"
    operator_labels: dict[str, Any] = Field(default_factory=dict)
    training_preferences: dict[str, Any] = Field(default_factory=dict)


class ExperimentRunMatrixPlan(BaseModel):
    experiment_group: PacketGroupResponse | PacketGroupRequest
    condition_groups: list[PacketGroupResponse | PacketGroupRequest]
    requests: list[dict[str, Any]]


class ExperimentRunMatrixResult(BaseModel):
    plan: ExperimentRunMatrixPlan
    packets: list[PacketSummaryEnvelope] = Field(default_factory=list)
    projection: ProjectionResult | None = None


class SessionComparisonRequest(BaseModel):
    session_ids: list[str]
    metric_keys: list[str] = Field(default_factory=list)


class ManualPacketSetRequest(BaseModel):
    packet_ids: list[str]
    metric_keys: list[str] = Field(default_factory=list)


class OperatorFeedbackRequest(BaseModel):
    score: float | None = None
    label: str | None = None
    note: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)

    @model_validator(mode="after")
    def validate_any_feedback(self) -> "OperatorFeedbackRequest":
        if self.score is None and not (self.label or "").strip():
            raise ValueError("operator feedback requires score or label; note may accompany either")
        return self


class OperatorFeedbackResponse(BaseModel):
    turn_packet_id: str
    metric_facts: list[PacketMetricFactResponse] = Field(default_factory=list)


class ContentLoadRequest(BaseModel):
    content_ref_id: str


class ContentLoadResponse(BaseModel):
    content_ref: PacketContentRefResponse
    text: str | None = None
    unavailable_reason: str | None = None


class RespondResponse(BaseModel):
    ok: bool
    turn_packet_id: str
    packet_summary: PacketSummaryEnvelope
    workflow_id: str
    workflow_kind: str
    model_profile: str
    rag_profile: str
    prompt_profile: str
    response_text: str
    support: SupportMetadata
    retrievals: list[RetrievalResult]
    warnings: list[WarningItem] = Field(default_factory=list)
    latency_ms: int
    capture_mode: CaptureModeName = "full"
    privacy_level: PrivacyLevelName = "none"
    text_persisted: bool = True
    metadata_redacted: bool = False
    redaction_policy_version: int | None = None
    capture_status: str = "completed"
    capture_error_json: dict[str, Any] = Field(default_factory=dict)


class ModelProviderResponse(BaseModel):
    text: str
    raw_response: dict[str, Any] = Field(default_factory=dict)
    provider_metadata: dict[str, Any] = Field(default_factory=dict)
    latency_ms: int = 0


class CreateSessionRequest(BaseModel):
    title: str = "New session"
    description: str = ""
    default_workflow_id: str | None = None
    default_capture_mode: CaptureModeName | None = None
    default_privacy_level: PrivacyLevelName | None = None
    privacy_locked: bool = False
    metadata: dict[str, Any] = Field(default_factory=dict)


class UpdateSessionRequest(BaseModel):
    title: str | None = None
    description: str | None = None
    default_workflow_id: str | None = None
    default_capture_mode: CaptureModeName | None = None
    default_privacy_level: PrivacyLevelName | None = None
    privacy_locked: bool | None = None
    metadata: dict[str, Any] | None = None


class SessionResponse(BaseModel):
    session_id: str
    title: str
    description: str = ""
    default_workflow_id: str
    default_model_profile: str | None = None
    default_rag_profile: str | None = None
    default_prompt_profile: str | None = None
    default_capture_mode: CaptureModeName = "full"
    default_privacy_level: PrivacyLevelName = "none"
    privacy_locked: bool = False
    created_at: str
    updated_at: str
    archived_at: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    turn_count: int = 0
    latest_turn_packet_id: str | None = None
    latest_turn_at: str | None = None


class CreateTurnRequest(BaseModel):
    input: str
    workflow_id: str | None = None
    capture_mode: CaptureModeName | None = None
    eval_capture_mode: CaptureModeName | None = None
    privacy_mode: bool | None = None
    privacy_level: PrivacyLevelName | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    idempotency_key: str | None = None
    idempotency_scope_hash: str | None = None


class TurnResponse(BaseModel):
    turn_id: str
    session_id: str
    ordinal: int
    user_input: str | None = None
    turn_packet_id: str
    created_at: str
    metadata: dict[str, Any] = Field(default_factory=dict)
    capture_mode: CaptureModeName = "full"
    privacy_level: PrivacyLevelName = "none"
    text_persisted: bool = True
    metadata_redacted: bool = False
    redaction_policy_version: int | None = None
    capture_status: str = "completed"
    capture_error_json: dict[str, Any] = Field(default_factory=dict)


class SessionTurnResponse(BaseModel):
    session_id: str
    turn_id: str
    turn_packet_id: str
    turn: TurnResponse
    response: RespondResponse
    packet_summary: PacketSummaryEnvelope