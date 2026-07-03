from local_llm.eval_capture.privacy_audit import assert_no_forbidden_text


def test_privacy_audit_detects_forbidden_marker():
    try:
        assert_no_forbidden_text({"nested": ["SECRET_DO_NOT_PERSIST"]})
    except AssertionError:
        pass
    else:
        raise AssertionError("privacy marker was not detected")