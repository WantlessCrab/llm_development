from __future__ import annotations

from importlib.resources import files
from typing import Any, Literal

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, RedirectResponse

from local_llm import __version__
from local_llm.config import AppConfig, load_config
from local_llm.contracts import (
    ContentLoadResponse,
    ExperimentRunMatrixRequest,
    CreateSessionRequest,
    CreateTurnRequest,
    DoctorResponse,
    HealthResponse,
    IngestResponse,
    MetricAvailabilityResponse,
    OperatorFeedbackRequest,
    OperatorFeedbackResponse,
    PacketDetailResponse,
    PacketGroupResponse,
    PacketListRequest,
    PacketListResponse,
    ProjectionRequest,
    ProjectionResult,
    ResolvedExperimentCondition,
    ResolvedExperimentRunMatrixRequest,
    RespondRequest,
    RespondResponse,
    SearchRequest,
    SearchResponse,
    SessionComparisonRequest,
    SessionResponse,
    SessionTurnResponse,
    UpdateSessionRequest,
)
from local_llm.diagnostics import run_doctor
from local_llm.eval_capture.experiments import ExperimentRunMatrixPlanner
from local_llm.eval_capture.groups import build_session_comparison_request
from local_llm.eval_capture.operator_feedback import build_operator_feedback_facts
from local_llm.eval_capture.projections import ProjectionService
from local_llm.retrieval.indexer import ingest_corpus
from local_llm.retrieval.retriever import search
from local_llm.sessions.service import create_session, create_turn, update_session
from local_llm.store.base import StoreProtocol
from local_llm.store.factory import build_store
from local_llm.turns.execution import TurnExecutionService
from local_llm.turns.request import TurnExecutionRequest


def _resolve_experiment_condition(
        *,
        condition: Any,
        role: Literal["baseline", "variable"],
        cfg: AppConfig,
) -> ResolvedExperimentCondition:
    replicate_count = condition.replicate_count
    if replicate_count is None:
        replicate_count = cfg.training.experiment_default_replicates
    if replicate_count > cfg.training.experiment_max_replicates_per_condition:
        raise HTTPException(
            status_code=422,
            detail=(
                f"replicate_count for {condition.label!r} exceeds "
                "training.experiment_max_replicates_per_condition"
            ),
        )
    return ResolvedExperimentCondition(
        label=condition.label,
        role=role,
        config_overlay=condition.config_overlay,
        replicate_count=replicate_count,
    )


def _resolve_experiment_request(
        request: ExperimentRunMatrixRequest,
        cfg: AppConfig,
) -> ResolvedExperimentRunMatrixRequest:
    return ResolvedExperimentRunMatrixRequest(
        workflow_id=request.workflow_id,
        input=request.input,
        baseline=_resolve_experiment_condition(condition=request.baseline, role="baseline",
                                               cfg=cfg),
        variables=[
            _resolve_experiment_condition(condition=item, role="variable", cfg=cfg)
            for item in request.variables
        ],
        capture_mode=request.capture_mode,
        privacy_level=request.privacy_level,
        operator_labels=request.operator_labels,
        training_preferences={
            "experiment_default_replicates": cfg.training.experiment_default_replicates,
            "experiment_max_replicates_per_condition": cfg.training.experiment_max_replicates_per_condition,
            "experiment_max_planned_packets": cfg.training.experiment_max_planned_packets,
        },
    )


