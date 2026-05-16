from __future__ import annotations

from dataclasses import dataclass

from local_llm.config import RagProfile
from local_llm.contracts import RetrievalResult, WarningItem


@dataclass(frozen=True)
class BuiltContext:
    text: str
    retrievals: list[RetrievalResult]
    warnings: list[WarningItem]


def build_context(rag_profile: RagProfile, retrievals: list[RetrievalResult]) -> BuiltContext:
    max_chars = rag_profile.context.max_context_chars
    parts: list[str] = []
    used: list[RetrievalResult] = []
    warnings: list[WarningItem] = []
    seen: set[str] = set()
    current_len = 0

    for retrieval in retrievals:
        if retrieval.chunk_id in seen:
            continue
        seen.add(retrieval.chunk_id)

        if rag_profile.context.include_source_headers:
            block = (
                f"[Source {len(used) + 1}]\n"
                f"source_id: {retrieval.source_id}\n"
                f"document_path: {retrieval.document_path}\n"
                f"chunk_id: {retrieval.chunk_id}\n"
                f"rank: {retrieval.rank}\n"
                f"method: {retrieval.method}\n"
                f"score: {retrieval.score}\n\n"
                f"{retrieval.text}\n"
            )
        else:
            block = retrieval.text + "\n"

        if current_len + len(block) > max_chars:
            warnings.append(
                WarningItem(
                    code="context_truncated",
                    message="retrieved context exceeded configured max_context_chars",
                    details={"max_context_chars": max_chars},
                )
            )
            break

        parts.append(block)
        used.append(retrieval)
        current_len += len(block)

    return BuiltContext(text="\n".join(parts).strip(), retrievals=used, warnings=warnings)
