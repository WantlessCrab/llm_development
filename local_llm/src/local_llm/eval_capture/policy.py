from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from local_llm.config import AppConfig


@dataclass(frozen=True)
class CapturePolicy:
    capture_mode: str
    privacy_level: str
    text_persisted: bool
    metadata_redacted: bool
    redaction_policy_version: int | None
    payload_policy: str
    body_persisted: bool
    source_system: str
    failure_policy: str

    def as_json(self) -> dict[str, Any]:
        return {
            "capture_mode": self.capture_mode,
            "privacy_level": self.privacy_level,
            "text_persisted": self.text_persisted,
            "metadata_redacted": self.metadata_redacted,
            "redaction_policy_version": self.redaction_policy_version,
            "payload_policy": self.payload_policy,
            "body_persisted": self.body_persisted,
            "source_system": self.source_system,
            "failure_policy": self.failure_policy,
        }


def _request_value(request: Any, *names: str) -> Any:
    for name in names:
        value = getattr(request, name, None)
        if value is not None:
            return value
    return None


def resolve_capture_policy(config: AppConfig, workflow: Any, request: Any) -> CapturePolicy:
    forced_privacy = bool(
        getattr(workflow.model_profile, "privacy_required", False) or getattr(workflow.workflow,
                                                                              "privacy_required",
                                                                              False))
    request_privacy_mode = bool(getattr(request, "privacy_mode", False))
    capture_mode = _request_value(request, "capture_mode") or _request_value(request,
                                                                             "eval_capture_mode")
    privacy_level = _request_value(request, "privacy_level")

    if forced_privacy or request_privacy_mode:
        capture_mode = "privacy"
        privacy_level = privacy_level or "strict"
    else:
        capture_mode = capture_mode or getattr(workflow.workflow, "eval_capture_mode",
                                               None) or getattr(workflow.model_profile,
                                                                "eval_capture_mode",
                                                                None) or config.eval_capture.default_capture_mode
        privacy_level = privacy_level or getattr(workflow.workflow, "privacy_level",
                                                 None) or getattr(workflow.model_profile,
                                                                  "privacy_level",
                                                                  None) or config.eval_capture.default_privacy_level

    if capture_mode == "full" and privacy_level != "none":
        raise ValueError("privacy_level must be none when capture_mode is full")
    if capture_mode == "privacy" and privacy_level == "none":
        raise ValueError("privacy_level must be standard or strict when capture_mode is privacy")

    privacy = capture_mode == "privacy"
    return CapturePolicy(
        capture_mode=capture_mode,
        privacy_level=privacy_level,
        text_persisted=not privacy,
        metadata_redacted=privacy,
        redaction_policy_version=config.eval_capture.redaction_policy_version if privacy else None,
        payload_policy="omitted_body" if privacy else "full_body",
        body_persisted=not privacy,
        source_system=config.eval_capture.source_system or "local_llm",
        failure_policy=config.eval_capture.failure_policy,
    )


def payload_policy_for_content(policy: CapturePolicy, *, non_text: bool = False) -> str:
    if non_text:
        return "non_text_body"
    return policy.payload_policy


def privacy_safe_metric(metric_key: str) -> bool:
    return not metric_key.startswith(
        ("chars.user_input", "chars.response", "chars.prompt", "chars.context", "quality."))