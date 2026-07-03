from __future__ import annotations

import time
import uuid
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from local_llm.config import AppConfig
from local_llm.contracts import PacketSummaryEnvelope, RespondResponse, RetrievalResult, \
    SupportMetadata, WarningItem
from local_llm.eval_capture.artifacts import build_retrieval_content_refs, \
    build_standard_artifact_refs, build_standard_content_refs
from local_llm.eval_capture.metrics import packet_metric_candidates
from local_llm.eval_capture.provider_metrics import extract_exposed_reasoning, \
    extract_provider_summary
from local_llm.eval_capture.recorder import TurnRecorder
from local_llm.eval_capture.redaction import sanitize_retrieval_identity
from local_llm.eval_capture.runtime import build_runtime_links
from local_llm.generation.prompt_builder import build_prompt
from local_llm.generation.providers.base import build_provider
from local_llm.retrieval.context_builder import build_context
from local_llm.retrieval.retriever import search
from local_llm.store.base import StoreProtocol
from local_llm.turns.packet import TurnAttempt, TurnGroupMembership, TurnPacket
from local_llm.turns.request import TurnExecutionRequest, build_execution_plan


def _retrieval_to_dict(item: Any) -> dict[str, Any]:
    return item.model_dump() if hasattr(item, "model_dump") else dict(getattr(item, "__dict__", {}))


def _safe_retrieval_payload(retrievals: list[Any], *, privacy: bool) -> list[dict[str, Any]]:
    payload: list[dict[str, Any]] = []
    for item in retrievals:
        data = _retrieval_to_dict(item)
        if privacy:
            payload.append(
                sanitize_retrieval_identity(
                    {
                        "rank": data.get("rank"),
                        "method": data.get("method"),
                        "score": data.get("score"),
                        "source_id": data.get("source_id"),
                        "document_id": data.get("document_id"),
                        "chunk_id": data.get("chunk_id"),
                        "document_path": data.get("document_path"),
                        "source_title": data.get("source_title"),
                    }
                )
            )
        else:
            payload.append(data)
    return payload


def _safe_context_summary(summary: dict[str, Any], *, privacy: bool) -> dict[str, Any]:
    if not privacy:
        return summary
    safe = dict(summary)
    safe["included_chunk_ids"] = []
    safe["content_ref_inputs"] = [sanitize_retrieval_identity(dict(item)) for item in
                                  safe.get("content_ref_inputs", [])]
    return safe


def _safe_metadata(metadata: dict[str, Any], *, privacy: bool) -> dict[str, Any]:
    if not privacy:
        return dict(metadata)
    allowed = {"source", "session_id", "turn_id", "turn_ordinal", "privacy_locked"}
    return {key: value for key, value in metadata.items() if key in allowed}


def _safe_provider_base_url(value: Any) -> str:
    parts = urlsplit(str(value))
    if not parts.scheme or not parts.netloc:
        return str(value).split("?", 1)[0].split("#", 1)[0]
    host = parts.hostname or ""
    port = f":{parts.port}" if parts.port else ""
    return urlunsplit((parts.scheme, f"{host}{port}", parts.path.rstrip("/"), "", ""))


def _safe_model_profile_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    safe = dict(snapshot)
    if "api_key" in safe:
        safe["api_key_present"] = bool(str(safe.pop("api_key") or "").strip())
    if "base_url" in safe:
        safe["base_url"] = _safe_provider_base_url(safe["base_url"])
    return safe


def _provider_request_identity(workflow: Any, *, api_key_present: bool) -> dict[str, Any]:
    return {
        "provider": workflow.model_profile.provider,
        "base_url": _safe_provider_base_url(workflow.model_profile.base_url),
        "model": workflow.model_profile.model,
        "request_format": "openai_chat_compatible",
        "api_key_present": api_key_present,
    }


def _attempt_provider_evidence(provider_request: dict[str, Any], *, privacy: bool) -> dict[
    str, Any]:
    if not privacy:
        return {"provider_request": provider_request}
    safe = {key: value for key, value in provider_request.items() if key != "payload"}
    safe["payload_omitted"] = True
    return {"provider_request": safe}


