from __future__ import annotations

import json
import os
from datetime import datetime
from typing import Any
from urllib.parse import urlsplit

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from local_llm.config import AppConfig, safe_database_label
from local_llm.contracts import (
    ContentLoadResponse,
    MetricAvailabilityResponse,
    MetricDefinitionResponse,
    PacketArtifactResponse,
    PacketAttemptResponse,
    PacketContentRefResponse,
    PacketDetailResponse,
    PacketEventResponse,
    PacketGroupRequest,
    PacketGroupResponse,
    PacketGroupMemberResponse,
    PacketListRequest,
    PacketListResponse,
    PacketMetricFactResponse,
    PacketSummaryEnvelope,
    ProjectionRequest,
    ProjectionResult,
    ProjectionTablePayload,
    RetrievalResult,
)
from local_llm.retrieval.postgres_fts import build_postgres_fts_or_query, \
    build_postgres_fts_query_shape, has_postgres_fts_query, normalize_postgres_fts_query
from local_llm.store.base import ActiveDocument

_FINAL_PHASE_1_5_MIGRATION_ID = "010_final_phase_1_5_schema"
_FINAL_PHASE_1_5_BOOT_CHECK = "phase_1_5_final_schema_created"
_FINAL_SCHEMA_COMPONENTS = {"data_stack", "local_llm_schema", "eval_schema"}

_REQUIRED_SCHEMAS = {"core", "local_llm", "eval"}
_REQUIRED_CORE_TABLES = {"schema_version", "applied_migrations", "boot_checks"}
_REQUIRED_LOCAL_TABLES = {"corpora", "sources", "documents", "chunks", "sessions"}
_REQUIRED_EVAL_TABLES = {
    "turn_packets",
    "turn_attempts",
    "turn_events",
    "turn_content_refs",
    "turn_artifacts",
    "metric_registry",
    "turn_metric_facts",
    "packet_groups",
    "packet_group_members",
}

_LEGACY_MIGRATION_IDS = {
    "010_local_llm_schema",
    "020_postgres_fts",
    "030_eval_runtime_catalog",
    "040_always_on_eval_capture",
    "050_turn_packet_core",
}

_FORBIDDEN_SCHEMAS = {"model_runtime"}
_FORBIDDEN_TABLES: dict[str, set[str]] = {
    "local_llm": {"runs", "run_retrievals", "run_artifacts", "turns"},
    "eval": {
        "evidence_batches",
        "comparison_groups",
        "eval_reports",
        "eval_metrics",
        "eval_artifacts",
    },
    "model_runtime": {"model_files", "runtime_artifacts", "runtime_snapshots"},
}
_FORBIDDEN_VIEWS: dict[str, set[str]] = {
    "eval": {
        "model_runtime_summary_v",
        "privacy_capture_summary_v",
        "report_summary_v",
        "run_capture_summary_v",
        "tuning_comparison_v",
    }
}


def _iso(value: Any) -> Any:
    return value.isoformat() if isinstance(value, datetime) else value


