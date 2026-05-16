from __future__ import annotations

import hashlib
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse

from . import __version__
from .config import AppConfig, load_config
from .events import event_broker
from .format_capture import FORMAT_CAPTURE_VERSION, FormatCapture
from .models import (
    CaptureEvent,
    CaptureResponse,
    ClearQueuedRequest,
    ClearQueuedResponse,
    DeliveryUpdateResponse,
    DraftCancelRequest,
    DraftFailedRequest,
    DraftInsertedRequest,
    DraftListResponse,
    HealthResponse,
    NextDraftResponse,
    ProviderDispatchRequest,
    ProviderDispatchResponse,
    ProviderListResponse,
    ProviderProbeResult,
    QueueGroupCreateRequest,
    QueueGroupDeleteRequest,
    QueueGroupListResponse,
    QueueGroupMutationResponse,
    QueueGroupRenameRequest,
    SessionQueueGroupRequest,
    SessionQueueGroupResponse,
    StatusDetailResponse,
)
from .providers import ProviderRegistry
from .router import Router
from .store import Store

_WEB_DIR = Path(__file__).resolve().parents[2] / "web"


def _route_summary(cfg: AppConfig) -> list[dict[str, object]]:
    return [
        {
            "route_id": route.route_id,
            "name": route.name,
            "enabled": route.enabled,
            "mode": route.mode,
            "source": {
                "provider": route.source.provider,
                "role": route.source.role,
            },
            "target": {
                "type": route.target.type,
                "id": route.target.id,
            },
            "wrapper": route.wrapper,
        }
        for route in cfg.routes
    ]


def _stable_text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:24]


def _generated_capture_event(
        *,
        provider_id: str,
        queue_group_id: str,
        parent_delivery_id: str,
        parent_message_id: str,
        format_capture: FormatCapture,
) -> CaptureEvent:
    text = format_capture.canonical_markdown
    return CaptureEvent(
        provider=provider_id,
        source_session_id=f"{provider_id}:{queue_group_id}",
        conversation_id=queue_group_id,
        gizmo_id=None,
        conversation_url=f"local-provider://{provider_id}/{queue_group_id}",
        conversation_title=f"{provider_id} response for {queue_group_id}",
        role="assistant",
        turn_testid=f"response-to-{parent_delivery_id}",
        capture_source="provider_dispatch",
        text=text,
        text_hash=_stable_text_hash(text),
        text_length=len(text),
        format_capture=format_capture,
        metadata={
            "provider_id": provider_id,
            "queue_group_id": queue_group_id,
            "parent_delivery_id": parent_delivery_id,
            "parent_message_id": parent_message_id,
            "generated_by_provider_dispatch": True,
        },
    )


