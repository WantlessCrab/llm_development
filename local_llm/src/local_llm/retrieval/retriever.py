from __future__ import annotations

import time
from dataclasses import dataclass, field

from local_llm.config import AppConfig
from local_llm.contracts import SearchObservationResponse, SearchResponse, WarningItem
from local_llm.retrieval.postgres_fts import empty_postgres_fts_observation, sha256_text
from local_llm.store.base import StoreProtocol


@dataclass(frozen=True)
class SearchObservation:
    retrieval_method: str = "postgres_fts"
    backend: str = "postgresql"
    search_config: str = "simple"
    rag_profile_id: str | None = None
    corpus_id: str | None = None
    query_hash: str | None = None
    normalized_query_hash: str | None = None
    normalized_query: str | None = None
    query_text_allowed: bool = True
    stage_1_query_shape: dict[str, object] = field(default_factory=dict)
    stage_2_fallback_query_shape: dict[str, object] = field(default_factory=dict)
    fallback_terms: list[str] = field(default_factory=list)
    fallback_available: bool = False
    fallback_used: bool = False
    fallback_reason: str | None = None
    top_k_requested: int = 0
    candidate_count: int = 0
    returned_count: int = 0
    included_count: int = 0
    latency_ms: int = 0
    warning_codes: list[str] = field(default_factory=list)
    privacy_behavior: dict[str, object] = field(default_factory=dict)

    def to_response(self) -> SearchObservationResponse:
        return SearchObservationResponse(**self.__dict__)


def search(
        config: AppConfig,
        store: StoreProtocol,
        *,
        rag_profile_id: str,
        query: str,
        top_k: int | None = None,
        query_text_allowed: bool = True,
) -> SearchResponse:
    started = time.monotonic()
    rag_profile = config.rag_profiles.get(rag_profile_id)
    if not rag_profile:
        raise KeyError(f"rag_profile not found: {rag_profile_id}")

    if rag_profile.retrieval.method != "postgres_fts":
        raise ValueError(
            f"retrieval method not implemented in Phase 1.5: {rag_profile.retrieval.method}")

    requested_top_k = top_k or rag_profile.retrieval.top_k
    warnings: list[WarningItem] = []

    if not query.strip():
        observation_json = empty_postgres_fts_observation(
            query=query,
            top_k=requested_top_k,
            query_text_allowed=query_text_allowed,
            privacy_behavior={"query_text_persisted": query_text_allowed},
        )
        warnings.append(WarningItem(code="empty_query", message="search query is empty"))
        return SearchResponse(
            ok=True,
            query=query if query_text_allowed else "",
            rag_profile=rag_profile_id,
            results=[],
            warnings=warnings,
            observation=SearchObservationResponse(**observation_json),
        )

    results, observation_json = store.search_chunks_with_observation(
        query=query,
        corpus_id=rag_profile.corpus,
        top_k=requested_top_k,
        query_text_allowed=query_text_allowed,
    )

    if not results:
        warnings.append(
            WarningItem(
                code="no_retrieval_results",
                message="retrieval returned no chunks",
                details={"rag_profile": rag_profile_id},
            )
        )

    elapsed_ms = int((time.monotonic() - started) * 1000)
    observation_json = {
        **observation_json,
        "rag_profile_id": rag_profile_id,
        "corpus_id": rag_profile.corpus,
        "query_hash": observation_json.get("query_hash") or sha256_text(query.strip()),
        "latency_ms": observation_json.get("latency_ms") or elapsed_ms,
        "warning_codes": sorted(
            {*(observation_json.get("warning_codes") or []), *(w.code for w in warnings)}),
        "privacy_behavior": {
            **(observation_json.get("privacy_behavior") or {}),
            "query_text_persisted": query_text_allowed,
        },
    }

    return SearchResponse(
        ok=True,
        query=query if query_text_allowed else "",
        rag_profile=rag_profile_id,
        results=results,
        warnings=warnings,
        observation=SearchObservationResponse(**observation_json),
    )