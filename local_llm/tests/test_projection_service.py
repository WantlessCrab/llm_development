from local_llm.contracts import ProjectionRequest
from local_llm.eval_capture.projections import ProjectionService


class Store:
    def __init__(self):
        self.request = None

    def query_projection(self, request):
        self.request = request
        return {"ok": True}


def test_projection_service_delegates_authoritative_math_to_store():
    store = Store()
    service = ProjectionService(store)  # type: ignore[arg-type]
    result = service.projection_result(ProjectionRequest(packet_group_id="g1"))
    assert result == {"ok": True}
    assert store.request.packet_group_id == "g1"


def test_projection_service_accepts_operator_quality_metric_keys_without_ui_math():
    store = Store()
    service = ProjectionService(store)  # type: ignore[arg-type]
    service.projection_result(
        ProjectionRequest(packet_group_id="g1", metric_keys=["quality.operator_score"])
    )
    assert store.request.metric_keys == ["quality.operator_score"]