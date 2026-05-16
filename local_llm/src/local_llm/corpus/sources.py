from __future__ import annotations

import hashlib
from pathlib import Path


def stable_source_id(corpus_id: str, origin_uri_or_path: str) -> str:
    return hashlib.sha256(f"{corpus_id}|{origin_uri_or_path}".encode("utf-8")).hexdigest()


def stable_document_id(source_id: str, content_hash: str) -> str:
    return hashlib.sha256(f"{source_id}|{content_hash}".encode("utf-8")).hexdigest()


def stable_chunk_id(document_id: str, ordinal: int, text_hash: str) -> str:
    return hashlib.sha256(f"{document_id}|{ordinal}|{text_hash}".encode("utf-8")).hexdigest()


def title_from_path(path: Path) -> str:
    return path.name
