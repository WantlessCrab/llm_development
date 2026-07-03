-- data_stack/db/migrations/010_final_phase_1_5_schema.sql
--
-- Phase 1.5 final packet-native schema.
--
-- This is the only active Phase 1.5 schema migration after the old Phase 1
-- migration chain is removed from the active migration path.
--
-- Final active database shape:
--   core       bootstrap metadata from db/init/002_bootstrap.sql
--   local_llm  app/retrieval foundation: corpora, sources, documents, chunks, sessions, postgres_fts
--   eval       packet-native tuning foundation: TurnPackets, attempts, events, content refs,
--              artifact refs, metric registry/facts, packet groups, packet group members
--
-- Not present:
--   local_llm.runs
--   local_llm.run_retrievals
--   local_llm.run_artifacts
--   local_llm.turns as separate evidence table
--   eval.evidence_batches
--   eval.comparison_groups
--   eval.eval_reports
--   eval.eval_metrics
--   eval.eval_artifacts
--   model_runtime.*
--   old eval/report/summary/tuning views
--   vector/embedding tables
--   search-stage/provider-call/prompt/context/read-bundle/chart/export table families

DO
$$
BEGIN
    IF to_regclass('core.applied_migrations') IS NULL THEN
        RAISE EXCEPTION 'core.applied_migrations is required before applying 010_final_phase_1_5_schema.sql';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        RAISE EXCEPTION 'Required extension missing: pgcrypto';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'vector') THEN
        RAISE EXCEPTION 'Installed inert future-foundation extension missing: vector';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.applied_migrations
        WHERE migration_id = '010_final_phase_1_5_schema'
    ) THEN
        DROP SCHEMA IF EXISTS model_runtime CASCADE;
        DROP SCHEMA IF EXISTS eval CASCADE;
        DROP SCHEMA IF EXISTS local_llm CASCADE;

        DELETE FROM core.applied_migrations
        WHERE migration_id IN (
            '010_local_llm_schema',
            '020_postgres_fts',
            '030_eval_runtime_catalog',
            '040_always_on_eval_capture',
            '050_turn_packet_core'
        );

        DELETE FROM core.schema_version
        WHERE component IN (
            'local_llm_schema',
            'eval_schema',
            'model_runtime_schema',
            'eval_runtime_catalog',
            'always_on_eval_capture'
        );

        DELETE FROM core.boot_checks
        WHERE check_name IN (
            'phase1_bootstrap_created',
            'phase_1_eval_capture_created'
        );
    END IF;
END;
$$;

CREATE SCHEMA IF NOT EXISTS local_llm;
CREATE SCHEMA IF NOT EXISTS eval;

COMMENT ON SCHEMA local_llm IS
    'Final Phase 1.5 local_llm foundation: corpus/source/document/chunk/session records and postgres_fts retrieval support.';

