from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db" / "migrations" / "010_final_phase_1_5_schema.sql"


def read_sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def normalize_sql(sql: str) -> str:
    return re.sub(r"\s+", " ", sql)


def constraint_body(sql: str, start_marker: str, end_marker: str) -> str:
    start = sql.index(start_marker)
    end = sql.index(end_marker, start)
    return sql[start:end]


def test_turn_packet_privacy_state_is_explicit() -> None:
    sql = read_sql()

    for column_name in (
            "capture_mode",
            "privacy_level",
            "text_persisted",
            "metadata_redacted",
            "redaction_policy_version",
            "privacy_json",
    ):
        assert column_name in sql

    assert "turn_packets_capture_mode_valid" in sql
    assert "turn_packets_privacy_level_valid" in sql
    assert "turn_packets_capture_privacy_consistent" in sql
    assert "turn_packets_redaction_version_consistent" in sql


def test_turn_packet_privacy_requires_no_text_persistence_and_metadata_redaction() -> None:
    sql = normalize_sql(read_sql())

    assert "capture_mode = 'privacy'" in sql
    assert "privacy_level IN ('standard', 'strict')" in sql
    assert "text_persisted = false" in sql
    assert "metadata_redacted = true" in sql
    assert "redaction_policy_version IS NOT NULL" in sql


def test_content_refs_have_privacy_policy_fields_and_constraints() -> None:
    sql = read_sql()
    normalized = normalize_sql(sql)

    for column_name in (
            "capture_mode",
            "privacy_level",
            "body_persisted",
            "metadata_redacted",
            "payload_policy",
    ):
        assert column_name in sql

    assert "turn_content_refs_capture_privacy_consistent" in sql
    assert "turn_content_refs_privacy_body_absent" in sql
    assert "body_persisted = false" in normalized

    body = constraint_body(sql, "CONSTRAINT turn_content_refs_payload_policy_valid",
                           "CONSTRAINT turn_content_refs_size_nonnegative")
    for policy in ("redacted_body", "omitted_body", "non_text_body"):
        assert f"'{policy}'" in body


def test_content_refs_privacy_mode_cannot_store_body_text() -> None:
    sql = read_sql()
    body = constraint_body(
        sql,
        "CONSTRAINT turn_content_refs_privacy_body_absent",
        "CONSTRAINT turn_content_refs_metadata_is_object",
    )
    normalized = normalize_sql(body)

    assert "capture_mode <> 'privacy'" in normalized
    assert "body_text IS NULL" in normalized


def test_content_refs_omitted_storage_has_no_body_or_path() -> None:
    sql = normalize_sql(read_sql())

    assert "turn_content_refs_omitted_has_no_body" in sql
    assert "body_text IS NULL" in sql
    assert "file_path IS NULL" in sql
    assert "body_persisted = false" in sql


def test_artifact_refs_have_body_policy_and_privacy_constraints() -> None:
    sql = read_sql()
    normalized = normalize_sql(sql)

    assert "CREATE TABLE IF NOT EXISTS eval.turn_artifacts" in sql
    assert "turn_artifacts_capture_privacy_consistent" in sql
    assert "body_persisted = false" in normalized

    body = constraint_body(sql, "CONSTRAINT turn_artifacts_payload_policy_valid",
                           "CONSTRAINT turn_artifacts_capture_mode_valid")
    for policy in ("redacted_body", "omitted_body", "non_text_body"):
        assert f"'{policy}'" in body


def test_metric_facts_have_privacy_safe_flag() -> None:
    sql = read_sql()

    assert "CREATE TABLE IF NOT EXISTS eval.turn_metric_facts" in sql
    assert "privacy_safe BOOLEAN NOT NULL" in sql
    assert "idx_turn_metric_facts_privacy_safe" in sql


def test_packet_group_metadata_is_structured_for_privacy_auditing() -> None:
    sql = read_sql()

    assert "packet_groups_metadata_is_object" in sql
    assert "packet_group_members_metadata_is_object" in sql
    assert "privacy_policy_json" in sql
    assert "packet_groups_privacy_policy_is_object" in sql


def test_privacy_metric_seed_rows_exist() -> None:
    sql = read_sql()

    for metric_key in ("privacy.text_persisted", "privacy.metadata_redacted"):
        assert f"'{metric_key}'" in sql


def test_legacy_privacy_capture_columns_are_not_recreated() -> None:
    sql = read_sql()

    for fragment in (
            "identity_persisted",
            "original_identity_hmac",
            "artifact_payload_policy",
            "runs_text_privacy_consistent",
            "turns_text_privacy_consistent",
            "run_retrievals_identity_privacy_consistent",
            "eval_reports_text_privacy_consistent",
            "runtime_artifacts_body_privacy_consistent",
    ):
        assert fragment not in sql


def test_no_legacy_privacy_tables_are_required() -> None:
    sql = read_sql()

    for table_name in (
            "local_llm.runs",
            "local_llm.run_retrievals",
            "local_llm.run_artifacts",
            "local_llm.turns",
            "eval.eval_reports",
            "eval.eval_artifacts",
            "model_runtime.runtime_snapshots",
            "model_runtime.model_files",
    ):
        assert f"ALTER TABLE {table_name}" not in sql
        assert f"CREATE TABLE IF NOT EXISTS {table_name}" not in sql


def test_privacy_projection_can_be_supported_without_old_views() -> None:
    sql = read_sql()

    for required_surface in (
            "eval.turn_packets",
            "eval.turn_content_refs",
            "eval.turn_artifacts",
            "eval.turn_metric_facts",
            "eval.packet_groups",
            "eval.packet_group_members",
    ):
        assert required_surface in sql

    assert "CREATE OR REPLACE VIEW eval.privacy_capture_summary_v" not in sql
    assert "CREATE OR REPLACE VIEW eval.report_summary_v" not in sql