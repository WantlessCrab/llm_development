from __future__ import annotations

SCHEMA_SQL = """
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS sources (
    source_id TEXT PRIMARY KEY,
    corpus_id TEXT NOT NULL,
    source_type TEXT NOT NULL,
    title TEXT NOT NULL,
    origin_uri_or_path TEXT NOT NULL,
    source_version TEXT,
    content_hash TEXT NOT NULL,
    fetched_or_indexed_at TEXT NOT NULL,
    license_label TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS documents (
    document_id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL,
    corpus_id TEXT NOT NULL,
    path TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    mtime_ns INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    extension TEXT NOT NULL,
    indexed_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    is_active INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY(source_id) REFERENCES sources(source_id)
);

CREATE TABLE IF NOT EXISTS chunks (
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    corpus_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    text TEXT NOT NULL,
    text_hash TEXT NOT NULL,
    char_start INTEGER NOT NULL,
    char_end INTEGER NOT NULL,
    token_estimate INTEGER NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    is_active INTEGER NOT NULL DEFAULT 1,
    FOREIGN KEY(document_id) REFERENCES documents(document_id),
    FOREIGN KEY(source_id) REFERENCES sources(source_id)
);

CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    chunk_id UNINDEXED,
    text,
    tokenize = 'unicode61'
);

CREATE TABLE IF NOT EXISTS runs (
    run_id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    workflow_kind TEXT NOT NULL,
    model_profile TEXT NOT NULL,
    rag_profile TEXT NOT NULL,
    prompt_profile TEXT NOT NULL,
    user_input TEXT NOT NULL,
    final_prompt TEXT NOT NULL,
    response_text TEXT NOT NULL,
    created_at TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    support_json TEXT NOT NULL,
    warnings_json TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS run_retrievals (
    run_id TEXT NOT NULL,
    chunk_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    rank INTEGER NOT NULL,
    method TEXT NOT NULL,
    score REAL NOT NULL,
    raw_score REAL,
    normalized_score REAL,
    document_path TEXT NOT NULL,
    source_title TEXT NOT NULL,
    source_version TEXT,
    chunk_text_snapshot TEXT NOT NULL,
    PRIMARY KEY(run_id, rank),
    FOREIGN KEY(run_id) REFERENCES runs(run_id)
);

CREATE TABLE IF NOT EXISTS run_artifacts (
    run_id TEXT NOT NULL,
    artifact_type TEXT NOT NULL,
    path TEXT NOT NULL,
    content_hash TEXT NOT NULL,
    created_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    PRIMARY KEY(run_id, artifact_type),
    FOREIGN KEY(run_id) REFERENCES runs(run_id)
);


CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    default_workflow_id TEXT NOT NULL,
    default_model_profile TEXT,
    default_rag_profile TEXT,
    default_prompt_profile TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    archived_at TEXT,
    metadata_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE IF NOT EXISTS turns (
    turn_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    user_input TEXT NOT NULL,
    run_id TEXT,
    created_at TEXT NOT NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    FOREIGN KEY(session_id) REFERENCES sessions(session_id),
    FOREIGN KEY(run_id) REFERENCES runs(run_id)
);

CREATE INDEX IF NOT EXISTS idx_documents_source_active ON documents(source_id, is_active);
CREATE INDEX IF NOT EXISTS idx_chunks_document_active ON chunks(document_id, is_active);
CREATE INDEX IF NOT EXISTS idx_chunks_source_active ON chunks(source_id, is_active);
CREATE INDEX IF NOT EXISTS idx_runs_created_at ON runs(created_at);
CREATE INDEX IF NOT EXISTS idx_sessions_archived_updated ON sessions(archived_at, updated_at);
CREATE INDEX IF NOT EXISTS idx_turns_session_ordinal ON turns(session_id, ordinal);
CREATE INDEX IF NOT EXISTS idx_turns_run ON turns(run_id);
"""
