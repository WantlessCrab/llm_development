from __future__ import annotations

import uuid
from typing import Any

from local_llm.config import AppConfig
from local_llm.contracts import (
    CreateSessionRequest,
    CreateTurnRequest,
    PacketListRequest,
    RespondRequest,
    SessionResponse,
    SessionTurnResponse,
    TurnResponse,
    UpdateSessionRequest,
)
from local_llm.store.base import StoreProtocol
from local_llm.turns.execution import TurnExecutionService
from local_llm.turns.request import TurnExecutionRequest


def _default_workflow_id(config: AppConfig, requested: str | None = None) -> str:
    if requested:
        if requested not in config.workflows:
            raise KeyError(requested)
        return requested
    if "default_rag_answer" in config.workflows:
        return "default_rag_answer"
    try:
        return next(iter(config.workflows))
    except StopIteration as exc:
        raise ValueError("no workflows configured") from exc


def _capture_pair(mode: str | None, level: str | None) -> tuple[str, str]:
    mode = mode or "full"
    level = level or ("standard" if mode == "privacy" else "none")
    if mode == "full" and level != "none":
        raise ValueError("privacy_level must be none when capture mode is full")
    if mode == "privacy" and level == "none":
        raise ValueError("privacy_level must be standard or strict when capture mode is privacy")
    return mode, level


def _session_response(row: dict[str, object]) -> SessionResponse:
    data = dict(row)
    if "metadata" not in data and "metadata_json" in data:
        data["metadata"] = data.get("metadata_json") or {}
    data.setdefault("turn_count", 0)
    data.setdefault("latest_turn_packet_id", None)
    data.setdefault("latest_turn_at", None)
    return SessionResponse(**data)


def create_session(
        config: AppConfig,
        store: StoreProtocol,
        request: CreateSessionRequest,
) -> SessionResponse:
    workflow_id = _default_workflow_id(config, request.default_workflow_id)
    workflow = config.workflows[workflow_id]
    mode, level = _capture_pair(
        request.default_capture_mode or workflow.eval_capture_mode or config.eval_capture.default_capture_mode,
        request.default_privacy_level or workflow.privacy_level or config.eval_capture.default_privacy_level,
    )
    session_id = str(uuid.uuid4())
    row = store.create_session(
        session_id=session_id,
        title=request.title.strip() or "Untitled session",
        description=request.description or "",
        default_workflow_id=workflow_id,
        default_model_profile=workflow.model_profile,
        default_rag_profile=workflow.rag_profile,
        default_prompt_profile=workflow.prompt_profile,
        metadata=request.metadata,
        default_capture_mode=mode,
        default_privacy_level=level,
        privacy_locked=request.privacy_locked,
    )
    return _session_response(row)


def update_session(
        config: AppConfig,
        store: StoreProtocol,
        session_id: str,
        request: UpdateSessionRequest,
) -> SessionResponse:
    current = store.get_session(session_id)
    if not current:
        raise KeyError(session_id)

    workflow_id = request.default_workflow_id
    defaults: dict[str, Any] = {}
    if workflow_id is not None:
        workflow_id = _default_workflow_id(config, workflow_id)
        workflow = config.workflows[workflow_id]
        defaults = {
            "default_workflow_id": workflow_id,
            "default_model_profile": workflow.model_profile,
            "default_rag_profile": workflow.rag_profile,
            "default_prompt_profile": workflow.prompt_profile,
        }

    if request.default_capture_mode is not None or request.default_privacy_level is not None:
        mode, level = _capture_pair(
            request.default_capture_mode or str(current.get("default_capture_mode", "full")),
            request.default_privacy_level or str(current.get("default_privacy_level", "none")),
        )
        defaults["default_capture_mode"] = mode
        defaults["default_privacy_level"] = level
    if request.privacy_locked is not None:
        defaults["privacy_locked"] = request.privacy_locked

    row = store.update_session(
        session_id=session_id,
        title=request.title,
        description=request.description,
        metadata=request.metadata,
        **defaults,
    )
    if not row:
        raise KeyError(session_id)
    return _session_response(row)


def _next_turn_ordinal(store: StoreProtocol, session_id: str) -> int:
    return store.next_turn_ordinal(session_id)


async def create_turn(
        config: AppConfig,
        store: StoreProtocol,
        session_id: str,
        request: CreateTurnRequest,
) -> SessionTurnResponse:
    session = store.get_session(session_id)
    if not session:
        raise KeyError(session_id)

    workflow_id = request.workflow_id or str(session["default_workflow_id"])
    if workflow_id not in config.workflows:
        raise KeyError(workflow_id)

    requested_mode = request.capture_mode or request.eval_capture_mode
    if session.get("privacy_locked") and requested_mode == "full":
        raise ValueError(
            "session privacy_locked=true prevents request-level downgrade to full mode")

    turn_id = str(uuid.uuid4())
    turn_ordinal = _next_turn_ordinal(store, session_id)
    metadata = {
        **request.metadata,
        "source": request.metadata.get("source", "session_turn"),
        "session_id": session_id,
        "turn_id": turn_id,
        "turn_ordinal": turn_ordinal,
        "default_capture_mode": session.get("default_capture_mode"),
        "default_privacy_level": session.get("default_privacy_level"),
        "privacy_locked": session.get("privacy_locked", False),
    }

    service = TurnExecutionService(config, store)
    response = await service.respond(
        TurnExecutionRequest(
            source_kind="session_turn",
            workflow_id=workflow_id,
            input=request.input,
            metadata=metadata,
            session_id=session_id,
            turn_id=turn_id,
            turn_ordinal=turn_ordinal,
            capture_mode=request.capture_mode or request.eval_capture_mode or str(
                session.get("default_capture_mode") or "full"),
            privacy_mode=request.privacy_mode,
            privacy_level=request.privacy_level or str(
                session.get("default_privacy_level") or "none"),
            idempotency_key=request.idempotency_key,
            idempotency_scope_hash=request.idempotency_scope_hash,
            source_system="local_llm",
        )
    )

    turn = TurnResponse(
        turn_id=turn_id,
        session_id=session_id,
        ordinal=turn_ordinal,
        user_input=request.input if response.text_persisted else None,
        turn_packet_id=response.turn_packet_id,
        created_at=response.packet_summary.created_at or "",
        metadata=metadata if not response.metadata_redacted else {"source": metadata.get("source")},
        capture_mode=response.capture_mode,
        privacy_level=response.privacy_level,
        text_persisted=response.text_persisted,
        metadata_redacted=response.metadata_redacted,
        redaction_policy_version=response.redaction_policy_version,
        capture_status=response.capture_status,
        capture_error_json=response.capture_error_json,
    )

    return SessionTurnResponse(
        session_id=session_id,
        turn_id=turn_id,
        turn_packet_id=response.turn_packet_id,
        turn=turn,
        response=response,
        packet_summary=response.packet_summary,
    )