from __future__ import annotations

from local_llm.contracts import ProjectionRequest, ProjectionResult
from local_llm.store.base import StoreProtocol


class ProjectionService:
    def __init__(self, store: StoreProtocol):
        self.store = store

    def packet_summary(self, turn_packet_id: str):
        return self.store.get_turn_packet_summary(turn_packet_id)

    def packet_detail(self, turn_packet_id: str):
        return self.store.get_turn_packet_detail(turn_packet_id)

    def list_packets(self, filters):
        return self.store.list_turn_packets(filters)

    def load_content(self, content_ref_id: str):
        return self.store.get_content_ref(content_ref_id)

    def available_metrics(self, scope=None):
        return self.store.get_available_metrics(scope=scope)

    def group_detail(self, packet_group_id: str):
        return self.store.get_packet_group(packet_group_id)

    def group_comparison(self, packet_group_id: str,
                         metric_keys: list[str] | None = None) -> ProjectionResult:
        return self.projection_result(
            ProjectionRequest(packet_group_id=packet_group_id, metric_keys=metric_keys or []))

    def session_comparison(self, session_ids: list[str],
                           metric_keys: list[str] | None = None) -> ProjectionResult:
        return self.projection_result(
            ProjectionRequest(session_ids=session_ids, metric_keys=metric_keys or []))

    def manual_packet_set(self, packet_ids: list[str],
                          metric_keys: list[str] | None = None) -> ProjectionResult:
        return self.projection_result(
            ProjectionRequest(packet_ids=packet_ids, metric_keys=metric_keys or []))

    def projection_result(self, request: ProjectionRequest) -> ProjectionResult:
        return self.store.query_projection(request)