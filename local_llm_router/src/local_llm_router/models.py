from __future__ import annotations

from datetime import datetime, timezone
import uuid
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from .format_capture import FormatCapture


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


DeliveryStatus = Literal[
    "queued",
    "dispatching",
    "dispatched",
    "response_received",
    "draft_inserted",
    "handled",
    "failed",
    "cancelled",
]

ProviderAvailability = Literal["ready", "needs_configuration", "unavailable", "disabled", "error"]


class CaptureEvent(BaseModel):
    event_type: Literal["message.captured"] = "message.captured"
    provider: str
    source_session_id: str | None = None
    conversation_id: str | None = None
    gizmo_id: str | None = None
    conversation_url: str
    conversation_title: str | None = None
    role: str = "assistant"
    turn_testid: str | None = None
    capture_source: str = "markdown"

    text: str
    text_hash: str
    text_length: int

    captured_at: str = Field(default_factory=now_iso)
    metadata: dict[str, Any] = Field(default_factory=dict)

    format_capture: FormatCapture | None = None

    def resolved_format_capture(self) -> FormatCapture:
        if self.format_capture is not None:
            return self.format_capture.normalized()
        return FormatCapture.from_legacy_text(
            self.text,
            source_format="markdown",
            provider_hints={
                "provider": self.provider,
                "capture_source": self.capture_source,
                "legacy_text_only": True,
            },
        )


class CaptureResponse(BaseModel):
    accepted: bool
    message_id: str
    deduped: bool
    route_decision: str
    delivery_ids: list[str] = Field(default_factory=list)
    target_session_id: str | None = None


class HealthResponse(BaseModel):
    status: str
    app: str
    version: str
    database_path: str
    route_count: int


class ProviderCapabilities(BaseModel):
    can_capture: bool = False
    can_receive: bool = False
    can_insert_draft: bool = False
    can_manual_send: bool = False
    can_dispatch_request: bool = False
    can_return_response: bool = False
    supports_browser_session: bool = False
    supports_http_session: bool = False
    supports_streaming: bool = False
    supports_queue_groups: bool = True
    supports_manual_review: bool = True


class ProviderProfile(BaseModel):
    provider_id: str
    provider_type: str
    label: str
    enabled: bool = True
    availability: ProviderAvailability = "ready"
    capabilities: ProviderCapabilities = Field(default_factory=ProviderCapabilities)
    config: dict[str, Any] = Field(default_factory=dict)


class ProviderListResponse(BaseModel):
    providers: list[ProviderProfile]


class ProviderProbeResult(BaseModel):
    ok: bool
    provider_id: str
    availability: ProviderAvailability
    message: str
    missing_config: list[str] = Field(default_factory=list)
    details: dict[str, Any] = Field(default_factory=dict)


class ProviderDispatchRequest(BaseModel):
    delivery_id: str
    queue_group_id: str | None = None
    manual_confirmed: bool = True
    prompt_wrapper_id: str | None = None
    prompt_wrapper_label: str | None = None
    options: dict[str, Any] = Field(default_factory=dict)


class ProviderDispatchResponse(BaseModel):
    ok: bool
    provider_id: str
    delivery_id: str | None = None
    status: str
    message: str
    error_code: str | None = None
    generated_format_capture: FormatCapture | None = None
    generated_message_id: str | None = None
    generated_delivery_ids: list[str] = Field(default_factory=list)
    details: dict[str, Any] = Field(default_factory=dict)


class ProviderSessionItem(BaseModel):
    source_session_id: str
    provider: str | None = None
    label: str | None = None
    label_source: str | None = None
    manual_alias: str | None = None
    inferred_label: str | None = None
    inferred_label_source: str | None = None
    label_updated_at: str | None = None
    conversation_id: str | None = None
    gizmo_id: str | None = None
    conversation_url: str | None = None
    conversation_title: str | None = None
    queue_group_id: str = "default"
    queue_group_name: str = "Default queue"
    assigned_at: str | None = None
    last_seen_at: str | None = None


