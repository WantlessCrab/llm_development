from __future__ import annotations

import hashlib
from typing import Any

SENSITIVE_KEYS = frozenset({
    "text", "body", "body_text", "content", "prompt", "messages", "message", "user_input",
    "response_text", "final_prompt", "retrieved_context", "document_path", "source_title", "path",
})
REDACTED = "[privacy_mode:redacted]"


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sanitize_json(value: Any, *, strict: bool = True) -> Any:
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            key_s = str(key)
            if strict and key_s in SENSITIVE_KEYS:
                result[key_s] = REDACTED
            else:
                result[key_s] = sanitize_json(item, strict=strict)
        return result
    if isinstance(value, list):
        return [sanitize_json(item, strict=strict) for item in value]
    return value


def sanitize_packet_json(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_event_payload(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_content_metadata(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_artifact_metadata(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_metric_json(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_group_metadata(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_provider_raw_response(value: dict[str, Any]) -> dict[str, Any]:
    return sanitize_json(value)


def sanitize_provider_exposed_reasoning(value: Any) -> Any:
    return sanitize_json(value)


def sanitize_retrieval_identity(value: dict[str, Any]) -> dict[str, Any]:
    sanitized = dict(value)
    for key in ("source_id", "document_id", "chunk_id", "document_path", "source_title"):
        if key in sanitized:
            sanitized[key] = REDACTED
    return sanitized