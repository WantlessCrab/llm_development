from __future__ import annotations

import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from typing import Any

from local_llm.contracts import PacketSummaryEnvelope, WarningItem


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


@dataclass
class TurnAttempt:
    turn_attempt_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    attempt_index: int = 1
    attempt_kind: str = "primary"
    attempt_status: str = "started"
    is_primary: bool = True
    started_at: datetime = field(default_factory=utc_now)
    completed_at: datetime | None = None
    latency_total_ms: int | None = None
    phase_timings_json: dict[str, Any] = field(default_factory=dict)
    provider_evidence_json: dict[str, Any] = field(default_factory=dict)
    failure_json: dict[str, Any] = field(default_factory=dict)
    metadata_json: dict[str, Any] = field(default_factory=dict)

    def complete(self, *, status: str = "completed", latency_ms: int | None = None) -> None:
        self.attempt_status = status
        self.completed_at = utc_now()
        if latency_ms is not None:
            self.latency_total_ms = latency_ms


@dataclass
class TurnEvent:
    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    turn_packet_id: str = ""
    turn_attempt_id: str | None = None
    event_order: int = 1
    event_name: str = "request_received"
    event_status: str = "completed"
    started_at: datetime | None = None
    completed_at: datetime | None = None
    latency_ms: int | None = None
    payload_json: dict[str, Any] = field(default_factory=dict)
    failure_json: dict[str, Any] = field(default_factory=dict)
    privacy_safe: bool = True
    created_at: datetime = field(default_factory=utc_now)


@dataclass
class TurnContentRef:
    content_ref_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    turn_packet_id: str = ""
    turn_attempt_id: str | None = None
    owner_type: str = "packet"
    owner_id: str | None = None
    content_role: str = "packet_summary"
    storage_kind: str = "inline_text"
    body_text: str | None = None
    file_path: str | None = None
    sha256: str | None = None
    size_bytes: int | None = None
    mime_type: str | None = None
    capture_mode: str = "full"
    privacy_level: str = "none"
    body_persisted: bool = True
    metadata_redacted: bool = False
    payload_policy: str = "full_body"
    metadata_json: dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=utc_now)


@dataclass
class TurnArtifactRef:
    artifact_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    turn_packet_id: str = ""
    turn_attempt_id: str | None = None
    artifact_type: str = "other"
    path: str = ""
    sha256: str = ""
    size_bytes: int = 0
    mime_type: str | None = None
    body_text: str | None = None
    body_persisted: bool = True
    payload_policy: str = "full_body"
    capture_mode: str = "full"
    privacy_level: str = "none"
    metadata_json: dict[str, Any] = field(default_factory=dict)
    created_at: datetime = field(default_factory=utc_now)


@dataclass
class TurnMetricFact:
    metric_fact_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    turn_packet_id: str = ""
    turn_attempt_id: str | None = None
    owner_type: str = "packet"
    owner_id: str | None = None
    metric_key: str = ""
    metric_value_num: float | None = None
    metric_value_text: str | None = None
    metric_json: dict[str, Any] = field(default_factory=dict)
    unit: str | None = None
    privacy_safe: bool = True
    source: str = "derived"
    created_at: datetime = field(default_factory=utc_now)


@dataclass
class TurnGroupMembership:
    packet_group_id: str
    member_type: str = "turn_packet"
    member_role: str = "analysis_member"
    member_id: str | None = None
    turn_packet_id: str | None = None
    turn_attempt_id: str | None = None
    session_id: str | None = None
    turn_id: str | None = None
    member_label: str | None = None
    replicate_index: int | None = None
    include_in_aggregate: bool = True
    exclusion_reason: str | None = None
    ordinal: int | None = None
    metadata_json: dict[str, Any] = field(default_factory=dict)