def _row(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {key: _iso(value) for key, value in dict(row).items()}


def _json(value: Any) -> Any:
    if value is None:
        return {}
    return value


class PostgresStore:
    def __init__(self, *, database_url: str, database_password_env: str):
        self.database_url = database_url
        self.database_password_env = database_password_env
        self.database_label = safe_database_label(database_url)

    @classmethod
    def from_config(cls, config: AppConfig) -> "PostgresStore":
        return cls(database_url=config.storage.database_url,
                   database_password_env=config.storage.database_password_env)

    def _connection_kwargs(self) -> dict[str, Any]:
        parts = urlsplit(self.database_url)
        password = os.environ.get(self.database_password_env)
        if not password:
            raise RuntimeError(
                f"required database password environment variable is unset: {self.database_password_env}")
        return {"dbname": parts.path.lstrip("/"), "user": parts.username, "password": password,
                "host": parts.hostname or "127.0.0.1", "port": parts.port or 5432,
                "row_factory": dict_row}

    def _connect(self) -> psycopg.Connection[dict[str, Any]]:
        return psycopg.connect(**self._connection_kwargs())

    def init(self) -> None:
        health = self.database_health()
        if not health.get("connected"):
            raise RuntimeError(str(health.get("error") or "PostgreSQL connection failed"))
        if not health.get("phase_1_5_schema_ready"):
            raise RuntimeError(f"PostgreSQL Phase 1.5 packet schema is not ready: {health}")

    def database_health(self) -> dict[str, Any]:
        try:
            with self._connect() as conn:
                schemas = {
                    row["schema_name"]
                    for row in conn.execute(
                        """
                        SELECT schema_name
                        FROM information_schema.schemata
                        WHERE schema_name IN ('core', 'local_llm', 'eval', 'model_runtime')
                        """
                    ).fetchall()
                }
                relation_rows = [
                    dict(row)
                    for row in conn.execute(
                        """
                        SELECT table_schema, table_name, table_type
                        FROM information_schema.tables
                        WHERE table_schema IN ('core', 'local_llm', 'eval', 'model_runtime')
                        ORDER BY table_schema, table_name
                        """
                    ).fetchall()
                ]
                core_tables = {
                    row["table_name"]
                    for row in relation_rows
                    if row["table_schema"] == "core" and row["table_type"] == "BASE TABLE"
                }
                local_tables = {
                    row["table_name"]
                    for row in relation_rows
                    if row["table_schema"] == "local_llm" and row["table_type"] == "BASE TABLE"
                }
                eval_tables = {
                    row["table_name"]
                    for row in relation_rows
                    if row["table_schema"] == "eval" and row["table_type"] == "BASE TABLE"
                }

                schema_versions: list[dict[str, Any]] = []
                migrations: list[dict[str, Any]] = []
                boot_checks: list[dict[str, Any]] = []

                core_metadata_tables_ready = _REQUIRED_CORE_TABLES <= core_tables
                if core_metadata_tables_ready:
                    schema_versions = [
                        dict(row)
                        for row in conn.execute(
                            """
                            SELECT component, version_label, phase, status
                            FROM core.schema_version
                            ORDER BY component
                            """
                        ).fetchall()
                    ]
                    migrations = [
                        dict(row)
                        for row in conn.execute(
                            """
                            SELECT migration_id, migration_file, applied_at, last_verified_at
                            FROM core.applied_migrations
                            ORDER BY migration_id
                            """
                        ).fetchall()
                    ]
                    boot_checks = [
                        dict(row)
                        for row in conn.execute(
                            """
                            SELECT check_name, check_value, created_at, last_verified_at
                            FROM core.boot_checks
                            ORDER BY check_name
                            """
                        ).fetchall()
                    ]

                search_vector = bool(
                    conn.execute(
                        """
                        SELECT 1
                        FROM information_schema.columns
                        WHERE table_schema = 'local_llm'
                          AND table_name = 'chunks'
                          AND column_name = 'search_vector'
                        """
                    ).fetchone()
                )
                search_index = bool(
                    conn.execute(
                        """
                        SELECT 1
                        FROM pg_indexes
                        WHERE schemaname = 'local_llm'
                          AND tablename = 'chunks'
                          AND indexname = 'idx_chunks_search_vector'
                        """
                    ).fetchone()
                )

            schema_versions_by_component = {row["component"]: row for row in schema_versions}
            migration_ids = {row["migration_id"] for row in migrations}
            boot_check_names = {row["check_name"] for row in boot_checks}

            missing_schemas = sorted(_REQUIRED_SCHEMAS - schemas)
            missing_core_tables = sorted(_REQUIRED_CORE_TABLES - core_tables)
            missing_local_tables = sorted(_REQUIRED_LOCAL_TABLES - local_tables)
            missing_eval_tables = sorted(_REQUIRED_EVAL_TABLES - eval_tables)

            forbidden_schemas = sorted(_FORBIDDEN_SCHEMAS & schemas)
            forbidden_tables: list[str] = []
            forbidden_views: list[str] = []
            for row in relation_rows:
                schema = row["table_schema"]
                table_name = row["table_name"]
                relation_name = f"{schema}.{table_name}"
                if row["table_type"] == "BASE TABLE" and table_name in _FORBIDDEN_TABLES.get(
                        schema, set()):
                    forbidden_tables.append(relation_name)
                if row["table_type"] == "VIEW" and table_name in _FORBIDDEN_VIEWS.get(
                        schema, set()):
                    forbidden_views.append(relation_name)

            legacy_migration_ids = sorted(_LEGACY_MIGRATION_IDS & migration_ids)
            final_migration_applied = _FINAL_PHASE_1_5_MIGRATION_ID in migration_ids
            final_boot_check_present = _FINAL_PHASE_1_5_BOOT_CHECK in boot_check_names
            final_schema_versions_ready = all(
                schema_versions_by_component.get(component, {}).get("phase") == "phase_1_5"
                and schema_versions_by_component.get(component, {}).get("status") == "active"
                for component in _FINAL_SCHEMA_COMPONENTS
            )
            postgres_fts_ready = bool(search_vector and search_index)
            packet_tables_ready = not missing_local_tables and not missing_eval_tables
            forbidden_objects = sorted(forbidden_schemas + forbidden_tables + forbidden_views)

            phase_1_5_schema_ready = all(
                [
                    not missing_schemas,
                    not missing_core_tables,
                    final_migration_applied,
                    final_boot_check_present,
                    final_schema_versions_ready,
                    not legacy_migration_ids,
                    not forbidden_objects,
                    packet_tables_ready,
                    postgres_fts_ready,
                ]
            )

            return {
                "backend": "postgres",
                "database_label": self.database_label,
                "connected": True,
                "required_schemas": {schema: schema in schemas for schema in
                                     sorted(_REQUIRED_SCHEMAS)},
                "missing_schemas": missing_schemas,
                "core_metadata_tables_ready": core_metadata_tables_ready,
                "missing_core_tables": missing_core_tables,
                "schema_versions": [_row(row) for row in schema_versions],
                "schema_version_components": sorted(schema_versions_by_component),
                "final_schema_versions_ready": final_schema_versions_ready,
                "applied_migration_ids": sorted(migration_ids),
                "final_migration_applied": final_migration_applied,
                "legacy_migration_ids": legacy_migration_ids,
                "boot_check_names": sorted(boot_check_names),
                "final_boot_check_present": final_boot_check_present,
                "missing_local_tables": missing_local_tables,
                "missing_eval_tables": missing_eval_tables,
                "packet_tables_ready": packet_tables_ready,
                "search_vector_column_ready": bool(search_vector),
                "search_vector_index_ready": bool(search_index),
                "postgres_fts_ready": postgres_fts_ready,
                "model_runtime_active": "model_runtime" in schemas,
                "forbidden_schemas": forbidden_schemas,
                "forbidden_tables": sorted(forbidden_tables),
                "forbidden_views": sorted(forbidden_views),
                "forbidden_objects": forbidden_objects,
                "legacy_schema_active": bool(legacy_migration_ids or forbidden_objects),
                "phase_1_5_schema_ready": phase_1_5_schema_ready,
                "packet_schema_ready": phase_1_5_schema_ready,
            }
        except Exception as exc:
            return {
                "backend": "postgres",
                "database_label": self.database_label,
                "connected": False,
                "error": str(exc),
                "phase_1_5_schema_ready": False,
                "packet_schema_ready": False,
                "postgres_fts_ready": False,
            }

    def summary(self) -> dict[str, int]:
        with self._connect() as conn:
            counts = {}
            for key, table in {"sources": "local_llm.sources", "documents": "local_llm.documents",
                               "chunks": "local_llm.chunks", "sessions": "local_llm.sessions",
                               "turn_packets": "eval.turn_packets",
                               "packet_groups": "eval.packet_groups"}.items():
                counts[key] = int(
                    conn.execute(f"SELECT count(*) AS c FROM {table}").fetchone()["c"])
            return counts

    def get_active_document_for_source(self, source_id: str) -> ActiveDocument | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT document_id, file_hash FROM local_llm.documents WHERE source_id=%s AND is_active ORDER BY indexed_at DESC LIMIT 1",
                (source_id,)).fetchone()
        return ActiveDocument(**row) if row else None

    def upsert_document_with_chunks(self, *, source: dict[str, Any], document: dict[str, Any],
                                    chunks: list[dict[str, Any]]) -> None:
        with self._connect() as conn:
            with conn.transaction():
                conn.execute("""
                             INSERT INTO local_llm.corpora (corpus_id, metadata_json)
                             VALUES (%s, %s) ON CONFLICT (corpus_id) DO NOTHING
                             """, (source["corpus_id"], Jsonb({})))
                conn.execute("""
                             INSERT INTO local_llm.sources (source_id, corpus_id, source_type,
                                                            title, origin_uri_or_path,
                                                            source_version, content_hash,
                                                            metadata_json, is_active)
                             VALUES (%s, %s, %s, %s, %s, %s, %s, %s,
                                     true) ON CONFLICT (source_id) DO
                             UPDATE SET corpus_id=EXCLUDED.corpus_id, source_type=EXCLUDED.source_type, title=EXCLUDED.title, origin_uri_or_path=EXCLUDED.origin_uri_or_path, source_version=EXCLUDED.source_version, content_hash=EXCLUDED.content_hash, metadata_json=EXCLUDED.metadata_json, is_active= true, updated_at=now()
                             """, (source["source_id"], source["corpus_id"],
                                   source.get("source_type", "file"),
                                   source.get("title", source["source_id"]),
                                   source.get("origin_uri_or_path",
                                              source.get("path", source["source_id"])),
                                   source.get("source_version"),
                                   source.get("content_hash", document["file_hash"]),
                                   Jsonb(source.get("metadata", source.get("metadata_json", {})))))
                conn.execute("""
                             INSERT INTO local_llm.documents (document_id, source_id, corpus_id,
                                                              path, relative_path, file_hash,
                                                              mtime_ns, size_bytes, extension,
                                                              metadata_json, is_active)
                             VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                     true) ON CONFLICT (document_id) DO
                             UPDATE SET source_id=EXCLUDED.source_id, corpus_id=EXCLUDED.corpus_id, path =EXCLUDED.path, relative_path=EXCLUDED.relative_path, file_hash=EXCLUDED.file_hash, mtime_ns=EXCLUDED.mtime_ns, size_bytes=EXCLUDED.size_bytes, extension=EXCLUDED.extension, metadata_json=EXCLUDED.metadata_json, is_active= true, updated_at=now()
                             """,
                             (document["document_id"], document["source_id"], document["corpus_id"],
                              document["path"], document["relative_path"], document["file_hash"],
                              document["mtime_ns"], document["size_bytes"], document["extension"],
                              Jsonb(document.get("metadata", document.get("metadata_json", {})))))
                for chunk in chunks:
                    conn.execute("""
                                 INSERT INTO local_llm.chunks (chunk_id, document_id, source_id,
                                                               corpus_id, ordinal, text, text_hash,
                                                               char_start, char_end, token_estimate,
                                                               metadata_json, is_active)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         true) ON CONFLICT (chunk_id) DO
                                 UPDATE SET document_id=EXCLUDED.document_id, source_id=EXCLUDED.source_id, corpus_id=EXCLUDED.corpus_id, ordinal=EXCLUDED.ordinal, text=EXCLUDED.text, text_hash=EXCLUDED.text_hash, char_start=EXCLUDED.char_start, char_end=EXCLUDED.char_end, token_estimate=EXCLUDED.token_estimate, metadata_json=EXCLUDED.metadata_json, is_active= true, updated_at=now()
                                 """, (chunk["chunk_id"], chunk["document_id"], chunk["source_id"],
                                       chunk["corpus_id"], chunk["ordinal"], chunk["text"],
                                       chunk["text_hash"], chunk["char_start"], chunk["char_end"],
                                       chunk["token_estimate"], Jsonb(
                            chunk.get("metadata", chunk.get("metadata_json", {})))))

    def mark_missing_sources_inactive(self, corpus_id: str, active_source_ids: set[str]) -> None:
        with self._connect() as conn:
            with conn.transaction():
                if active_source_ids:
                    conn.execute(
                        "UPDATE local_llm.sources SET is_active=false, updated_at=now() WHERE corpus_id=%s AND is_active AND NOT (source_id = ANY(%s))",
                        (corpus_id, sorted(active_source_ids)))
                else:
                    conn.execute(
                        "UPDATE local_llm.sources SET is_active=false, updated_at=now() WHERE corpus_id=%s AND is_active",
                        (corpus_id,))

    def search_chunks(self, query: str, corpus_id: str, top_k: int) -> list[RetrievalResult]:
        results, _ = self.search_chunks_with_observation(query=query, corpus_id=corpus_id,
                                                         top_k=top_k)
        return results

    def search_chunks_with_observation(
            self,
            *,
            query: str,
            corpus_id: str,
            top_k: int,
            query_text_allowed: bool = True,
    ) -> tuple[list[RetrievalResult], dict[str, Any]]:
        import time

        shape = build_postgres_fts_query_shape(
            query,
            top_k=top_k,
            query_text_allowed=query_text_allowed,
        )
        started = time.monotonic()
        if not has_postgres_fts_query(query):
            return [], shape.to_observation_json(
                latency_ms=0,
                fallback_used=False,
                fallback_reason="query_empty",
                privacy_behavior={"query_text_persisted": query_text_allowed},
            )

        normalized = normalize_postgres_fts_query(query)
        fallback = build_postgres_fts_or_query(normalized)
        strict_sql = """
                     WITH q AS (SELECT websearch_to_tsquery('simple', %s) AS query),
                          ranked AS (SELECT c.chunk_id, \
                                            c.document_id, \
                                            c.source_id, \
                                            d.path  AS document_path, \
                                            s.title AS source_title, \
                                            s.source_version, \
                                            ts_rank_cd(c.search_vector, q.query)::float8 AS score, c.text \
                                     FROM local_llm.chunks c \
                                              JOIN local_llm.documents d ON d.document_id = c.document_id \
                                              JOIN local_llm.sources s ON s.source_id = c.source_id \
                                              CROSS JOIN q \
                                     WHERE c.corpus_id = %s \
                                       AND c.is_active \
                                       AND d.is_active \
                                       AND s.is_active \
                                       AND c.search_vector @@ q.query
                     ORDER BY score DESC, c.document_id, c.ordinal LIMIT %s
                         )
                     SELECT row_number() OVER (ORDER BY score DESC, document_id, chunk_id)::int AS rank, 'postgres_fts' AS method, \
                            chunk_id, \
                            document_id, \
                            source_id, \
                            document_path, \
                            source_title, \
                            source_version,
                            score, \
                            score AS     raw_score, \
                            NULL::float8 AS normalized_score, text
                     FROM ranked \
                     ORDER BY rank \
                     """
        fallback_sql = strict_sql.replace("websearch_to_tsquery('simple', %s)",
                                          "to_tsquery('simple', %s)")
        fallback_used = False
        fallback_reason = None
        with self._connect() as conn:
            rows = conn.execute(strict_sql, (normalized, corpus_id, top_k)).fetchall()
            if not rows and fallback:
                fallback_used = True
                fallback_reason = "stage_1_no_rows"
                rows = conn.execute(fallback_sql, (fallback, corpus_id, top_k)).fetchall()

        results = [RetrievalResult(**dict(row)) for row in rows]
        latency_ms = int((time.monotonic() - started) * 1000)
        observation = shape.to_observation_json(
            candidate_count=len(results),
            returned_count=len(results),
            included_count=len(results),
            latency_ms=latency_ms,
            fallback_used=fallback_used,
            fallback_reason=fallback_reason,
            privacy_behavior={"query_text_persisted": query_text_allowed},
        )
        return results, observation

    def _session_select_sql(self, where_sql: str = "") -> str:
        return f"""
            SELECT
                s.*,
                COALESCE(packet_stats.turn_count, 0)::int AS turn_count,
                packet_stats.latest_turn_packet_id,
                packet_stats.latest_turn_at
            FROM local_llm.sessions s
            LEFT JOIN LATERAL (
                SELECT
                    count(*)::int AS turn_count,
                    (array_agg(tp.turn_packet_id ORDER BY tp.created_at DESC))[1] AS latest_turn_packet_id,
                    max(tp.created_at) AS latest_turn_at
                FROM eval.turn_packets tp
                WHERE tp.session_id = s.session_id
            ) packet_stats ON true
            {where_sql}
        """

    def create_session(self, **kwargs: Any) -> dict[str, object]:
        with self._connect() as conn:
            row = conn.execute("""
                               INSERT INTO local_llm.sessions (session_id, title, description,
                                                               default_workflow_id,
                                                               default_model_profile,
                                                               default_rag_profile,
                                                               default_prompt_profile,
                                                               metadata_json, default_capture_mode,
                                                               default_privacy_level,
                                                               privacy_locked)
                               VALUES (%(session_id)s, %(title)s, %(description)s,
                                       %(default_workflow_id)s, %(default_model_profile)s,
                                       %(default_rag_profile)s, %(default_prompt_profile)s,
                                       %(metadata)s, %(default_capture_mode)s,
                                       %(default_privacy_level)s,
                                       %(privacy_locked)s) RETURNING session_id
                               """, {**kwargs,
                                     "metadata": Jsonb(kwargs.get("metadata") or {})}).fetchone()
        return self.get_session(str(row["session_id"])) or {}

    def list_sessions(self, *, include_archived: bool = False) -> list[dict[str, object]]:
        where_sql = "" if include_archived else "WHERE s.archived_at IS NULL"
        sql = self._session_select_sql(where_sql) + " ORDER BY s.updated_at DESC"
        with self._connect() as conn:
            return [_row(r) or {} for r in conn.execute(sql).fetchall()]

    def get_session(self, session_id: str) -> dict[str, object] | None:
        with self._connect() as conn:
            row = conn.execute(self._session_select_sql("WHERE s.session_id=%s"),
                               (session_id,)).fetchone()
        return _row(row)

    def update_session(self, **kwargs: Any) -> dict[str, object] | None:
        session_id = kwargs.pop("session_id")
        sets = [];
        params = {"session_id": session_id}
        for key, value in kwargs.items():
            if value is None: continue
            column = "metadata_json" if key == "metadata" else key
            sets.append(f"{column}=%({key})s")
            params[key] = Jsonb(value) if key == "metadata" else value
        if not sets:
            return self.get_session(session_id)
        with self._connect() as conn:
            conn.execute(
                f"UPDATE local_llm.sessions SET {', '.join(sets)}, updated_at=now() WHERE session_id=%(session_id)s",
                params)
        return self.get_session(session_id)

    def archive_session(self, session_id: str) -> dict[str, object] | None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE local_llm.sessions SET archived_at=now(), updated_at=now() WHERE session_id=%s",
                (session_id,))
        return self.get_session(session_id)

    def next_turn_ordinal(self, session_id: str) -> int:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COALESCE(MAX(turn_ordinal), 0)::int + 1 AS next_ordinal FROM eval.turn_packets WHERE session_id=%s",
                (session_id,),
            ).fetchone()
        return int(row["next_ordinal"] if row else 1)

    def persist_turn_packet(self, turn_packet: Any) -> PacketSummaryEnvelope:
        with self._connect() as conn:
            with conn.transaction():
                if turn_packet.idempotency_key:
                    existing = conn.execute(
                        """
                        SELECT *
                        FROM eval.turn_packets
                        WHERE source_kind = %s
                          AND idempotency_key = %s
                          AND idempotency_scope_hash = %s LIMIT 1
                        """,
                        (turn_packet.source_kind, turn_packet.idempotency_key,
                         turn_packet.idempotency_scope_hash),
                    ).fetchone()
                    if existing:
                        return self._packet_summary_from_row(
                            existing,
                            response_text=self._assistant_response_text(
                                conn,
                                existing["turn_packet_id"],
                                bool(existing.get("text_persisted", True)),
                            ),
                        )

                conn.execute("""
                             INSERT INTO eval.turn_packets (turn_packet_id, request_id,
                                                            idempotency_key, idempotency_scope_hash,
                                                            source_kind, capture_status,
                                                            capture_mode, privacy_level,
                                                            text_persisted, metadata_redacted,
                                                            redaction_policy_version, session_id,
                                                            turn_id, turn_ordinal, workflow_id,
                                                            workflow_kind, model_profile_id,
                                                            rag_profile_id, prompt_profile_id,
                                                            corpus_id, retrieval_method,
                                                            config_snapshot_hash,
                                                            effective_config_hash,
                                                            config_snapshot_json,
                                                            request_summary_json,
                                                            search_observation_json,
                                                            retrieval_summary_json,
                                                            context_summary_json,
                                                            prompt_summary_json,
                                                            provider_summary_json,
                                                            runtime_links_json, privacy_json,
                                                            manifest_json, error_json,
                                                            metadata_json, source_system,
                                                            source_record_id, is_imported,
                                                            imported_at, finalized_at)
                             VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                     %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                     %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT (turn_packet_id) DO
                             UPDATE SET capture_status=EXCLUDED.capture_status, finalized_at=EXCLUDED.finalized_at, manifest_json=EXCLUDED.manifest_json, error_json=EXCLUDED.error_json, updated_at=now()
                             """, (
                                 turn_packet.turn_packet_id, turn_packet.request_id,
                                 turn_packet.idempotency_key, turn_packet.idempotency_scope_hash,
                                 turn_packet.source_kind, turn_packet.capture_status,
                                 turn_packet.capture_mode, turn_packet.privacy_level,
                                 turn_packet.text_persisted,
                                 turn_packet.metadata_redacted,
                                 turn_packet.redaction_policy_version, turn_packet.session_id,
                                 turn_packet.turn_id, turn_packet.turn_ordinal,
                                 turn_packet.workflow_id, turn_packet.workflow_kind,
                                 turn_packet.model_profile_id, turn_packet.rag_profile_id,
                                 turn_packet.prompt_profile_id,
                                 turn_packet.corpus_id, turn_packet.retrieval_method,
                                 turn_packet.config_snapshot_hash,
                                 turn_packet.effective_config_hash,
                                 Jsonb(turn_packet.config_snapshot_json),
                                 Jsonb(turn_packet.request_summary_json),
                                 Jsonb(turn_packet.search_observation_json),
                                 Jsonb(turn_packet.retrieval_summary_json),
                                 Jsonb(turn_packet.context_summary_json),
                                 Jsonb(turn_packet.prompt_summary_json),
                                 Jsonb(turn_packet.provider_summary_json),
                                 Jsonb(turn_packet.runtime_links_json),
                                 Jsonb(turn_packet.privacy_json), Jsonb(turn_packet.manifest_json),
                                 Jsonb(turn_packet.error_json), Jsonb(turn_packet.metadata_json),
                                 turn_packet.source_system, turn_packet.source_record_id,
                                 turn_packet.is_imported, turn_packet.imported_at,
                                 turn_packet.finalized_at,
                             ))
                for attempt in turn_packet.attempts:
                    conn.execute("""
                                 INSERT INTO eval.turn_attempts (turn_attempt_id, turn_packet_id,
                                                                 attempt_index, attempt_kind,
                                                                 attempt_status, is_primary,
                                                                 started_at, completed_at,
                                                                 latency_total_ms,
                                                                 phase_timings_json,
                                                                 provider_evidence_json,
                                                                 failure_json, metadata_json)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s) ON CONFLICT DO NOTHING
                                 """, (attempt.turn_attempt_id, turn_packet.turn_packet_id,
                                       attempt.attempt_index, attempt.attempt_kind,
                                       attempt.attempt_status, attempt.is_primary,
                                       attempt.started_at, attempt.completed_at,
                                       attempt.latency_total_ms, Jsonb(attempt.phase_timings_json),
                                       Jsonb(attempt.provider_evidence_json),
                                       Jsonb(attempt.failure_json), Jsonb(attempt.metadata_json)))
                for event in turn_packet.events:
                    conn.execute("""
                                 INSERT INTO eval.turn_events (event_id, turn_packet_id,
                                                               turn_attempt_id, event_order,
                                                               event_name, event_status, started_at,
                                                               completed_at, latency_ms,
                                                               payload_json, failure_json,
                                                               privacy_safe)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s) ON CONFLICT DO NOTHING
                                 """,
                                 (event.event_id, turn_packet.turn_packet_id, event.turn_attempt_id,
                                  event.event_order, event.event_name, event.event_status,
                                  event.started_at, event.completed_at, event.latency_ms,
                                  Jsonb(event.payload_json), Jsonb(event.failure_json),
                                  event.privacy_safe))
                for ref in turn_packet.content_refs:
                    conn.execute("""
                                 INSERT INTO eval.turn_content_refs (content_ref_id, turn_packet_id,
                                                                     turn_attempt_id, owner_type,
                                                                     owner_id, content_role,
                                                                     storage_kind, body_text,
                                                                     file_path, sha256, size_bytes,
                                                                     mime_type, capture_mode,
                                                                     privacy_level, body_persisted,
                                                                     metadata_redacted,
                                                                     payload_policy, metadata_json)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s, %s, %s) ON CONFLICT DO NOTHING
                                 """, (ref.content_ref_id, turn_packet.turn_packet_id,
                                       ref.turn_attempt_id, ref.owner_type, ref.owner_id,
                                       ref.content_role, ref.storage_kind, ref.body_text,
                                       ref.file_path, ref.sha256, ref.size_bytes, ref.mime_type,
                                       ref.capture_mode, ref.privacy_level, ref.body_persisted,
                                       ref.metadata_redacted, ref.payload_policy,
                                       Jsonb(ref.metadata_json)))
                for artifact in turn_packet.artifacts:
                    conn.execute("""
                                 INSERT INTO eval.turn_artifacts (artifact_id, turn_packet_id,
                                                                  turn_attempt_id, artifact_type,
                                                                  path, sha256, size_bytes,
                                                                  mime_type, body_persisted,
                                                                  payload_policy, capture_mode,
                                                                  privacy_level, metadata_json)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s) ON CONFLICT DO NOTHING
                                 """, (artifact.artifact_id, turn_packet.turn_packet_id,
                                       artifact.turn_attempt_id, artifact.artifact_type,
                                       artifact.path, artifact.sha256, artifact.size_bytes,
                                       artifact.mime_type, artifact.body_persisted,
                                       artifact.payload_policy, artifact.capture_mode,
                                       artifact.privacy_level, Jsonb(artifact.metadata_json)))
                for metric in turn_packet.metric_facts:
                    self._insert_turn_metric_fact(conn, turn_packet.turn_packet_id, metric)
                for membership in turn_packet.group_memberships:
                    conn.execute("""
                                 INSERT INTO eval.packet_group_members (packet_group_id,
                                                                        member_type, member_id,
                                                                        turn_packet_id,
                                                                        turn_attempt_id, session_id,
                                                                        turn_id, member_label,
                                                                        member_role,
                                                                        replicate_index,
                                                                        include_in_aggregate,
                                                                        exclusion_reason, ordinal,
                                                                        metadata_json)
                                 VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
                                         %s) ON CONFLICT DO NOTHING
                                 """, (membership.packet_group_id, membership.member_type,
                                       membership.member_id or turn_packet.turn_packet_id,
                                       membership.turn_packet_id or turn_packet.turn_packet_id,
                                       membership.turn_attempt_id, membership.session_id,
                                       membership.turn_id, membership.member_label,
                                       membership.member_role, membership.replicate_index,
                                       membership.include_in_aggregate, membership.exclusion_reason,
                                       membership.ordinal, Jsonb(membership.metadata_json)))
        return turn_packet.to_summary_envelope()

    def _insert_turn_metric_fact(
            self,
            conn: psycopg.Connection[dict[str, Any]],
            turn_packet_id: str,
            metric: Any,
    ) -> dict[str, Any] | None:
        row = conn.execute(
            """
            INSERT INTO eval.turn_metric_facts (metric_fact_id, turn_packet_id,
                                                turn_attempt_id, owner_type, owner_id,
                                                metric_key, metric_value_num, metric_value_text,
                                                metric_json, unit, privacy_safe, source)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING
            RETURNING *
            """,
            (
                metric.metric_fact_id,
                turn_packet_id,
                metric.turn_attempt_id,
                metric.owner_type,
                metric.owner_id,
                metric.metric_key,
                metric.metric_value_num,
                metric.metric_value_text,
                Jsonb(metric.metric_json),
                metric.unit,
                metric.privacy_safe,
                metric.source,
            ),
        ).fetchone()
        return _row(row) if row else None

    def append_turn_metric_facts(self, metric_facts: list[Any]) -> list[PacketMetricFactResponse]:
        if not metric_facts:
            return []
        packet_ids = {metric.turn_packet_id for metric in metric_facts}
        if len(packet_ids) != 1:
            raise ValueError("all appended metric facts must target the same turn_packet_id")
        turn_packet_id = next(iter(packet_ids))
        with self._connect() as conn:
            with conn.transaction():
                exists = conn.execute(
                    "SELECT 1 FROM eval.turn_packets WHERE turn_packet_id=%s",
                    (turn_packet_id,),
                ).fetchone()
                if not exists:
                    raise KeyError(f"turn packet not found: {turn_packet_id}")
                rows = [
                    self._insert_turn_metric_fact(conn, turn_packet_id, metric)
                    for metric in metric_facts
                ]
        return [PacketMetricFactResponse(**row) for row in rows if row]

    def _assistant_response_text(self, conn: psycopg.Connection[dict[str, Any]],
                                 turn_packet_id: str, text_persisted: bool) -> str:
        if not text_persisted:
            return ""
        row = conn.execute(
            """
            SELECT body_text
            FROM eval.turn_content_refs
            WHERE turn_packet_id = %s
              AND content_role = 'assistant_response'
              AND body_persisted = true
            ORDER BY created_at DESC LIMIT 1
            """,
            (turn_packet_id,),
        ).fetchone()
        return str(row["body_text"] or "") if row else ""

    def _packet_summary_from_row(self, row: dict[str, Any], *,
                                 response_text: str = "") -> PacketSummaryEnvelope:
        return PacketSummaryEnvelope(ok=row["capture_status"] in {"completed", "imported"},
                                     turn_packet_id=row["turn_packet_id"],
                                     source_kind=row["source_kind"],
                                     capture_status=row["capture_status"],
                                     workflow_id=row["workflow_id"],
                                     workflow_kind=row["workflow_kind"],
                                     model_profile=row["model_profile_id"],
                                     rag_profile=row["rag_profile_id"],
                                     prompt_profile=row["prompt_profile_id"],
                                     created_at=_iso(row.get("created_at")),
                                     session_id=row.get("session_id"), turn_id=row.get("turn_id"),
                                     turn_ordinal=row.get("turn_ordinal"),
                                     response_text=response_text, latency_ms=0,
                                     capture_mode=row["capture_mode"],
                                     privacy_level=row["privacy_level"],
                                     text_persisted=row["text_persisted"],
                                     metadata_redacted=row["metadata_redacted"],
                                     redaction_policy_version=row.get("redaction_policy_version"),
                                     warnings=[], error_json=_json(row.get("error_json")),
                                     manifest_json=_json(row.get("manifest_json")))

    def get_turn_packet_summary(self, turn_packet_id: str) -> PacketSummaryEnvelope | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM eval.turn_packets WHERE turn_packet_id=%s",
                               (turn_packet_id,)).fetchone()
            if not row:
                return None
            response_text = self._assistant_response_text(conn, turn_packet_id,
                                                          bool(row.get("text_persisted", True)))
        return self._packet_summary_from_row(row, response_text=response_text)

    def list_turn_packets(self, filters: PacketListRequest | dict[str, Any]) -> PacketListResponse:
        if isinstance(filters, dict):
            session_id = filters.get("session_id")
            workflow_id = filters.get("workflow_id")
            group_id = filters.get("group_id")
            capture_mode = filters.get("capture_mode")
            limit = filters.get("limit", 50)
        else:
            session_id = filters.session_id
            workflow_id = filters.workflow_id
            group_id = filters.group_id
            capture_mode = filters.capture_mode
            limit = filters.limit

        bounded_limit = max(1, min(int(limit or 50), 500))
        clauses: list[str] = []
        params: list[Any] = []
        if session_id:
            clauses.append("tp.session_id = %s")
            params.append(session_id)
        if workflow_id:
            clauses.append("tp.workflow_id = %s")
            params.append(workflow_id)
        if capture_mode:
            clauses.append("tp.capture_mode = %s")
            params.append(capture_mode)
        if group_id:
            clauses.append(
                "tp.turn_packet_id IN (SELECT turn_packet_id FROM eval.packet_group_members WHERE packet_group_id = %s AND turn_packet_id IS NOT NULL)")
            params.append(group_id)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        sql = f"SELECT tp.* FROM eval.turn_packets tp{where} ORDER BY tp.created_at DESC LIMIT %s"
        params.append(bounded_limit)
        with self._connect() as conn:
            rows = conn.execute(sql, tuple(params)).fetchall()
        return PacketListResponse(packets=[self._packet_summary_from_row(r) for r in rows])

    def get_turn_packet_detail(self, turn_packet_id: str) -> PacketDetailResponse | None:
        summary = self.get_turn_packet_summary(turn_packet_id)
        if not summary:
            return None
        with self._connect() as conn:
            attempts = [PacketAttemptResponse(**_row(r)) for r in conn.execute(
                "SELECT * FROM eval.turn_attempts WHERE turn_packet_id=%s ORDER BY attempt_index",
                (turn_packet_id,)).fetchall()]
            events = [PacketEventResponse(**_row(r)) for r in conn.execute(
                "SELECT * FROM eval.turn_events WHERE turn_packet_id=%s ORDER BY event_order",
                (turn_packet_id,)).fetchall()]
            content_refs = [PacketContentRefResponse(**_row(r)) for r in conn.execute(
                "SELECT * FROM eval.turn_content_refs WHERE turn_packet_id=%s ORDER BY created_at, content_role",
                (turn_packet_id,)).fetchall()]
            artifacts = [PacketArtifactResponse(**_row(r)) for r in conn.execute(
                "SELECT * FROM eval.turn_artifacts WHERE turn_packet_id=%s ORDER BY created_at, artifact_type",
                (turn_packet_id,)).fetchall()]
            metric_facts = [PacketMetricFactResponse(**_row(r)) for r in conn.execute(
                "SELECT * FROM eval.turn_metric_facts WHERE turn_packet_id=%s ORDER BY metric_key",
                (turn_packet_id,)).fetchall()]
            groups = [
                _row(r) or {}
                for r in conn.execute(
                    """
                    SELECT pg.packet_group_id,
                           pg.group_kind,
                           pg.label,
                           pgm.member_role,
                           pgm.replicate_index,
                           pgm.include_in_aggregate,
                           pgm.ordinal
                    FROM eval.packet_group_members pgm
                             JOIN eval.packet_groups pg ON pg.packet_group_id = pgm.packet_group_id
                    WHERE pgm.turn_packet_id = %s
                    ORDER BY pg.group_kind, pg.label, pgm.ordinal NULLS LAST, pgm.created_at
                    """,
                    (turn_packet_id,),
                ).fetchall()
            ]
        return PacketDetailResponse(summary=summary, attempts=attempts, events=events,
                                    content_refs=content_refs, artifacts=artifacts,
                                    metric_facts=metric_facts, groups=groups)

    def get_content_ref(self, content_ref_id: str) -> ContentLoadResponse | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM eval.turn_content_refs WHERE content_ref_id=%s",
                               (content_ref_id,)).fetchone()
        if not row:
            return None
        response = PacketContentRefResponse(**_row(row))
        text = response.body_text if response.body_persisted else None
        reason = None if text is not None else "content body not persisted"
        return ContentLoadResponse(content_ref=response, text=text, unavailable_reason=reason)

    def get_available_metrics(self,
                              scope: dict[str, Any] | None = None) -> MetricAvailabilityResponse:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM eval.metric_registry WHERE active ORDER BY namespace, metric_key").fetchall()
        return MetricAvailabilityResponse(
            metrics=[MetricDefinitionResponse(**_row(r)) for r in rows])

    def create_packet_group(self, request: PacketGroupRequest) -> PacketGroupResponse:
        with self._connect() as conn:
            row = conn.execute("""
                               INSERT INTO eval.packet_groups (group_kind, label, purpose,
                                                               parent_group_id, baseline_group_id,
                                                               workflow_id, capture_mode,
                                                               privacy_level, plan_json,
                                                               condition_json, metadata_json)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) RETURNING *
                               """, (request.group_kind, request.label, request.purpose,
                                     request.parent_group_id, request.baseline_group_id,
                                     request.workflow_id, request.capture_mode,
                                     request.privacy_level, Jsonb(request.plan_json),
                                     Jsonb(request.condition_json),
                                     Jsonb(request.metadata_json))).fetchone()
        return PacketGroupResponse(**_row(row))

    def add_packet_group_member(self, request: Any) -> PacketGroupMemberResponse:
        data = request.model_dump() if hasattr(request, "model_dump") else dict(request)
        with self._connect() as conn:
            row = conn.execute("""
                               INSERT INTO eval.packet_group_members (packet_group_id, member_type,
                                                                      member_id, turn_packet_id,
                                                                      turn_attempt_id,
                                                                      session_id, turn_id,
                                                                      member_label, member_role,
                                                                      replicate_index,
                                                                      include_in_aggregate,
                                                                      exclusion_reason, ordinal,
                                                                      metadata_json)
                               VALUES (%(packet_group_id)s, %(member_type)s, %(member_id)s,
                                       %(turn_packet_id)s, %(turn_attempt_id)s,
                                       %(session_id)s, %(turn_id)s, %(member_label)s,
                                       %(member_role)s, %(replicate_index)s,
                                       %(include_in_aggregate)s, %(exclusion_reason)s, %(ordinal)s,
                                       %(metadata_json)s) RETURNING *
                               """, {**data, "metadata_json": Jsonb(
                data.get("metadata_json") or {})}).fetchone()
        return PacketGroupMemberResponse(**(_row(row) or {}))

    def get_packet_group(self, packet_group_id: str) -> dict[str, Any] | None:
        with self._connect() as conn:
            group = _row(conn.execute("SELECT * FROM eval.packet_groups WHERE packet_group_id=%s",
                                      (packet_group_id,)).fetchone())
            if not group:
                return None
            members = [_row(r) for r in conn.execute(
                "SELECT * FROM eval.packet_group_members WHERE packet_group_id=%s ORDER BY ordinal NULLS LAST, created_at",
                (packet_group_id,)).fetchall()]
        group["members"] = members
        return group

    def _projection_packet_filter_sql(self, request: ProjectionRequest) -> tuple[
        str, list[Any], bool]:
        conditions: list[str] = []
        params: list[Any] = []
        join_group_members = False

        if request.packet_group_id:
            join_group_members = True
            with self._connect() as conn:
                group_row = conn.execute(
                    "SELECT group_kind FROM eval.packet_groups WHERE packet_group_id=%s",
                    (request.packet_group_id,),
                ).fetchone()
            group_kind = group_row["group_kind"] if group_row else None
            if group_kind == "experiment":
                conditions.append(
                    """
                    pgm.packet_group_id IN (
                        SELECT packet_group_id
                        FROM eval.packet_groups
                        WHERE parent_group_id = %s
                    )
                    """
                )
                params.append(request.packet_group_id)
            else:
                conditions.append("pgm.packet_group_id = %s")
                params.append(request.packet_group_id)
        elif request.packet_ids:
            conditions.append("tmf.turn_packet_id = ANY(%s)")
            params.append(request.packet_ids)
        elif request.session_ids:
            conditions.append("tp.session_id = ANY(%s)")
            params.append(request.session_ids)

        if request.metric_keys:
            conditions.append("tmf.metric_key = ANY(%s)")
            params.append(request.metric_keys)

        return ("WHERE " + " AND ".join(conditions) if conditions else "", params,
                join_group_members)

    def _projection_privacy_and_drilldown(self, request: ProjectionRequest) -> tuple[
        dict[str, Any], list[dict[str, Any]]]:
        clauses: list[str] = []
        params: list[Any] = []
        if request.packet_group_id:
            clauses.append(
                """
                tp.turn_packet_id IN (
                    SELECT turn_packet_id
                    FROM eval.packet_group_members
                    WHERE turn_packet_id IS NOT NULL
                      AND include_in_aggregate = true
                      AND (
                        packet_group_id = %s
                        OR packet_group_id IN (SELECT packet_group_id FROM eval.packet_groups WHERE parent_group_id = %s)
                      )
                )
                """
            )
            params.extend([request.packet_group_id, request.packet_group_id])
        elif request.packet_ids:
            clauses.append("tp.turn_packet_id = ANY(%s)")
            params.append(request.packet_ids)
        elif request.session_ids:
            clauses.append("tp.session_id = ANY(%s)")
            params.append(request.session_ids)
        where = "WHERE " + " AND ".join(clauses) if clauses else ""
        with self._connect() as conn:
            counts = conn.execute(
                f"""
                SELECT
                    count(*)::int AS packet_count,
                    count(*) FILTER (WHERE capture_mode='full')::int AS full_packet_count,
                    count(*) FILTER (WHERE capture_mode='privacy')::int AS privacy_packet_count,
                    count(*) FILTER (WHERE text_persisted=true)::int AS text_persisted_count,
                    count(*) FILTER (WHERE text_persisted=false)::int AS text_omitted_count
                FROM eval.turn_packets tp
                {where}
                """,
                tuple(params),
            ).fetchone() or {}
            drilldown = [
                _row(r) or {}
                for r in conn.execute(
                    f"""
                    SELECT tp.turn_packet_id, tp.session_id, tp.workflow_id, tp.capture_status,
                           tp.capture_mode, tp.privacy_level, tp.created_at
                    FROM eval.turn_packets tp
                    {where}
                    ORDER BY tp.created_at DESC
                    LIMIT 500
                    """,
                    tuple(params),
                ).fetchall()
            ]
        privacy = {
            "contains_private_packets": int(counts.get("privacy_packet_count") or 0) > 0,
            "full_packet_count": int(counts.get("full_packet_count") or 0),
            "privacy_packet_count": int(counts.get("privacy_packet_count") or 0),
            "text_persisted_count": int(counts.get("text_persisted_count") or 0),
            "text_omitted_count": int(counts.get("text_omitted_count") or 0),
            "warnings": [],
        }
        return privacy, drilldown

    def query_projection(self, request: ProjectionRequest) -> ProjectionResult:
        where, params, join_group_members = self._projection_packet_filter_sql(request)
        if join_group_members:
            from_sql = """
                FROM eval.turn_metric_facts tmf
                JOIN eval.turn_packets tp ON tp.turn_packet_id = tmf.turn_packet_id
                JOIN eval.packet_group_members pgm
                  ON pgm.turn_packet_id = tmf.turn_packet_id
                 AND pgm.include_in_aggregate = true
                JOIN eval.packet_groups pg ON pg.packet_group_id = pgm.packet_group_id
                JOIN eval.metric_registry mr ON mr.metric_key = tmf.metric_key
            """
            select_group = "pg.packet_group_id AS condition_group_id, pg.label AS condition_label,"
            group_by = "pg.packet_group_id, pg.label, tmf.metric_key, mr.display_name, mr.unit, mr.aggregation_default, mr.higher_is_better"
            order_by = "condition_label, tmf.metric_key"
        else:
            from_sql = """
                FROM eval.turn_metric_facts tmf
                JOIN eval.turn_packets tp ON tp.turn_packet_id = tmf.turn_packet_id
                JOIN eval.metric_registry mr ON mr.metric_key = tmf.metric_key
            """
            select_group = "NULL::text AS condition_group_id, NULL::text AS condition_label,"
            group_by = "tmf.metric_key, mr.display_name, mr.unit, mr.aggregation_default, mr.higher_is_better"
            order_by = "tmf.metric_key"

        sql = f"""
            SELECT
                {select_group}
                tmf.metric_key,
                mr.display_name,
                mr.unit,
                mr.aggregation_default,
                mr.higher_is_better,
                count(*)::int AS fact_count,
                avg(tmf.metric_value_num)::float8 AS avg_value,
                min(tmf.metric_value_num)::float8 AS min_value,
                max(tmf.metric_value_num)::float8 AS max_value,
                (array_agg(tmf.metric_value_text ORDER BY tmf.created_at DESC)
                    FILTER (WHERE tmf.metric_value_text IS NOT NULL))[1] AS latest_text_value
            {from_sql}
            {where}
            GROUP BY {group_by}
            ORDER BY {order_by}
        """
        with self._connect() as conn:
            rows = [_row(r) for r in conn.execute(sql, tuple(params)).fetchall()]
        metrics = self.get_available_metrics().metrics
        privacy_json, drilldown = self._projection_privacy_and_drilldown(request)
        from local_llm.contracts import ProjectionPrivacySummary
        return ProjectionResult(
            request=request,
            table=ProjectionTablePayload(
                columns=[
                    {"key": "condition_label"},
                    {"key": "metric_key"},
                    {"key": "display_name"},
                    {"key": "fact_count"},
                    {"key": "avg_value"},
                    {"key": "min_value"},
                    {"key": "max_value"},
                    {"key": "latest_text_value"},
                ],
                rows=rows,
            ),
            privacy=ProjectionPrivacySummary(**privacy_json),
            drilldown=drilldown,
            metrics=metrics,
        )