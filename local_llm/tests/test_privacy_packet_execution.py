from local_llm.eval_capture.artifacts import (
    PacketContentRefPlanItem,
    build_content_ref,
    build_standard_content_refs,
)
from local_llm.eval_capture.policy import CapturePolicy


def strict_policy() -> CapturePolicy:
    return CapturePolicy(
        capture_mode="privacy",
        privacy_level="strict",
        text_persisted=False,
        metadata_redacted=True,
        redaction_policy_version=1,
        payload_policy="omitted_body",
        body_persisted=False,
        source_system="local_llm",
        failure_policy="fail_closed",
    )


def test_privacy_content_ref_omits_body_and_owner_id():
    ref = build_content_ref(
        PacketContentRefPlanItem("retrieval", "retrieved_chunk_snapshot", "SECRET",
                                 owner_id="chunk1"), strict_policy())
    assert ref.body_text is None
    assert ref.owner_id is None
    assert ref.body_persisted is False
    assert ref.payload_policy == "omitted_body"


def test_privacy_provider_request_ref_omits_body():
    refs = build_standard_content_refs(
        user_input="SECRET user",
        retrieved_context="SECRET context",
        final_prompt="SECRET prompt",
        response_text="SECRET response",
        provider_request={"payload": {"messages": [{"role": "user", "content": "SECRET"}]}},
        provider_raw_response={"choices": []},
        provider_exposed_reasoning=None,
        policy=strict_policy(),
    )
    provider_request = [ref for ref in refs if ref.content_role == "provider_request"]
    assert len(provider_request) == 1
    ref = provider_request[0]
    assert ref.body_text is None
    assert ref.storage_kind == "omitted"
    assert ref.body_persisted is False
    assert ref.metadata_redacted is True
    assert ref.payload_policy == "omitted_body"