COMMENT ON SCHEMA eval IS
    'Final Phase 1.5 packet-native evidence authority: TurnPackets, attempts, events, content refs, artifact refs, metric facts, packet groups, and packet group members.';

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS local_llm.corpora
(
    corpus_id TEXT PRIMARY KEY,
    display_name TEXT,
    roots_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    include_globs_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    exclude_globs_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    config_hash TEXT,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT corpora_id_not_blank CHECK (btrim(corpus_id) <> ''),
    CONSTRAINT corpora_roots_is_array CHECK (jsonb_typeof(roots_json) = 'array'),
    CONSTRAINT corpora_include_globs_is_array CHECK (jsonb_typeof(include_globs_json) = 'array'),
    CONSTRAINT corpora_exclude_globs_is_array CHECK (jsonb_typeof(exclude_globs_json) = 'array'),
    CONSTRAINT corpora_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE local_llm.corpora IS
    'Final Phase 1.5 configured local_llm corpus identities and config snapshots.';

CREATE INDEX IF NOT EXISTS idx_corpora_config_hash
    ON local_llm.corpora(config_hash);

DROP TRIGGER IF EXISTS trg_corpora_updated_at ON local_llm.corpora;
CREATE TRIGGER trg_corpora_updated_at
BEFORE UPDATE ON local_llm.corpora
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS local_llm.sources
(
    source_id TEXT PRIMARY KEY,
    corpus_id TEXT NOT NULL REFERENCES local_llm.corpora(corpus_id) ON DELETE CASCADE,
    source_type TEXT NOT NULL,
    title TEXT NOT NULL,
    origin_uri_or_path TEXT NOT NULL,
    source_version TEXT,
    content_hash TEXT NOT NULL,
    fetched_or_indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    license_label TEXT,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT sources_id_not_blank CHECK (btrim(source_id) <> ''),
    CONSTRAINT sources_corpus_id_not_blank CHECK (btrim(corpus_id) <> ''),
    CONSTRAINT sources_type_not_blank CHECK (btrim(source_type) <> ''),
    CONSTRAINT sources_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT sources_origin_not_blank CHECK (btrim(origin_uri_or_path) <> ''),
    CONSTRAINT sources_content_hash_not_blank CHECK (btrim(content_hash) <> ''),
    CONSTRAINT sources_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE local_llm.sources IS
    'Final Phase 1.5 indexed corpus source units.';

CREATE INDEX IF NOT EXISTS idx_sources_corpus_active
    ON local_llm.sources(corpus_id, is_active);

CREATE INDEX IF NOT EXISTS idx_sources_origin
    ON local_llm.sources(origin_uri_or_path);

CREATE INDEX IF NOT EXISTS idx_sources_content_hash
    ON local_llm.sources(content_hash);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sources_active_origin
    ON local_llm.sources(corpus_id, origin_uri_or_path)
    WHERE is_active;

DROP TRIGGER IF EXISTS trg_sources_updated_at ON local_llm.sources;
CREATE TRIGGER trg_sources_updated_at
BEFORE UPDATE ON local_llm.sources
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS local_llm.documents
(
    document_id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES local_llm.sources(source_id) ON DELETE CASCADE,
    corpus_id TEXT NOT NULL REFERENCES local_llm.corpora(corpus_id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    relative_path TEXT NOT NULL,
    file_hash TEXT NOT NULL,
    mtime_ns BIGINT NOT NULL,
    size_bytes BIGINT NOT NULL,
    extension TEXT NOT NULL,
    indexed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT documents_id_not_blank CHECK (btrim(document_id) <> ''),
    CONSTRAINT documents_source_id_not_blank CHECK (btrim(source_id) <> ''),
    CONSTRAINT documents_corpus_id_not_blank CHECK (btrim(corpus_id) <> ''),
    CONSTRAINT documents_path_not_blank CHECK (btrim(path) <> ''),
    CONSTRAINT documents_relative_path_not_blank CHECK (btrim(relative_path) <> ''),
    CONSTRAINT documents_file_hash_not_blank CHECK (btrim(file_hash) <> ''),
    CONSTRAINT documents_mtime_nonnegative CHECK (mtime_ns >= 0),
    CONSTRAINT documents_size_nonnegative CHECK (size_bytes >= 0),
    CONSTRAINT documents_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE local_llm.documents IS
    'Final Phase 1.5 indexed document versions associated with sources.';

CREATE INDEX IF NOT EXISTS idx_documents_source_active
    ON local_llm.documents(source_id, is_active);

CREATE INDEX IF NOT EXISTS idx_documents_corpus_active
    ON local_llm.documents(corpus_id, is_active);

CREATE INDEX IF NOT EXISTS idx_documents_file_hash
    ON local_llm.documents(file_hash);

CREATE INDEX IF NOT EXISTS idx_documents_path
    ON local_llm.documents(path);

DROP TRIGGER IF EXISTS trg_documents_updated_at ON local_llm.documents;
CREATE TRIGGER trg_documents_updated_at
BEFORE UPDATE ON local_llm.documents
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS local_llm.chunks
(
    chunk_id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES local_llm.documents(document_id) ON DELETE CASCADE,
    source_id TEXT NOT NULL REFERENCES local_llm.sources(source_id) ON DELETE CASCADE,
    corpus_id TEXT NOT NULL REFERENCES local_llm.corpora(corpus_id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    text TEXT NOT NULL,
    text_hash TEXT NOT NULL,
    char_start INTEGER NOT NULL,
    char_end INTEGER NOT NULL,
    token_estimate INTEGER NOT NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    search_vector tsvector GENERATED ALWAYS AS (to_tsvector('simple', text)) STORED,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chunks_id_not_blank CHECK (btrim(chunk_id) <> ''),
    CONSTRAINT chunks_document_id_not_blank CHECK (btrim(document_id) <> ''),
    CONSTRAINT chunks_source_id_not_blank CHECK (btrim(source_id) <> ''),
    CONSTRAINT chunks_corpus_id_not_blank CHECK (btrim(corpus_id) <> ''),
    CONSTRAINT chunks_ordinal_nonnegative CHECK (ordinal >= 0),
    CONSTRAINT chunks_text_not_blank CHECK (btrim(text) <> ''),
    CONSTRAINT chunks_text_hash_not_blank CHECK (btrim(text_hash) <> ''),
    CONSTRAINT chunks_char_start_nonnegative CHECK (char_start >= 0),
    CONSTRAINT chunks_char_end_valid CHECK (char_end >= char_start),
    CONSTRAINT chunks_token_estimate_positive CHECK (token_estimate >= 1),
    CONSTRAINT chunks_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object'),
    CONSTRAINT chunks_document_ordinal_unique UNIQUE (document_id, ordinal)
);

COMMENT ON TABLE local_llm.chunks IS
    'Final Phase 1.5 retrievable text chunks with active PostgreSQL FTS search_vector foundation.';

CREATE INDEX IF NOT EXISTS idx_chunks_document_active
    ON local_llm.chunks(document_id, is_active);

CREATE INDEX IF NOT EXISTS idx_chunks_source_active
    ON local_llm.chunks(source_id, is_active);

CREATE INDEX IF NOT EXISTS idx_chunks_corpus_active
    ON local_llm.chunks(corpus_id, is_active);

CREATE INDEX IF NOT EXISTS idx_chunks_text_hash
    ON local_llm.chunks(text_hash);

CREATE INDEX IF NOT EXISTS idx_chunks_search_vector
    ON local_llm.chunks
    USING GIN (search_vector);

DROP TRIGGER IF EXISTS trg_chunks_updated_at ON local_llm.chunks;
CREATE TRIGGER trg_chunks_updated_at
BEFORE UPDATE ON local_llm.chunks
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS local_llm.sessions
(
    session_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    default_workflow_id TEXT NOT NULL,
    default_model_profile TEXT,
    default_rag_profile TEXT,
    default_prompt_profile TEXT,
    default_capture_mode TEXT NOT NULL DEFAULT 'full',
    default_privacy_level TEXT NOT NULL DEFAULT 'none',
    privacy_locked BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    archived_at TIMESTAMPTZ,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT sessions_id_not_blank CHECK (btrim(session_id) <> ''),
    CONSTRAINT sessions_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT sessions_default_workflow_not_blank CHECK (btrim(default_workflow_id) <> ''),
    CONSTRAINT sessions_capture_mode_valid CHECK (default_capture_mode IN ('full', 'privacy')),
    CONSTRAINT sessions_privacy_level_valid CHECK (default_privacy_level IN ('none', 'standard', 'strict')),
    CONSTRAINT sessions_default_capture_privacy_consistent CHECK (
        (
            default_capture_mode = 'full'
            AND default_privacy_level = 'none'
        )
        OR
        (
            default_capture_mode = 'privacy'
            AND default_privacy_level IN ('standard', 'strict')
        )
    ),
    CONSTRAINT sessions_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE local_llm.sessions IS
    'Final Phase 1.5 UI/API session identities. Turn evidence is owned by eval.turn_packets, not by a separate local_llm.turns evidence table.';

CREATE INDEX IF NOT EXISTS idx_sessions_archived_updated
    ON local_llm.sessions(archived_at, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_sessions_default_workflow
    ON local_llm.sessions(default_workflow_id);

DROP TRIGGER IF EXISTS trg_sessions_updated_at ON local_llm.sessions;
CREATE TRIGGER trg_sessions_updated_at
BEFORE UPDATE ON local_llm.sessions
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS eval.turn_packets
(
    turn_packet_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    request_id TEXT,
    idempotency_key TEXT,
    idempotency_scope_hash TEXT,
    source_kind TEXT NOT NULL,
    capture_status TEXT NOT NULL DEFAULT 'started',
    capture_mode TEXT NOT NULL DEFAULT 'full',
    privacy_level TEXT NOT NULL DEFAULT 'none',
    text_persisted BOOLEAN NOT NULL DEFAULT true,
    metadata_redacted BOOLEAN NOT NULL DEFAULT false,
    redaction_policy_version INTEGER,
    session_id TEXT REFERENCES local_llm.sessions(session_id) ON DELETE SET NULL,
    turn_id TEXT,
    turn_ordinal INTEGER,
    workflow_id TEXT NOT NULL,
    workflow_kind TEXT NOT NULL,
    model_profile_id TEXT NOT NULL,
    rag_profile_id TEXT NOT NULL,
    prompt_profile_id TEXT NOT NULL,
    corpus_id TEXT REFERENCES local_llm.corpora(corpus_id) ON DELETE SET NULL,
    retrieval_method TEXT NOT NULL DEFAULT 'postgres_fts',
    config_snapshot_hash TEXT NOT NULL,
    effective_config_hash TEXT NOT NULL,
    config_snapshot_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    request_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    search_observation_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    retrieval_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    context_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    prompt_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    provider_summary_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    runtime_links_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    privacy_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    manifest_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    error_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    source_system TEXT NOT NULL DEFAULT 'local_llm',
    source_record_id TEXT,
    is_imported BOOLEAN NOT NULL DEFAULT false,
    imported_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finalized_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT turn_packets_id_not_blank CHECK (btrim(turn_packet_id) <> ''),
    CONSTRAINT turn_packets_source_kind_valid CHECK (
        source_kind IN (
            'respond',
            'session_turn',
            'experiment_replicate',
            'router_handoff',
            'backfill_import'
        )
    ),
    CONSTRAINT turn_packets_status_valid CHECK (
        capture_status IN (
            'started',
            'completed',
            'partial',
            'failed',
            'imported',
            'cancelled'
        )
    ),
    CONSTRAINT turn_packets_capture_mode_valid CHECK (capture_mode IN ('full', 'privacy')),
    CONSTRAINT turn_packets_privacy_level_valid CHECK (privacy_level IN ('none', 'standard', 'strict')),
    CONSTRAINT turn_packets_capture_privacy_consistent CHECK (
        (
            capture_mode = 'full'
            AND privacy_level = 'none'
            AND text_persisted = true
            AND metadata_redacted = false
        )
        OR
        (
            capture_mode = 'privacy'
            AND privacy_level IN ('standard', 'strict')
            AND text_persisted = false
            AND metadata_redacted = true
        )
    ),
    CONSTRAINT turn_packets_redaction_version_consistent CHECK (
        metadata_redacted = false
        OR redaction_policy_version IS NOT NULL
    ),
    CONSTRAINT turn_packets_turn_ordinal_positive CHECK (
        turn_ordinal IS NULL
        OR turn_ordinal >= 1
    ),
    CONSTRAINT turn_packets_workflow_not_blank CHECK (btrim(workflow_id) <> ''),
    CONSTRAINT turn_packets_workflow_kind_not_blank CHECK (btrim(workflow_kind) <> ''),
    CONSTRAINT turn_packets_model_profile_not_blank CHECK (btrim(model_profile_id) <> ''),
    CONSTRAINT turn_packets_rag_profile_not_blank CHECK (btrim(rag_profile_id) <> ''),
    CONSTRAINT turn_packets_prompt_profile_not_blank CHECK (btrim(prompt_profile_id) <> ''),
    CONSTRAINT turn_packets_retrieval_method_valid CHECK (retrieval_method IN ('postgres_fts')),
    CONSTRAINT turn_packets_config_hash_not_blank CHECK (btrim(config_snapshot_hash) <> ''),
    CONSTRAINT turn_packets_effective_config_hash_not_blank CHECK (btrim(effective_config_hash) <> ''),
    CONSTRAINT turn_packets_config_snapshot_is_object CHECK (jsonb_typeof(config_snapshot_json) = 'object'),
    CONSTRAINT turn_packets_request_summary_is_object CHECK (jsonb_typeof(request_summary_json) = 'object'),
    CONSTRAINT turn_packets_search_observation_is_object CHECK (jsonb_typeof(search_observation_json) = 'object'),
    CONSTRAINT turn_packets_retrieval_summary_is_object CHECK (jsonb_typeof(retrieval_summary_json) = 'object'),
    CONSTRAINT turn_packets_context_summary_is_object CHECK (jsonb_typeof(context_summary_json) = 'object'),
    CONSTRAINT turn_packets_prompt_summary_is_object CHECK (jsonb_typeof(prompt_summary_json) = 'object'),
    CONSTRAINT turn_packets_provider_summary_is_object CHECK (jsonb_typeof(provider_summary_json) = 'object'),
    CONSTRAINT turn_packets_runtime_links_is_object CHECK (jsonb_typeof(runtime_links_json) = 'object'),
    CONSTRAINT turn_packets_privacy_is_object CHECK (jsonb_typeof(privacy_json) = 'object'),
    CONSTRAINT turn_packets_manifest_is_object CHECK (jsonb_typeof(manifest_json) = 'object'),
    CONSTRAINT turn_packets_error_is_object CHECK (jsonb_typeof(error_json) = 'object'),
    CONSTRAINT turn_packets_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object'),
    CONSTRAINT turn_packets_source_system_not_blank CHECK (btrim(source_system) <> ''),
    CONSTRAINT turn_packets_idempotency_scope_required CHECK (
        idempotency_key IS NULL
        OR (
            idempotency_scope_hash IS NOT NULL
            AND btrim(idempotency_scope_hash) <> ''
        )
    ),
    CONSTRAINT turn_packets_imported_state_consistent CHECK (
        (
            is_imported = false
            AND imported_at IS NULL
        )
        OR
        (
            is_imported = true
            AND imported_at IS NOT NULL
            AND capture_status = 'imported'
        )
    )
);

COMMENT ON TABLE eval.turn_packets IS
    'Final Phase 1.5 durable evidence object for one accepted native local_llm turn.';

CREATE INDEX IF NOT EXISTS idx_turn_packets_created_at
    ON eval.turn_packets(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_turn_packets_status_created
    ON eval.turn_packets(capture_status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_turn_packets_session_ordinal
    ON eval.turn_packets(session_id, turn_ordinal);

CREATE INDEX IF NOT EXISTS idx_turn_packets_workflow
    ON eval.turn_packets(workflow_id);

CREATE INDEX IF NOT EXISTS idx_turn_packets_model_profile
    ON eval.turn_packets(model_profile_id);

CREATE INDEX IF NOT EXISTS idx_turn_packets_rag_profile
    ON eval.turn_packets(rag_profile_id);

CREATE INDEX IF NOT EXISTS idx_turn_packets_prompt_profile
    ON eval.turn_packets(prompt_profile_id);

CREATE INDEX IF NOT EXISTS idx_turn_packets_capture_privacy
    ON eval.turn_packets(capture_mode, privacy_level, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_turn_packets_source_record
    ON eval.turn_packets(source_system, source_record_id)
    WHERE source_record_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_turn_packets_idempotency
    ON eval.turn_packets(source_kind, idempotency_key, idempotency_scope_hash)
    WHERE idempotency_key IS NOT NULL;

DROP TRIGGER IF EXISTS trg_turn_packets_updated_at ON eval.turn_packets;
CREATE TRIGGER trg_turn_packets_updated_at
BEFORE UPDATE ON eval.turn_packets
FOR EACH ROW
EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS eval.turn_attempts
(
    turn_attempt_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    turn_packet_id TEXT NOT NULL REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    attempt_index INTEGER NOT NULL,
    attempt_kind TEXT NOT NULL DEFAULT 'primary',
    attempt_status TEXT NOT NULL DEFAULT 'started',
    is_primary BOOLEAN NOT NULL DEFAULT false,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    latency_total_ms INTEGER,
    phase_timings_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    provider_evidence_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    failure_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT turn_attempts_id_not_blank CHECK (btrim(turn_attempt_id) <> ''),
    CONSTRAINT turn_attempts_index_positive CHECK (attempt_index >= 1),
    CONSTRAINT turn_attempts_kind_valid CHECK (attempt_kind IN ('primary', 'retry', 'repair', 'import')),
    CONSTRAINT turn_attempts_status_valid CHECK (
        attempt_status IN (
            'started',
            'completed',
            'partial',
            'failed',
            'skipped',
            'cancelled',
            'imported'
        )
    ),
    CONSTRAINT turn_attempts_primary_kind_consistent CHECK (
        is_primary = false
        OR attempt_kind = 'primary'
    ),
    CONSTRAINT turn_attempts_primary_index_consistent CHECK (
        is_primary = false
        OR attempt_index = 1
    ),
    CONSTRAINT turn_attempts_latency_nonnegative CHECK (
        latency_total_ms IS NULL
        OR latency_total_ms >= 0
    ),
    CONSTRAINT turn_attempts_phase_timings_is_object CHECK (jsonb_typeof(phase_timings_json) = 'object'),
    CONSTRAINT turn_attempts_provider_evidence_is_object CHECK (jsonb_typeof(provider_evidence_json) = 'object'),
    CONSTRAINT turn_attempts_failure_is_object CHECK (jsonb_typeof(failure_json) = 'object'),
    CONSTRAINT turn_attempts_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object'),
    CONSTRAINT turn_attempts_completion_order CHECK (
        completed_at IS NULL
        OR completed_at >= started_at
    )
);

COMMENT ON TABLE eval.turn_attempts IS
    'Execution attempts inside a TurnPacket. Attempts are not experiment replicates.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_turn_attempts_packet_index
    ON eval.turn_attempts(turn_packet_id, attempt_index);

CREATE UNIQUE INDEX IF NOT EXISTS uq_turn_attempts_one_primary
    ON eval.turn_attempts(turn_packet_id)
    WHERE is_primary;

CREATE INDEX IF NOT EXISTS idx_turn_attempts_packet_status
    ON eval.turn_attempts(turn_packet_id, attempt_status);

CREATE TABLE IF NOT EXISTS eval.turn_events
(
    event_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    turn_packet_id TEXT NOT NULL REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    turn_attempt_id TEXT REFERENCES eval.turn_attempts(turn_attempt_id) ON DELETE CASCADE,
    event_order INTEGER NOT NULL,
    event_name TEXT NOT NULL,
    event_status TEXT NOT NULL,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    latency_ms INTEGER,
    payload_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    failure_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    privacy_safe BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT turn_events_id_not_blank CHECK (btrim(event_id) <> ''),
    CONSTRAINT turn_events_order_positive CHECK (event_order >= 1),
    CONSTRAINT turn_events_name_valid CHECK (
        event_name IN (
            'request_received',
            'plan_resolved',
            'rag_directives_resolved',
            'privacy_policy_resolved',
            'retrieval_started',
            'retrieval_completed',
            'retrieval_candidates_ranked',
            'context_built',
            'prompt_built',
            'provider_started',
            'provider_completed',
            'provider_exposed_reasoning_captured',
            'content_refs_written',
            'artifacts_written',
            'metrics_written',
            'runtime_evidence_captured',
            'group_membership_attached',
            'manifest_finalized',
            'packet_finalized',
            'failed'
        )
    ),
    CONSTRAINT turn_events_status_valid CHECK (event_status IN ('started', 'completed', 'failed', 'skipped')),
    CONSTRAINT turn_events_latency_nonnegative CHECK (
        latency_ms IS NULL
        OR latency_ms >= 0
    ),
    CONSTRAINT turn_events_payload_is_object CHECK (jsonb_typeof(payload_json) = 'object'),
    CONSTRAINT turn_events_failure_is_object CHECK (jsonb_typeof(failure_json) = 'object'),
    CONSTRAINT turn_events_completion_order CHECK (
        completed_at IS NULL
        OR started_at IS NULL
        OR completed_at >= started_at
    )
);

COMMENT ON TABLE eval.turn_events IS
    'Ordered packet timeline for phase timing, execution sequence, and inspectable failures.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_turn_events_packet_order
    ON eval.turn_events(turn_packet_id, event_order);

CREATE INDEX IF NOT EXISTS idx_turn_events_attempt_order
    ON eval.turn_events(turn_attempt_id, event_order);

CREATE INDEX IF NOT EXISTS idx_turn_events_name_status
    ON eval.turn_events(event_name, event_status);

CREATE TABLE IF NOT EXISTS eval.turn_content_refs
(
    content_ref_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    turn_packet_id TEXT NOT NULL REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    turn_attempt_id TEXT REFERENCES eval.turn_attempts(turn_attempt_id) ON DELETE CASCADE,
    owner_type TEXT NOT NULL,
    owner_id TEXT,
    content_role TEXT NOT NULL,
    storage_kind TEXT NOT NULL,
    body_text TEXT,
    file_path TEXT,
    sha256 TEXT,
    size_bytes BIGINT,
    mime_type TEXT,
    capture_mode TEXT NOT NULL,
    privacy_level TEXT NOT NULL,
    body_persisted BOOLEAN NOT NULL,
    metadata_redacted BOOLEAN NOT NULL,
    payload_policy TEXT NOT NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT turn_content_refs_id_not_blank CHECK (btrim(content_ref_id) <> ''),
    CONSTRAINT turn_content_refs_owner_type_valid CHECK (
        owner_type IN (
            'packet',
            'attempt',
            'event',
            'search',
            'retrieval',
            'context',
            'prompt',
            'provider',
            'artifact'
        )
    ),
    CONSTRAINT turn_content_refs_role_valid CHECK (
        content_role IN (
            'user_input',
            'retrieval_query',
            'retrieved_chunk_snapshot',
            'context_text',
            'prompt_messages',
            'provider_request',
            'provider_raw_response',
            'provider_exposed_reasoning',
            'assistant_response',
            'diagnostics',
            'packet_summary'
        )
    ),
    CONSTRAINT turn_content_refs_storage_kind_valid CHECK (
        storage_kind IN (
            'inline_text',
            'file_ref',
            'redacted_inline',
            'redacted_file',
            'omitted',
            'non_text_file'
        )
    ),
    CONSTRAINT turn_content_refs_capture_mode_valid CHECK (capture_mode IN ('full', 'privacy')),
    CONSTRAINT turn_content_refs_privacy_level_valid CHECK (privacy_level IN ('none', 'standard', 'strict')),
    CONSTRAINT turn_content_refs_payload_policy_valid CHECK (
        payload_policy IN (
            'full_body',
            'redacted_body',
            'omitted_body',
            'non_text_body'
        )
    ),
    CONSTRAINT turn_content_refs_size_nonnegative CHECK (
        size_bytes IS NULL
        OR size_bytes >= 0
    ),
    CONSTRAINT turn_content_refs_inline_requires_body CHECK (
        storage_kind <> 'inline_text'
        OR body_text IS NOT NULL
    ),
    CONSTRAINT turn_content_refs_file_requires_path CHECK (
        storage_kind NOT IN ('file_ref', 'redacted_file', 'non_text_file')
        OR file_path IS NOT NULL
    ),
    CONSTRAINT turn_content_refs_omitted_has_no_body CHECK (
        storage_kind <> 'omitted'
        OR (
            body_text IS NULL
            AND file_path IS NULL
            AND body_persisted = false
        )
    ),
    CONSTRAINT turn_content_refs_capture_privacy_consistent CHECK (
        (
            capture_mode = 'full'
            AND privacy_level = 'none'
            AND metadata_redacted = false
        )
        OR
        (
            capture_mode = 'privacy'
            AND privacy_level IN ('standard', 'strict')
            AND body_persisted = false
            AND metadata_redacted = true
            AND payload_policy IN ('redacted_body', 'omitted_body', 'non_text_body')
        )
    ),
    CONSTRAINT turn_content_refs_privacy_body_absent CHECK (
        capture_mode <> 'privacy'
        OR body_text IS NULL
    ),
    CONSTRAINT turn_content_refs_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE eval.turn_content_refs IS
    'Unified content access contract for inline text, file-backed text, redacted text, omitted text, and non-text file references.';

CREATE INDEX IF NOT EXISTS idx_turn_content_refs_packet
    ON eval.turn_content_refs(turn_packet_id);

CREATE INDEX IF NOT EXISTS idx_turn_content_refs_attempt
    ON eval.turn_content_refs(turn_attempt_id);

CREATE INDEX IF NOT EXISTS idx_turn_content_refs_role
    ON eval.turn_content_refs(content_role);

CREATE INDEX IF NOT EXISTS idx_turn_content_refs_storage_kind
    ON eval.turn_content_refs(storage_kind);

CREATE INDEX IF NOT EXISTS idx_turn_content_refs_sha256
    ON eval.turn_content_refs(sha256);

CREATE TABLE IF NOT EXISTS eval.turn_artifacts
(
    artifact_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    turn_packet_id TEXT NOT NULL REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    turn_attempt_id TEXT REFERENCES eval.turn_attempts(turn_attempt_id) ON DELETE CASCADE,
    artifact_type TEXT NOT NULL,
    path TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    mime_type TEXT,
    body_persisted BOOLEAN NOT NULL,
    payload_policy TEXT NOT NULL,
    capture_mode TEXT NOT NULL,
    privacy_level TEXT NOT NULL,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT turn_artifacts_id_not_blank CHECK (btrim(artifact_id) <> ''),
    CONSTRAINT turn_artifacts_type_valid CHECK (
        artifact_type IN (
            'request',
            'retrievals',
            'context',
            'prompt',
            'response',
            'provider_raw_response',
            'provider_exposed_reasoning',
            'diagnostics',
            'report',
            'other'
        )
    ),
    CONSTRAINT turn_artifacts_path_not_blank CHECK (btrim(path) <> ''),
    CONSTRAINT turn_artifacts_sha256_not_blank CHECK (btrim(sha256) <> ''),
    CONSTRAINT turn_artifacts_size_nonnegative CHECK (size_bytes >= 0),
    CONSTRAINT turn_artifacts_payload_policy_valid CHECK (
        payload_policy IN (
            'full_body',
            'redacted_body',
            'omitted_body',
            'non_text_body'
        )
    ),
    CONSTRAINT turn_artifacts_capture_mode_valid CHECK (capture_mode IN ('full', 'privacy')),
    CONSTRAINT turn_artifacts_privacy_level_valid CHECK (privacy_level IN ('none', 'standard', 'strict')),
    CONSTRAINT turn_artifacts_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object'),
    CONSTRAINT turn_artifacts_capture_privacy_consistent CHECK (
        (
            capture_mode = 'full'
            AND privacy_level = 'none'
        )
        OR
        (
            capture_mode = 'privacy'
            AND privacy_level IN ('standard', 'strict')
            AND body_persisted = false
            AND payload_policy IN ('redacted_body', 'omitted_body', 'non_text_body')
        )
    )
);

COMMENT ON TABLE eval.turn_artifacts IS
    'Packet-owned index for filesystem-backed artifact bodies. Raw bodies remain filesystem-backed.';

CREATE INDEX IF NOT EXISTS idx_turn_artifacts_packet
    ON eval.turn_artifacts(turn_packet_id);

CREATE INDEX IF NOT EXISTS idx_turn_artifacts_attempt
    ON eval.turn_artifacts(turn_attempt_id);

CREATE INDEX IF NOT EXISTS idx_turn_artifacts_type
    ON eval.turn_artifacts(artifact_type);

CREATE INDEX IF NOT EXISTS idx_turn_artifacts_sha256
    ON eval.turn_artifacts(sha256);

CREATE TABLE IF NOT EXISTS eval.metric_registry
(
    metric_key TEXT PRIMARY KEY,
    namespace TEXT NOT NULL,
    display_name TEXT NOT NULL,
    description TEXT NOT NULL,
    unit TEXT,
    value_type TEXT NOT NULL,
    aggregation_default TEXT NOT NULL,
    higher_is_better BOOLEAN,
    privacy_safe BOOLEAN NOT NULL,
    source_layer TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT metric_registry_key_not_blank CHECK (btrim(metric_key) <> ''),
    CONSTRAINT metric_registry_namespace_not_blank CHECK (btrim(namespace) <> ''),
    CONSTRAINT metric_registry_display_name_not_blank CHECK (btrim(display_name) <> ''),
    CONSTRAINT metric_registry_description_not_blank CHECK (btrim(description) <> ''),
    CONSTRAINT metric_registry_value_type_valid CHECK (value_type IN ('number', 'text', 'json', 'boolean')),
    CONSTRAINT metric_registry_aggregation_valid CHECK (
        aggregation_default IN (
            'avg',
            'sum',
            'min',
            'max',
            'count',
            'latest',
            'none'
        )
    ),
    CONSTRAINT metric_registry_source_layer_valid CHECK (
        source_layer IN (
            'packet',
            'attempt',
            'event',
            'search',
            'retrieval',
            'context',
            'prompt',
            'provider',
            'artifact',
            'runtime',
            'comparison',
            'quality'
        )
    ),
    CONSTRAINT metric_registry_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE eval.metric_registry IS
    'Typed metric definitions for discovery, aggregation, privacy safety, and future tuning labels.';

CREATE INDEX IF NOT EXISTS idx_metric_registry_namespace
    ON eval.metric_registry(namespace);

CREATE INDEX IF NOT EXISTS idx_metric_registry_active
    ON eval.metric_registry(active);

CREATE INDEX IF NOT EXISTS idx_metric_registry_privacy_safe
    ON eval.metric_registry(privacy_safe);

CREATE TABLE IF NOT EXISTS eval.turn_metric_facts
(
    metric_fact_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    turn_packet_id TEXT NOT NULL REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    turn_attempt_id TEXT REFERENCES eval.turn_attempts(turn_attempt_id) ON DELETE CASCADE,
    owner_type TEXT NOT NULL,
    owner_id TEXT,
    metric_key TEXT NOT NULL REFERENCES eval.metric_registry(metric_key),
    metric_value_num NUMERIC,
    metric_value_text TEXT,
    metric_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    unit TEXT,
    privacy_safe BOOLEAN NOT NULL,
    source TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT turn_metric_facts_id_not_blank CHECK (btrim(metric_fact_id) <> ''),
    CONSTRAINT turn_metric_facts_owner_type_valid CHECK (
        owner_type IN (
            'packet',
            'attempt',
            'event',
            'search',
            'retrieval',
            'context',
            'prompt',
            'provider',
            'artifact',
            'group',
            'session'
        )
    ),
    CONSTRAINT turn_metric_facts_source_valid CHECK (
        source IN (
            'derived',
            'provider',
            'runtime',
            'recorder',
            'projection',
            'operator'
        )
    ),
    CONSTRAINT turn_metric_facts_json_is_object CHECK (jsonb_typeof(metric_json) = 'object'),
    CONSTRAINT turn_metric_facts_value_present CHECK (
        metric_value_num IS NOT NULL
        OR metric_value_text IS NOT NULL
        OR metric_json <> '{}'::jsonb
    )
);

COMMENT ON TABLE eval.turn_metric_facts IS
    'Packet-owned metric values using registry-backed metric keys.';

CREATE INDEX IF NOT EXISTS idx_turn_metric_facts_packet
    ON eval.turn_metric_facts(turn_packet_id);

CREATE INDEX IF NOT EXISTS idx_turn_metric_facts_attempt
    ON eval.turn_metric_facts(turn_attempt_id);

CREATE INDEX IF NOT EXISTS idx_turn_metric_facts_metric_key
    ON eval.turn_metric_facts(metric_key);

CREATE INDEX IF NOT EXISTS idx_turn_metric_facts_owner
    ON eval.turn_metric_facts(owner_type, owner_id);

CREATE INDEX IF NOT EXISTS idx_turn_metric_facts_privacy_safe
    ON eval.turn_metric_facts(privacy_safe);

CREATE TABLE IF NOT EXISTS eval.packet_groups
(
    packet_group_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    parent_group_id TEXT REFERENCES eval.packet_groups(packet_group_id) ON DELETE CASCADE,
    group_kind TEXT NOT NULL,
    label TEXT NOT NULL,
    purpose TEXT,
    status TEXT NOT NULL DEFAULT 'planned',
    baseline_group_id TEXT REFERENCES eval.packet_groups(packet_group_id) ON DELETE SET NULL,
    workflow_id TEXT,
    capture_mode TEXT,
    privacy_level TEXT,
    plan_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    condition_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    metric_policy_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    privacy_policy_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finalized_at TIMESTAMPTZ,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT packet_groups_id_not_blank CHECK (btrim(packet_group_id) <> ''),
    CONSTRAINT packet_groups_kind_valid CHECK (
        group_kind IN (
            'experiment',
            'condition',
            'analysis_collection',
            'session_comparison',
            'manual_packet_set',
            'workflow_scope',
            'model_scope',
            'rag_scope',
            'prompt_scope',
            'privacy_scope'
        )
    ),
    CONSTRAINT packet_groups_label_not_blank CHECK (btrim(label) <> ''),
    CONSTRAINT packet_groups_status_valid CHECK (
        status IN (
            'planned',
            'running',
            'active',
            'completed',
            'failed',
            'cancelled',
            'archived'
        )
    ),
    CONSTRAINT packet_groups_capture_mode_valid CHECK (
        capture_mode IS NULL
        OR capture_mode IN ('full', 'privacy')
    ),
    CONSTRAINT packet_groups_privacy_level_valid CHECK (
        privacy_level IS NULL
        OR privacy_level IN ('none', 'standard', 'strict')
    ),
    CONSTRAINT packet_groups_capture_privacy_consistent CHECK (
        capture_mode IS NULL
        OR privacy_level IS NULL
        OR (
            capture_mode = 'full'
            AND privacy_level = 'none'
        )
        OR (
            capture_mode = 'privacy'
            AND privacy_level IN ('standard', 'strict')
        )
    ),
    CONSTRAINT packet_groups_condition_requires_parent CHECK (
        group_kind <> 'condition'
        OR parent_group_id IS NOT NULL
    ),
    CONSTRAINT packet_groups_plan_is_object CHECK (jsonb_typeof(plan_json) = 'object'),
    CONSTRAINT packet_groups_condition_is_object CHECK (jsonb_typeof(condition_json) = 'object'),
    CONSTRAINT packet_groups_metric_policy_is_object CHECK (jsonb_typeof(metric_policy_json) = 'object'),
    CONSTRAINT packet_groups_privacy_policy_is_object CHECK (jsonb_typeof(privacy_policy_json) = 'object'),
    CONSTRAINT packet_groups_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object'),
    CONSTRAINT packet_groups_finalization_order CHECK (
        finalized_at IS NULL
        OR finalized_at >= created_at
    )
);

COMMENT ON TABLE eval.packet_groups IS
    'Generic physical model for experiments, conditions, session comparisons, manual packet sets, and analysis scopes.';

CREATE INDEX IF NOT EXISTS idx_packet_groups_parent
    ON eval.packet_groups(parent_group_id);

CREATE INDEX IF NOT EXISTS idx_packet_groups_kind
    ON eval.packet_groups(group_kind);

CREATE INDEX IF NOT EXISTS idx_packet_groups_status
    ON eval.packet_groups(status);

CREATE INDEX IF NOT EXISTS idx_packet_groups_label
    ON eval.packet_groups(label);

CREATE INDEX IF NOT EXISTS idx_packet_groups_baseline
    ON eval.packet_groups(baseline_group_id);

CREATE OR REPLACE FUNCTION eval.validate_packet_group_parent()
RETURNS TRIGGER
LANGUAGE plpgsql
AS
$$
DECLARE
    parent_kind TEXT;
BEGIN
    IF NEW.group_kind <> 'condition' THEN
        RETURN NEW;
    END IF;

    IF NEW.parent_group_id IS NULL THEN
        RAISE EXCEPTION 'condition packet_group % requires an experiment parent_group_id', NEW.packet_group_id;
    END IF;

    SELECT group_kind
    INTO parent_kind
    FROM eval.packet_groups
    WHERE packet_group_id = NEW.parent_group_id;

    IF parent_kind IS DISTINCT FROM 'experiment' THEN
        RAISE EXCEPTION 'condition packet_group % parent must be group_kind=experiment', NEW.packet_group_id;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_validate_packet_group_parent ON eval.packet_groups;
CREATE TRIGGER trg_validate_packet_group_parent
BEFORE INSERT OR UPDATE OF group_kind, parent_group_id
ON eval.packet_groups
FOR EACH ROW
EXECUTE FUNCTION eval.validate_packet_group_parent();

CREATE TABLE IF NOT EXISTS eval.packet_group_members
(
    packet_group_member_id TEXT PRIMARY KEY DEFAULT gen_random_uuid()::text,
    packet_group_id TEXT NOT NULL REFERENCES eval.packet_groups(packet_group_id) ON DELETE CASCADE,
    member_type TEXT NOT NULL,
    member_id TEXT NOT NULL,
    turn_packet_id TEXT REFERENCES eval.turn_packets(turn_packet_id) ON DELETE CASCADE,
    turn_attempt_id TEXT REFERENCES eval.turn_attempts(turn_attempt_id) ON DELETE SET NULL,
    session_id TEXT REFERENCES local_llm.sessions(session_id) ON DELETE CASCADE,
    turn_id TEXT,
    member_label TEXT,
    member_role TEXT NOT NULL,
    replicate_index INTEGER,
    include_in_aggregate BOOLEAN NOT NULL DEFAULT true,
    exclusion_reason TEXT,
    ordinal INTEGER,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT packet_group_members_id_not_blank CHECK (btrim(packet_group_member_id) <> ''),
    CONSTRAINT packet_group_members_member_id_not_blank CHECK (btrim(member_id) <> ''),
    CONSTRAINT packet_group_members_type_valid CHECK (
        member_type IN (
            'turn_packet',
            'session',
            'turn',
            'workflow',
            'model_profile',
            'rag_profile',
            'prompt_profile',
            'privacy_mode',
            'manual_filter'
        )
    ),
    CONSTRAINT packet_group_members_role_valid CHECK (
        member_role IN (
            'baseline',
            'condition',
            'replicate',
            'analysis_member',
            'comparison_member',
            'excluded',
            'reference'
        )
    ),
    CONSTRAINT packet_group_members_replicate_index_positive CHECK (
        replicate_index IS NULL
        OR replicate_index >= 1
    ),
    CONSTRAINT packet_group_members_ordinal_positive CHECK (
        ordinal IS NULL
        OR ordinal >= 1
    ),
    CONSTRAINT packet_group_members_exclusion_reason_required CHECK (
        include_in_aggregate = true
        OR exclusion_reason IS NOT NULL
    ),
    CONSTRAINT packet_group_members_type_target_consistent CHECK (
        (
            member_type = 'turn_packet'
            AND turn_packet_id IS NOT NULL
        )
        OR
        (
            member_type = 'session'
            AND session_id IS NOT NULL
        )
        OR
        (
            member_type = 'turn'
            AND turn_id IS NOT NULL
        )
        OR
        member_type IN (
            'workflow',
            'model_profile',
            'rag_profile',
            'prompt_profile',
            'privacy_mode',
            'manual_filter'
        )
    ),
    CONSTRAINT packet_group_members_member_identity_consistent CHECK (
        (
            member_type = 'turn_packet'
            AND member_id = turn_packet_id
        )
        OR
        (
            member_type = 'session'
            AND member_id = session_id
        )
        OR
        (
            member_type = 'turn'
            AND member_id = turn_id
        )
        OR
        member_type IN (
            'workflow',
            'model_profile',
            'rag_profile',
            'prompt_profile',
            'privacy_mode',
            'manual_filter'
        )
    ),
    CONSTRAINT packet_group_members_replicate_requires_packet CHECK (
        member_role <> 'replicate'
        OR (
            turn_packet_id IS NOT NULL
            AND replicate_index IS NOT NULL
        )
    ),
    CONSTRAINT packet_group_members_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE eval.packet_group_members IS
    'Generic membership model for packet groups. Replicate identity lives here and is distinct from attempts.';

CREATE INDEX IF NOT EXISTS idx_packet_group_members_group
    ON eval.packet_group_members(packet_group_id);

CREATE INDEX IF NOT EXISTS idx_packet_group_members_packet
    ON eval.packet_group_members(turn_packet_id);

CREATE INDEX IF NOT EXISTS idx_packet_group_members_session
    ON eval.packet_group_members(session_id);

CREATE INDEX IF NOT EXISTS idx_packet_group_members_type_member
    ON eval.packet_group_members(member_type, member_id);

CREATE INDEX IF NOT EXISTS idx_packet_group_members_role
    ON eval.packet_group_members(member_role);

CREATE UNIQUE INDEX IF NOT EXISTS uq_packet_group_members_included_replicate
    ON eval.packet_group_members(packet_group_id, replicate_index)
    WHERE member_role = 'replicate'
      AND include_in_aggregate = true
      AND replicate_index IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_packet_group_members_included_packet_role
    ON eval.packet_group_members(packet_group_id, turn_packet_id, member_role)
    WHERE turn_packet_id IS NOT NULL
      AND include_in_aggregate = true;

INSERT INTO eval.metric_registry (
    metric_key,
    namespace,
    display_name,
    description,
    unit,
    value_type,
    aggregation_default,
    higher_is_better,
    privacy_safe,
    source_layer,
    active,
    metadata_json
)
VALUES
    ('latency.total_ms', 'latency', 'Total latency', 'Total end-to-end turn latency.', 'ms', 'number', 'avg', false, true, 'packet', true, '{}'::jsonb),
    ('latency.retrieval_ms', 'latency', 'Retrieval latency', 'Time spent in retrieval.', 'ms', 'number', 'avg', false, true, 'retrieval', true, '{}'::jsonb),
    ('latency.context_build_ms', 'latency', 'Context build latency', 'Time spent building selected context.', 'ms', 'number', 'avg', false, true, 'context', true, '{}'::jsonb),
    ('latency.prompt_build_ms', 'latency', 'Prompt build latency', 'Time spent building provider prompt/messages.', 'ms', 'number', 'avg', false, true, 'prompt', true, '{}'::jsonb),
    ('latency.provider_ms', 'latency', 'Provider latency', 'Time spent waiting on configured provider.', 'ms', 'number', 'avg', false, true, 'provider', true, '{}'::jsonb),
    ('latency.artifact_write_ms', 'latency', 'Artifact write latency', 'Time spent staging/writing filesystem artifacts.', 'ms', 'number', 'avg', false, true, 'artifact', true, '{}'::jsonb),
    ('tokens.prompt', 'tokens', 'Prompt tokens', 'Provider-reported prompt token count when available.', 'tokens', 'number', 'avg', null, true, 'provider', true, '{}'::jsonb),
    ('tokens.completion', 'tokens', 'Completion tokens', 'Provider-reported completion token count when available.', 'tokens', 'number', 'avg', null, true, 'provider', true, '{}'::jsonb),
    ('tokens.total', 'tokens', 'Total tokens', 'Provider-reported total token count when available.', 'tokens', 'number', 'avg', null, true, 'provider', true, '{}'::jsonb),
    ('chars.user_input', 'chars', 'User input characters', 'Character count of user input when permitted by privacy policy.', 'chars', 'number', 'avg', null, false, 'packet', true, '{}'::jsonb),
    ('chars.context', 'chars', 'Context characters', 'Character count of selected context when available.', 'chars', 'number', 'avg', null, false, 'context', true, '{}'::jsonb),
    ('chars.prompt', 'chars', 'Prompt characters', 'Character count of built prompt/messages when available.', 'chars', 'number', 'avg', null, false, 'prompt', true, '{}'::jsonb),
    ('chars.response', 'chars', 'Response characters', 'Character count of assistant response when permitted by privacy policy.', 'chars', 'number', 'avg', null, false, 'provider', true, '{}'::jsonb),
    ('search.candidate_count', 'search', 'Search candidate count', 'Number of raw candidates considered by the active search implementation when available.', 'count', 'number', 'avg', null, true, 'search', true, '{}'::jsonb),
    ('search.returned_count', 'search', 'Search returned count', 'Number of search results returned by the active search implementation.', 'count', 'number', 'avg', null, true, 'search', true, '{}'::jsonb),
    ('search.included_count', 'search', 'Search included count', 'Number of search results selected for downstream context.', 'count', 'number', 'avg', null, true, 'search', true, '{}'::jsonb),
    ('search.top_k_requested', 'search', 'Requested top-k', 'Requested top-k retrieval/search setting.', 'count', 'number', 'latest', null, true, 'search', true, '{}'::jsonb),
    ('retrieval.returned_count', 'retrieval', 'Returned retrieval count', 'Number of retrieval candidates returned by the active retriever.', 'count', 'number', 'avg', null, true, 'retrieval', true, '{}'::jsonb),
    ('retrieval.included_count', 'retrieval', 'Included retrieval count', 'Number of retrieval candidates included in context.', 'count', 'number', 'avg', null, true, 'context', true, '{}'::jsonb),
    ('retrieval.unique_source_count', 'retrieval', 'Unique source count', 'Number of unique sources represented in selected retrieval evidence.', 'count', 'number', 'avg', null, true, 'retrieval', true, '{}'::jsonb),
    ('retrieval.unique_document_count', 'retrieval', 'Unique document count', 'Number of unique documents represented in selected retrieval evidence.', 'count', 'number', 'avg', null, true, 'retrieval', true, '{}'::jsonb),
    ('context.truncated', 'context', 'Context truncated', 'Whether selected context was truncated.', null, 'boolean', 'latest', false, true, 'context', true, '{}'::jsonb),
    ('context.char_count', 'context', 'Context character count', 'Character count of selected context when available.', 'chars', 'number', 'avg', null, false, 'context', true, '{}'::jsonb),
    ('provider.finish_reason', 'provider', 'Provider finish reason', 'Provider finish reason text when available.', null, 'text', 'latest', null, true, 'provider', true, '{}'::jsonb),
    ('provider.prompt_per_second', 'provider', 'Prompt tokens per second', 'Provider prompt processing rate when reported.', 'tokens/s', 'number', 'avg', true, true, 'provider', true, '{}'::jsonb),
    ('provider.completion_per_second', 'provider', 'Completion tokens per second', 'Provider completion generation rate when reported.', 'tokens/s', 'number', 'avg', true, true, 'provider', true, '{}'::jsonb),
    ('artifact.count', 'artifact', 'Artifact count', 'Number of packet artifacts recorded.', 'count', 'number', 'avg', null, true, 'artifact', true, '{}'::jsonb),
    ('warnings.count', 'warning', 'Warning count', 'Number of packet warnings.', 'count', 'number', 'avg', false, true, 'packet', true, '{}'::jsonb),
    ('privacy.text_persisted', 'privacy', 'Text persisted', 'Whether conversational/content text was persisted for the packet.', null, 'boolean', 'latest', null, true, 'packet', true, '{}'::jsonb),
    ('privacy.metadata_redacted', 'privacy', 'Metadata redacted', 'Whether content-revealing metadata was redacted for the packet.', null, 'boolean', 'latest', null, true, 'packet', true, '{}'::jsonb),
    ('quality.operator_score', 'quality', 'Operator quality score', 'Optional human/operator quality score for future tuning labels.', 'score', 'number', 'avg', true, false, 'quality', true, jsonb_build_object('source', 'operator_optional')),
    ('quality.operator_label', 'quality', 'Operator quality label', 'Optional human/operator label for future tuning labels.', null, 'text', 'latest', null, false, 'quality', true, jsonb_build_object('source', 'operator_optional'))
ON CONFLICT (metric_key) DO UPDATE
SET
    namespace = EXCLUDED.namespace,
    display_name = EXCLUDED.display_name,
    description = EXCLUDED.description,
    unit = EXCLUDED.unit,
    value_type = EXCLUDED.value_type,
    aggregation_default = EXCLUDED.aggregation_default,
    higher_is_better = EXCLUDED.higher_is_better,
    privacy_safe = EXCLUDED.privacy_safe,
    source_layer = EXCLUDED.source_layer,
    active = EXCLUDED.active,
    metadata_json = EXCLUDED.metadata_json;

INSERT INTO core.applied_migrations (
    migration_id,
    migration_file,
    description,
    metadata_json
)
VALUES (
    '010_final_phase_1_5_schema',
    'db/migrations/010_final_phase_1_5_schema.sql',
    'Create final Phase 1.5 packet-native local_llm/eval schema and postgres_fts foundation.',
    jsonb_build_object(
        'schemas', jsonb_build_array('local_llm', 'eval'),
        'local_llm_tables', jsonb_build_array(
            'corpora',
            'sources',
            'documents',
            'chunks',
            'sessions'
        ),
        'eval_tables', jsonb_build_array(
            'turn_packets',
            'turn_attempts',
            'turn_events',
            'turn_content_refs',
            'turn_artifacts',
            'metric_registry',
            'turn_metric_facts',
            'packet_groups',
            'packet_group_members'
        ),
        'retrieval_method', 'postgres_fts',
        'search_config', 'simple',
        'old_schema_form_preserved', false,
        'old_run_evidence_tables_active', false,
        'old_eval_report_tables_active', false,
        'model_runtime_schema_active', false,
        'vector_behavior_active', false
    )
)
ON CONFLICT (migration_id) DO UPDATE
SET
    last_verified_at = now(),
    metadata_json = EXCLUDED.metadata_json;

INSERT INTO core.schema_version (
    component,
    version_label,
    phase,
    status,
    metadata_json
)
VALUES
    (
        'local_llm_schema',
        'phase_1_5_packet_native_local_llm_v1',
        'phase_1_5',
        'active',
        jsonb_build_object(
            'active_tables', jsonb_build_array(
                'local_llm.corpora',
                'local_llm.sources',
                'local_llm.documents',
                'local_llm.chunks',
                'local_llm.sessions'
            ),
            'retrieval_method', 'postgres_fts',
            'old_run_evidence_form_active', false
        )
    ),
    (
        'eval_schema',
        'phase_1_5_turn_packet_eval_v1',
        'phase_1_5',
        'active',
        jsonb_build_object(
            'active_tables', jsonb_build_array(
                'eval.turn_packets',
                'eval.turn_attempts',
                'eval.turn_events',
                'eval.turn_content_refs',
                'eval.turn_artifacts',
                'eval.metric_registry',
                'eval.turn_metric_facts',
                'eval.packet_groups',
                'eval.packet_group_members'
            ),
            'old_eval_report_form_active', false,
            'packet_native', true
        )
    )
ON CONFLICT (component) DO UPDATE
SET
    version_label = EXCLUDED.version_label,
    phase = EXCLUDED.phase,
    status = EXCLUDED.status,
    updated_at = now(),
    metadata_json = EXCLUDED.metadata_json;

INSERT INTO core.boot_checks (
    check_name,
    check_value,
    metadata_json
)
VALUES (
    'phase_1_5_final_schema_created',
    'ok',
    jsonb_build_object(
        'migration', '010_final_phase_1_5_schema',
        'packet_native', true,
        'old_schema_form_preserved', false
    )
)
ON CONFLICT (check_name) DO UPDATE
SET
    last_verified_at = now(),
    check_value = EXCLUDED.check_value,
    metadata_json = EXCLUDED.metadata_json;