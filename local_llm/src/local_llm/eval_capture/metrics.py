from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from local_llm.eval_capture.policy import privacy_safe_metric
from local_llm.turns.packet import TurnMetricFact


@dataclass(frozen=True)
class TurnMetricFactCandidate:
    metric_key: str
    owner_type: str = "packet"
    owner_id: str | None = None
    metric_value_num: float | None = None
    metric_value_text: str | None = None
    metric_json: dict[str, Any] = field(default_factory=dict)
    unit: str | None = None
    privacy_safe: bool | None = None
    source: str = "derived"

    def to_packet_fact(self, *, packet_id: str, attempt_id: str | None = None) -> TurnMetricFact:
        return TurnMetricFact(
            turn_packet_id=packet_id,
            turn_attempt_id=attempt_id,
            owner_type=self.owner_type,
            owner_id=self.owner_id,
            metric_key=self.metric_key,
            metric_value_num=self.metric_value_num,
            metric_value_text=self.metric_value_text,
            metric_json=self.metric_json,
            unit=self.unit,
            privacy_safe=privacy_safe_metric(
                self.metric_key) if self.privacy_safe is None else self.privacy_safe,
            source=self.source,
        )


def num_metric(key: str, value: int | float | None, *, unit: str | None = None,
               owner_type: str = "packet",
               source: str = "derived") -> TurnMetricFactCandidate | None:
    if value is None:
        return None
    return TurnMetricFactCandidate(metric_key=key, metric_value_num=float(value), unit=unit,
                                   owner_type=owner_type, source=source)


def text_metric(key: str, value: str | None, *, owner_type: str = "packet",
                source: str = "derived") -> TurnMetricFactCandidate | None:
    if value is None:
        return None
    return TurnMetricFactCandidate(metric_key=key, metric_value_text=str(value),
                                   owner_type=owner_type, source=source)


def packet_metric_candidates(*, latency_ms: int, retrieval_summary: dict[str, Any],
                             context_summary: dict[str, Any],
                             prompt_summary: dict[str, Any], provider_summary: dict[str, Any],
                             artifact_count: int,
                             warning_count: int, text_persisted: bool, metadata_redacted: bool) -> \
list[TurnMetricFactCandidate]:
    metrics: list[TurnMetricFactCandidate | None] = [
        num_metric("latency.total_ms", latency_ms, unit="ms"),
        num_metric("latency.retrieval_ms", retrieval_summary.get("latency_ms"), unit="ms",
                   owner_type="retrieval"),
        num_metric("latency.context_build_ms", context_summary.get("latency_ms"), unit="ms",
                   owner_type="context"),
        num_metric("latency.prompt_build_ms", prompt_summary.get("latency_ms"), unit="ms",
                   owner_type="prompt"),
        num_metric("latency.provider_ms", provider_summary.get("latency_ms"), unit="ms",
                   owner_type="provider", source="provider"),
        num_metric("tokens.prompt", provider_summary.get("prompt_tokens"), unit="tokens",
                   owner_type="provider", source="provider"),
        num_metric("tokens.completion", provider_summary.get("completion_tokens"), unit="tokens",
                   owner_type="provider", source="provider"),
        num_metric("tokens.total", provider_summary.get("total_tokens"), unit="tokens",
                   owner_type="provider", source="provider"),
        num_metric("chars.user_input", prompt_summary.get("user_chars"), unit="chars",
                   owner_type="prompt"),
        num_metric("chars.context", context_summary.get("context_char_count"), unit="chars",
                   owner_type="context"),
        num_metric("chars.prompt", prompt_summary.get("prompt_chars"), unit="chars",
                   owner_type="prompt"),
        num_metric("chars.response", provider_summary.get("response_chars"), unit="chars",
                   owner_type="provider"),
        num_metric("search.candidate_count", retrieval_summary.get("candidate_count"), unit="count",
                   owner_type="search"),
        num_metric("search.returned_count", retrieval_summary.get("returned_count"), unit="count",
                   owner_type="search"),
        num_metric("search.included_count", context_summary.get("included_count"), unit="count",
                   owner_type="search"),
        num_metric("search.top_k_requested", retrieval_summary.get("top_k_requested"), unit="count",
                   owner_type="search"),
        num_metric("retrieval.returned_count", retrieval_summary.get("returned_count"),
                   unit="count", owner_type="retrieval"),
        num_metric("retrieval.included_count", context_summary.get("included_count"), unit="count",
                   owner_type="context"),
        num_metric("retrieval.unique_source_count", context_summary.get("unique_source_count"),
                   unit="count", owner_type="retrieval"),
        num_metric("retrieval.unique_document_count", context_summary.get("unique_document_count"),
                   unit="count", owner_type="retrieval"),
        TurnMetricFactCandidate("context.truncated", metric_value_text=str(
            bool(context_summary.get("truncated", False))).lower(), owner_type="context",
                                source="derived"),
        num_metric("context.char_count", context_summary.get("context_char_count"), unit="chars",
                   owner_type="context"),
        text_metric("provider.finish_reason", provider_summary.get("finish_reason"),
                    owner_type="provider", source="provider"),
        num_metric("provider.prompt_per_second", provider_summary.get("prompt_per_second"),
                   unit="tokens/s", owner_type="provider", source="provider"),
        num_metric("provider.completion_per_second", provider_summary.get("completion_per_second"),
                   unit="tokens/s", owner_type="provider", source="provider"),
        num_metric("artifact.count", artifact_count, unit="count", owner_type="artifact"),
        num_metric("warnings.count", warning_count, unit="count"),
        TurnMetricFactCandidate("privacy.text_persisted",
                                metric_value_text=str(text_persisted).lower(), privacy_safe=True),
        TurnMetricFactCandidate("privacy.metadata_redacted",
                                metric_value_text=str(metadata_redacted).lower(),
                                privacy_safe=True),
    ]
    return [metric for metric in metrics if metric is not None]