def create_app(config: AppConfig | None = None) -> FastAPI:
    cfg = config or load_config()
    store = Store(cfg.database_path)
    router = Router(cfg, store)
    providers = ProviderRegistry(cfg)

    app = FastAPI(title="local_llm_router", version=__version__)

    app.add_middleware(
        CORSMiddleware,
        allow_origins=cfg.server.cors_origins
                      + [
                          "http://127.0.0.1:8015",
                          "http://localhost:8015",
                      ],
        allow_origin_regex=r"chrome-extension://.*",
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.on_event("startup")
    def startup() -> None:
        cfg.database_path.parent.mkdir(parents=True, exist_ok=True)
        cfg.audit_dir.mkdir(parents=True, exist_ok=True)
        store.init()

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        return RedirectResponse(url="/draft-inbox")

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(
            status="ok",
            app="local_llm_router",
            version=__version__,
            database_path=str(cfg.database_path),
            route_count=len(cfg.routes),
        )

    @app.get("/api/v1/status/detail", response_model=StatusDetailResponse)
    def status_detail() -> StatusDetailResponse:
        store.init()
        return StatusDetailResponse(
            app="local_llm_router",
            version=__version__,
            database_path=str(cfg.database_path),
            server={
                "host": cfg.server.host,
                "port": cfg.server.port,
            },
            format_capture_version=FORMAT_CAPTURE_VERSION,
            schema_info={
                "config_version": cfg.version,
                "provider_contract": "provider_connector.v1",
            },
            store=store.summary(),
            providers=providers.list_profiles(),
            queue_groups=store.list_queue_groups(),
            provider_sessions=store.list_provider_sessions(),
            routes=_route_summary(cfg),
        )

    @app.get("/api/v1/events")
    async def events(request: Request) -> StreamingResponse:
        async def generate():
            async for item in event_broker.stream():
                if await request.is_disconnected():
                    break
                yield item

        return StreamingResponse(generate(), media_type="text/event-stream")

    @app.get("/api/v1/providers", response_model=ProviderListResponse)
    def list_providers() -> ProviderListResponse:
        return ProviderListResponse(providers=providers.list_profiles())

    @app.get("/api/v1/providers/{provider_id}", response_model=dict)
    def get_provider(provider_id: str) -> dict:
        connector = providers.get(provider_id)
        if connector is None:
            raise HTTPException(status_code=404, detail="provider not found")
        return connector.profile().model_dump()

    @app.post("/api/v1/providers/{provider_id}/probe", response_model=ProviderProbeResult)
    async def probe_provider(provider_id: str) -> ProviderProbeResult:
        connector = providers.get(provider_id)
        if connector is None:
            raise HTTPException(status_code=404, detail="provider not found")

        result = await connector.probe()
        event_broker.publish(
            "provider.probe_completed",
            provider_id=provider_id,
            availability=result.availability,
            ok=result.ok,
            message=result.message,
        )
        return result

    @app.post("/api/v1/providers/{provider_id}/dispatch", response_model=ProviderDispatchResponse)
    async def dispatch_to_provider(
            provider_id: str,
            request: ProviderDispatchRequest,
    ) -> ProviderDispatchResponse:
        connector = providers.get(provider_id)
        if connector is None:
            raise HTTPException(status_code=404, detail="provider not found")

        draft = store.get_draft_by_delivery_id(request.delivery_id)
        if draft is None:
            raise HTTPException(status_code=404, detail="delivery not found")

        queue_group_id = request.queue_group_id or draft.queue_group_id or "default"
        if draft.queue_group_id and request.queue_group_id and draft.queue_group_id != request.queue_group_id:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                status="blocked",
                message="delivery does not belong to requested queue group",
                error_code="queue_group_mismatch",
                details={
                    "delivery_queue_group_id": draft.queue_group_id,
                    "requested_queue_group_id": request.queue_group_id,
                },
            )

        if not request.manual_confirmed:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                status="blocked",
                message="manual confirmation is required before dispatch",
                error_code="manual_confirmation_required",
            )

        probe = await connector.probe()
        if not probe.ok:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                status="blocked",
                message=probe.message,
                error_code=probe.availability,
                details={
                    "missing_config": probe.missing_config,
                    "probe_details": probe.details,
                },
            )

        dispatch_started = store.mark_delivery_dispatching(
            request.delivery_id,
            provider_id=provider_id,
            metadata={
                "queue_group_id": queue_group_id,
                "manual_confirmed": request.manual_confirmed,
                "options": request.options,
            },
        )
        if not dispatch_started:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                status="blocked",
                message="delivery is not dispatchable from its current state",
                error_code="delivery_not_dispatchable",
                details={"delivery_status": draft.status},
            )

        event_broker.publish(
            "delivery.dispatching",
            provider_id=provider_id,
            delivery_id=request.delivery_id,
            queue_group_id=queue_group_id,
        )

        result = await connector.dispatch(draft, request)

        if not result.ok:
            store.mark_delivery_failed(
                request.delivery_id,
                error=result.message,
                metadata={
                    "provider_id": provider_id,
                    "error_code": result.error_code,
                    "details": result.details,
                },
            )
            event_broker.publish(
                "delivery.failed",
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                queue_group_id=queue_group_id,
                error_code=result.error_code,
                message=result.message,
            )
            return result

        if result.generated_format_capture is None:
            store.mark_delivery_dispatched(
                request.delivery_id,
                provider_id=provider_id,
                metadata={"details": result.details},
            )
            event_broker.publish(
                "delivery.dispatched",
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                queue_group_id=queue_group_id,
            )
            return result

        generated_event = _generated_capture_event(
            provider_id=provider_id,
            queue_group_id=queue_group_id,
            parent_delivery_id=request.delivery_id,
            parent_message_id=draft.message_id,
            format_capture=result.generated_format_capture,
        )

        generated_session_id = store.upsert_session(generated_event)
        store.set_session_queue_group(
            source_session_id=generated_session_id,
            queue_group_id=queue_group_id,
            provider=provider_id,
            label=generated_event.conversation_title,
        )

        generated_message_id, _deduped = store.insert_message(generated_event, generated_session_id)
        generated_delivery_id = store.create_delivery(
            message_id=generated_message_id,
            route_id=f"{provider_id}_generated_response_to_local_draft",
            target_type="local_draft",
            target_id="default",
            wrapped_body=result.generated_format_capture.canonical_markdown,
            wrapped_format_capture=result.generated_format_capture,
            queue_group_id=queue_group_id,
        )

        store.mark_delivery_response_received(
            request.delivery_id,
            provider_id=provider_id,
            generated_message_id=generated_message_id,
            metadata={
                "generated_delivery_id": generated_delivery_id,
                "details": result.details,
            },
        )

        result.status = "response_received"
        result.generated_message_id = generated_message_id
        result.generated_delivery_ids = [generated_delivery_id]

        event_broker.publish(
            "message.generated",
            provider_id=provider_id,
            queue_group_id=queue_group_id,
            parent_delivery_id=request.delivery_id,
            generated_message_id=generated_message_id,
            generated_delivery_ids=[generated_delivery_id],
        )
        event_broker.publish(
            "delivery.response_received",
            provider_id=provider_id,
            delivery_id=request.delivery_id,
            queue_group_id=queue_group_id,
            generated_message_id=generated_message_id,
        )

        return result

    @app.get("/api/v1/provider-sessions")
    def provider_sessions() -> dict[str, object]:
        return {
            "provider_sessions": [
                item.model_dump() for item in store.list_provider_sessions()
            ]
        }

    @app.post("/api/v1/capture", response_model=CaptureResponse)
    def capture(event: CaptureEvent) -> CaptureResponse:
        if not event.text.strip():
            raise HTTPException(status_code=422, detail="capture text is empty")

        if event.text_length != len(event.text):
            if abs(event.text_length - len(event.text)) > 5:
                raise HTTPException(
                    status_code=422,
                    detail="text_length does not match text length",
                )

        result = router.capture(event)
        event_broker.publish(
            "message.captured",
            provider=event.provider,
            source_session_id=event.source_session_id,
            message_id=result.message_id,
            delivery_ids=result.delivery_ids,
            deduped=result.deduped,
            route_decision=result.route_decision,
        )
        if result.delivery_ids:
            event_broker.publish(
                "delivery.queued",
                provider=event.provider,
                source_session_id=event.source_session_id,
                delivery_ids=result.delivery_ids,
                message_id=result.message_id,
            )
        return result

    @app.get("/api/v1/drafts", response_model=DraftListResponse)
    def list_drafts(
            include_handled: bool = False,
            queue_group_id: str | None = Query(default=None),
    ) -> DraftListResponse:
        return DraftListResponse(
            drafts=store.list_drafts(
                include_handled=include_handled,
                queue_group_id=queue_group_id,
            )
        )

    @app.get("/api/v1/drafts/next", response_model=NextDraftResponse)
    def next_draft(
            exclude_source_session_id: str | None = Query(default=None),
            provider: str | None = Query(default=None),
            target_type: str = Query(default="local_draft"),
            target_id: str = Query(default="default"),
            queue_group_id: str | None = Query(default=None),
    ) -> NextDraftResponse:
        draft = store.get_next_draft(
            exclude_source_session_id=exclude_source_session_id,
            provider=provider,
            target_type=target_type,
            target_id=target_id,
            queue_group_id=queue_group_id,
        )

        if not draft:
            return NextDraftResponse(
                found=False,
                draft=None,
                reason="no queued draft matched request",
            )

        return NextDraftResponse(found=True, draft=draft)

    @app.post("/api/v1/drafts/clear-queued", response_model=ClearQueuedResponse)
    def clear_queued(request: ClearQueuedRequest) -> ClearQueuedResponse:
        count = store.clear_queued(
            queue_group_id=request.queue_group_id,
            provider=request.provider,
            reason=request.reason,
        )
        event_broker.publish(
            "delivery.clear_queued",
            queue_group_id=request.queue_group_id,
            provider=request.provider,
            cancelled_count=count,
        )
        return ClearQueuedResponse(
            ok=True,
            cancelled_count=count,
            queue_group_id=request.queue_group_id,
        )

    @app.post("/api/v1/drafts/{delivery_id}/cancel", response_model=DeliveryUpdateResponse)
    def cancel_draft(delivery_id: str, request: DraftCancelRequest) -> DeliveryUpdateResponse:
        changed = store.cancel_delivery(delivery_id, reason=request.reason)
        if changed:
            event_broker.publish(
                "delivery.cancelled",
                delivery_id=delivery_id,
            )
        return DeliveryUpdateResponse(
            ok=changed,
            delivery_id=delivery_id,
            status="cancelled" if changed else None,
        )

    @app.post("/api/v1/drafts/{delivery_id}/draft-inserted", response_model=DeliveryUpdateResponse)
    def mark_draft_inserted(
            delivery_id: str,
            request: DraftInsertedRequest,
    ) -> DeliveryUpdateResponse:
        changed = store.mark_delivery_draft_inserted(
            delivery_id,
            target_session_id=request.target_session_id,
            target_provider=request.target_provider,
            target_conversation_id=request.target_conversation_id,
            target_gizmo_id=request.target_gizmo_id,
            inserted_at=request.inserted_at,
            metadata=request.metadata,
        )
        if changed:
            event_broker.publish(
                "delivery.draft_inserted",
                delivery_id=delivery_id,
                target_session_id=request.target_session_id,
                target_provider=request.target_provider,
            )
        return DeliveryUpdateResponse(
            ok=changed,
            delivery_id=delivery_id,
            status="draft_inserted" if changed else None,
        )

    @app.post("/api/v1/drafts/{delivery_id}/failed", response_model=DeliveryUpdateResponse)
    def mark_draft_failed(
            delivery_id: str,
            request: DraftFailedRequest,
    ) -> DeliveryUpdateResponse:
        changed = store.mark_delivery_failed(
            delivery_id,
            error=request.error,
            target_session_id=request.target_session_id,
            failed_at=request.failed_at,
            metadata=request.metadata,
        )
        if changed:
            event_broker.publish(
                "delivery.failed",
                delivery_id=delivery_id,
                error=request.error,
                target_session_id=request.target_session_id,
            )
        return DeliveryUpdateResponse(
            ok=changed,
            delivery_id=delivery_id,
            status="failed" if changed else None,
        )

    @app.post("/api/v1/drafts/{delivery_id}/handled")
    def mark_handled(delivery_id: str) -> dict[str, object]:
        changed = store.mark_delivery_handled(delivery_id)
        if changed:
            event_broker.publish(
                "delivery.handled",
                delivery_id=delivery_id,
            )
        return {"ok": changed, "delivery_id": delivery_id}

    @app.get("/api/v1/queue-groups", response_model=QueueGroupListResponse)
    def list_queue_groups(include_deleted: bool = False) -> QueueGroupListResponse:
        return QueueGroupListResponse(
            queue_groups=store.list_queue_groups(include_deleted=include_deleted)
        )

    @app.post("/api/v1/queue-groups", response_model=QueueGroupMutationResponse)
    def create_queue_group(request: QueueGroupCreateRequest) -> QueueGroupMutationResponse:
        group = store.create_queue_group(request.name)
        event_broker.publish(
            "queue_group.created",
            queue_group_id=group.queue_group_id,
            name=group.name,
        )
        return QueueGroupMutationResponse(
            ok=True,
            queue_group_id=group.queue_group_id,
            queue_group=group,
        )

    @app.post(
        "/api/v1/queue-groups/{queue_group_id}/rename",
        response_model=QueueGroupMutationResponse,
    )
    def rename_queue_group(
            queue_group_id: str,
            request: QueueGroupRenameRequest,
    ) -> QueueGroupMutationResponse:
        group = store.rename_queue_group(queue_group_id, request.name)
        if group is not None:
            event_broker.publish(
                "queue_group.renamed",
                queue_group_id=queue_group_id,
                name=group.name,
            )
        return QueueGroupMutationResponse(
            ok=group is not None,
            queue_group_id=queue_group_id,
            queue_group=group,
            error=None if group else "queue group not found or invalid name",
        )

    @app.post(
        "/api/v1/queue-groups/{queue_group_id}/delete",
        response_model=QueueGroupMutationResponse,
    )
    def delete_queue_group(
            queue_group_id: str,
            request: QueueGroupDeleteRequest,
    ) -> QueueGroupMutationResponse:
        ok, cancelled = store.delete_queue_group(
            queue_group_id,
            cancel_queued=request.cancel_queued,
            reason=request.reason,
        )
        if ok:
            event_broker.publish(
                "queue_group.deleted",
                queue_group_id=queue_group_id,
                cancelled_count=cancelled,
            )
        return QueueGroupMutationResponse(
            ok=ok,
            queue_group_id=queue_group_id,
            queue_group=None,
            cancelled_count=cancelled,
            error=None if ok else "default or missing queue group cannot be deleted",
        )

    @app.get("/api/v1/sessions/queue-group", response_model=SessionQueueGroupResponse)
    def get_session_queue_group(
            source_session_id: str,
            provider: str | None = None,
            label: str | None = None,
    ) -> SessionQueueGroupResponse:
        group = store.get_session_queue_group(source_session_id, provider=provider, label=label)
        return SessionQueueGroupResponse(
            ok=True,
            source_session_id=source_session_id,
            queue_group=group,
        )

    @app.post("/api/v1/sessions/queue-group", response_model=SessionQueueGroupResponse)
    def set_session_queue_group(request: SessionQueueGroupRequest) -> SessionQueueGroupResponse:
        group = store.set_session_queue_group(
            source_session_id=request.source_session_id,
            provider=request.provider,
            label=request.label,
            queue_group_id=request.queue_group_id,
        )
        if group is None:
            default_group = store.get_session_queue_group(
                request.source_session_id,
                provider=request.provider,
                label=request.label,
            )
            return SessionQueueGroupResponse(
                ok=False,
                source_session_id=request.source_session_id,
                queue_group=default_group,
                error="queue group not found",
            )

        event_broker.publish(
            "session.queue_group.assigned",
            source_session_id=request.source_session_id,
            provider=request.provider,
            queue_group_id=group.queue_group_id,
            queue_group_name=group.name,
        )
        return SessionQueueGroupResponse(
            ok=True,
            source_session_id=request.source_session_id,
            queue_group=group,
        )

    @app.get("/api/v1/admin/summary")
    def summary() -> dict[str, object]:
        return {"database_path": str(cfg.database_path), **store.summary()}

    @app.get("/draft-inbox", response_class=HTMLResponse)
    def draft_inbox() -> HTMLResponse:
        html_path = _WEB_DIR / "draft_inbox.html"
        if not html_path.exists():
            raise HTTPException(status_code=500, detail=f"missing web asset: {html_path}")
        return HTMLResponse(html_path.read_text(encoding="utf-8"))

    return app


app = create_app()