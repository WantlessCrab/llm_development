from types import SimpleNamespace

from local_llm.contracts import RetrievalResult
from local_llm.retrieval.retriever import search


class FakeStore:
    def __init__(self):
        self.calls = []

    def search_chunks_with_observation(self, *, query, corpus_id, top_k, query_text_allowed=True):
        self.calls.append(
            {
                "query": query,
                "corpus_id": corpus_id,
                "top_k": top_k,
                "query_text_allowed": query_text_allowed,
            }
        )
        return [
            RetrievalResult(
                rank=1,
                method="postgres_fts",
                chunk_id="chunk-1",
                document_id="doc-1",
                source_id="src-1",
                document_path="/tmp/doc.md",
                source_title="doc",
                score=1.0,
                text="retrieved text",
            )
        ], {
            "retrieval_method": "postgres_fts",
            "backend": "postgresql",
            "search_config": "simple",
            "query_hash": "hash",
            "normalized_query_hash": "hash",
            "normalized_query": None,
            "query_text_allowed": query_text_allowed,
            "stage_1_query_shape": {},
            "stage_2_fallback_query_shape": {},
            "fallback_terms": [],
            "fallback_available": False,
            "fallback_used": False,
            "fallback_reason": None,
            "top_k_requested": top_k,
            "candidate_count": 1,
            "returned_count": 1,
            "included_count": 1,
            "latency_ms": 1,
            "warning_codes": [],
            "privacy_behavior": {"query_text_persisted": query_text_allowed},
        }


def test_search_returns_observation_and_uses_privacy_flag():
    cfg = SimpleNamespace(
        rag_profiles={
            "rag": SimpleNamespace(
                corpus="corpus",
                retrieval=SimpleNamespace(method="postgres_fts", top_k=7),
            )
        }
    )
    store = FakeStore()

    response = search(
        cfg,
        store,
        rag_profile_id="rag",
        query="secret query",
        query_text_allowed=False,
    )

    assert response.ok is True
    assert response.observation is not None
    assert response.observation.query_text_allowed is False
    assert response.observation.privacy_behavior["query_text_persisted"] is False
    assert store.calls[0]["query_text_allowed"] is False
    assert response.results[0].chunk_id == "chunk-1"


def test_search_rejects_inactive_retrieval_methods():
    cfg = SimpleNamespace(
        rag_profiles={
            "rag": SimpleNamespace(
                corpus="corpus",
                retrieval=SimpleNamespace(method="postgres_vector", top_k=7),
            )
        }
    )

    try:
        search(cfg, FakeStore(), rag_profile_id="rag", query="x")
    except ValueError as exc:
        assert "Phase 1.5" in str(exc)
    else:
        raise AssertionError("inactive retrieval method was accepted")