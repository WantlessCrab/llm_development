from __future__ import annotations

import os
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from local_llm.config import AppConfig, default_config_path, load_config
from local_llm.contracts import DoctorCheck, DoctorResponse, ProjectionRequest
from local_llm.control.profiles import ResolvedWorkflow, resolve_workflow
from local_llm.generation.providers.base import build_provider
from local_llm.store.factory import build_store

_FINAL_PHASE_1_5_MIGRATION_ID = "010_final_phase_1_5_schema"
_FINAL_PHASE_1_5_BOOT_CHECK = "phase_1_5_final_schema_created"

_REQUIRED_SCHEMAS = {"core", "local_llm", "eval"}
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


def _format_list(values: list[str] | set[str] | tuple[str, ...]) -> str:
    items = sorted(str(v) for v in values)
    return "[]" if not items else "[" + ", ".join(items) + "]"


def _format_mapping(mapping: dict[str, Any]) -> str:
    if not mapping:
        return "{}"
    return "; ".join(f"{key}={value}" for key, value in sorted(mapping.items()))


def _postgres_connection_kwargs(config: AppConfig) -> dict[str, Any]:
    try:
        import psycopg  # noqa: F401
        from psycopg.rows import dict_row
    except Exception as exc:  # pragma: no cover - dependency failure is surfaced in doctor output.
        raise RuntimeError(f"psycopg is required for PostgreSQL diagnostics: {exc}") from exc

    parts = urlsplit(config.storage.database_url)
    password = os.getenv(config.storage.database_password_env)
    if not password:
        raise RuntimeError(
            f"required database password environment variable is unset: "
            f"{config.storage.database_password_env}"
        )

    return {
        "dbname": parts.path.lstrip("/"),
        "user": parts.username,
        "password": password,
        "host": parts.hostname or "127.0.0.1",
        "port": parts.port or 5432,
        "row_factory": dict_row,
    }


def _collect_postgres_phase_state(config: AppConfig) -> dict[str, Any]:
    import psycopg

    try:
        with psycopg.connect(**_postgres_connection_kwargs(config)) as conn:
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

            relation_rows = conn.execute(
                """
                SELECT table_schema, table_name, table_type
                FROM information_schema.tables
                WHERE table_schema IN ('local_llm', 'eval', 'model_runtime')
                ORDER BY table_schema, table_name
                """
            ).fetchall()

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
                    SELECT migration_id, migration_file
                    FROM core.applied_migrations
                    ORDER BY migration_id
                    """
                ).fetchall()
            ]
            boot_checks = [
                dict(row)
                for row in conn.execute(
                    """
                    SELECT check_name, check_value
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

        migration_ids = {row["migration_id"] for row in migrations}
        boot_check_names = {row["check_name"] for row in boot_checks}
        schema_version_by_component = {row["component"]: row for row in schema_versions}

        missing_local_tables = sorted(_REQUIRED_LOCAL_TABLES - local_tables)
        missing_eval_tables = sorted(_REQUIRED_EVAL_TABLES - eval_tables)
        missing_schemas = sorted(_REQUIRED_SCHEMAS - schemas)

        forbidden_schemas = sorted(_FORBIDDEN_SCHEMAS & schemas)
        forbidden_tables: list[str] = []
        forbidden_views: list[str] = []
        for row in relation_rows:
            schema = row["table_schema"]
            name = row["table_name"]
            relation = f"{schema}.{name}"
            if row["table_type"] == "BASE TABLE" and name in _FORBIDDEN_TABLES.get(schema, set()):
                forbidden_tables.append(relation)
            if row["table_type"] == "VIEW" and name in _FORBIDDEN_VIEWS.get(schema, set()):
                forbidden_views.append(relation)

        final_schema_versions_ready = all(
            schema_version_by_component.get(component, {}).get("phase") == "phase_1_5"
            and schema_version_by_component.get(component, {}).get("status") == "active"
            for component in ("data_stack", "local_llm_schema", "eval_schema")
        )

        postgres_fts_ready = search_vector and search_index
        packet_tables_ready = not missing_local_tables and not missing_eval_tables
        legacy_migrations = sorted(_LEGACY_MIGRATION_IDS & migration_ids)
        final_migration_applied = _FINAL_PHASE_1_5_MIGRATION_ID in migration_ids
        final_boot_check_present = _FINAL_PHASE_1_5_BOOT_CHECK in boot_check_names
        forbidden_objects = sorted(forbidden_schemas + forbidden_tables + forbidden_views)

        phase_ready = all(
            [
                not missing_schemas,
                final_migration_applied,
                final_boot_check_present,
                final_schema_versions_ready,
                not legacy_migrations,
                not forbidden_objects,
                packet_tables_ready,
                postgres_fts_ready,
            ]
        )

        return {
            "connected": True,
            "required_schemas": {schema: schema in schemas for schema in sorted(_REQUIRED_SCHEMAS)},
            "missing_schemas": missing_schemas,
            "schema_versions": schema_versions,
            "schema_version_components": sorted(schema_version_by_component),
            "final_schema_versions_ready": final_schema_versions_ready,
            "applied_migration_ids": sorted(migration_ids),
            "final_migration_applied": final_migration_applied,
            "legacy_migration_ids": legacy_migrations,
            "boot_check_names": sorted(boot_check_names),
            "final_boot_check_present": final_boot_check_present,
            "missing_local_tables": missing_local_tables,
            "missing_eval_tables": missing_eval_tables,
            "packet_tables_ready": packet_tables_ready,
            "postgres_fts_ready": postgres_fts_ready,
            "search_vector_column_ready": search_vector,
            "search_vector_index_ready": search_index,
            "forbidden_schemas": forbidden_schemas,
            "forbidden_tables": sorted(forbidden_tables),
            "forbidden_views": sorted(forbidden_views),
            "forbidden_objects": forbidden_objects,
            "phase_1_5_schema_ready": phase_ready,
        }
    except Exception as exc:
        return {
            "connected": False,
            "error": str(exc),
            "phase_1_5_schema_ready": False,
            "postgres_fts_ready": False,
            "packet_tables_ready": False,
        }


