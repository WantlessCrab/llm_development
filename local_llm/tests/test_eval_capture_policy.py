from types import SimpleNamespace

from local_llm.eval_capture.policy import privacy_safe_metric


def test_privacy_safe_metric_blocks_text_length_quality_namespace():
    assert privacy_safe_metric("latency.total_ms") is True
    assert privacy_safe_metric("chars.prompt") is False
    assert privacy_safe_metric("quality.operator_score") is False