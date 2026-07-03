from local_llm.contracts import RespondResponse


def test_respond_response_is_packet_native():
    fields = set(RespondResponse.model_fields)
    assert "turn_packet_id" in fields
    assert "packet_summary" in fields
    assert "run_id" not in fields
    assert "eval_report_id" not in fields