def _schema_version_detail(state: dict[str, Any]) -> str:
    rows = state.get("schema_versions") or []
    if not rows:
        return "no core.schema_version rows visible"
    return "; ".join(
        f"{row.get('component')}={row.get('version_label')}/{row.get('phase')}/{row.get('status')}"
        for row in rows
    )


def _resolve_target_workflows(
        config: AppConfig,
        workflow_id: str | None,
        add_check,
) -> list[ResolvedWorkflow]:
    if workflow_id:
        try:
            resolved = resolve_workflow(config, workflow_id)
            add_check(f"workflow resolves:{workflow_id}", True, resolved.workflow.kind)
            return [resolved]
        except Exception as exc:
            add_check(f"workflow resolves:{workflow_id}", False, str(exc))
            return []

    resolved_workflows: list[ResolvedWorkflow] = []
    for configured_workflow_id in config.workflows:
        try:
            resolved = resolve_workflow(config, configured_workflow_id)
            resolved_workflows.append(resolved)
            add_check(f"workflow resolves:{configured_workflow_id}", True, resolved.workflow.kind)
        except Exception as exc:
            add_check(f"workflow resolves:{configured_workflow_id}", False, str(exc))
    return resolved_workflows


def _provider_targets(
        *,
        config: AppConfig,
        resolved_workflows: list[ResolvedWorkflow],
        workflow_id: str | None,
        model_profile_id: str | None,
        add_check,
) -> list[str]:
    if model_profile_id and model_profile_id not in config.model_profiles:
        add_check(f"model profile exists:{model_profile_id}", False, "missing")
        return []

    if model_profile_id:
        add_check(f"model profile exists:{model_profile_id}", True)

    workflow_model_ids = {resolved.model_profile_id for resolved in resolved_workflows}
    if workflow_id and model_profile_id and workflow_model_ids and model_profile_id not in workflow_model_ids:
        add_check(
            "doctor target model matches workflow",
            False,
            f"workflow_models={_format_list(workflow_model_ids)}; requested_model={model_profile_id}",
        )
        return []

    if model_profile_id:
        return [model_profile_id]

    if workflow_id:
        return sorted(workflow_model_ids)

    return sorted(config.model_profiles)


