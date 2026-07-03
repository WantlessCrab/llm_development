from pathlib import Path

from local_llm.config import AppConfig
from local_llm.retrieval.indexer import ingest_corpus


class FakeStore:
    def __init__(self):
        self.active_documents = {}
        self.upserts = []
        self.mark_missing_calls = []

    def get_active_document_for_source(self, source_id: str):
        return self.active_documents.get(source_id)

    def upsert_document_with_chunks(self, *, source, document, chunks):
        self.upserts.append((source, document, chunks))

    def mark_missing_sources_inactive(self, corpus_id: str, active_source_ids: set[str]):
        self.mark_missing_calls.append((corpus_id, active_source_ids))


def test_ingest_writes_document_and_chunks_through_packet_native_store_substrate(tmp_path: Path):
    source_file = tmp_path / "source.py"
    source_file.write_text("def hello():\n    return 'world'\n" * 80, encoding="utf-8")

    cfg = AppConfig.model_validate(
        {
            "version": 1,
            "storage": {
                "backend": "postgres",
                "database_url": "postgresql://llm_database@127.0.0.1:8032/llm_database",
                "database_password_env": "LOCAL_LLM_POSTGRES_PASSWORD",
                "artifact_dir": "~/.local/share/local-llm/artifacts",
            },
            "model_profiles": {
                "local_basic": {
                    "provider": "openai_compatible",
                    "base_url": "http://127.0.0.1:8021/v1",
                    "api_key": "not-needed",
                    "model": "local-small",
                }
            },
            "corpora": {
                "primary_local_corpus": {
                    "roots": [str(tmp_path)],
                    "include_globs": ["**/*.py"],
                    "exclude_globs": [],
                }
            },
            "rag_profiles": {
                "project_basic": {
                    "enabled": True,
                    "corpus": "primary_local_corpus",
                    "retrieval": {"method": "postgres_fts", "top_k": 3},
                }
            },
            "prompt_profiles": {
                "source_grounded_answer": {
                    "grounding_mode": "require_sources",
                    "system": "system",
                    "user_template": "{user_input}\n{retrieved_context}",
                }
            },
            "workflows": {
                "default_rag_answer": {
                    "kind": "rag_answer",
                    "model_profile": "local_basic",
                    "rag_profile": "project_basic",
                    "prompt_profile": "source_grounded_answer",
                }
            },
        }
    )

    store = FakeStore()
    response = ingest_corpus(cfg, store, "primary_local_corpus")

    assert response.ok is True
    assert response.sources_seen == 1
    assert response.sources_indexed == 1
    assert response.documents_indexed == 1
    assert response.chunks_indexed >= 1

    assert len(store.upserts) == 1
    source, document, chunks = store.upserts[0]
    assert source["metadata"]["relative_path"] == "source.py"
    assert document["metadata"]["extractor_type"] == "plain_text"
    assert chunks
    assert store.mark_missing_calls