from __future__ import annotations

import hashlib
import threading
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, RedirectResponse, StreamingResponse

from . import __version__
from .config import AppConfig, load_config
from .events import event_broker
from .format_capture import FORMAT_CAPTURE_VERSION, FormatCapture
from .prompt_wrappers import PromptWrapperError, apply_prompt_wrapper_by_id, list_prompt_wrappers
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
    PromptWrapperApplyRequest,
    PromptWrapperApplyResponse,
    PromptWrapperListResponse,
    PromptWrapperSummary,
    RouteActionExecuteRequest,
    RouteActionExecuteResponse,
    LocalServiceActionRequest,
    LocalServiceActionResponse,
    LocalServicesStatusResponse,
    QueueGroupCreateRequest,
    QueueGroupDeleteRequest,
    QueueGroupListResponse,
    QueueGroupMutationResponse,
    QueueGroupRenameRequest,
    SessionLabelRequest,
    SessionLabelResponse,
    SessionQueueGroupRequest,
    SessionQueueGroupResponse,
    StatusDetailResponse,
)
from .provider_discovery import ProviderDiscoveryManager
from .providers import ProviderRegistry
from .router import Router
from .service_control import LocalServiceController
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
    discovery = ProviderDiscoveryManager(cfg, providers)
    local_services = LocalServiceController.from_config(cfg.local_services)

    def prompt_wrapper_metadata(wrapper_id: str | None, text: str, *, source: str) -> tuple[
        str, dict[str, Any]]:
        if not wrapper_id:
            return text, {"enabled": False}
        wrapped, wrapper, meta = apply_prompt_wrapper_by_id(text, wrapper_id)
        if wrapper is None:
            return text, {"enabled": False}
        return wrapped, {
            **meta,
            "source": source,
        }

    def draft_with_prompt_wrapper(draft, wrapper_id: str | None, *, source: str):
        if not wrapper_id:
            return draft, {"enabled": False}
        original_text = draft.wrapped_body_markdown or draft.wrapped_body or ""
        wrapped_text, wrapper_meta = prompt_wrapper_metadata(wrapper_id, original_text,
                                                             source=source)
        wrapped_format = FormatCapture.from_legacy_text(
            wrapped_text,
            source_format="prompt_wrapper",
            provider_hints={
                "prompt_wrapper_id": wrapper_meta.get("wrapper_id"),
                "prompt_wrapper_label": wrapper_meta.get("label"),
                "parent_delivery_id": draft.delivery_id,
            },
        )
        return draft.model_copy(update={
            "wrapped_body": wrapped_text,
            "wrapped_body_markdown": wrapped_text,
            "wrapped_body_plain": wrapped_format.plain_text,
            "wrapped_body_html": wrapped_format.html_fragment,
            "wrapped_format_capture": wrapped_format,
            "metadata": {**(draft.metadata or {}), "prompt_wrapper": wrapper_meta},
        }), wrapper_meta

    async def dispatch_delivery_to_provider(
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

        wrapper_id = request.prompt_wrapper_id or (request.options or {}).get("prompt_wrapper_id")
        wrapper_source = (request.options or {}).get("prompt_wrapper_source") or "provider_dispatch"
        try:
            dispatch_draft, prompt_wrapper_meta = draft_with_prompt_wrapper(draft, wrapper_id,
                                                                            source=wrapper_source)
        except PromptWrapperError as exc:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=provider_id,
                delivery_id=request.delivery_id,
                status="blocked",
                message=str(exc),
                error_code="prompt_wrapper_error",
            )

        dispatch_started = store.mark_delivery_dispatching(
            request.delivery_id,
            provider_id=provider_id,
            metadata={
                "queue_group_id": queue_group_id,
                "manual_confirmed": request.manual_confirmed,
                "options": request.options,
                "prompt_wrapper": prompt_wrapper_meta,
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

        result = await connector.dispatch(dispatch_draft, request)

        if not result.ok:
            store.mark_delivery_failed(
                request.delivery_id,
                error=result.message,
                metadata={
                    "provider_id": provider_id,
                    "error_code": result.error_code,
                    "details": result.details,
                    "prompt_wrapper": prompt_wrapper_meta,
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
                metadata={"details": result.details, "prompt_wrapper": prompt_wrapper_meta},
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
        generated_event.metadata = {**(generated_event.metadata or {}),
                                    "prompt_wrapper": prompt_wrapper_meta}

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
            metadata={"generated_response": True, "parent_delivery_id": request.delivery_id,
                      "prompt_wrapper": prompt_wrapper_meta},
        )

        store.mark_delivery_response_received(
            request.delivery_id,
            provider_id=provider_id,
            generated_message_id=generated_message_id,
            metadata={
                "generated_delivery_id": generated_delivery_id,
                "details": result.details,
                "prompt_wrapper": prompt_wrapper_meta,
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

        if cfg.provider_discovery.enabled and cfg.provider_discovery.run_after_startup:
            def run_startup_discovery() -> None:
                try:
                    report = discovery.run(
                        probe=True,
                        apply_runtime=cfg.provider_discovery.apply_runtime,
                        persist_report=cfg.provider_discovery.persist_report,
                    )
                    event_broker.publish(
                        "provider_discovery.completed",
                        run_id=report.run_id,
                        applied_provider_ids=report.applied_provider_ids,
                        candidate_count=len(report.candidates),
                    )
                except Exception as exc:  # discovery must never make router startup unhealthy
                    discovery.latest_error = str(exc)
                    event_broker.publish(
                        "provider_discovery.failed",
                        error=str(exc),
                    )

            threading.Thread(
                target=run_startup_discovery,
                name="local-llm-router-provider-discovery",
                daemon=True,
            ).start()

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
        return await dispatch_delivery_to_provider(provider_id, request)

    @app.post("/api/v1/route-actions/execute", response_model=RouteActionExecuteResponse)
    async def execute_route_action(
            request: RouteActionExecuteRequest) -> RouteActionExecuteResponse:
        source = request.source.model_dump(exclude={"capture_event"})
        target = request.target.model_dump()

        def response(
                *,
                ok: bool,
                status: str,
                message: str,
                delivery_ids: list[str] | None = None,
                generated_delivery_ids: list[str] | None = None,
                details: dict[str, Any] | None = None,
        ) -> RouteActionExecuteResponse:
            return RouteActionExecuteResponse(
                ok=ok,
                status=status,
                message=message,
                operator_action_id=request.operator_action_id,
                queue_group_id=request.queue_group_id,
                source=source,
                target=target,
                delivery_ids=delivery_ids or [],
                generated_delivery_ids=generated_delivery_ids or [],
                details=details or {},
            )

        if request.target.kind in {"browser_provider", "chatgpt_active"}:
            return response(
                ok=False,
                status="blocked",
                message="browser insertion is owned by the active content script, not the daemon",
                details={"reason": "browser_dom_authority_required"},
            )

        delivery_id = request.source.delivery_id

        if not delivery_id and request.source.capture_event is not None:
            capture_event = request.source.capture_event
            metadata = dict(capture_event.metadata or {})
            metadata.update({
                "route_action": True,
                "operator_action_id": request.operator_action_id,
                "duplicate_intent": request.duplicate_intent,
                "queue_group_id": request.queue_group_id,
                "route_source_kind": request.source.kind,
                "route_target_kind": request.target.kind,
                "prompt_wrapper_id": request.prompt_wrapper_id,
                "prompt_wrapper_label": request.prompt_wrapper_label,
                **(request.metadata or {}),
            })
            capture_event.metadata = metadata
            capture_result = router.capture(capture_event)
            event_broker.publish(
                "message.captured",
                provider=capture_event.provider,
                source_session_id=capture_event.source_session_id,
                message_id=capture_result.message_id,
                delivery_ids=capture_result.delivery_ids,
                deduped=capture_result.deduped,
                route_decision=capture_result.route_decision,
            )
            if capture_result.delivery_ids:
                event_broker.publish(
                    "delivery.queued",
                    provider=capture_event.provider,
                    source_session_id=capture_event.source_session_id,
                    delivery_ids=capture_result.delivery_ids,
                    message_id=capture_result.message_id,
                )
            delivery_id = capture_result.delivery_ids[0] if capture_result.delivery_ids else None
            if request.target.kind == "local_draft":
                return response(
                    ok=True,
                    status="queued",
                    message="captured message queued to local draft",
                    delivery_ids=capture_result.delivery_ids,
                    details={
                        "message_id": capture_result.message_id,
                        "deduped": capture_result.deduped,
                        "route_decision": capture_result.route_decision,
                    },
                )

        if request.target.kind == "local_draft":
            if delivery_id and store.get_draft_by_delivery_id(delivery_id):
                return response(
                    ok=True,
                    status="already_queued",
                    message="selected delivery is already available in the local draft queue",
                    delivery_ids=[delivery_id],
                )
            return response(
                ok=False,
                status="failed",
                message="local_draft route action requires a capture_event or existing delivery_id",
            )

        if request.target.kind == "local_provider":
            provider_id = request.target.provider_id
            if not provider_id:
                return response(
                    ok=False,
                    status="failed",
                    message="local_provider target requires provider_id",
                )
            if not delivery_id:
                return response(
                    ok=False,
                    status="failed",
                    message="local_provider route action requires capture_event or delivery_id",
                )

            dispatch = await dispatch_delivery_to_provider(
                provider_id,
                ProviderDispatchRequest(
                    delivery_id=delivery_id,
                    queue_group_id=request.queue_group_id,
                    manual_confirmed=request.manual_confirmed,
                    prompt_wrapper_id=request.prompt_wrapper_id,
                    prompt_wrapper_label=request.prompt_wrapper_label,
                    options={
                        "route_action": True,
                        "operator_action_id": request.operator_action_id,
                        "duplicate_intent": request.duplicate_intent,
                        "route_source_kind": request.source.kind,
                        "route_target_kind": request.target.kind,
                        "prompt_wrapper_id": request.prompt_wrapper_id,
                        "prompt_wrapper_label": request.prompt_wrapper_label,
                        "prompt_wrapper_source": "route_action",
                        **(request.metadata or {}),
                    },
                ),
            )
            return response(
                ok=dispatch.ok,
                status="dispatched" if dispatch.ok else "blocked",
                message=dispatch.message,
                delivery_ids=[delivery_id],
                generated_delivery_ids=dispatch.generated_delivery_ids,
                details=dispatch.model_dump(),
            )

        return response(
            ok=False,
            status="failed",
            message=f"unsupported route target kind: {request.target.kind}",
        )

    @app.get("/api/v1/local-services/status", response_model=LocalServicesStatusResponse)
    def local_services_status(
            target: str | None = Query(default=None)) -> LocalServicesStatusResponse:
        try:
            statuses = local_services.status(target)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return LocalServicesStatusResponse(
            ok=True,
            enabled=cfg.local_services.enabled,
            services=[item.to_dict() for item in statuses],
        )

    @app.post("/api/v1/local-services/{action}", response_model=LocalServiceActionResponse)
    def local_services_action(
            action: str,
            request: LocalServiceActionRequest | None = None,
            target: str | None = Query(default=None),
    ) -> LocalServiceActionResponse:
        if action not in {"status", "start", "stop", "restart"}:
            raise HTTPException(status_code=422,
                                detail="action must be status, start, stop, or restart")
        service_target = target or (request.target if request else None)
        try:
            result = local_services.action(action, service_id=service_target)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        event_broker.publish(
            "local_services.action",
            action=action,
            target=service_target,
            ok=result.ok,
        )
        return LocalServiceActionResponse(
            ok=result.ok,
            enabled=cfg.local_services.enabled,
            action=action,
            target=service_target,
            message=result.message,
            services=[item.to_dict() for item in result.statuses],
            command_results=result.command_results,
        )

    @app.get("/api/v1/provider-discovery/status")
    def provider_discovery_status() -> dict[str, Any]:
        return discovery.status()

    @app.post("/api/v1/provider-discovery/run")
    def run_provider_discovery(request: dict[str, Any] | None = None) -> dict[str, Any]:
        request = request or {}
        roots = request.get("roots")
        if roots is not None and not isinstance(roots, list):
            raise HTTPException(status_code=422, detail="roots must be a list when provided")

        report = discovery.run(
            roots=[str(item) for item in roots] if roots else None,
            probe=bool(request.get("probe", True)),
            apply_runtime=bool(request.get("apply_runtime", cfg.provider_discovery.apply_runtime)),
            persist_report=bool(
                request.get("persist_report", cfg.provider_discovery.persist_report)),
            add_only_ready=bool(
                request.get("add_only_ready", cfg.provider_discovery.add_only_ready)),
            include_offline_candidates=bool(request.get("include_offline_candidates",
                                                        cfg.provider_discovery.include_offline_candidates)),
            replace_existing=bool(
                request.get("replace_existing", cfg.provider_discovery.replace_existing)),
        )
        event_broker.publish(
            "provider_discovery.completed",
            run_id=report.run_id,
            applied_provider_ids=report.applied_provider_ids,
            candidate_count=len(report.candidates),
        )
        return report.to_dict()

    @app.get("/api/v1/prompt-wrappers", response_model=PromptWrapperListResponse)
    def prompt_wrappers() -> PromptWrapperListResponse:
        try:
            wrappers = list_prompt_wrappers()
        except PromptWrapperError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        return PromptWrapperListResponse(
            prompt_wrappers=[PromptWrapperSummary(**item.summary()) for item in wrappers]
        )

    @app.post("/api/v1/prompt-wrappers/apply", response_model=PromptWrapperApplyResponse)
    def apply_prompt_wrapper(request: PromptWrapperApplyRequest) -> PromptWrapperApplyResponse:
        try:
            wrapped, wrapper, metadata = apply_prompt_wrapper_by_id(request.text,
                                                                    request.wrapper_id)
        except PromptWrapperError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        if wrapper is None:
            raise HTTPException(status_code=404, detail="prompt wrapper not found")
        return PromptWrapperApplyResponse(
            ok=True,
            wrapper_id=wrapper.wrapper_id,
            label=wrapper.label,
            original_length=len(request.text or ""),
            wrapped_length=len(wrapped),
            text=wrapped,
            metadata=metadata,
        )

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

        try:
            result = router.capture(event)
        except PromptWrapperError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
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

    @app.post("/api/v1/sessions/label", response_model=SessionLabelResponse)
    def set_session_label(request: SessionLabelRequest) -> SessionLabelResponse:
        try:
            group, label, label_source, updated_at = store.set_session_label(
                source_session_id=request.source_session_id,
                provider=request.provider,
                label=request.label,
                label_source=request.label_source,
            )
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

        event_broker.publish(
            "session.label.updated",
            source_session_id=request.source_session_id,
            provider=request.provider,
            label=label,
            label_source=label_source,
            queue_group_id=group.queue_group_id,
        )

        return SessionLabelResponse(
            ok=True,
            source_session_id=request.source_session_id,
            provider=request.provider,
            label=label,
            label_source=label_source,
            label_updated_at=updated_at,
            queue_group_id=group.queue_group_id,
            queue_group_name=group.name,
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