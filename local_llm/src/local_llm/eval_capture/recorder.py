from __future__ import annotations

from pathlib import Path

from local_llm.contracts import PacketSummaryEnvelope
from local_llm.store.artifacts import ArtifactWriter
from local_llm.store.base import StoreProtocol
from local_llm.turns.packet import TurnPacket


class TurnRecorder:
    """Sole durable write boundary for TurnPacket persistence."""

    def __init__(self, store: StoreProtocol, *, artifact_root: str | Path | None = None):
        self.store = store
        self.artifact_writer = ArtifactWriter(
            Path(artifact_root).expanduser()) if artifact_root else None

    def _finalize_artifacts(self, turn_packet: TurnPacket) -> None:
        if not self.artifact_writer:
            if turn_packet.artifacts:
                raise RuntimeError("artifact_root is required when packet artifacts are present")
            return

        for artifact in turn_packet.artifacts:
            if artifact.path and artifact.sha256 and artifact.size_bytes is not None:
                continue

            if artifact.payload_policy == "omitted_body" or not artifact.body_persisted:
                finalized = self.artifact_writer.finalize_omission_marker(
                    turn_packet_id=turn_packet.turn_packet_id,
                    artifact_type=artifact.artifact_type,
                    reason=str(artifact.metadata_json.get(
                        "omitted_reason") or "privacy_body_not_persisted"),
                )
                artifact.body_persisted = False
                artifact.payload_policy = "omitted_body"
            else:
                finalized = self.artifact_writer.finalize_text(
                    turn_packet_id=turn_packet.turn_packet_id,
                    artifact_type=artifact.artifact_type,
                    text=artifact.body_text or "",
                    suffix=".json" if artifact.mime_type == "application/json" else ".txt",
                    mime_type=artifact.mime_type,
                )

            artifact.path = finalized.path
            artifact.sha256 = finalized.sha256
            artifact.size_bytes = finalized.size_bytes
            artifact.mime_type = finalized.mime_type
            artifact.metadata_json = {
                **artifact.metadata_json,
                "artifact_outcome": finalized.outcome,
            }
            artifact.body_text = None

    def persist(self, turn_packet: TurnPacket) -> PacketSummaryEnvelope:
        self._finalize_artifacts(turn_packet)

        if not turn_packet.finalized_at:
            if turn_packet.error_json:
                turn_packet.mark_failed(turn_packet.error_json)
            else:
                turn_packet.mark_completed()

        turn_packet.manifest_json.setdefault("attempt_count", len(turn_packet.attempts))
        turn_packet.manifest_json.setdefault("event_count", len(turn_packet.events))
        turn_packet.manifest_json.setdefault("content_ref_count", len(turn_packet.content_refs))
        turn_packet.manifest_json.setdefault("artifact_count", len(turn_packet.artifacts))
        turn_packet.manifest_json.setdefault("omitted_artifact_count", sum(
            1 for a in turn_packet.artifacts if a.payload_policy == "omitted_body"))
        turn_packet.manifest_json.setdefault("metric_fact_count", len(turn_packet.metric_facts))
        turn_packet.manifest_json.setdefault("group_membership_count",
                                             len(turn_packet.group_memberships))
        turn_packet.manifest_json["store_persistence"] = "completed"

        return self.store.persist_turn_packet(turn_packet)