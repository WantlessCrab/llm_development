from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db" / "migrations" / "010_final_phase_1_5_schema.sql"

GROUP_KINDS = (
    "experiment",
    "condition",
    "analysis_collection",
    "session_comparison",
    "manual_packet_set",
    "workflow_scope",
    "model_scope",
    "rag_scope",
    "prompt_scope",
    "privacy_scope",
)

MEMBER_TYPES = (
    "turn_packet",
    "session",
    "turn",
    "workflow",
    "model_profile",
    "rag_profile",
    "prompt_profile",
    "privacy_mode",
    "manual_filter",
)

MEMBER_ROLES = (
    "baseline",
    "condition",
    "replicate",
    "analysis_member",
    "comparison_member",
    "excluded",
    "reference",
)


def read_sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def normalize_sql(sql: str) -> str:
    return re.sub(r"\s+", " ", sql)


def constraint_body(sql: str, start_marker: str, end_marker: str) -> str:
    start = sql.index(start_marker)
    end = sql.index(end_marker, start)
    return sql[start:end]


def assert_index_on(sql: str, index_name: str, table_name: str, columns: tuple[str, ...]) -> None:
    column_pattern = r"\s*,\s*".join(re.escape(column) for column in columns)
    pattern = rf"CREATE\s+(?:UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+{re.escape(index_name)}\s+ON\s+{re.escape(table_name)}\s*\(\s*{column_pattern}\s*\)"
    assert re.search(pattern, sql, flags=re.IGNORECASE), index_name


def test_packet_group_tables_exist_and_old_comparison_group_is_absent() -> None:
    sql = read_sql()

    assert "CREATE TABLE IF NOT EXISTS eval.packet_groups" in sql
    assert "CREATE TABLE IF NOT EXISTS eval.packet_group_members" in sql
    assert "CREATE TABLE IF NOT EXISTS eval.comparison_groups" not in sql
    assert "ALTER TABLE eval.comparison_groups" not in sql


def test_group_kind_domain_is_final_and_generic() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT packet_groups_kind_valid",
                           "CONSTRAINT packet_groups_label_not_blank")

    for group_kind in GROUP_KINDS:
        assert f"'{group_kind}'" in body

    for forbidden_kind in (
            "experiment_condition",
            "experiment_replicate",
            "analysis_member",
            "session_comparison_member",
    ):
        assert f"'{forbidden_kind}'" not in body


def test_condition_groups_require_experiment_parent_trigger() -> None:
    sql = read_sql()
    normalized = normalize_sql(sql)

    assert "packet_groups_condition_requires_parent" in sql
    assert "CREATE OR REPLACE FUNCTION eval.validate_packet_group_parent()" in sql
    assert "condition packet_group" in sql
    assert "parent must be group_kind=experiment" in sql
    assert "parent_kind IS DISTINCT FROM 'experiment'" in normalized
    assert "trg_validate_packet_group_parent" in sql


def test_member_type_domain_and_identity_constraints_are_strict() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT packet_group_members_type_valid",
                           "CONSTRAINT packet_group_members_role_valid")

    for member_type in MEMBER_TYPES:
        assert f"'{member_type}'" in body

    assert "packet_group_members_type_target_consistent" in sql
    assert "packet_group_members_member_identity_consistent" in sql


def test_member_role_domain_supports_experiments_and_analysis_without_extra_tables() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT packet_group_members_role_valid",
                           "CONSTRAINT packet_group_members_replicate_index_positive")

    for role in MEMBER_ROLES:
        assert f"'{role}'" in body

    assert "experiment_conditions" not in sql
    assert "experiment_replicates" not in sql
    assert "analysis_collection_members" not in sql


def test_replicate_membership_requires_packet_and_replicate_index() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT packet_group_members_replicate_requires_packet",
                           "CONSTRAINT packet_group_members_metadata_is_object")
    normalized = normalize_sql(body)

    assert "member_role <> 'replicate'" in normalized
    assert "turn_packet_id IS NOT NULL" in normalized
    assert "replicate_index IS NOT NULL" in normalized


def test_attempt_rows_cannot_substitute_for_replicates() -> None:
    sql = read_sql()
    replicate_body = constraint_body(sql,
                                     "CONSTRAINT packet_group_members_replicate_requires_packet",
                                     "CONSTRAINT packet_group_members_metadata_is_object")

    assert "turn_packet_id" in replicate_body
    assert "replicate_index" in replicate_body
    assert "turn_attempt_id IS NOT NULL" not in replicate_body


def test_included_replicate_uniqueness_is_protected() -> None:
    sql = read_sql()

    assert "uq_packet_group_members_included_replicate" in sql
    assert_index_on(sql, "uq_packet_group_members_included_replicate", "eval.packet_group_members",
                    ("packet_group_id", "replicate_index"))
    assert "member_role = 'replicate'" in sql
    assert "include_in_aggregate = true" in sql


def test_included_packet_role_duplication_is_protected() -> None:
    sql = read_sql()

    assert "uq_packet_group_members_included_packet_role" in sql
    assert_index_on(sql, "uq_packet_group_members_included_packet_role",
                    "eval.packet_group_members",
                    ("packet_group_id", "turn_packet_id", "member_role"))
    assert "turn_packet_id IS NOT NULL" in sql
    assert "include_in_aggregate = true" in sql


def test_exclusion_reason_required_for_aggregate_exclusion() -> None:
    sql = normalize_sql(read_sql())

    assert "packet_group_members_exclusion_reason_required" in sql
    assert "include_in_aggregate = true OR exclusion_reason IS NOT NULL" in sql


def test_packet_group_projection_support_exists_without_views() -> None:
    sql = read_sql()

    for index_name in (
            "idx_packet_groups_parent",
            "idx_packet_groups_kind",
            "idx_packet_groups_status",
            "idx_packet_groups_baseline",
            "idx_packet_group_members_group",
            "idx_packet_group_members_packet",
            "idx_packet_group_members_session",
            "idx_packet_group_members_type_member",
            "idx_packet_group_members_role",
    ):
        assert index_name in sql

    assert "CREATE OR REPLACE VIEW" not in sql