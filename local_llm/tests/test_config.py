import os

from local_llm.config import load_runtime_env_file


def test_load_runtime_env_file_sets_missing_values(tmp_path, monkeypatch):
    env_file = tmp_path / "local-llm.env"
    env_file.write_text(
        "# comment\nLOCAL_LLM_POSTGRES_PASSWORD=secret-value\n",
        encoding="utf-8",
    )

    monkeypatch.delenv("LOCAL_LLM_POSTGRES_PASSWORD", raising=False)

    load_runtime_env_file(env_file)

    assert os.environ["LOCAL_LLM_POSTGRES_PASSWORD"] == "secret-value"


def test_load_runtime_env_file_preserves_existing_values(tmp_path, monkeypatch):
    env_file = tmp_path / "local-llm.env"
    env_file.write_text("LOCAL_LLM_POSTGRES_PASSWORD=file-value\n", encoding="utf-8")

    monkeypatch.setenv("LOCAL_LLM_POSTGRES_PASSWORD", "existing-value")

    load_runtime_env_file(env_file)

    assert os.environ["LOCAL_LLM_POSTGRES_PASSWORD"] == "existing-value"