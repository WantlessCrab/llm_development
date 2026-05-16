from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field


class WarningItem(BaseModel):
    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


class HealthResponse(BaseModel):
    status: str
    app: str
    version: str
    database_path: str
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


class SearchResponse(BaseModel):
    ok: bool
    query: str
    rag_profile: str
    results: list[RetrievalResult]
    warnings: list[WarningItem] = Field(default_factory=list)


class RespondRequest(BaseModel):
    workflow_id: str
    input: str
    metadata: dict[str, Any] = Field(default_factory=dict)


class SupportMetadata(BaseModel):
    retrieval_used: bool
    source_count: int
    document_count: int
    chunk_count: int
    grounding_mode: str


class RespondResponse(BaseModel):
    ok: bool
    run_id: str
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


class ModelProviderResponse(BaseModel):
    text: str
    raw_response: dict[str, Any] = Field(default_factory=dict)
    provider_metadata: dict[str, Any] = Field(default_factory=dict)
    latency_ms: int = 0


class CreateSessionRequest(BaseModel):
    title: str = "New session"
    description: str = ""
    default_workflow_id: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class UpdateSessionRequest(BaseModel):
    title: str | None = None
    description: str | None = None
    default_workflow_id: str | None = None
    metadata: dict[str, Any] | None = None


class SessionResponse(BaseModel):
    session_id: str
    title: str
    description: str = ""
    default_workflow_id: str
    default_model_profile: str | None = None
    default_rag_profile: str | None = None
    default_prompt_profile: str | None = None
    created_at: str
    updated_at: str
    archived_at: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    turn_count: int = 0
    latest_run_id: str | None = None
    latest_turn_at: str | None = None


class CreateTurnRequest(BaseModel):
    input: str
    workflow_id: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class TurnResponse(BaseModel):
    turn_id: str
    session_id: str
    ordinal: int
    user_input: str
    run_id: str | None = None
    created_at: str
    metadata: dict[str, Any] = Field(default_factory=dict)


class SessionTurnResponse(BaseModel):
    session_id: str
    turn_id: str
    run_id: str
    turn: TurnResponse
    response: RespondResponse


class RunSummaryResponse(BaseModel):
    run_id: str
    workflow_id: str
    workflow_kind: str
    model_profile: str
    rag_profile: str
    prompt_profile: str
    user_input: str
    response_preview: str
    created_at: str
    latency_ms: int
    warnings: list[dict[str, Any]] = Field(default_factory=list)
    support: dict[str, Any] = Field(default_factory=dict)


class RunDetailResponse(BaseModel):
    run: dict[str, Any]
    retrievals: list[dict[str, Any]]
    artifacts: list[dict[str, Any]]
