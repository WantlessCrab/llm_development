from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db" / "migrations" / "010_final_phase_1_5_schema.sql"

FINAL_LOCAL_LLM_TABLES = ("corpora", "sources", "documents", "chunks", "sessions")
FINAL_EVAL_TABLES = (
    "turn_packets",
    "turn_attempts",
    "turn_events",
    "turn_content_refs",
    "turn_artifacts",
    "metric_registry",
    "turn_metric_facts",
    "packet_groups",
    "packet_group_members",
)

FORBIDDEN_TABLE_PATTERNS = (
    "local_llm.runs",
    "local_llm.run_retrievals",
    "local_llm.run_artifacts",
    "local_llm.turns",
    "eval.evidence_batches",
    "eval.comparison_groups",
    "eval.eval_reports",
    "eval.eval_metrics",
    "eval.eval_artifacts",
    "model_runtime.runtime_snapshots",
    "model_runtime.model_files",
    "model_runtime.runtime_artifacts",
)

REQUIRED_PACKET_FACETS = (
    "config_snapshot_json",
    "request_summary_json",
    "search_observation_json",
    "retrieval_summary_json",
    "context_summary_json",
    "prompt_summary_json",
    "provider_summary_json",
    "runtime_links_json",
    "privacy_json",
    "manifest_json",
    "error_json",
    "metadata_json",
)

REQUIRED_EVENTS = (
    "request_received",
    "plan_resolved",
    "rag_directives_resolved",
    "privacy_policy_resolved",
    "retrieval_started",
    "retrieval_completed",
    "retrieval_candidates_ranked",
    "context_built",
    "prompt_built",
    "provider_started",
    "provider_completed",
    "provider_exposed_reasoning_captured",
    "content_refs_written",
    "artifacts_written",
    "metrics_written",
    "runtime_evidence_captured",
    "group_membership_attached",
    "manifest_finalized",
    "packet_finalized",
    "failed",
)

REQUIRED_CONTENT_ROLES = (
    "user_input",
    "retrieval_query",
    "retrieved_chunk_snapshot",
    "context_text",
    "prompt_messages",
    "provider_request",
    "provider_raw_response",
    "provider_exposed_reasoning",
    "assistant_response",
    "diagnostics",
    "packet_summary",
)

FINAL_SOURCE_KINDS = (
    "respond",
    "session_turn",
    "experiment_replicate",
    "router_handoff",
    "backfill_import",
)


def read_sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def normalize_sql(sql: str) -> str:
    return re.sub(r"\s+", " ", sql)


def constraint_body(sql: str, start_marker: str, end_marker: str) -> str:
    start = sql.index(start_marker)
    end = sql.index(end_marker, start)
    return sql[start:end]


def assert_sql_index_on(sql: str, index_name: str, table_name: str,
                        columns: tuple[str, ...]) -> None:
    column_pattern = r"\s*,\s*".join(re.escape(column) for column in columns)
    pattern = rf"CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+{re.escape(index_name)}\s+ON\s+{re.escape(table_name)}\s*\(\s*{column_pattern}\s*\)"
    assert re.search(pattern, sql, flags=re.IGNORECASE), index_name


def test_final_schema_migration_exists() -> None:
    assert MIGRATION.exists()


def test_final_schema_sql_tokens_are_not_corrupted() -> None:
    sql = read_sql()

    forbidden_patterns = (
        r"'\[\]'\s*:\s+:\s*jsonb",
        r"'\{\}'\s*:\s+:\s*jsonb",
        r"gen_random_uuid\s*\(\s*\)\s*:\s+:\s*text",
        r"metric_json\s*<>\s*'\{\}'\s*:\s+:\s*jsonb",
    )

    for pattern in forbidden_patterns:
        assert not re.search(pattern, sql, flags=re.IGNORECASE | re.MULTILINE), pattern


def test_final_local_llm_substrate_tables_are_created() -> None:
    sql = read_sql()

    for table_name in FINAL_LOCAL_LLM_TABLES:
        assert f"CREATE TABLE IF NOT EXISTS local_llm.{table_name}" in sql


def test_final_eval_packet_tables_are_created() -> None:
    sql = read_sql()

    for table_name in FINAL_EVAL_TABLES:
        assert f"CREATE TABLE IF NOT EXISTS eval.{table_name}" in sql


def test_forbidden_legacy_tables_are_not_created() -> None:
    sql = read_sql()

    for table_name in FORBIDDEN_TABLE_PATTERNS:
        assert f"CREATE TABLE IF NOT EXISTS {table_name}" not in sql
        assert f"CREATE TABLE {table_name}" not in sql
        assert f"ALTER TABLE {table_name}" not in sql


def test_old_eval_views_are_not_created() -> None:
    sql = read_sql()

    assert "CREATE OR REPLACE VIEW" not in sql
    assert "CREATE VIEW" not in sql

    for view_name in (
            "eval.report_summary_v",
            "eval.run_capture_summary_v",
            "eval.privacy_capture_summary_v",
            "eval.model_runtime_summary_v",
            "eval.tuning_comparison_v",
    ):
        assert view_name not in sql