def run_doctor(
        config_path: Path | None = None,
        check_provider: bool = True,
        workflow_id: str | None = None,
        model_profile_id: str | None = None,
) -> DoctorResponse:
    checks: list[DoctorCheck] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        checks.append(DoctorCheck(name=name, ok=ok, detail=detail))

    path = config_path or default_config_path()
    add("config exists", path.exists(), str(path))

    config: AppConfig | None = None
    resolved_workflows: list[ResolvedWorkflow] = []

    try:
        config = load_config(path)
        add("config parses", True)
        add("storage backend is postgres", config.storage.backend == "postgres",
            config.storage.backend)

        if workflow_id:
            candidate_workflow = config.workflows.get(workflow_id)
            rag_ids = [candidate_workflow.rag_profile] if candidate_workflow else []
        else:
            rag_ids = sorted(config.rag_profiles)
        for rag_id in rag_ids:
            rag_profile = config.rag_profiles.get(rag_id)
            add(
                f"retrieval method active:{rag_id}",
                bool(rag_profile and rag_profile.retrieval.method == "postgres_fts"),
                rag_profile.retrieval.method if rag_profile else "missing",
            )
    except Exception as exc:
        add("config parses", False, str(exc))

    if config:
        store = None
        try:
            store = build_store(config)
            store_health = store.database_health()
            add(
                "database connected",
                bool(store_health.get("connected")),
                str(store_health.get("database_label") or config.database_label),
            )
        except Exception as exc:
            store_health = {"connected": False, "error": str(exc), "packet_schema_ready": False}
            add("database connected", False, str(exc))

        phase_state = _collect_postgres_phase_state(config)
        if not phase_state.get("connected"):
            add("Phase 1.5 database diagnostics", False, str(phase_state.get("error", "unknown")))
        else:
            add(
                "required schemas present",
                not bool(phase_state.get("missing_schemas")),
                _format_mapping(phase_state.get("required_schemas") or {}),
            )
            add(
                "schema_version is Phase 1.5 final",
                bool(phase_state.get("final_schema_versions_ready")),
                _schema_version_detail(phase_state),
            )
            add(
                "final Phase 1.5 migration applied",
                bool(phase_state.get("final_migration_applied")),
                _FINAL_PHASE_1_5_MIGRATION_ID,
            )
            add(
                "final Phase 1.5 boot check present",
                bool(phase_state.get("final_boot_check_present")),
                _FINAL_PHASE_1_5_BOOT_CHECK,
            )
            add(
                "legacy migrations absent",
                not bool(phase_state.get("legacy_migration_ids")),
                f"found={_format_list(phase_state.get('legacy_migration_ids') or [])}",
            )
            add(
                "packet table set present",
                bool(phase_state.get("packet_tables_ready")),
                f"missing_local={_format_list(phase_state.get('missing_local_tables') or [])}; "
                f"missing_eval={_format_list(phase_state.get('missing_eval_tables') or [])}",
            )
            add(
                "postgres_fts ready",
                bool(phase_state.get("postgres_fts_ready")),
                f"search_vector_column={phase_state.get('search_vector_column_ready')}; "
                f"search_vector_index={phase_state.get('search_vector_index_ready')}",
            )
            add(
                "legacy schema objects absent",
                not bool(phase_state.get("forbidden_objects")),
                f"found={_format_list(phase_state.get('forbidden_objects') or [])}",
            )
            add(
                "Phase 1.5 schema ready",
                bool(phase_state.get("phase_1_5_schema_ready")),
                "final migration + final schema_version + final boot check + packet tables + FTS + no legacy objects",
            )

            if phase_state.get("phase_1_5_schema_ready") and store is not None:
                try:
                    metrics = store.get_available_metrics()
                    add("metric registry ready", bool(metrics.metrics),
                        f"metrics={len(metrics.metrics)}")
                except Exception as exc:
                    add("metric registry ready", False, str(exc))
                try:
                    store.query_projection(ProjectionRequest(metric_keys=[]))
                    add("ProjectionService query ready", True)
                except Exception as exc:
                    add("ProjectionService query ready", False, str(exc))

        add(
            "vector substrate inert",
            True,
            "vector extension may exist in data_stack; active retrieval method is postgres_fts only",
        )

        try:
            config.artifact_dir.mkdir(parents=True, exist_ok=True)
            probe = config.artifact_dir / ".write_probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            add("artifact directory writable", True, str(config.artifact_dir))
        except Exception as exc:
            add("artifact directory writable", False, str(exc))

        for corpus_id, corpus in config.corpora.items():
            for root in corpus.roots:
                root_path = Path(root).expanduser()
                add(f"corpus root exists:{corpus_id}", root_path.exists(), str(root_path))

        resolved_workflows = _resolve_target_workflows(config, workflow_id, add)

        provider_targets = _provider_targets(
            config=config,
            resolved_workflows=resolved_workflows,
            workflow_id=workflow_id,
            model_profile_id=model_profile_id,
            add_check=add,
        )

        if check_provider:
            for target_model_profile_id in provider_targets:
                try:
                    model_profile = config.model_profiles[target_model_profile_id]
                    provider = build_provider(model_profile)
                    ok, detail = provider.health_check()
                    add(f"provider health:{target_model_profile_id}", ok, detail)
                except Exception as exc:
                    add(f"provider health:{target_model_profile_id}", False, str(exc))

    return DoctorResponse(ok=all(c.ok for c in checks), checks=checks)