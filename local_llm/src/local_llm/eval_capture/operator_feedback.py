from __future__ import annotations

from typing import Any

from local_llm.config import TrainingConfig
from local_llm.contracts import OperatorFeedbackRequest
from local_llm.turns.packet import TurnMetricFact


def _feedback_metadata(request: OperatorFeedbackRequest) -> dict[str, Any]:
    note = (request.note or "").strip()
    metadata: dict[str, Any] = dict(request.metadata or {})
    if note:
        metadata["note"] = note
    return {key: value for key, value in metadata.items() if value not in ("", None)}


def build_operator_feedback_facts(
        *,
        turn_packet_id: str,
        request: OperatorFeedbackRequest,
        training: TrainingConfig,
) -> list[TurnMetricFact]:
    facts: list[TurnMetricFact] = []
    metadata = _feedback_metadata(request)

    if request.score is not None:
        score = float(request.score)
        if score < training.operator_score_min or score > training.operator_score_max:
            raise ValueError(
                f"operator score must be between "
                f"{training.operator_score_min} and {training.operator_score_max}"
            )
        facts.append(TurnMetricFact(
            turn_packet_id=turn_packet_id,
            owner_type="packet",
            owner_id=turn_packet_id,
            metric_key="quality.operator_score",
            metric_value_num=score,
            metric_json=metadata,
            unit="score",
            privacy_safe=False,
            source="operator",
        ))

    label = (request.label or "").strip()
    if label:
        if label not in training.operator_label_options:
            raise ValueError(
                "operator label must be one of: "
                + ", ".join(training.operator_label_options)
            )
        facts.append(TurnMetricFact(
            turn_packet_id=turn_packet_id,
            owner_type="packet",
            owner_id=turn_packet_id,
            metric_key="quality.operator_label",
            metric_value_text=label,
            metric_json=metadata,
            privacy_safe=False,
            source="operator",
        ))

    if not facts:
        raise ValueError("operator feedback requires score or label")

    return facts