def test_turn_packets_has_identity_and_idempotency_fields() -> None:
    sql = read_sql()

    for column_name in (
            "turn_packet_id",
            "request_id",
            "idempotency_key",
            "idempotency_scope_hash",
            "source_kind",
            "source_system",
            "source_record_id",
    ):
        assert column_name in sql

    assert "turn_packets_idempotency_scope_required" in sql
    assert "CREATE UNIQUE INDEX IF NOT EXISTS uq_turn_packets_idempotency" in sql
    assert_sql_index_on(
        sql,
        "uq_turn_packets_idempotency",
        "eval.turn_packets",
        ("source_kind", "idempotency_key", "idempotency_scope_hash"),
    )
    assert "WHERE idempotency_key IS NOT NULL" in sql
    assert "idx_turn_packets_source_record" in sql


def test_turn_packets_source_kind_excludes_retry() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT turn_packets_source_kind_valid",
                           "CONSTRAINT turn_packets_status_valid")

    for source_kind in FINAL_SOURCE_KINDS:
        assert f"'{source_kind}'" in body

    assert "'retry'" not in body


def test_turn_packets_jsonb_facets_have_object_checks() -> None:
    sql = read_sql()

    for column_name in REQUIRED_PACKET_FACETS:
        assert column_name in sql
        check_name = f"turn_packets_{column_name.removesuffix('_json')}_is_object"
        assert check_name in sql
        assert re.search(
            rf"jsonb_typeof\s*\(\s*{re.escape(column_name)}\s*\)\s*=\s*'object'",
            sql,
            flags=re.IGNORECASE,
        )


def test_turn_attempts_distinguish_retries_from_replicates() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT turn_attempts_kind_valid",
                           "CONSTRAINT turn_attempts_status_valid")
    normalized = normalize_sql(sql)

    for attempt_kind in ("primary", "retry", "repair", "import"):
        assert f"'{attempt_kind}'" in body

    assert "COMMENT ON TABLE eval.turn_attempts" in normalized
    assert "Attempts are not experiment replicates" in normalized
    assert "uq_turn_attempts_packet_index" in sql
    assert "uq_turn_attempts_one_primary" in sql
    assert "turn_attempts_primary_kind_consistent" in sql
    assert "turn_attempts_primary_index_consistent" in sql


def test_turn_events_capture_required_timeline_vocabulary() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT turn_events_name_valid",
                           "CONSTRAINT turn_events_status_valid")

    for event_name in REQUIRED_EVENTS:
        assert f"'{event_name}'" in body

    assert "uq_turn_events_packet_order" in sql
    assert "idx_turn_events_name_status" in sql


def test_turn_content_refs_support_all_required_roles_and_storage_modes() -> None:
    sql = read_sql()
    role_body = constraint_body(sql, "CONSTRAINT turn_content_refs_role_valid",
                                "CONSTRAINT turn_content_refs_storage_kind_valid")
    owner_body = constraint_body(sql, "CONSTRAINT turn_content_refs_owner_type_valid",
                                 "CONSTRAINT turn_content_refs_role_valid")

    for role in REQUIRED_CONTENT_ROLES:
        assert f"'{role}'" in role_body

    for owner_type in ("packet", "attempt", "event", "search", "retrieval", "context", "prompt",
                       "provider", "artifact"):
        assert f"'{owner_type}'" in owner_body

    for storage_kind in ("inline_text", "file_ref", "redacted_inline", "redacted_file", "omitted",
                         "non_text_file"):
        assert f"'{storage_kind}'" in sql

    assert "turn_content_refs_privacy_body_absent" in sql


def test_turn_artifacts_remain_filesystem_backed_refs() -> None:
    sql = read_sql()

    assert "CREATE TABLE IF NOT EXISTS eval.turn_artifacts" in sql
    for column_name in ("path", "sha256", "size_bytes", "mime_type", "payload_policy"):
        assert column_name in sql

    for fragment in (" BYTEA", " BLOB", "raw_body", "artifact_body", "file_bytes"):
        assert fragment.lower() not in sql.lower()


def test_final_schema_keeps_postgres_fts_not_vector_behavior() -> None:
    sql = read_sql()
    normalized = normalize_sql(sql)

    assert "search_vector tsvector GENERATED ALWAYS AS" in sql
    assert "to_tsvector('simple', text)" in normalized
    assert "idx_chunks_search_vector" in sql
    assert "CREATE TABLE IF NOT EXISTS eval.embedding" not in sql
    assert "CREATE TABLE IF NOT EXISTS local_llm.embedding" not in sql
    assert "USING hnsw" not in sql.lower()
    assert "USING ivfflat" not in sql.lower()
    assert "vector_l2_ops" not in sql


def test_migration_records_itself_and_final_schema_versions() -> None:
    sql = read_sql()

    assert "INSERT INTO core.applied_migrations" in sql
    assert "'010_final_phase_1_5_schema'" in sql
    assert "'db/migrations/010_final_phase_1_5_schema.sql'" in sql
    assert "'local_llm_schema'" in sql
    assert "'eval_schema'" in sql
    assert "'phase_1_5_final_schema_created'" in sql