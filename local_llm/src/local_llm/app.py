from __future__ import annotations

import json
from importlib.resources import files
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, RedirectResponse

from local_llm import __version__
from local_llm.config import AppConfig, load_config
from local_llm.contracts import (
    CreateSessionRequest,
    CreateTurnRequest,
    DoctorResponse,
    HealthResponse,
    IngestResponse,
    RespondRequest,
    RespondResponse,
    RunDetailResponse,
    SearchRequest,
    SearchResponse,
    SessionResponse,
    SessionTurnResponse,
    TurnResponse,
    UpdateSessionRequest,
)
from local_llm.diagnostics import run_doctor
from local_llm.retrieval.indexer import ingest_corpus
from local_llm.retrieval.retriever import search
from local_llm.runs.inspector import show_context
from local_llm.runs.runner import respond
from local_llm.sessions.service import create_session, create_turn, update_session
from local_llm.store.sqlite_store import SQLiteStore


def _json_load(value: object, default: Any) -> Any:
    if value is None:
        return default
    if isinstance(value, (dict, list)):
        return value
    try:
        return json.loads(str(value))
    except json.JSONDecodeError:
        return default


def _run_detail(store: SQLiteStore, run_id: str) -> RunDetailResponse:
    run = store.get_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
    run = dict(run)
    run["support"] = _json_load(run.get("support_json"), {})
    run["warnings"] = _json_load(run.get("warnings_json"), [])
    run["metadata"] = _json_load(run.get("metadata_json"), {})
    return RunDetailResponse(
        run=run,
        retrievals=store.get_run_retrievals(run_id),
        artifacts=_artifacts_with_exists(store, run_id),
    )


def _artifacts_with_exists(store: SQLiteStore, run_id: str) -> list[dict[str, Any]]:
    artifacts: list[dict[str, Any]] = []
    for item in store.get_run_artifacts(run_id):
        item = dict(item)
        path = Path(str(item["path"]))
        item["exists"] = path.exists()
        item["metadata"] = _json_load(item.get("metadata_json"), {})
        artifacts.append(item)
    return artifacts


def _artifact_text(store: SQLiteStore, run_id: str, artifact_type: str) -> str:
    for artifact in store.get_run_artifacts(run_id):
        if artifact.get("artifact_type") == artifact_type:
            path = Path(str(artifact["path"]))
            if not path.exists():
                raise HTTPException(status_code=404, detail=f"artifact file missing: {artifact_type}")
            return path.read_text(encoding="utf-8")
    raise HTTPException(status_code=404, detail=f"artifact not found: {artifact_type}")


