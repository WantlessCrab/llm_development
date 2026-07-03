from local_llm.turns.packet import TurnAttempt, TurnContentRef, TurnMetricFact, TurnPacket


def test_turn_packet_uses_packet_identity_and_final_names():
    packet = TurnPacket(
        workflow_id="wf",
        workflow_kind="rag_answer",
        model_profile_id="model",
        rag_profile_id="rag",
        prompt_profile_id="prompt",
        config_snapshot_hash="a",
        effective_config_hash="b",
    )
    attempt = packet.add_attempt(TurnAttempt())
    packet.add_event("request_received", attempt_id=attempt.turn_attempt_id)
    packet.add_content_ref(TurnContentRef(content_role="assistant_response", body_text="ok"))
    packet.add_content_ref(
        TurnContentRef(content_role="provider_request", body_text='{"model":"m"}',
                       mime_type="application/json"))
    packet.add_metric(TurnMetricFact(metric_key="latency.total_ms", metric_value_num=1.0))

    assert packet.events[0].event_id
    assert packet.events[0].event_order == 1
    assert packet.content_refs[0].content_role == "assistant_response"
    assert packet.content_refs[1].content_role == "provider_request"
    assert packet.metric_facts[0].metric_json == {}
    assert packet.to_summary_envelope().turn_packet_id == packet.turn_packet_id