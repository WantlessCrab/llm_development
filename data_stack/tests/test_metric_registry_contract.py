from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "db" / "migrations" / "010_final_phase_1_5_schema.sql"

REQUIRED_METRIC_KEYS = (
    "latency.total_ms",
    "latency.retrieval_ms",
    "latency.context_build_ms",
    "latency.prompt_build_ms",
    "latency.provider_ms",
    "latency.artifact_write_ms",
    "tokens.prompt",
    "tokens.completion",
    "tokens.total",
    "chars.user_input",
    "chars.context",
    "chars.prompt",
    "chars.response",
    "search.candidate_count",
    "search.returned_count",
    "search.included_count",
    "search.top_k_requested",
    "retrieval.returned_count",
    "retrieval.included_count",
    "retrieval.unique_source_count",
    "retrieval.unique_document_count",
    "context.truncated",
    "context.char_count",
    "provider.finish_reason",
    "provider.prompt_per_second",
    "provider.completion_per_second",
    "artifact.count",
    "warnings.count",
    "privacy.text_persisted",
    "privacy.metadata_redacted",
    "quality.operator_score",
    "quality.operator_label",
)


def read_sql() -> str:
    return MIGRATION.read_text(encoding="utf-8")


def normalize_sql(sql: str) -> str:
    return re.sub(r"\s+", " ", sql)


def constraint_body(sql: str, start_marker: str, end_marker: str) -> str:
    start = sql.index(start_marker)
    end = sql.index(end_marker, start)
    return sql[start:end]


def test_metric_registry_and_fact_tables_exist() -> None:
    sql = read_sql()

    assert "CREATE TABLE IF NOT EXISTS eval.metric_registry" in sql
    assert "CREATE TABLE IF NOT EXISTS eval.turn_metric_facts" in sql
    assert "CREATE TABLE IF NOT EXISTS eval.eval_metrics" not in sql
    assert "ALTER TABLE eval.eval_metrics" not in sql


def test_metric_registry_has_required_definition_columns_and_constraints() -> None:
    sql = read_sql()

    for column_name in (
            "metric_key",
            "namespace",
            "display_name",
            "description",
            "unit",
            "value_type",
            "aggregation_default",
            "higher_is_better",
            "privacy_safe",
            "source_layer",
            "active",
            "metadata_json",
    ):
        assert column_name in sql

    assert "metric_registry_value_type_valid" in sql
    assert "metric_registry_aggregation_valid" in sql
    assert "metric_registry_source_layer_valid" in sql


def test_metric_fact_table_is_registry_backed() -> None:
    sql = read_sql()

    assert re.search(
        r"metric_key\s+TEXT\s+NOT\s+NULL\s+REFERENCES\s+eval\.metric_registry\s*\(\s*metric_key\s*\)",
        sql,
        flags=re.IGNORECASE,
    )
    assert "turn_metric_facts_value_present" in sql
    assert "idx_turn_metric_facts_metric_key" in sql
    assert "idx_turn_metric_facts_owner" in sql
    assert "idx_turn_metric_facts_privacy_safe" in sql


def test_metric_fact_owner_type_includes_search() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT turn_metric_facts_owner_type_valid",
                           "CONSTRAINT turn_metric_facts_source_valid")

    for owner_type in (
            "packet",
            "attempt",
            "event",
            "search",
            "retrieval",
            "context",
            "prompt",
            "provider",
            "artifact",
            "group",
            "session",
    ):
        assert f"'{owner_type}'" in body


def test_metric_sources_use_operator_not_quality() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT turn_metric_facts_source_valid",
                           "CONSTRAINT turn_metric_facts_json_is_object")

    for source in ("derived", "provider", "runtime", "recorder", "projection", "operator"):
        assert f"'{source}'" in body

    assert "'quality'" not in body


def test_registry_source_layer_allows_quality_namespace() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT metric_registry_source_layer_valid",
                           "CONSTRAINT metric_registry_metadata_is_object")

    assert "'quality'" in body


def test_required_seed_metric_keys_are_present() -> None:
    sql = read_sql()

    for metric_key in REQUIRED_METRIC_KEYS:
        assert f"'{metric_key}'" in sql


def test_search_and_retrieval_metrics_are_both_seeded() -> None:
    sql = read_sql()

    for metric_key in (
            "search.candidate_count",
            "search.returned_count",
            "search.included_count",
            "search.top_k_requested",
            "retrieval.returned_count",
            "retrieval.included_count",
            "retrieval.unique_source_count",
            "retrieval.unique_document_count",
    ):
        assert f"'{metric_key}'" in sql


def test_aggregation_defaults_match_contract_domain() -> None:
    sql = read_sql()
    body = constraint_body(sql, "CONSTRAINT metric_registry_aggregation_valid",
                           "CONSTRAINT metric_registry_source_layer_valid")

    for aggregation in ("avg", "sum", "min", "max", "count", "latest", "none"):
        assert f"'{aggregation}'" in body


def test_metric_discovery_indexes_exist() -> None:
    sql = read_sql()

    for index_name in (
            "idx_metric_registry_namespace",
            "idx_metric_registry_active",
            "idx_metric_registry_privacy_safe",
    ):
        assert index_name in sql


def test_quality_operator_metrics_are_optional_and_not_privacy_safe_by_default() -> None:
    sql = normalize_sql(read_sql()).lower()

    assert "'quality.operator_score'" in sql
    assert "'quality.operator_label'" in sql
    assert "jsonb_build_object('source', 'operator_optional')" in sql
    assert "'quality.operator_score', 'quality', 'operator quality score'" in sql