def create_app(config: AppConfig | None = None) -> FastAPI:
    cfg = config or load_config()
    store = SQLiteStore(cfg.database_path)

    app = FastAPI(title="local_llm", version=__version__)

    @app.on_event("startup")
    def startup() -> None:
        store.init()
        cfg.artifact_dir.mkdir(parents=True, exist_ok=True)

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        return RedirectResponse(url="/ui")

    @app.get("/ui", include_in_schema=False)
    def ui() -> FileResponse:
        index = files("local_llm").joinpath("web/index.html")
        return FileResponse(str(index))

    @app.get("/health", response_model=HealthResponse)
    def health() -> HealthResponse:
        return HealthResponse(
            status="ok",
            app="local_llm",
            version=__version__,
            database_path=str(cfg.database_path),
            configured_models=sorted(cfg.model_profiles),
            configured_rag_profiles=sorted(cfg.rag_profiles),
            configured_workflows=sorted(cfg.workflows),
        )

    @app.get("/api/v1/doctor", response_model=DoctorResponse)
    def doctor() -> DoctorResponse:
        return run_doctor(check_provider=True)

    @app.get("/api/v1/config/summary")
    def config_summary() -> dict[str, object]:
        return {
            "workflows": sorted(cfg.workflows),
            "model_profiles": sorted(cfg.model_profiles),
            "rag_profiles": sorted(cfg.rag_profiles),
            "prompt_profiles": sorted(cfg.prompt_profiles),
            "corpora": sorted(cfg.corpora),
        }

    @app.post("/api/v1/corpora/{corpus_id}/ingest", response_model=IngestResponse)
    def ingest(corpus_id: str) -> IngestResponse:
        try:
            return ingest_corpus(cfg, store, corpus_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/v1/search", response_model=SearchResponse)
    def search_api(request: SearchRequest) -> SearchResponse:
        try:
            return search(cfg, store, rag_profile_id=request.rag_profile, query=request.query, top_k=request.top_k)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/v1/respond", response_model=RespondResponse)
    async def respond_api(request: RespondRequest) -> RespondResponse:
        try:
            return await respond(cfg, store, request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/sessions", response_model=list[SessionResponse])
    def list_sessions(include_archived: bool = False) -> list[SessionResponse]:
        return [SessionResponse(**row) for row in store.list_sessions(include_archived=include_archived)]

    @app.post("/api/v1/sessions", response_model=SessionResponse)
    def create_session_api(request: CreateSessionRequest) -> SessionResponse:
        try:
            return create_session(cfg, store, request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=f"workflow not found: {exc}") from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/sessions/{session_id}", response_model=SessionResponse)
    def get_session_api(session_id: str) -> SessionResponse:
        row = store.get_session(session_id)
        if not row:
            raise HTTPException(status_code=404, detail=f"session not found: {session_id}")
        return SessionResponse(**row)

    @app.patch("/api/v1/sessions/{session_id}", response_model=SessionResponse)
    def update_session_api(session_id: str, request: UpdateSessionRequest) -> SessionResponse:
        try:
            return update_session(cfg, store, session_id, request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/v1/sessions/{session_id}/archive", response_model=SessionResponse)
    def archive_session_api(session_id: str) -> SessionResponse:
        row = store.archive_session(session_id)
        if not row:
            raise HTTPException(status_code=404, detail=f"session not found: {session_id}")
        return SessionResponse(**row)

    @app.get("/api/v1/sessions/{session_id}/turns", response_model=list[TurnResponse])
    def list_turns_api(session_id: str) -> list[TurnResponse]:
        if not store.get_session(session_id):
            raise HTTPException(status_code=404, detail=f"session not found: {session_id}")
        return [TurnResponse(**row) for row in store.list_turns(session_id)]

    @app.post("/api/v1/sessions/{session_id}/turns", response_model=SessionTurnResponse)
    async def create_turn_api(session_id: str, request: CreateTurnRequest) -> SessionTurnResponse:
        try:
            return await create_turn(cfg, store, session_id, request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/runs")
    def list_runs(limit: int = 50) -> dict[str, object]:
        limit = max(1, min(limit, 200))
        return {"runs": store.list_runs(limit=limit)}

    @app.get("/api/v1/runs/{run_id}", response_model=RunDetailResponse)
    def get_run_api(run_id: str) -> RunDetailResponse:
        return _run_detail(store, run_id)

    @app.get("/api/v1/runs/{run_id}/retrievals")
    def get_run_retrievals_api(run_id: str) -> dict[str, object]:
        if not store.get_run(run_id):
            raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
        return {"run_id": run_id, "retrievals": store.get_run_retrievals(run_id)}

    @app.get("/api/v1/runs/{run_id}/artifacts")
    def get_run_artifacts_api(run_id: str) -> dict[str, object]:
        if not store.get_run(run_id):
            raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
        return {"run_id": run_id, "artifacts": _artifacts_with_exists(store, run_id)}

    @app.get("/api/v1/runs/{run_id}/prompt")
    def get_run_prompt_api(run_id: str) -> dict[str, object]:
        run = store.get_run(run_id)
        if not run:
            raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
        return {"run_id": run_id, "prompt": str(run["final_prompt"])}

    @app.get("/api/v1/runs/{run_id}/context")
    def get_run_context_api(run_id: str) -> dict[str, object]:
        if not store.get_run(run_id):
            raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
        return {"run_id": run_id, "context": show_context(store, run_id)}

    @app.get("/api/v1/runs/{run_id}/artifacts/{artifact_type}")
    def get_run_artifact_text_api(run_id: str, artifact_type: str) -> dict[str, object]:
        if not store.get_run(run_id):
            raise HTTPException(status_code=404, detail=f"run not found: {run_id}")
        return {"run_id": run_id, "artifact_type": artifact_type, "text": _artifact_text(store, run_id, artifact_type)}

    @app.get("/api/v1/admin/summary")
    def summary() -> dict[str, object]:
        return {"database": str(cfg.database_path), **store.summary()}

    return app


app = create_app()
