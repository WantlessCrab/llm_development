from local_llm.eval_capture.redaction import sanitize_retrieval_identity


def test_retrieval_identity_redaction_removes_joinable_fields():
    payload = {
        "source_id": "s1",
        "document_id": "d1",
        "chunk_id": "c1",
        "document_path": "/secret/path.py",
        "source_title": "secret.py",
        "rank": 1,
    }
    redacted = sanitize_retrieval_identity(payload)
    assert redacted["rank"] == 1
    for key in ["source_id", "document_id", "chunk_id", "document_path", "source_title"]:
        assert redacted[key] == "[privacy_mode:redacted]"