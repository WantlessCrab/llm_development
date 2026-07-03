from __future__ import annotations

from typing import Any


def _choice(raw: dict[str, Any]) -> dict[str, Any]:
    choices = raw.get("choices") if isinstance(raw, dict) else None
    if isinstance(choices, list) and choices and isinstance(choices[0], dict):
        return choices[0]
    return {}


def extract_provider_summary(*, text: str, raw_response: dict[str, Any],
                             provider_metadata: dict[str, Any], latency_ms: int) -> dict[str, Any]:
    choice = _choice(raw_response)
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    usage = raw_response.get("usage") if isinstance(raw_response.get("usage"), dict) else {}
    timings = raw_response.get("timings") if isinstance(raw_response.get("timings"), dict) else {}
    prompt_per_second = raw_response.get("prompt_per_second", timings.get("prompt_per_second"))
    completion_per_second = raw_response.get("predicted_per_second",
                                             raw_response.get("completion_per_second",
                                                              timings.get("predicted_per_second")))
    return {
        "finish_reason": choice.get("finish_reason"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "total_tokens": usage.get("total_tokens"),
        "prompt_per_second": prompt_per_second,
        "completion_per_second": completion_per_second,
        "status_code": provider_metadata.get("status_code"),
        "base_url": provider_metadata.get("base_url"),
        "model": provider_metadata.get("model"),
        "latency_ms": latency_ms,
        "response_chars": len(text or ""),
    }


def extract_exposed_reasoning(raw_response: dict[str, Any]) -> Any | None:
    choice = _choice(raw_response)
    message = choice.get("message") if isinstance(choice.get("message"), dict) else {}
    for key in ("reasoning_content", "reasoning", "analysis", "thinking"):
        value = message.get(key)
        if value:
            return {key: value}
    return None