class TurnExecutionService:
    def __init__(self, config: AppConfig, store: StoreProtocol):
        self.config = config
        self.store = store
        self.recorder = TurnRecorder(store, artifact_root=config.artifact_dir)

    async def execute(self, request: TurnExecutionRequest) -> PacketSummaryEnvelope:
        start = time.monotonic()
        plan = build_execution_plan(self.config, request)
        workflow = plan.resolved_workflow
        policy = plan.capture_policy
        privacy = policy.capture_mode == "privacy"
        packet = TurnPacket(
            turn_packet_id=str(uuid.uuid4()),
            request_id=str(uuid.uuid4()),
            idempotency_key=plan.request.idempotency_key,
            idempotency_scope_hash=plan.request.idempotency_scope_hash,
            source_kind=str(plan.request.source_kind),
            capture_mode=policy.capture_mode,
            privacy_level=policy.privacy_level,
            text_persisted=policy.text_persisted,
            metadata_redacted=policy.metadata_redacted,
            redaction_policy_version=policy.redaction_policy_version,
            session_id=plan.request.session_id,
            turn_id=plan.request.turn_id,
            turn_ordinal=plan.request.turn_ordinal,
            workflow_id=workflow.workflow_id,
            workflow_kind=workflow.workflow.kind,
            model_profile_id=workflow.model_profile_id,
            rag_profile_id=workflow.rag_profile_id,
            prompt_profile_id=workflow.prompt_profile_id,
            corpus_id=workflow.rag_profile.corpus,
            config_snapshot_hash=plan.config_snapshot_hash,
            effective_config_hash=plan.effective_config_hash,
            config_snapshot_json={
                "workflow": plan.workflow_snapshot,
                "model_profile": _safe_model_profile_snapshot(plan.model_profile_snapshot),
                "rag_profile": plan.rag_profile_snapshot,
                "prompt_profile": plan.prompt_profile_snapshot,
                "overlay": plan.overlay_applied_json,
            },
            request_summary_json={"input_chars": len(plan.request.input),
                                  "metadata": _safe_metadata(plan.request.metadata,
                                                             privacy=privacy)},
            privacy_json=plan.privacy_policy,
            metadata_json={"operator_labels": plan.request.operator_labels,
                           **_safe_metadata(plan.request.metadata, privacy=privacy)},
            source_system=plan.request.source_system,
            source_record_id=plan.request.source_record_id,
        )
        attempt = packet.add_attempt(TurnAttempt())
        packet.add_event("request_received", payload={"source_kind": request.source_kind},
                         attempt_id=attempt.turn_attempt_id)
        packet.add_event("plan_resolved", payload={"workflow_id": workflow.workflow_id},
                         attempt_id=attempt.turn_attempt_id)
        packet.add_event("rag_directives_resolved", payload=plan.rag_directives_json,
                         attempt_id=attempt.turn_attempt_id)
        packet.add_event("privacy_policy_resolved", payload=plan.privacy_policy,
                         attempt_id=attempt.turn_attempt_id)

        warnings: list[WarningItem] = []
        retrievals: list[RetrievalResult] = []
        retrieved_context = ""
        retrieval_summary: dict[str, Any] = {}
        context_summary: dict[str, Any] = {}
        prompt_summary: dict[str, Any] = {}
        provider_summary: dict[str, Any] = {}
        provider_request_json: dict[str, Any] = {}
        provider_raw_response: dict[str, Any] = {}
        provider_exposed_reasoning: Any | None = None
        response_text = ""

        try:
            if workflow.rag_profile.enabled:
                r_start = time.monotonic()
                packet.add_event("retrieval_started", attempt_id=attempt.turn_attempt_id)
                search_response = search(
                    self.config,
                    self.store,
                    rag_profile_id=workflow.rag_profile_id,
                    query=request.input,
                    top_k=workflow.rag_profile.retrieval.top_k,
                    query_text_allowed=not privacy,
                )
                retrievals = search_response.results
                warnings.extend(search_response.warnings)
                observation = search_response.observation.model_dump() if search_response.observation else {}
                observation["latency_ms"] = int((time.monotonic() - r_start) * 1000)
                packet.search_observation_json = observation
                retrieval_summary = {
                    **observation,
                    "returned_count": len(retrievals),
                    "candidate_count": observation.get("candidate_count", len(retrievals)),
                }
                packet.retrieval_summary_json = retrieval_summary
                packet.add_event("retrieval_completed", payload={"returned_count": len(retrievals)},
                                 attempt_id=attempt.turn_attempt_id,
                                 latency_ms=observation["latency_ms"])
                packet.add_event("retrieval_candidates_ranked",
                                 payload={"returned_count": len(retrievals)},
                                 attempt_id=attempt.turn_attempt_id)
                c_start = time.monotonic()
                built_context = build_context(workflow.rag_profile, retrievals)
                retrievals = built_context.retrievals
                warnings.extend(built_context.warnings)
                retrieved_context = built_context.text
                context_summary = built_context.summary.model_dump()
                context_summary["latency_ms"] = int((time.monotonic() - c_start) * 1000)
                packet.context_summary_json = _safe_context_summary(context_summary,
                                                                    privacy=privacy)
                packet.add_event("context_built", payload=packet.context_summary_json,
                                 attempt_id=attempt.turn_attempt_id,
                                 latency_ms=context_summary["latency_ms"])

            p_start = time.monotonic()
            built_prompt = build_prompt(workflow.prompt_profile, user_input=request.input,
                                        retrieved_context=retrieved_context)
            prompt_summary = built_prompt.summary.model_dump()
            prompt_summary["latency_ms"] = int((time.monotonic() - p_start) * 1000)
            packet.prompt_summary_json = prompt_summary if not privacy else {
                "message_count": prompt_summary.get("message_count"),
                "system_chars": prompt_summary.get("system_chars"),
                "user_chars": prompt_summary.get("user_chars"),
                "prompt_chars": prompt_summary.get("prompt_chars"),
                "context_in_prompt_chars": prompt_summary.get("context_in_prompt_chars"),
                "token_estimate": prompt_summary.get("token_estimate"),
                "latency_ms": prompt_summary.get("latency_ms"),
            }
            packet.add_event("prompt_built", payload=packet.prompt_summary_json,
                             attempt_id=attempt.turn_attempt_id,
                             latency_ms=prompt_summary["latency_ms"])

            provider_settings = workflow.model_profile.defaults.model_dump()
            api_key_present = bool(str(workflow.model_profile.api_key or "").strip())

            if workflow.prompt_profile.grounding_mode == "require_sources" and not retrievals:
                warnings.append(WarningItem(code="answer_generated_without_context",
                                            message="grounding_mode=require_sources and no retrieval results were available; provider call skipped",
                                            details={"workflow_id": request.workflow_id}))
                provider_request_json = {
                    **_provider_request_identity(workflow, api_key_present=api_key_present),
                    "provider_call_skipped": True,
                    "skip_reason": "grounding_mode=require_sources and no retrieval results were available",
                    "payload": {},
                    "settings": provider_settings,
                }
                attempt.provider_evidence_json = _attempt_provider_evidence(
                    provider_request_json, privacy=privacy)
                response_text = "No source-supported answer is available because retrieval returned no context."
            else:
                provider = build_provider(workflow.model_profile)
                provider_request_payload = provider.build_request_payload(
                    built_prompt.messages,
                    provider_settings,
                )
                provider_request_json = {
                    **_provider_request_identity(workflow, api_key_present=api_key_present),
                    "provider_call_skipped": False,
                    "payload": provider_request_payload,
                    "settings": provider_settings,
                }
                attempt.provider_evidence_json = _attempt_provider_evidence(
                    provider_request_json, privacy=privacy)
                packet.add_event("provider_started", attempt_id=attempt.turn_attempt_id)
                provider_response = await provider.chat(built_prompt.messages,
                                                        settings=provider_settings)
                response_text = provider_response.text
                provider_raw_response = provider_response.raw_response
                provider_summary = extract_provider_summary(text=response_text,
                                                            raw_response=provider_raw_response,
                                                            provider_metadata=provider_response.provider_metadata,
                                                            latency_ms=provider_response.latency_ms)
                provider_exposed_reasoning = extract_exposed_reasoning(provider_raw_response)
                packet.provider_summary_json = provider_summary
                attempt.provider_evidence_json = {
                    **attempt.provider_evidence_json,
                    "provider_summary": provider_summary,
                    "provider_exposed_reasoning_present": provider_exposed_reasoning is not None,
                }
                if provider_exposed_reasoning is not None:
                    packet.add_event("provider_exposed_reasoning_captured",
                                     payload={"present": True}, attempt_id=attempt.turn_attempt_id)
                packet.add_event("provider_completed", payload=provider_summary,
                                 attempt_id=attempt.turn_attempt_id,
                                 latency_ms=provider_response.latency_ms)

            packet.response_text = response_text
            packet.runtime_links_json = build_runtime_links(self.config,
                                                            runtime_root=plan.runtime_root,
                                                            provider_summary=provider_summary)
            packet.add_event("runtime_evidence_captured", payload=packet.runtime_links_json,
                             attempt_id=attempt.turn_attempt_id)

            if plan.request.condition_group_id and plan.request.replicate_index is not None:
                packet.add_group_membership(TurnGroupMembership(
                    packet_group_id=plan.request.condition_group_id,
                    member_type="turn_packet",
                    member_role="replicate",
                    member_id=packet.turn_packet_id,
                    turn_packet_id=packet.turn_packet_id,
                    turn_attempt_id=attempt.turn_attempt_id,
                    replicate_index=plan.request.replicate_index,
                    include_in_aggregate=True,
                    metadata_json={"experiment_group_id": plan.request.experiment_group_id},
                ))
            for group_id in plan.request.packet_group_ids:
                packet.add_group_membership(TurnGroupMembership(
                    packet_group_id=group_id,
                    member_type="turn_packet",
                    member_role="analysis_member",
                    member_id=packet.turn_packet_id,
                    turn_packet_id=packet.turn_packet_id,
                    turn_attempt_id=attempt.turn_attempt_id,
                    include_in_aggregate=True,
                ))
            packet.add_event("group_membership_attached",
                             payload={"group_membership_count": len(packet.group_memberships)},
                             attempt_id=attempt.turn_attempt_id)

            for ref in build_standard_content_refs(
                    user_input=request.input,
                    retrieved_context=retrieved_context,
                    final_prompt=built_prompt.final_prompt,
                    response_text=response_text,
                    provider_request=provider_request_json,
                    provider_raw_response=provider_raw_response,
                    provider_exposed_reasoning=provider_exposed_reasoning,
                    policy=policy,
                    attempt_id=attempt.turn_attempt_id,
            ):
                packet.add_content_ref(ref)
            for ref in build_retrieval_content_refs(retrievals=retrievals, policy=policy,
                                                    attempt_id=attempt.turn_attempt_id):
                packet.add_content_ref(ref)
            packet.add_event("content_refs_written",
                             payload={"content_ref_count": len(packet.content_refs)},
                             attempt_id=attempt.turn_attempt_id)

            retrieval_payload = _safe_retrieval_payload(retrievals, privacy=privacy)
            packet.manifest_json["created_at"] = packet.created_at.isoformat()
            if not privacy:
                packet.manifest_json["retrievals_response"] = retrieval_payload
            else:
                packet.manifest_json["retrievals_response_omitted"] = True
                packet.manifest_json["retrieval_count"] = len(retrievals)
            for artifact in build_standard_artifact_refs(
                    request_json={
                        "workflow_id": request.workflow_id,
                        "source_kind": request.source_kind,
                        "metadata": _safe_metadata(request.metadata, privacy=privacy),
                        "input_chars": len(request.input),
                        "provider_request": provider_request_json,
                    },
                    retrievals_json=retrieval_payload,
                    context_text=retrieved_context,
                    prompt_json={"messages": built_prompt.messages, "summary": prompt_summary},
                    response_json={"response_text": response_text, "summary": provider_summary},
                    provider_raw_response=provider_raw_response,
                    provider_exposed_reasoning=provider_exposed_reasoning,
                    diagnostics_json={
                        "warnings": [warning.model_dump() for warning in warnings],
                        "runtime_links": packet.runtime_links_json,
                        "manifest": packet.manifest_json,
                    },
                    policy=policy,
                    attempt_id=attempt.turn_attempt_id,
            ):
                packet.add_artifact(artifact)
            packet.add_event("artifacts_written", payload={"artifact_count": len(packet.artifacts)},
                             attempt_id=attempt.turn_attempt_id)

            packet.warnings = warnings
            packet.latency_ms = int((time.monotonic() - start) * 1000)
            for candidate in packet_metric_candidates(
                    latency_ms=packet.latency_ms,
                    retrieval_summary=retrieval_summary,
                    context_summary=context_summary,
                    prompt_summary=prompt_summary,
                    provider_summary=provider_summary,
                    artifact_count=len(packet.artifacts),
                    warning_count=len(warnings),
                    text_persisted=packet.text_persisted,
                    metadata_redacted=packet.metadata_redacted,
            ):
                packet.add_metric(candidate.to_packet_fact(packet_id=packet.turn_packet_id,
                                                           attempt_id=attempt.turn_attempt_id))
            packet.add_event("metrics_written",
                             payload={"metric_fact_count": len(packet.metric_facts)},
                             attempt_id=attempt.turn_attempt_id)
            packet.add_event("manifest_finalized", payload={"status": "ready"},
                             attempt_id=attempt.turn_attempt_id)
            packet.add_event("packet_finalized", payload={"capture_status": "completed"},
                             attempt_id=attempt.turn_attempt_id)
            attempt.complete(status="completed", latency_ms=packet.latency_ms)
            packet.mark_completed()
        except Exception as exc:
            warnings.append(WarningItem(code="turn_execution_failed", message=str(exc),
                                        details={"type": type(exc).__name__}))
            packet.warnings = warnings
            packet.error_json = {"type": type(exc).__name__, "message": str(exc)}
            packet.latency_ms = int((time.monotonic() - start) * 1000)
            attempt.failure_json = packet.error_json
            attempt.complete(status="failed", latency_ms=packet.latency_ms)
            packet.add_event("failed", status="failed", failure=packet.error_json,
                             attempt_id=attempt.turn_attempt_id)
            packet.mark_failed(packet.error_json)

        return self.recorder.persist(packet)

    async def respond(self, request: TurnExecutionRequest) -> RespondResponse:
        envelope = await self.execute(request)
        detail = self.store.get_turn_packet_detail(envelope.turn_packet_id)

        retrieval_payload = envelope.manifest_json.get("retrievals_response") or []
        retrievals: list[RetrievalResult] = []
        for item in retrieval_payload:
            try:
                retrievals.append(RetrievalResult(**item))
            except Exception:
                continue

        support = SupportMetadata(
            retrieval_used=bool(retrievals),
            source_count=len({item.source_id for item in retrievals}),
            document_count=len({item.document_id for item in retrievals}),
            chunk_count=len(retrievals),
            grounding_mode="require_sources",
        )
        if detail and not retrievals:
            content_rows = [ref for ref in detail.content_refs if
                            ref.content_role == "retrieved_chunk_snapshot"]
            support = SupportMetadata(
                retrieval_used=bool(content_rows),
                source_count=0,
                document_count=0,
                chunk_count=len(content_rows),
                grounding_mode="require_sources",
            )

        return RespondResponse(
            ok=envelope.ok,
            turn_packet_id=envelope.turn_packet_id,
            packet_summary=envelope,
            workflow_id=envelope.workflow_id,
            workflow_kind=envelope.workflow_kind,
            model_profile=envelope.model_profile,
            rag_profile=envelope.rag_profile,
            prompt_profile=envelope.prompt_profile,
            response_text=envelope.response_text,
            support=support,
            retrievals=retrievals,
            warnings=envelope.warnings,
            latency_ms=envelope.latency_ms,
            capture_mode=envelope.capture_mode,
            privacy_level=envelope.privacy_level,
            text_persisted=envelope.text_persisted,
            metadata_redacted=envelope.metadata_redacted,
            redaction_policy_version=envelope.redaction_policy_version,
            capture_status=envelope.capture_status,
            capture_error_json=envelope.error_json,
        )