@dataclass
class TurnPacket:
    workflow_id: str
    workflow_kind: str
    model_profile_id: str
    rag_profile_id: str
    prompt_profile_id: str
    config_snapshot_hash: str
    effective_config_hash: str
    source_kind: str = "respond"
    turn_packet_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    request_id: str | None = None
    idempotency_key: str | None = None
    idempotency_scope_hash: str | None = None
    capture_status: str = "started"
    capture_mode: str = "full"
    privacy_level: str = "none"
    text_persisted: bool = True
    metadata_redacted: bool = False
    redaction_policy_version: int | None = None
    session_id: str | None = None
    turn_id: str | None = None
    turn_ordinal: int | None = None
    corpus_id: str | None = None
    retrieval_method: str = "postgres_fts"
    config_snapshot_json: dict[str, Any] = field(default_factory=dict)
    request_summary_json: dict[str, Any] = field(default_factory=dict)
    search_observation_json: dict[str, Any] = field(default_factory=dict)
    retrieval_summary_json: dict[str, Any] = field(default_factory=dict)
    context_summary_json: dict[str, Any] = field(default_factory=dict)
    prompt_summary_json: dict[str, Any] = field(default_factory=dict)
    provider_summary_json: dict[str, Any] = field(default_factory=dict)
    runtime_links_json: dict[str, Any] = field(default_factory=dict)
    privacy_json: dict[str, Any] = field(default_factory=dict)
    manifest_json: dict[str, Any] = field(default_factory=dict)
    error_json: dict[str, Any] = field(default_factory=dict)
    metadata_json: dict[str, Any] = field(default_factory=dict)
    source_system: str = "local_llm"
    source_record_id: str | None = None
    is_imported: bool = False
    imported_at: datetime | None = None
    created_at: datetime = field(default_factory=utc_now)
    finalized_at: datetime | None = None
    response_text: str = ""
    latency_ms: int = 0
    warnings: list[WarningItem] = field(default_factory=list)
    attempts: list[TurnAttempt] = field(default_factory=list)
    events: list[TurnEvent] = field(default_factory=list)
    content_refs: list[TurnContentRef] = field(default_factory=list)
    artifacts: list[TurnArtifactRef] = field(default_factory=list)
    metric_facts: list[TurnMetricFact] = field(default_factory=list)
    group_memberships: list[TurnGroupMembership] = field(default_factory=list)

    def primary_attempt(self) -> TurnAttempt:
        if self.attempts:
            return self.attempts[0]
        attempt = TurnAttempt(is_primary=True)
        self.add_attempt(attempt)
        return attempt

    def add_attempt(self, attempt: TurnAttempt) -> TurnAttempt:
        if not self.attempts and attempt.attempt_index != 1:
            attempt.attempt_index = 1
        attempt.turn_packet_id = self.turn_packet_id  # dynamic attribute for store use
        self.attempts.append(attempt)
        return attempt

    def add_event(self, event_name: str, *, status: str = "completed",
                  payload: dict[str, Any] | None = None,
                  failure: dict[str, Any] | None = None, attempt_id: str | None = None,
                  latency_ms: int | None = None, privacy_safe: bool = True) -> TurnEvent:
        event = TurnEvent(
            turn_packet_id=self.turn_packet_id,
            turn_attempt_id=attempt_id,
            event_order=len(self.events) + 1,
            event_name=event_name,
            event_status=status,
            completed_at=utc_now() if status in {"completed", "failed", "skipped"} else None,
            latency_ms=latency_ms,
            payload_json=payload or {},
            failure_json=failure or {},
            privacy_safe=privacy_safe,
        )
        self.events.append(event)
        return event

    def add_content_ref(self, ref: TurnContentRef) -> TurnContentRef:
        ref.turn_packet_id = self.turn_packet_id
        self.content_refs.append(ref)
        return ref

    def add_artifact(self, artifact: TurnArtifactRef) -> TurnArtifactRef:
        artifact.turn_packet_id = self.turn_packet_id
        self.artifacts.append(artifact)
        return artifact

    def add_metric(self, metric: TurnMetricFact) -> TurnMetricFact:
        metric.turn_packet_id = self.turn_packet_id
        self.metric_facts.append(metric)
        return metric

    def add_group_membership(self, membership: TurnGroupMembership) -> TurnGroupMembership:
        membership.turn_packet_id = membership.turn_packet_id or self.turn_packet_id
        membership.member_id = membership.member_id or self.turn_packet_id
        self.group_memberships.append(membership)
        return membership

    def mark_completed(self) -> None:
        self.capture_status = "completed"
        self.finalized_at = utc_now()

    def mark_partial(self, error: dict[str, Any] | None = None) -> None:
        self.capture_status = "partial"
        if error:
            self.error_json = error
        self.finalized_at = utc_now()

    def mark_failed(self, error: dict[str, Any] | None = None) -> None:
        self.capture_status = "failed"
        if error:
            self.error_json = error
        self.finalized_at = utc_now()

    def to_summary_envelope(self) -> PacketSummaryEnvelope:
        return PacketSummaryEnvelope(
            ok=self.capture_status in {"completed", "imported"},
            turn_packet_id=self.turn_packet_id,
            source_kind=self.source_kind,  # type: ignore[arg-type]
            capture_status=self.capture_status,  # type: ignore[arg-type]
            workflow_id=self.workflow_id,
            workflow_kind=self.workflow_kind,
            model_profile=self.model_profile_id,
            rag_profile=self.rag_profile_id,
            prompt_profile=self.prompt_profile_id,
            created_at=iso(self.created_at),
            session_id=self.session_id,
            turn_id=self.turn_id,
            turn_ordinal=self.turn_ordinal,
            response_text=self.response_text,
            latency_ms=self.latency_ms,
            capture_mode=self.capture_mode,  # type: ignore[arg-type]
            privacy_level=self.privacy_level,  # type: ignore[arg-type]
            text_persisted=self.text_persisted,
            metadata_redacted=self.metadata_redacted,
            redaction_policy_version=self.redaction_policy_version,
            warnings=self.warnings,
            error_json=self.error_json,
            manifest_json=self.manifest_json,
        )

    def as_store_dict(self) -> dict[str, Any]:
        return asdict(self)