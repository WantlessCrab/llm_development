from __future__ import annotations

import time

from local_llm.config import AppConfig, ChunkingConfig
from local_llm.contracts import IngestResponse, WarningItem
from local_llm.corpus.chunker import chunk_text
from local_llm.corpus.extractors import extract_text
from local_llm.corpus.scanner import scan_corpus
from local_llm.corpus.sources import stable_chunk_id, stable_document_id, stable_source_id, \
    title_from_path
from local_llm.store.base import StoreProtocol


def ingest_corpus(config: AppConfig, store: StoreProtocol, corpus_id: str) -> IngestResponse:
    corpus = config.corpora.get(corpus_id)
    if not corpus:
        raise KeyError(f"corpus not found: {corpus_id}")

    rag_profiles = [rp for rp in config.rag_profiles.values() if rp.corpus == corpus_id]
    chunking = rag_profiles[0].chunking if rag_profiles else ChunkingConfig()

    start = time.monotonic()
    candidates = scan_corpus(corpus_id, corpus)
    active_source_ids: set[str] = set()

    sources_indexed = 0
    sources_skipped = 0
    documents_indexed = 0
    chunks_indexed = 0
    warnings: list[WarningItem] = []

    for candidate in candidates:
        source_id = stable_source_id(corpus_id, str(candidate.path))
        active_source_ids.add(source_id)

        existing = store.get_active_document_for_source(source_id)
        if existing and existing.file_hash == candidate.file_hash:
            sources_skipped += 1
            continue

        extracted = extract_text(candidate.path)
        if not extracted.text.strip():
            warnings.append(
                WarningItem(
                    code="empty_or_unsupported_document",
                    message=f"no indexable text extracted from {candidate.path}",
                    details={"path": str(candidate.path), "extractor": extracted.extractor_type},
                )
            )
            sources_skipped += 1
            continue

        document_id = stable_document_id(source_id, candidate.file_hash)
        chunks = chunk_text(extracted.text, chunking.target_chars, chunking.overlap_chars)

        chunk_records = []
        for chunk in chunks:
            chunk_records.append(
                {
                    "chunk_id": stable_chunk_id(document_id, chunk.ordinal, chunk.text_hash),
                    "document_id": document_id,
                    "source_id": source_id,
                    "corpus_id": corpus_id,
                    "ordinal": chunk.ordinal,
                    "text": chunk.text,
                    "text_hash": chunk.text_hash,
                    "char_start": chunk.char_start,
                    "char_end": chunk.char_end,
                    "token_estimate": chunk.token_estimate,
                    "metadata": {},
                }
            )

        source = {
            "source_id": source_id,
            "corpus_id": corpus_id,
            "source_type": "local_file",
            "title": title_from_path(candidate.path),
            "origin_uri_or_path": str(candidate.path),
            "source_version": candidate.file_hash,
            "content_hash": candidate.file_hash,
            "license_label": None,
            "metadata": {"relative_path": candidate.relative_path, "root": str(candidate.root)},
        }

        document = {
            "document_id": document_id,
            "source_id": source_id,
            "corpus_id": corpus_id,
            "path": str(candidate.path),
            "relative_path": candidate.relative_path,
            "file_hash": candidate.file_hash,
            "mtime_ns": candidate.mtime_ns,
            "size_bytes": candidate.size_bytes,
            "extension": candidate.extension,
            "metadata": {
                "encoding": extracted.encoding,
                "extractor_type": extracted.extractor_type,
                "warnings": extracted.warnings,
            },
        }

        store.upsert_document_with_chunks(source=source, document=document, chunks=chunk_records)
        sources_indexed += 1
        documents_indexed += 1
        chunks_indexed += len(chunk_records)

    store.mark_missing_sources_inactive(corpus_id, active_source_ids)

    return IngestResponse(
        ok=True,
        corpus_id=corpus_id,
        sources_seen=len(candidates),
        sources_indexed=sources_indexed,
        sources_skipped=sources_skipped,
        documents_indexed=documents_indexed,
        chunks_indexed=chunks_indexed,
        duration_ms=int((time.monotonic() - start) * 1000),
        warnings=warnings,
    )