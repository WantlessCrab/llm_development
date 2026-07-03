from local_llm.store.base import StoreProtocol


def test_store_protocol_exposes_packet_methods_only():
    names = set(StoreProtocol.__annotations__) if hasattr(StoreProtocol,
                                                          "__annotations__") else set()
    forbidden = {"insert_run", "insert_run_artifact", "insert_eval_report", "insert_eval_metric",
                 "link_run_eval_report"}
    assert not forbidden & set(dir(StoreProtocol))
    assert hasattr(StoreProtocol, "persist_turn_packet")
    assert hasattr(StoreProtocol, "query_projection")