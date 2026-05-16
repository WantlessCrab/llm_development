from __future__ import annotations

import uuid
from typing import Any

from local_llm.config import AppConfig
from local_llm.contracts import (
    CreateSessionRequest,
    CreateTurnRequest,
    SessionResponse,
    SessionTurnResponse,
    TurnResponse,
    UpdateSessionRequest,
)
from local_llm.runs.runner import respond
from local_llm.store.sqlite_store import SQLiteStore


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


def create_session(config: AppConfig, store: SQLiteStore, request: CreateSessionRequest) -> SessionResponse:
    workflow_id = _default_workflow_id(config, request.default_workflow_id)
    workflow = config.workflows[workflow_id]
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
    )
    return SessionResponse(**row)


def update_session(config: AppConfig, store: SQLiteStore, session_id: str, request: UpdateSessionRequest) -> SessionResponse:
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

    row = store.update_session(
        session_id=session_id,
        title=request.title,
        description=request.description,
        metadata=request.metadata,
        **defaults,
    )
    if not row:
        raise KeyError(session_id)
    return SessionResponse(**row)


async def create_turn(config: AppConfig, store: SQLiteStore, session_id: str, request: CreateTurnRequest) -> SessionTurnResponse:
    session = store.get_session(session_id)
    if not session:
        raise KeyError(session_id)

    workflow_id = request.workflow_id or str(session["default_workflow_id"])
    if workflow_id not in config.workflows:
        raise KeyError(workflow_id)

    turn_id = str(uuid.uuid4())
    turn_metadata = {**request.metadata, "source": request.metadata.get("source", "ui")}
    turn_row = store.create_turn(
        turn_id=turn_id,
        session_id=session_id,
        user_input=request.input,
        metadata=turn_metadata,
    )

    from local_llm.contracts import RespondRequest

    response = await respond(
        config,
        store,
        RespondRequest(
            workflow_id=workflow_id,
            input=request.input,
            metadata={**turn_metadata, "session_id": session_id, "turn_id": turn_id},
        ),
    )
    store.link_turn_run(turn_id, response.run_id)
    final_turn = store.get_turn(turn_id) or turn_row
    return SessionTurnResponse(
        session_id=session_id,
        turn_id=turn_id,
        run_id=response.run_id,
        turn=TurnResponse(**final_turn),
        response=response,
    )
