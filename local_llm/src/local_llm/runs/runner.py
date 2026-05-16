from __future__ import annotations

import time
import uuid
from typing import Any

from local_llm.config import AppConfig
from local_llm.contracts import RespondRequest, RespondResponse, SupportMetadata, WarningItem
from local_llm.control.profiles import resolve_workflow
from local_llm.control.workflows import assert_supported_workflow
from local_llm.generation.prompt_builder import build_prompt
from local_llm.generation.providers.base import build_provider
from local_llm.retrieval.context_builder import build_context
from local_llm.retrieval.retriever import search
from local_llm.store.artifacts import ArtifactWriter
from local_llm.store.sqlite_store import SQLiteStore


async def respond(config: AppConfig, store: SQLiteStore, request: RespondRequest) -> RespondResponse:
    start = time.monotonic()
    run_id = str(uuid.uuid4())
    workflow = resolve_workflow(config, request.workflow_id)
    assert_supported_workflow(workflow)

    warnings: list[WarningItem] = []
    retrievals = []
    retrieved_context = ""

    if workflow.rag_profile.enabled:
        search_response = search(config, store, rag_profile_id=workflow.rag_profile_id, query=request.input, top_k=workflow.rag_profile.retrieval.top_k)
        retrievals = search_response.results
        warnings.extend(search_response.warnings)
        built_context = build_context(workflow.rag_profile, retrievals)
        retrievals = built_context.retrievals
        warnings.extend(built_context.warnings)
        retrieved_context = built_context.text

    built_prompt = build_prompt(workflow.prompt_profile, user_input=request.input, retrieved_context=retrieved_context)

    grounding_mode = workflow.prompt_profile.grounding_mode
    provider_raw_response: dict[str, Any] = {}
    provider_metadata: dict[str, Any] = {}
    provider_latency_ms = 0

    if grounding_mode == "require_sources" and not retrievals:
        warnings.append(
            WarningItem(
                code="answer_generated_without_context",
                message="grounding_mode=require_sources and no retrieval results were available; provider call skipped",
                details={"workflow_id": request.workflow_id},
            )
        )
        response_text = "No source-supported answer is available because retrieval returned no context."
    else:
        provider = build_provider(workflow.model_profile)
        try:
            provider_response = await provider.chat(built_prompt.messages, settings=workflow.model_profile.defaults.model_dump())
            response_text = provider_response.text
            provider_raw_response = provider_response.raw_response
            provider_metadata = provider_response.provider_metadata
            provider_latency_ms = provider_response.latency_ms
        except Exception as exc:
            warnings.append(
                WarningItem(
                    code="model_endpoint_unreachable",
                    message=str(exc),
                    details={"model_profile": workflow.model_profile_id},
                )
            )
            response_text = ""
            provider_raw_response = {"error": str(exc)}

    support = SupportMetadata(
        retrieval_used=bool(retrievals),
        source_count=len({r.source_id for r in retrievals}),
        document_count=len({r.document_id for r in retrievals}),
        chunk_count=len(retrievals),
        grounding_mode=grounding_mode,
    )
    latency_ms = int((time.monotonic() - start) * 1000)
    metadata = {**request.metadata, "provider_metadata": provider_metadata, "provider_latency_ms": provider_latency_ms}

    store.insert_run(
        run_id=run_id,
        workflow_id=request.workflow_id,
        workflow_kind=workflow.workflow.kind,
        model_profile=workflow.model_profile_id,
        rag_profile=workflow.rag_profile_id,
        prompt_profile=workflow.prompt_profile_id,
        user_input=request.input,
        final_prompt=built_prompt.final_prompt,
        response_text=response_text,
        latency_ms=latency_ms,
        support=support,
        warnings=warnings,
        metadata=metadata,
        retrievals=retrievals,
    )

    writer = ArtifactWriter(config.artifact_dir)
    artifacts = [
        ("request", "request.json", request.model_dump()),
        ("retrievals", "retrievals.json", [r.model_dump() for r in retrievals]),
        ("context", "context.txt", retrieved_context),
        ("prompt", "prompt.json", {"messages": built_prompt.messages, "final_prompt": built_prompt.final_prompt}),
        ("response", "response.json", {"response_text": response_text, "support": support.model_dump(), "warnings": [w.model_dump() for w in warnings]}),
        ("provider_raw_response", "provider_raw_response.json", provider_raw_response),
        ("diagnostics", "diagnostics.json", {"latency_ms": latency_ms, "metadata": metadata}),
    ]
    for artifact_type, filename, payload in artifacts:
        if filename.endswith(".json"):
            path, digest = writer.write_json(run_id, filename, payload)
        else:
            path, digest = writer.write_text(run_id, filename, str(payload))
        store.insert_run_artifact(run_id=run_id, artifact_type=artifact_type, path=str(path), content_hash=digest)

    return RespondResponse(
        ok=bool(response_text),
        run_id=run_id,
        workflow_id=request.workflow_id,
        workflow_kind=workflow.workflow.kind,
        model_profile=workflow.model_profile_id,
        rag_profile=workflow.rag_profile_id,
        prompt_profile=workflow.prompt_profile_id,
        response_text=response_text,
        support=support,
        retrievals=retrievals,
        warnings=warnings,
        latency_ms=latency_ms,
    )
