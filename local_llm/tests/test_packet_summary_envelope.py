from local_llm.contracts import PacketSummaryEnvelope


def test_packet_summary_envelope_has_created_at_and_no_run_identity():
    fields = set(PacketSummaryEnvelope.model_fields)
    assert "created_at" in fields
    assert "turn_packet_id" in fields
    assert "run_id" not in fields
    assert "eval_report_id" not in fields