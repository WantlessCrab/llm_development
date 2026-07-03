from __future__ import annotations

from dataclasses import dataclass, field

from local_llm.config import RagProfile
from local_llm.contracts import RetrievalResult, WarningItem


@dataclass(frozen=True)
class ContextSummary:
    included_count: int = 0
    skipped_duplicate_count: int = 0
    truncated: bool = False
    truncation_reason: str | None = None
    max_context_chars: int = 0
    context_char_count: int = 0
    token_estimate: int = 0
    unique_source_count: int = 0
    unique_document_count: int = 0
    included_chunk_ids: list[str] = field(default_factory=list)
    content_ref_inputs: list[dict[str, object]] = field(default_factory=list)

    def model_dump(self) -> dict[str, object]:
        return self.__dict__.copy()


@dataclass(frozen=True)
class BuiltContext:
    text: str
    retrievals: list[RetrievalResult]
    warnings: list[WarningItem]
    summary: ContextSummary


def build_context(rag_profile: RagProfile, retrievals: list[RetrievalResult]) -> BuiltContext:
    max_chars = rag_profile.context.max_context_chars
    parts: list[str] = []
    used: list[RetrievalResult] = []
    warnings: list[WarningItem] = []
    seen: set[str] = set()
    current_len = 0
    skipped_duplicate_count = 0
    truncated = False
    truncation_reason = None

    for retrieval in retrievals:
        if retrieval.chunk_id in seen:
            skipped_duplicate_count += 1
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
            truncated = True
            truncation_reason = "max_context_chars"
            warnings.append(WarningItem(code="context_truncated",
                                        message="retrieved context exceeded configured max_context_chars",
                                        details={"max_context_chars": max_chars}))
            break
        parts.append(block)
        used.append(retrieval)
        current_len += len(block)

    text = "\n".join(parts).strip()
    summary = ContextSummary(
        included_count=len(used),
        skipped_duplicate_count=skipped_duplicate_count,
        truncated=truncated,
        truncation_reason=truncation_reason,
        max_context_chars=max_chars,
        context_char_count=len(text),
        token_estimate=max(1, len(text) // 4) if text else 0,
        unique_source_count=len({r.source_id for r in used}),
        unique_document_count=len({r.document_id for r in used}),
        included_chunk_ids=[r.chunk_id for r in used],
        content_ref_inputs=[{"chunk_id": r.chunk_id, "rank": r.rank, "document_id": r.document_id,
                             "source_id": r.source_id} for r in used],
    )
    return BuiltContext(text=text, retrievals=used, warnings=warnings, summary=summary)