from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from typing import Any

from local_llm.config import AppConfig, ModelProfile, PromptProfile, RagProfile
from local_llm.control.profiles import ResolvedWorkflow, resolve_workflow
from local_llm.control.workflows import assert_supported_workflow
from local_llm.eval_capture.constants import PACKET_SOURCE_KINDS
from local_llm.eval_capture.policy import CapturePolicy, resolve_capture_policy

ALLOWED_OVERLAY_PATHS = frozenset({
    "rag.retrieval.top_k",
    "rag.context.max_context_chars",
    "rag.context.include_source_headers",
    "rag_profile.retrieval.top_k",
    "rag_profile.context.max_context_chars",
    "rag_profile.context.include_source_headers",
    "model.defaults.temperature",
    "model.defaults.max_tokens",
    "model_profile.defaults.temperature",
    "model_profile.defaults.max_tokens",
    "prompt.system",
    "prompt.user_template",
    "prompt_profile.system",
    "prompt_profile.user_template",
})


def stable_hash(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, default=str, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def model_dump(value: Any) -> dict[str, Any]:
    if hasattr(value, "model_dump"):
        return value.model_dump()
    if hasattr(value, "__dict__"):
        return dict(value.__dict__)
    return dict(value)


def _flatten_overlay(value: dict[str, Any], prefix: str = "") -> dict[str, Any]:
    flat: dict[str, Any] = {}
    for key, item in value.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        if isinstance(item, dict):
            flat.update(_flatten_overlay(item, path))
        else:
            flat[path] = item
    return flat


def _model_copy(model: Any, update: dict[str, Any]) -> Any:
    if hasattr(model, "model_copy"):
        return model.model_copy(update=update)
    if hasattr(model, "copy"):
        return model.copy(update=update)
    return replace(model, **update)


@dataclass(frozen=True)
class TurnExecutionRequest:
    source_kind: str
    workflow_id: str
    input: str
    metadata: dict[str, Any] = field(default_factory=dict)
    session_id: str | None = None
    turn_id: str | None = None
    turn_ordinal: int | None = None
    capture_mode: str | None = None
    privacy_level: str | None = None
    privacy_mode: bool | None = None
    packet_group_ids: list[str] = field(default_factory=list)
    experiment_group_id: str | None = None
    condition_group_id: str | None = None
    replicate_index: int | None = None
    config_overlay: dict[str, Any] = field(default_factory=dict)
    operator_labels: dict[str, Any] = field(default_factory=dict)
    idempotency_key: str | None = None
    idempotency_scope_hash: str | None = None
    source_system: str = "local_llm"
    source_record_id: str | None = None

    def __post_init__(self) -> None:
        normalized = str(self.source_kind)
        if normalized == "retry":
            raise ValueError("retry is attempt_kind only; it is not a packet source_kind")
        if normalized not in PACKET_SOURCE_KINDS:
            raise ValueError(f"unsupported packet source_kind: {normalized}")
        object.__setattr__(self, "source_kind", normalized)

    def validate(self) -> None:
        if self.capture_mode == "full" and self.privacy_level not in (None, "none"):
            raise ValueError("privacy_level must be none when capture_mode is full")
        if self.capture_mode == "privacy" and self.privacy_level in (None, "none"):
            raise ValueError(
                "privacy_level must be standard or strict when capture_mode is privacy")
        if self.replicate_index is not None and self.replicate_index < 1:
            raise ValueError("replicate_index must be >= 1")
        if self.condition_group_id and self.replicate_index is None:
            raise ValueError("replicate_index is required when condition_group_id is supplied")

    def with_default_scope_hash(self) -> "TurnExecutionRequest":
        if not self.idempotency_key or self.idempotency_scope_hash:
            return self
        scope = stable_hash({
            "source_kind": self.source_kind,
            "workflow_id": self.workflow_id,
            "session_id": self.session_id,
            "turn_id": self.turn_id,
            "experiment_group_id": self.experiment_group_id,
            "condition_group_id": self.condition_group_id,
            "replicate_index": self.replicate_index,
            "source_record_id": self.source_record_id,
        })
        return replace(self, idempotency_scope_hash=scope)


@dataclass(frozen=True)
class TurnExecutionPlan:
    request: TurnExecutionRequest
    resolved_workflow: ResolvedWorkflow
    workflow_snapshot: dict[str, Any]
    model_profile_snapshot: dict[str, Any]
    rag_profile_snapshot: dict[str, Any]
    prompt_profile_snapshot: dict[str, Any]
    capture_policy: CapturePolicy
    privacy_policy: dict[str, Any]
    effective_config_hash: str
    config_snapshot_hash: str
    overlay_applied_json: dict[str, Any]
    rag_directives_json: dict[str, Any]
    runtime_root: str | None
    artifact_root: str
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


def validate_overlay(overlay: dict[str, Any]) -> dict[str, Any]:
    flat = _flatten_overlay(overlay)
    for path in flat:
        if path.startswith("__") or ".__" in path:
            raise ValueError(f"invalid config overlay key: {path}")
        if path not in ALLOWED_OVERLAY_PATHS:
            raise ValueError(f"config overlay path is not allowed in Phase 1.5: {path}")
    return flat


def apply_config_overlay(workflow: ResolvedWorkflow, overlay: dict[str, Any]) -> ResolvedWorkflow:
    if not overlay:
        return workflow
    flat = validate_overlay(overlay)

    model_profile: ModelProfile = workflow.model_profile
    rag_profile: RagProfile = workflow.rag_profile
    prompt_profile: PromptProfile = workflow.prompt_profile

    if "rag.retrieval.top_k" in flat or "rag_profile.retrieval.top_k" in flat:
        value = flat.get("rag.retrieval.top_k", flat.get("rag_profile.retrieval.top_k"))
        rag_profile = _model_copy(rag_profile, {
            "retrieval": _model_copy(rag_profile.retrieval, {"top_k": int(value)})})
    if "rag.context.max_context_chars" in flat or "rag_profile.context.max_context_chars" in flat:
        value = flat.get("rag.context.max_context_chars",
                         flat.get("rag_profile.context.max_context_chars"))
        rag_profile = _model_copy(rag_profile, {
            "context": _model_copy(rag_profile.context, {"max_context_chars": int(value)})})
    if "rag.context.include_source_headers" in flat or "rag_profile.context.include_source_headers" in flat:
        value = flat.get("rag.context.include_source_headers",
                         flat.get("rag_profile.context.include_source_headers"))
        rag_profile = _model_copy(rag_profile, {
            "context": _model_copy(rag_profile.context, {"include_source_headers": bool(value)})})

    if "model.defaults.temperature" in flat or "model_profile.defaults.temperature" in flat:
        value = flat.get("model.defaults.temperature",
                         flat.get("model_profile.defaults.temperature"))
        model_profile = _model_copy(model_profile, {
            "defaults": _model_copy(model_profile.defaults, {"temperature": float(value)})})
    if "model.defaults.max_tokens" in flat or "model_profile.defaults.max_tokens" in flat:
        value = flat.get("model.defaults.max_tokens", flat.get("model_profile.defaults.max_tokens"))
        model_profile = _model_copy(model_profile, {
            "defaults": _model_copy(model_profile.defaults, {"max_tokens": int(value)})})

    if "prompt.system" in flat or "prompt_profile.system" in flat:
        value = flat.get("prompt.system", flat.get("prompt_profile.system"))
        prompt_profile = _model_copy(prompt_profile, {"system": str(value)})
    if "prompt.user_template" in flat or "prompt_profile.user_template" in flat:
        value = flat.get("prompt.user_template", flat.get("prompt_profile.user_template"))
        prompt_profile = _model_copy(prompt_profile, {"user_template": str(value)})

    return ResolvedWorkflow(
        workflow_id=workflow.workflow_id,
        workflow=workflow.workflow,
        model_profile_id=workflow.model_profile_id,
        model_profile=model_profile,
        rag_profile_id=workflow.rag_profile_id,
        rag_profile=rag_profile,
        prompt_profile_id=workflow.prompt_profile_id,
        prompt_profile=prompt_profile,
    )


def build_execution_plan(config: AppConfig, request: TurnExecutionRequest) -> TurnExecutionPlan:
    request = request.with_default_scope_hash()
    request.validate()
    workflow = apply_config_overlay(resolve_workflow(config, request.workflow_id),
                                    request.config_overlay)
    assert_supported_workflow(workflow)
    policy = resolve_capture_policy(config, workflow, request)
    workflow_snapshot = model_dump(workflow.workflow)
    model_snapshot = model_dump(workflow.model_profile)
    rag_snapshot = model_dump(workflow.rag_profile)
    prompt_snapshot = model_dump(workflow.prompt_profile)
    config_snapshot = {
        "workflow": workflow_snapshot,
        "model_profile": model_snapshot,
        "rag_profile": rag_snapshot,
        "prompt_profile": prompt_snapshot,
        "overlay_applied": request.config_overlay,
    }
    runtime_root = workflow.model_profile.runtime_root or config.eval_capture.runtime_root
    return TurnExecutionPlan(
        request=request,
        resolved_workflow=workflow,
        workflow_snapshot=workflow_snapshot,
        model_profile_snapshot=model_snapshot,
        rag_profile_snapshot=rag_snapshot,
        prompt_profile_snapshot=prompt_snapshot,
        capture_policy=policy,
        privacy_policy=policy.as_json(),
        effective_config_hash=stable_hash(config_snapshot),
        config_snapshot_hash=stable_hash(config_snapshot),
        overlay_applied_json=request.config_overlay,
        rag_directives_json={"rag_profile_id": workflow.rag_profile_id, **rag_snapshot},
        runtime_root=runtime_root,
        artifact_root=str(config.artifact_dir),
    )