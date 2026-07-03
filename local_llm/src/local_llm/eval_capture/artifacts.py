from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from local_llm.eval_capture.policy import CapturePolicy
from local_llm.eval_capture.redaction import sanitize_artifact_metadata, sanitize_content_metadata, \
    sanitize_retrieval_identity
from local_llm.turns.packet import TurnArtifactRef, TurnContentRef


@dataclass(frozen=True)
class PacketContentRefPlanItem:
    owner_type: str
    content_role: str
    body_text: str | None
    metadata_json: dict[str, Any] = field(default_factory=dict)
    owner_id: str | None = None
    mime_type: str | None = "text/plain"


@dataclass(frozen=True)
class PacketArtifactPlanItem:
    artifact_type: str
    body_text: str | None
    metadata_json: dict[str, Any] = field(default_factory=dict)
    mime_type: str | None = "text/plain"


@dataclass(frozen=True)
class ArtifactManifestEntry:
    artifact_type: str
    path: str | None
    sha256: str | None
    size_bytes: int | None
    outcome: str
    error: str | None = None


def _json_text(value: Any) -> str:
    return json.dumps(value, sort_keys=True, indent=2, default=str)


def build_content_ref(
        plan: PacketContentRefPlanItem,
        policy: CapturePolicy,
        *,
        attempt_id: str | None = None,
) -> TurnContentRef:
    privacy = policy.capture_mode == "privacy"
    metadata = sanitize_content_metadata(plan.metadata_json) if privacy else dict(
        plan.metadata_json)
    return TurnContentRef(
        turn_attempt_id=attempt_id,
        owner_type=plan.owner_type,
        owner_id=None if privacy else plan.owner_id,
        content_role=plan.content_role,
        storage_kind="omitted" if privacy else "inline_text",
        body_text=None if privacy else plan.body_text,
        mime_type=plan.mime_type,
        capture_mode=policy.capture_mode,
        privacy_level=policy.privacy_level,
        body_persisted=not privacy and plan.body_text is not None,
        metadata_redacted=privacy,
        payload_policy="omitted_body" if privacy else "full_body",
        metadata_json=metadata,
    )


def build_standard_content_refs(
        *,
        user_input: str,
        retrieved_context: str,
        final_prompt: str,
        response_text: str,
        provider_request: dict[str, Any],
        provider_raw_response: dict[str, Any],
        provider_exposed_reasoning: Any | None,
        policy: CapturePolicy,
        attempt_id: str | None = None,
) -> list[TurnContentRef]:
    plans = [
        PacketContentRefPlanItem("packet", "user_input", user_input),
        PacketContentRefPlanItem("context", "context_text", retrieved_context),
        PacketContentRefPlanItem("prompt", "prompt_messages", final_prompt),
        PacketContentRefPlanItem("provider", "provider_request",
                                 _json_text(provider_request), mime_type="application/json"),
        PacketContentRefPlanItem("provider", "provider_raw_response",
                                 _json_text(provider_raw_response), mime_type="application/json"),
        PacketContentRefPlanItem("provider", "assistant_response", response_text),
    ]
    if provider_exposed_reasoning is not None:
        plans.append(PacketContentRefPlanItem("provider", "provider_exposed_reasoning",
                                              _json_text(provider_exposed_reasoning),
                                              mime_type="application/json"))
    return [build_content_ref(plan, policy, attempt_id=attempt_id) for plan in plans]


def build_retrieval_content_refs(
        *,
        retrievals: list[Any],
        policy: CapturePolicy,
        attempt_id: str | None = None,
) -> list[TurnContentRef]:
    refs: list[TurnContentRef] = []
    privacy = policy.capture_mode == "privacy"
    for item in retrievals:
        payload = item.model_dump() if hasattr(item, "model_dump") else dict(
            getattr(item, "__dict__", {}))
        metadata = {
            "rank": payload.get("rank"),
            "method": payload.get("method"),
            "score": payload.get("score"),
            "source_id": payload.get("source_id"),
            "document_id": payload.get("document_id"),
            "chunk_id": payload.get("chunk_id"),
            "document_path": payload.get("document_path"),
            "source_title": payload.get("source_title"),
        }
        if privacy:
            metadata = sanitize_retrieval_identity(metadata)
            body_text = None
            owner_id = None
        else:
            body_text = _json_text(payload)
            owner_id = str(payload.get("chunk_id") or "") or None
        refs.append(
            build_content_ref(
                PacketContentRefPlanItem(
                    owner_type="retrieval",
                    owner_id=owner_id,
                    content_role="retrieved_chunk_snapshot",
                    body_text=body_text,
                    mime_type="application/json",
                    metadata_json=metadata,
                ),
                policy,
                attempt_id=attempt_id,
            )
        )
    return refs


def build_artifact_ref(
        plan: PacketArtifactPlanItem,
        policy: CapturePolicy,
        *,
        attempt_id: str | None = None,
) -> TurnArtifactRef:
    privacy = policy.capture_mode == "privacy"
    metadata = sanitize_artifact_metadata(plan.metadata_json) if privacy else dict(
        plan.metadata_json)
    return TurnArtifactRef(
        turn_attempt_id=attempt_id,
        artifact_type=plan.artifact_type,
        body_text=None if privacy else plan.body_text,
        mime_type=plan.mime_type,
        body_persisted=not privacy and plan.body_text is not None,
        payload_policy="omitted_body" if privacy else "full_body",
        capture_mode=policy.capture_mode,
        privacy_level=policy.privacy_level,
        metadata_json=metadata if not privacy else {**metadata,
                                                    "omitted_reason": "privacy_body_not_persisted"},
    )


def build_standard_artifact_refs(
        *,
        request_json: dict[str, Any],
        retrievals_json: list[dict[str, Any]],
        context_text: str,
        prompt_json: dict[str, Any],
        response_json: dict[str, Any],
        provider_raw_response: dict[str, Any],
        provider_exposed_reasoning: Any | None,
        diagnostics_json: dict[str, Any],
        policy: CapturePolicy,
        attempt_id: str | None = None,
) -> list[TurnArtifactRef]:
    plans = [
        PacketArtifactPlanItem("request", _json_text(request_json), mime_type="application/json"),
        PacketArtifactPlanItem("retrievals", _json_text(retrievals_json),
                               mime_type="application/json"),
        PacketArtifactPlanItem("context", context_text),
        PacketArtifactPlanItem("prompt", _json_text(prompt_json), mime_type="application/json"),
        PacketArtifactPlanItem("response", _json_text(response_json), mime_type="application/json"),
        PacketArtifactPlanItem("provider_raw_response", _json_text(provider_raw_response),
                               mime_type="application/json"),
        PacketArtifactPlanItem("diagnostics", _json_text(diagnostics_json),
                               mime_type="application/json"),
    ]
    if provider_exposed_reasoning is not None:
        plans.append(PacketArtifactPlanItem("provider_exposed_reasoning",
                                            _json_text(provider_exposed_reasoning),
                                            mime_type="application/json"))
    return [build_artifact_ref(plan, policy, attempt_id=attempt_id) for plan in plans]