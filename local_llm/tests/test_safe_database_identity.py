from local_llm.config import safe_database_label


def test_safe_database_label_removes_password():
    label = safe_database_label("postgresql://user:secret@127.0.0.1:8032/llm_database")
    assert "secret" not in label
    assert label == "postgresql://user@127.0.0.1:8032/llm_database"