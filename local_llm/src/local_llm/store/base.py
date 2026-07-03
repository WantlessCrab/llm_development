from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

from local_llm.contracts import (
    ContentLoadResponse,
    MetricAvailabilityResponse,
    PacketDetailResponse,
    PacketGroupMemberRequest,
    PacketGroupMemberResponse,
    PacketGroupRequest,
    PacketGroupResponse,
    PacketListRequest,
    PacketListResponse,
    PacketMetricFactResponse,
    PacketSummaryEnvelope,
    ProjectionRequest,
    ProjectionResult,
    RetrievalResult,
)


@dataclass(frozen=True)
class ActiveDocument:
    document_id: str
    file_hash: str


class StoreProtocol(Protocol):
    def init(self) -> None: ...

    def summary(self) -> dict[str, int]: ...

    def database_health(self) -> dict[str, Any]: ...

    def get_active_document_for_source(self, source_id: str) -> ActiveDocument | None: ...

    def upsert_document_with_chunks(
            self,
            *,
            source: dict[str, Any],
            document: dict[str, Any],
            chunks: list[dict[str, Any]],
    ) -> None: ...

    def mark_missing_sources_inactive(self, corpus_id: str,
                                      active_source_ids: set[str]) -> None: ...

    def search_chunks(self, query: str, corpus_id: str, top_k: int) -> list[RetrievalResult]: ...

    def search_chunks_with_observation(
            self,
            *,
            query: str,
            corpus_id: str,
            top_k: int,
            query_text_allowed: bool = True,
    ) -> tuple[list[RetrievalResult], dict[str, Any]]: ...

    def create_session(self, **kwargs: Any) -> dict[str, object]: ...

    def list_sessions(self, *, include_archived: bool = False) -> list[dict[str, object]]: ...

    def get_session(self, session_id: str) -> dict[str, object] | None: ...

    def update_session(self, **kwargs: Any) -> dict[str, object] | None: ...

    def archive_session(self, session_id: str) -> dict[str, object] | None: ...

    def next_turn_ordinal(self, session_id: str) -> int: ...

    def persist_turn_packet(self, turn_packet: Any) -> PacketSummaryEnvelope: ...

    def append_turn_metric_facts(self, metric_facts: list[Any]) -> list[
        PacketMetricFactResponse]: ...

    def get_turn_packet_summary(self, turn_packet_id: str) -> PacketSummaryEnvelope | None: ...

    def get_turn_packet_detail(self, turn_packet_id: str) -> PacketDetailResponse | None: ...

    def list_turn_packets(self,
                          filters: PacketListRequest | dict[str, Any]) -> PacketListResponse: ...

    def get_content_ref(self, content_ref_id: str) -> ContentLoadResponse | None: ...

    def get_available_metrics(self, scope: dict[
                                               str, Any] | None = None) -> MetricAvailabilityResponse: ...

    def create_packet_group(self, request: PacketGroupRequest) -> PacketGroupResponse: ...

    def add_packet_group_member(self,
                                request: PacketGroupMemberRequest) -> PacketGroupMemberResponse: ...

    def get_packet_group(self, packet_group_id: str) -> dict[str, Any] | None: ...

    def query_projection(self, request: ProjectionRequest) -> ProjectionResult: ...