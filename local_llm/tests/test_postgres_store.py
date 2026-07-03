from __future__ import annotations

import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POSTGRES_STORE = ROOT / "src/local_llm/store/postgres_store.py"


def read_source() -> str:
    return POSTGRES_STORE.read_text(encoding="utf-8")


def normalized(value: str) -> str:
    compact = re.sub(r"\s+", " ", value).strip()
    compact = re.sub(r"\(\s+", "(", compact)
    compact = re.sub(r"\s+\)", ")", compact)
    return compact


def normalized_source() -> str:
    return normalized(read_source())


def sql_literals() -> str:
    tree = ast.parse(read_source())
    literals: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            value = node.value.strip()
            if value:
                literals.append(value)
    return "\n".join(literals)


def normalized_sql() -> str:
    return normalized(sql_literals())


def assert_sql_contains(fragment: str) -> None:
    assert normalized(fragment) in normalized_sql()


def assert_source_contains(fragment: str) -> None:
    assert normalized(fragment) in normalized_source()


def assert_no_sql_target(relation: str) -> None:
    escaped = re.escape(relation)
    pattern = rf"\b(?:FROM|JOIN|INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+{escaped}\b"
    assert not re.search(pattern, normalized_sql(), flags=re.IGNORECASE), relation


def test_postgres_store_uses_packet_native_tables_only():
    sql = normalized_sql()
    required_tables = [
        "eval.turn_packets",
        "eval.turn_attempts",
        "eval.turn_events",
        "eval.turn_content_refs",
        "eval.turn_artifacts",
        "eval.turn_metric_facts",
        "eval.packet_groups",
        "eval.packet_group_members",
    ]
    for table in required_tables:
        assert table in sql

    forbidden_targets = [
        "local_llm.runs",
        "local_llm.run_retrievals",
        "local_llm.run_artifacts",
        "eval.evidence_batches",
        "eval.comparison_groups",
        "eval.eval_reports",
        "eval.eval_metrics",
        "eval.eval_artifacts",
        "model_runtime.model_files",
        "model_runtime.runtime_artifacts",
        "model_runtime.runtime_snapshots",
    ]
    for relation in forbidden_targets:
        assert_no_sql_target(relation)


def test_postgres_store_targets_final_packet_columns():
    assert_sql_contains(
        """
        INSERT INTO eval.turn_events (event_id, turn_packet_id, turn_attempt_id, event_order,
                                      event_name, event_status, started_at, completed_at,
                                      latency_ms, payload_json, failure_json, privacy_safe)
        """
    )
    assert_sql_contains(
        """
        INSERT INTO eval.turn_content_refs (content_ref_id, turn_packet_id, turn_attempt_id,
                                            owner_type,
                                            owner_id, content_role, storage_kind, body_text,
                                            file_path, sha256, size_bytes, mime_type,
                                            capture_mode, privacy_level, body_persisted,
                                            metadata_redacted, payload_policy, metadata_json)
        """
    )
    assert_sql_contains(
        """
        INSERT INTO eval.turn_metric_facts (metric_fact_id, turn_packet_id, turn_attempt_id,
                                            owner_type,
                                            owner_id, metric_key, metric_value_num,
                                            metric_value_text,
                                            metric_json, unit, privacy_safe, source)
        """
    )

    source = read_source()
    assert "turn_event_id" not in source
    assert "event_index" not in source
    assert "turn_content_refs (content_ref_id, turn_packet_id, turn_attempt_id, owner_type, owner_id, role" not in source
    assert "turn_metric_facts" in source
    assert "metadata_json, unit, privacy_safe, source" not in source


def test_postgres_store_enforces_idempotency_lookup_before_insert():
    assert_source_contains("if turn_packet.idempotency_key:")
    assert_sql_contains(
        """
        SELECT *
        FROM eval.turn_packets
        WHERE source_kind = %s
          AND idempotency_key = %s
          AND idempotency_scope_hash = %s LIMIT 1
        """
    )
    assert_source_contains("return self._packet_summary_from_row")

    source = normalized_source()
    lookup_index = source.index("if turn_packet.idempotency_key:")
    insert_index = source.index("INSERT INTO eval.turn_packets")
    assert lookup_index < insert_index


def test_list_turn_packets_honors_packet_filters():
    for fragment in [
        "tp.session_id = %s",
        "tp.workflow_id = %s",
        "tp.capture_mode = %s",
        "packet_group_id = %s",
        "ORDER BY tp.created_at DESC LIMIT %s",
    ]:
        assert_source_contains(fragment)


def test_projection_supports_experiment_condition_rows():
    source = read_source()
    assert 'group_kind == "experiment"' in source
    assert_sql_contains("WHERE parent_group_id = %s")
    assert "condition_group_id" in source
    assert "condition_label" in source
    assert "GROUP BY {group_by}" in source


def test_postgres_store_exposes_session_packet_aggregate_helpers():
    source = read_source()
    assert "def next_turn_ordinal" in source
    assert "MAX(turn_ordinal)" in source
    assert "latest_turn_packet_id" in source
    assert "turn_count" in source


def test_packet_detail_includes_group_memberships():
    assert_sql_contains("JOIN eval.packet_groups pg ON pg.packet_group_id = pgm.packet_group_id")
    assert "groups=groups" in read_source()


def test_postgres_store_appends_operator_feedback_metric_facts_through_store_boundary():
    source = read_source()
    assert "def append_turn_metric_facts" in source
    assert "def _insert_turn_metric_fact" in source
    assert "quality.operator_score" not in source  # metric keys are caller-owned, store stays generic
    assert_sql_contains("SELECT 1 FROM eval.turn_packets WHERE turn_packet_id=%s")
    assert_sql_contains("RETURNING *")


def test_projection_exposes_latest_text_value_for_label_metrics():
    assert_sql_contains("latest_text_value")
    assert_sql_contains("array_agg(tmf.metric_value_text ORDER BY tmf.created_at DESC)")