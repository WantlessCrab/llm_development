from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from typing import Any

_WHITESPACE_RE = re.compile(r"\s+")
_TOKEN_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_'-]*")
_TOKEN_SAFE_RE = re.compile(r"[^a-z0-9_]+")
_MAX_FALLBACK_TERMS = 24

_STOPWORDS = frozenset({
    "about", "above", "after", "again", "against", "all", "also", "and", "any", "are",
    "because", "been", "before", "being", "below", "between", "both", "but", "can",
    "cannot", "could", "did", "does", "doing", "down", "during", "each", "few", "for",
    "from", "further", "had", "has", "have", "having", "her", "here", "hers", "him",
    "his", "how", "into", "its", "itself", "just", "more", "most", "not", "now", "off",
    "once", "only", "other", "our", "ours", "out", "over", "own", "same", "she",
    "should", "some", "such", "than", "that", "the", "their", "theirs", "them", "then",
    "there", "these", "they", "this", "those", "through", "too", "under", "until",
    "using", "very", "was", "were", "what", "when", "where", "which", "while", "who",
    "whom", "why", "will", "with", "would", "you", "your", "yours",
})

RETRIEVAL_METHOD = "postgres_fts"
BACKEND_NAME = "postgresql"
SEARCH_CONFIG = "simple"


def normalize_postgres_fts_query(query: str) -> str:
    """Return normalized plain query text for parameterized PostgreSQL FTS calls."""
    return _WHITESPACE_RE.sub(" ", query.strip())


def has_postgres_fts_query(query: str) -> bool:
    """Return whether a query has any searchable text after normalization."""
    return bool(normalize_postgres_fts_query(query))


def sha256_text(value: str) -> str:
    """Return a stable SHA-256 hash for UTF-8 text."""
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def meaningful_postgres_fts_terms(query: str, *, limit: int = _MAX_FALLBACK_TERMS) -> list[str]:
    """Return sanitized meaningful terms for fallback PostgreSQL FTS.

    Returned values are safe lexeme tokens for a parameterized to_tsquery() value.
    They are not SQL fragments.
    """
    normalized = normalize_postgres_fts_query(query).lower()
    seen: set[str] = set()
    terms: list[str] = []

    for raw_token in _TOKEN_RE.findall(normalized):
        token = _TOKEN_SAFE_RE.sub("_", raw_token).strip("_")
        if len(token) < 3 or token.isdigit() or token in _STOPWORDS or token in seen:
            continue
        seen.add(token)
        terms.append(token)
        if len(terms) >= limit:
            break

    return terms


def build_postgres_fts_or_query(query: str, *, limit: int = _MAX_FALLBACK_TERMS) -> str:
    """Return a sanitized OR tsquery string for parameterized fallback search."""
    return " | ".join(meaningful_postgres_fts_terms(query, limit=limit))


@dataclass(frozen=True)
class PostgresFtsQueryShape:
    retrieval_method: str
    backend: str
    search_config: str
    normalized_query_hash: str | None
    normalized_query: str | None
    query_text_allowed: bool
    stage_1_query_shape: dict[str, Any]
    fallback_terms: list[str]
    stage_2_fallback_query_shape: dict[str, Any]
    fallback_query: str
    fallback_available: bool
    top_k_requested: int
    warning_codes: list[str] = field(default_factory=list)

    def to_observation_json(
            self,
            *,
            candidate_count: int = 0,
            returned_count: int = 0,
            included_count: int = 0,
            latency_ms: int = 0,
            fallback_used: bool = False,
            fallback_reason: str | None = None,
            privacy_behavior: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return {
            "retrieval_method": self.retrieval_method,
            "backend": self.backend,
            "search_config": self.search_config,
            "query_hash": self.normalized_query_hash,
            "normalized_query_hash": self.normalized_query_hash,
            "normalized_query": self.normalized_query if self.query_text_allowed else None,
            "query_text_allowed": self.query_text_allowed,
            "stage_1_query_shape": self.stage_1_query_shape,
            "stage_2_fallback_query_shape": self.stage_2_fallback_query_shape,
            "fallback_terms": self.fallback_terms if self.query_text_allowed else [],
            "fallback_available": self.fallback_available,
            "fallback_used": fallback_used,
            "fallback_reason": fallback_reason,
            "top_k_requested": self.top_k_requested,
            "candidate_count": candidate_count,
            "returned_count": returned_count,
            "included_count": included_count,
            "latency_ms": latency_ms,
            "warning_codes": list(self.warning_codes),
            "privacy_behavior": privacy_behavior or {},
        }


def build_postgres_fts_query_shape(
        query: str,
        *,
        top_k: int,
        query_text_allowed: bool = True,
        fallback_limit: int = _MAX_FALLBACK_TERMS,
) -> PostgresFtsQueryShape:
    """Build packet evidence for the active PostgreSQL FTS query path."""
    normalized_query = normalize_postgres_fts_query(query)
    query_hash = sha256_text(normalized_query) if normalized_query else None
    fallback_terms = meaningful_postgres_fts_terms(normalized_query, limit=fallback_limit)
    fallback_query = " | ".join(fallback_terms)

    warning_codes: list[str] = []
    if not normalized_query:
        warning_codes.append("empty_query")
    if normalized_query and not fallback_terms:
        warning_codes.append("fallback_terms_empty")

    return PostgresFtsQueryShape(
        retrieval_method=RETRIEVAL_METHOD,
        backend=BACKEND_NAME,
        search_config=SEARCH_CONFIG,
        normalized_query_hash=query_hash,
        normalized_query=normalized_query if query_text_allowed else None,
        query_text_allowed=query_text_allowed,
        stage_1_query_shape={
            "stage": "stage_1_full_query",
            "function": "websearch_to_tsquery",
            "config": SEARCH_CONFIG,
            "input": "normalized_query_parameter",
            "normalized_query_hash": query_hash,
        },
        fallback_terms=fallback_terms,
        stage_2_fallback_query_shape={
            "stage": "stage_2_meaningful_terms_or_query",
            "function": "to_tsquery",
            "config": SEARCH_CONFIG,
            "input": "sanitized_fallback_terms_parameter",
            "term_count": len(fallback_terms),
            "fallback_query_hash": sha256_text(fallback_query) if fallback_query else None,
        },
        fallback_query=fallback_query,
        fallback_available=bool(fallback_query),
        top_k_requested=max(0, int(top_k)),
        warning_codes=warning_codes,
    )


def empty_postgres_fts_observation(
        *,
        query: str,
        top_k: int,
        query_text_allowed: bool = True,
        privacy_behavior: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Return a complete observation for a query that does not execute search."""
    shape = build_postgres_fts_query_shape(query, top_k=top_k,
                                           query_text_allowed=query_text_allowed)
    warning_codes = list(shape.warning_codes)
    if "empty_query" not in warning_codes:
        warning_codes.append("search_not_executed")

    return {
        **shape.to_observation_json(
            candidate_count=0,
            returned_count=0,
            included_count=0,
            latency_ms=0,
            fallback_used=False,
            fallback_reason="query_empty" if not has_postgres_fts_query(
                query) else "search_not_executed",
            privacy_behavior=privacy_behavior or {},
        ),
        "warning_codes": warning_codes,
    }