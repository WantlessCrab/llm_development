from __future__ import annotations

from local_llm.config import AppConfig
from local_llm.contracts import SearchResponse, WarningItem
from local_llm.store.sqlite_store import SQLiteStore


def search(config: AppConfig, store: SQLiteStore, *, rag_profile_id: str, query: str, top_k: int | None = None) -> SearchResponse:
    rag_profile = config.rag_profiles.get(rag_profile_id)
    if not rag_profile:
        raise KeyError(f"rag_profile not found: {rag_profile_id}")

    if rag_profile.retrieval.method != "sqlite_fts":
        raise ValueError(f"retrieval method not implemented: {rag_profile.retrieval.method}")

    results = store.search_chunks(query=query, corpus_id=rag_profile.corpus, top_k=top_k or rag_profile.retrieval.top_k)
    warnings: list[WarningItem] = []
    if not results:
        warnings.append(
            WarningItem(
                code="no_retrieval_results",
                message="retrieval returned no chunks",
                details={"rag_profile": rag_profile_id, "query": query},
            )
        )
    return SearchResponse(ok=True, query=query, rag_profile=rag_profile_id, results=results, warnings=warnings)