def create_app(config: AppConfig | None = None) -> FastAPI:
    cfg = config or load_config()
    store = build_store(cfg)

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
            storage_backend=cfg.storage_backend,
            database_label=cfg.database_label,
            artifact_dir=str(cfg.artifact_dir),
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
            "storage_backend": cfg.storage_backend,
            "database_label": cfg.database_label,
            "eval_capture": cfg.eval_capture.model_dump(),
            "privacy": cfg.privacy.model_dump(),
            "training": cfg.training.model_dump(),
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
            return search(cfg, store, rag_profile_id=request.rag_profile, query=request.query,
                          top_k=request.top_k)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/v1/respond", response_model=RespondResponse)
    async def respond_api(request: RespondRequest) -> RespondResponse:
        try:
            turn_request = TurnExecutionRequest(
                source_kind="respond",
                workflow_id=request.workflow_id,
                input=request.input,
                metadata=request.metadata,
                capture_mode=request.capture_mode or request.eval_capture_mode,
                privacy_mode=request.privacy_mode,
                privacy_level=request.privacy_level,
                idempotency_key=request.idempotency_key,
                idempotency_scope_hash=request.idempotency_scope_hash,
                source_system="local_llm",
            )
            return await TurnExecutionService(cfg, store).respond(turn_request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/sessions", response_model=list[SessionResponse])
    def list_sessions(include_archived: bool = False) -> list[SessionResponse]:
        return [SessionResponse(**row) for row in
                store.list_sessions(include_archived=include_archived)]

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
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/v1/sessions/{session_id}/archive", response_model=SessionResponse)
    def archive_session_api(session_id: str) -> SessionResponse:
        row = store.archive_session(session_id)
        if not row:
            raise HTTPException(status_code=404, detail=f"session not found: {session_id}")
        return SessionResponse(**row)

    @app.get("/api/v1/sessions/{session_id}/turns", response_model=PacketListResponse)
    def list_turns_api(session_id: str) -> PacketListResponse:
        if not store.get_session(session_id):
            raise HTTPException(status_code=404, detail=f"session not found: {session_id}")
        return store.list_turn_packets(PacketListRequest(session_id=session_id, limit=500))

    @app.post("/api/v1/sessions/{session_id}/turns", response_model=SessionTurnResponse)
    async def create_turn_api(session_id: str, request: CreateTurnRequest) -> SessionTurnResponse:
        try:
            return await create_turn(cfg, store, session_id, request)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/packets", response_model=PacketListResponse)
    def list_packets(
            session_id: str | None = None,
            workflow_id: str | None = None,
            group_id: str | None = None,
            capture_mode: str | None = None,
            limit: int = 50,
    ) -> PacketListResponse:
        return store.list_turn_packets(
            PacketListRequest(
                session_id=session_id,
                workflow_id=workflow_id,
                group_id=group_id,
                capture_mode=capture_mode,  # type: ignore[arg-type]
                limit=limit,
            )
        )

    @app.get("/api/v1/packets/{turn_packet_id}", response_model=PacketDetailResponse)
    def packet_detail(turn_packet_id: str) -> PacketDetailResponse:
        result = ProjectionService(store).packet_detail(turn_packet_id)
        if not result:
            raise HTTPException(status_code=404, detail=f"packet not found: {turn_packet_id}")
        return result

    @app.post("/api/v1/packets/{turn_packet_id}/operator-feedback",
              response_model=OperatorFeedbackResponse)
    def operator_feedback(turn_packet_id: str,
                          request: OperatorFeedbackRequest) -> OperatorFeedbackResponse:
        if not store.get_turn_packet_summary(turn_packet_id):
            raise HTTPException(status_code=404, detail=f"packet not found: {turn_packet_id}")
        try:
            facts = build_operator_feedback_facts(
                turn_packet_id=turn_packet_id,
                request=request,
                training=cfg.training,
            )
            inserted = store.append_turn_metric_facts(facts)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return OperatorFeedbackResponse(turn_packet_id=turn_packet_id, metric_facts=inserted)

    @app.get("/api/v1/content/{content_ref_id}", response_model=ContentLoadResponse)
    def content(content_ref_id: str) -> ContentLoadResponse:
        result = ProjectionService(store).load_content(content_ref_id)
        if not result:
            raise HTTPException(status_code=404, detail=f"content_ref not found: {content_ref_id}")
        return result

    @app.get("/api/v1/metrics", response_model=MetricAvailabilityResponse)
    def metrics() -> MetricAvailabilityResponse:
        return ProjectionService(store).available_metrics()

    @app.get("/api/v1/groups/{packet_group_id}")
    def group_detail(packet_group_id: str) -> dict[str, Any]:
        result = ProjectionService(store).group_detail(packet_group_id)
        if not result:
            raise HTTPException(status_code=404,
                                detail=f"packet group not found: {packet_group_id}")
        return result

    @app.post("/api/v1/projection", response_model=ProjectionResult)
    def projection(request: ProjectionRequest) -> ProjectionResult:
        return ProjectionService(store).projection_result(request)

    @app.get("/api/v1/groups/{packet_group_id}/projection", response_model=ProjectionResult)
    def group_projection(packet_group_id: str) -> ProjectionResult:
        return ProjectionService(store).group_comparison(packet_group_id)

    @app.post("/api/v1/experiments/run-matrix")
    async def experiment_run_matrix(request: ExperimentRunMatrixRequest) -> dict[str, Any]:
        resolved = _resolve_experiment_request(request, cfg)
        planned_count = resolved.baseline.replicate_count + sum(
            item.replicate_count for item in resolved.variables)
        if planned_count < 1:
            raise HTTPException(status_code=422,
                                detail="experiment run matrix must include at least one replicate")
        if planned_count > cfg.training.experiment_max_planned_packets:
            raise HTTPException(
                status_code=422,
                detail=(
                    "experiment run matrix is too large for synchronous execution; "
                    "reduce replicate count or training.experiment_max_planned_packets"
                ),
            )
        planner = ExperimentRunMatrixPlanner()
        plan = planner.plan(store, resolved)
        service = TurnExecutionService(cfg, store)
        packets = [await service.execute(TurnExecutionRequest(**item)) for item in plan.requests]
        projection = ProjectionService(store).group_comparison(
            plan.experiment_group.packet_group_id)
        return {
            "planned_packet_count": planned_count,
            "completed_packet_count": sum(1 for packet in packets if packet.ok),
            "failed_packet_count": sum(1 for packet in packets if not packet.ok),
            "plan": plan.model_dump(),
            "packets": [packet.model_dump() for packet in packets],
            "projection": projection.model_dump(),
        }

    @app.post("/api/v1/analysis/compare-sessions", response_model=ProjectionResult)
    def compare_sessions(request: SessionComparisonRequest) -> ProjectionResult:
        return ProjectionService(store).projection_result(
            build_session_comparison_request(request.session_ids, request.metric_keys))

    @app.get("/api/v1/admin/summary")
    def summary() -> dict[str, object]:
        return {
            "storage_backend": cfg.storage_backend,
            "database_label": cfg.database_label,
            "artifact_dir": str(cfg.artifact_dir),
            "eval_capture_enabled": cfg.eval_capture.enabled,
            "eval_capture_failure_policy": cfg.eval_capture.failure_policy,
            **store.summary(),
        }

    return app


app = create_app()