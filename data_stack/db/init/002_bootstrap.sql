-- data_stack/db/init/002_bootstrap.sql
--
-- Phase 1.5 packet-native foundation bootstrap.
--
-- This file owns only durable database metadata and concern-level schemas.
-- The final active application/retrieval/packet schema is created by:
--
--   data_stack/db/migrations/010_final_phase_1_5_schema.sql
--
-- Final active schemas:
--   core       database metadata, migration records, boot checks, schema version facts
--   local_llm  corpus/source/document/chunk/session substrate
--   eval       TurnPacket spine, packet groups, metrics, content refs, artifact refs
--
-- Not active in Phase 1.5:
--   model_runtime schema
--   old eval report catalog
--   old eval metric/artifact tables
--   old comparison-group forms
--   old run/retrieval/artifact evidence tables

DO
$$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'pgcrypto'
    ) THEN
        RAISE EXCEPTION 'Required extension missing: pgcrypto';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_extension
        WHERE extname = 'vector'
    ) THEN
        RAISE EXCEPTION 'Required extension missing: vector';
    END IF;
END;
$$;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS local_llm;
CREATE SCHEMA IF NOT EXISTS eval;

COMMENT ON SCHEMA core IS
    'Phase 1.5 packet-native database metadata: schema versioning, migration records, boot checks, and shared audit primitives.';

COMMENT ON SCHEMA local_llm IS
    'Phase 1.5 active local_llm app/retrieval foundation: corpus, source, document, chunk, postgres_fts, and session identity records.';

COMMENT ON SCHEMA eval IS
    'Phase 1.5 packet-native evaluation and tuning foundation: TurnPackets, attempts, events, content refs, artifact refs, metrics, packet groups, and projections.';

CREATE TABLE IF NOT EXISTS core.schema_version
(
    component TEXT PRIMARY KEY,
    version_label TEXT NOT NULL,
    phase TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT schema_version_component_not_blank CHECK (btrim(component) <> ''),
    CONSTRAINT schema_version_label_not_blank CHECK (btrim(version_label) <> ''),
    CONSTRAINT schema_version_phase_not_blank CHECK (btrim(phase) <> ''),
    CONSTRAINT schema_version_status_valid CHECK (status IN ('active', 'retired', 'superseded')),
    CONSTRAINT schema_version_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE core.schema_version IS
    'Current schema/foundation version markers for the llm_database PostgreSQL authority.';

CREATE TABLE IF NOT EXISTS core.applied_migrations
(
    migration_id TEXT PRIMARY KEY,
    migration_file TEXT NOT NULL,
    description TEXT NOT NULL,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by TEXT NOT NULL DEFAULT current_user,
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT applied_migrations_id_not_blank CHECK (btrim(migration_id) <> ''),
    CONSTRAINT applied_migrations_file_not_blank CHECK (btrim(migration_file) <> ''),
    CONSTRAINT applied_migrations_description_not_blank CHECK (btrim(description) <> ''),
    CONSTRAINT applied_migrations_applied_by_not_blank CHECK (btrim(applied_by) <> ''),
    CONSTRAINT applied_migrations_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE core.applied_migrations IS
    'Auditable record of active SQL bootstrap and migration files applied to the llm_database database.';

CREATE TABLE IF NOT EXISTS core.boot_checks
(
    check_name TEXT PRIMARY KEY,
    check_value TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_verified_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT boot_checks_name_not_blank CHECK (btrim(check_name) <> ''),
    CONSTRAINT boot_checks_value_not_blank CHECK (btrim(check_value) <> ''),
    CONSTRAINT boot_checks_metadata_is_object CHECK (jsonb_typeof(metadata_json) = 'object')
);

COMMENT ON TABLE core.boot_checks IS
    'Small durable rows used to prove database initialization and persistence across container restart/down-up cycles.';

CREATE INDEX IF NOT EXISTS idx_schema_version_status
    ON core.schema_version(status);

CREATE INDEX IF NOT EXISTS idx_applied_migrations_applied_at
    ON core.applied_migrations(applied_at);

CREATE INDEX IF NOT EXISTS idx_boot_checks_created_at
    ON core.boot_checks(created_at);

INSERT INTO core.applied_migrations (
    migration_id,
    migration_file,
    description,
    metadata_json
)
VALUES
    (
        '001_extensions',
        'db/init/001_extensions.sql',
        'Create required Phase 1.5 PostgreSQL extensions: pgcrypto required, vector inert/future foundation only.',
        jsonb_build_object(
            'pgcrypto_extversion', (SELECT extversion FROM pg_extension WHERE extname = 'pgcrypto'),
            'vector_extversion', (SELECT extversion FROM pg_extension WHERE extname = 'vector'),
            'vector_status', 'installed_inert_future_foundation',
            'active_vector_behavior', false
        )
    ),
    (
        '002_bootstrap',
        'db/init/002_bootstrap.sql',
        'Create Phase 1.5 packet-native schemas and foundation metadata tables.',
        jsonb_build_object(
            'schemas', jsonb_build_array('core', 'local_llm', 'eval'),
            'database', current_database(),
            'server_version', current_setting('server_version'),
            'server_version_num', current_setting('server_version_num'),
            'legacy_schema_form_preserved', false
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
VALUES (
    'data_stack',
    'phase_1_5_packet_native_bootstrap_v1',
    'phase_1_5',
    'active',
    jsonb_build_object(
        'database_authority', 'PostgreSQL',
        'database_name', current_database(),
        'active_schemas', jsonb_build_array('core', 'local_llm', 'eval'),
        'required_extensions', jsonb_build_array('pgcrypto'),
        'installed_inert_extensions', jsonb_build_array('vector'),
        'legacy_schema_form_preserved', false,
        'old_eval_report_form_active', false,
        'old_run_evidence_form_active', false,
        'server_version', current_setting('server_version'),
        'server_version_num', current_setting('server_version_num')
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
    'phase_1_5_bootstrap_created',
    'ok',
    jsonb_build_object(
        'database', current_database(),
        'created_by', current_user,
        'purpose', 'prove Phase 1.5 packet-native foundation initialization and persistence'
    )
)
ON CONFLICT (check_name) DO UPDATE
SET
    last_verified_at = now(),
    check_value = EXCLUDED.check_value,
    metadata_json = EXCLUDED.metadata_json;