class QueueGroupItem(BaseModel):
    queue_group_id: str
    name: str
    status: str = "active"
    is_default: bool = False
    created_at: str
    updated_at: str


class StatusDetailResponse(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    app: str
    version: str
    database_path: str
    server: dict[str, Any]
    format_capture_version: str
    schema_info: dict[str, Any] = Field(alias="schema")
    store: dict[str, Any]
    providers: list[ProviderProfile]
    queue_groups: list[QueueGroupItem]
    provider_sessions: list[ProviderSessionItem]
    routes: list[dict[str, Any]]


class QueueGroupListResponse(BaseModel):
    queue_groups: list[QueueGroupItem]


class QueueGroupCreateRequest(BaseModel):
    name: str


class QueueGroupRenameRequest(BaseModel):
    name: str


class QueueGroupDeleteRequest(BaseModel):
    cancel_queued: bool = True
    reason: str = "queue group deleted"


class QueueGroupMutationResponse(BaseModel):
    ok: bool
    queue_group_id: str
    queue_group: QueueGroupItem | None = None
    cancelled_count: int = 0
    error: str | None = None


class SessionQueueGroupRequest(BaseModel):
    source_session_id: str
    provider: str | None = None
    label: str | None = None
    queue_group_id: str = "default"


class SessionQueueGroupResponse(BaseModel):
    ok: bool
    source_session_id: str
    queue_group: QueueGroupItem
    error: str | None = None


class SessionLabelRequest(BaseModel):
    source_session_id: str
    provider: str | None = None
    label: str
    label_source: str = "user_saved"


class SessionLabelResponse(BaseModel):
    ok: bool
    source_session_id: str
    provider: str | None = None
    label: str
    label_source: str = "user_saved"
    label_updated_at: str | None = None
    queue_group_id: str = "default"
    queue_group_name: str = "Default queue"
    error: str | None = None


class PromptWrapperSummary(BaseModel):
    wrapper_id: str
    label: str
    description: str = ""
    transform: str = "none"
    has_before: bool = False
    has_after: bool = False
    has_line_prefix: bool = False


class PromptWrapperListResponse(BaseModel):
    prompt_wrappers: list[PromptWrapperSummary]


class PromptWrapperApplyRequest(BaseModel):
    wrapper_id: str
    text: str


class PromptWrapperApplyResponse(BaseModel):
    ok: bool
    wrapper_id: str
    label: str
    original_length: int
    wrapped_length: int
    text: str
    metadata: dict[str, Any] = Field(default_factory=dict)


class DraftCancelRequest(BaseModel):
    reason: str = "cancelled by operator"


class ClearQueuedRequest(BaseModel):
    queue_group_id: str | None = None
    provider: str | None = None
    reason: str = "clear queued by operator"


class ClearQueuedResponse(BaseModel):
    ok: bool
    cancelled_count: int
    queue_group_id: str | None = None


class DraftItem(BaseModel):
    delivery_id: str
    message_id: str
    route_id: str
    status: str
    target_type: str
    target_id: str
    queue_group_id: str = "default"
    queue_group_name: str | None = None
    queued_at: str
    delivered_at: str | None = None
    acknowledged_at: str | None = None
    cancelled_at: str | None = None
    error: str | None = None

    provider: str
    source_session_id: str
    conversation_id: str | None = None
    gizmo_id: str | None = None
    conversation_url: str
    conversation_title: str | None = None
    role: str
    turn_testid: str | None = None
    capture_source: str

    body_hash: str
    body_length: int
    captured_at: str

    wrapped_body: str

    body_markdown: str | None = None
    body_plain: str | None = None
    body_html: str | None = None
    wrapped_body_markdown: str | None = None
    wrapped_body_plain: str | None = None
    wrapped_body_html: str | None = None
    format_capture: FormatCapture | None = None
    wrapped_format_capture: FormatCapture | None = None
    format_version: str | None = None
    format_diagnostics: dict[str, Any] = Field(default_factory=dict)
    metadata: dict[str, Any] = Field(default_factory=dict)


class DraftListResponse(BaseModel):
    drafts: list[DraftItem]


class NextDraftResponse(BaseModel):
    found: bool
    draft: DraftItem | None = None
    reason: str | None = None


class DraftInsertedRequest(BaseModel):
    target_session_id: str | None = None
    target_provider: str | None = None
    target_conversation_id: str | None = None
    target_gizmo_id: str | None = None
    inserted_at: str = Field(default_factory=now_iso)
    metadata: dict[str, Any] = Field(default_factory=dict)


class DraftFailedRequest(BaseModel):
    target_session_id: str | None = None
    error: str
    failed_at: str = Field(default_factory=now_iso)
    metadata: dict[str, Any] = Field(default_factory=dict)


class DeliveryUpdateResponse(BaseModel):
    ok: bool
    delivery_id: str
    status: str | None = None


RouteActionSourceKind = Literal[
    "latest_user", "latest_assistant", "selected_draft", "generated_response"]
RouteActionTargetKind = Literal[
    "local_draft", "local_provider", "browser_provider", "chatgpt_active"]
RouteActionStatusName = Literal[
    "queued", "dispatched", "inserted", "already_queued", "blocked", "failed"]
LocalServiceActionName = Literal["status", "start", "stop", "restart"]


class RouteActionSourceModel(BaseModel):
    kind: RouteActionSourceKind
    provider: str | None = None
    role: str | None = None
    delivery_id: str | None = None
    source_session_id: str | None = None
    capture_event: CaptureEvent | None = None


class RouteActionTargetModel(BaseModel):
    kind: RouteActionTargetKind
    provider_id: str | None = None
    browser_provider: str | None = None
    target_session_id: str | None = None


class RouteActionExecuteRequest(BaseModel):
    source: RouteActionSourceModel
    target: RouteActionTargetModel
    queue_group_id: str = "default"
    duplicate_intent: bool = True
    manual_confirmed: bool = True
    prompt_wrapper_id: str | None = None
    prompt_wrapper_label: str | None = None
    operator_action_id: str = Field(default_factory=lambda: str(uuid.uuid4()))
    metadata: dict[str, Any] = Field(default_factory=dict)


class RouteActionExecuteResponse(BaseModel):
    ok: bool
    status: RouteActionStatusName
    message: str
    operator_action_id: str
    queue_group_id: str
    source: dict[str, Any] = Field(default_factory=dict)
    target: dict[str, Any] = Field(default_factory=dict)
    delivery_ids: list[str] = Field(default_factory=list)
    generated_delivery_ids: list[str] = Field(default_factory=list)
    details: dict[str, Any] = Field(default_factory=dict)


class LocalServiceStatusItem(BaseModel):
    service_id: str
    label: str
    authority: str = "supervisor"
    supervisor_name: str | None = None
    code_svc_command: str | None = None
    supervisor_available: bool = False
    code_svc_path: str | None = None
    supervisor_state: str | None = None
    supervisor_ok: bool = False
    health_url: str
    health_ok: bool
    health_status: str | None = None
    health_error: str | None = None
    managed: bool = True
    details: dict[str, Any] = Field(default_factory=dict)


class LocalServicesStatusResponse(BaseModel):
    ok: bool
    enabled: bool
    services: list[LocalServiceStatusItem]


class LocalServiceActionRequest(BaseModel):
    target: str | None = None


class LocalServiceActionResponse(BaseModel):
    ok: bool
    enabled: bool
    action: LocalServiceActionName
    target: str | None = None
    message: str
    services: list[LocalServiceStatusItem] = Field(default_factory=list)
    command_results: list[dict[str, Any]] = Field(default_factory=list)