from pathlib import Path

from local_llm.turns.request import TurnExecutionRequest

ROOT = Path(__file__).resolve().parents[1]
EXECUTION = ROOT / "src/local_llm/turns/execution.py"
PROVIDER_BASE = ROOT / "src/local_llm/generation/providers/base.py"
OPENAI_PROVIDER = ROOT / "src/local_llm/generation/providers/openai_compatible.py"


def test_retry_is_not_packet_source_kind():
    try:
        TurnExecutionRequest(source_kind="retry", workflow_id="wf", input="hello")
    except ValueError as exc:
        assert "attempt_kind" in str(exc)
    else:
        raise AssertionError("retry was accepted as source_kind")


def test_experiment_replicate_requires_replicate_index_when_condition_is_set():
    request = TurnExecutionRequest(
        source_kind="experiment_replicate",
        workflow_id="wf",
        input="hello",
        condition_group_id="condition",
    )
    try:
        request.validate()
    except ValueError as exc:
        assert "replicate_index" in str(exc)
    else:
        raise AssertionError("condition_group_id without replicate_index was accepted")


def test_provider_request_capture_uses_provider_payload_builder():
    base_source = PROVIDER_BASE.read_text(encoding="utf-8")
    provider_source = OPENAI_PROVIDER.read_text(encoding="utf-8")
    execution_source = EXECUTION.read_text(encoding="utf-8")

    assert "def build_request_payload" in base_source
    assert "def build_request_payload" in provider_source
    assert "payload = self.build_request_payload(messages, settings)" in provider_source
    assert "provider.build_request_payload" in execution_source
    assert "provider_request_json" in execution_source
    assert '"api_key_present"' in execution_source
    assert "_safe_provider_base_url" in execution_source
    assert "_safe_model_profile_snapshot" in execution_source
    provider_payload_builder = \
    provider_source.split("def build_request_payload", 1)[1].split("async def chat", 1)[0]
    assert "api_key" not in provider_payload_builder