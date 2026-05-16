from __future__ import annotations

import hashlib
from dataclasses import dataclass


@dataclass(frozen=True)
class TextChunk:
    ordinal: int
    text: str
    text_hash: str
    char_start: int
    char_end: int
    token_estimate: int


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def estimate_tokens(text: str) -> int:
    return max(1, int(len(text) / 4))


def chunk_text(text: str, target_chars: int, overlap_chars: int) -> list[TextChunk]:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.strip():
        return []

    target_chars = max(200, target_chars)
    overlap_chars = max(0, min(overlap_chars, target_chars // 2))
    chunks: list[TextChunk] = []
    n = len(normalized)
    start = 0
    ordinal = 0

    while start < n:
        hard_end = min(n, start + target_chars)
        if hard_end < n:
            window = normalized[start:hard_end]
            split_at = max(window.rfind("\n\n"), window.rfind("\n"), window.rfind(". "), window.rfind(" "))
            end = start + split_at + 1 if split_at > target_chars * 0.45 else hard_end
        else:
            end = hard_end

        chunk = normalized[start:end].strip()
        if chunk:
            chunks.append(TextChunk(ordinal, chunk, sha256_text(chunk), start, end, estimate_tokens(chunk)))
            ordinal += 1
        if end >= n:
            break
        start = max(0, end - overlap_chars)
        if start >= end:
            start = end
    return chunks
