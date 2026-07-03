from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "tools" / "apply_migrations.py"
MIGRATIONS_DIR = ROOT / "db" / "migrations"
INIT_SQL_FILES = (
    ROOT / "db" / "init" / "001_extensions.sql",
    ROOT / "db" / "init" / "002_bootstrap.sql",
)
FINAL_MIGRATION = MIGRATIONS_DIR / "010_final_phase_1_5_schema.sql"

REMOVED_MIGRATIONS = (
    "010_local_llm_schema.sql",
    "020_postgres_fts.sql",
    "030_eval_runtime_catalog.sql",
    "040_always_on_eval_capture.sql",
    "050_turn_packet_core.sql",
)

REMOVED_PHASE_1_TESTS_AND_TOOLS = (
    "tests/test_always_on_eval_capture_contract.py",
    "tests/test_eval_capture_views_contract.py",
    "tests/test_eval_runtime_catalog_contract.py",
    "tests/test_privacy_capture_contract.py",
    "tests/test_evidence_catalog_helpers.py",
    "tools/evidence_catalog.py",
)


def load_module():
    try:
        import psycopg  # noqa: F401
        import psycopg.rows  # noqa: F401
    except ModuleNotFoundError:
        import types

        psycopg_stub = types.ModuleType("psycopg")
        rows_stub = types.ModuleType("psycopg.rows")
        rows_stub.dict_row = object()
        psycopg_stub.Connection = object
        psycopg_stub.rows = rows_stub
        sys.modules.setdefault("psycopg", psycopg_stub)
        sys.modules.setdefault("psycopg.rows", rows_stub)

    spec = importlib.util.spec_from_file_location("apply_migrations", MODULE_PATH)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def normalized(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def assert_no_split_postgres_casts(sql: str) -> None:
    forbidden_patterns = (
        r"'\[\]'\s*:\s+:\s*jsonb",
        r"'\{\}'\s*:\s+:\s*jsonb",
        r"gen_random_uuid\s*\(\s*\)\s*:\s+:\s*text",
        r"metric_json\s*<>\s*'\{\}'\s*:\s+:\s*jsonb",
    )
    for pattern in forbidden_patterns:
        assert not re.search(pattern, sql, flags=re.IGNORECASE | re.MULTILINE), pattern


def test_active_migrations_directory_contains_only_final_schema() -> None:
    assert sorted(path.name for path in MIGRATIONS_DIR.glob("*.sql")) == [
        "010_final_phase_1_5_schema.sql"
    ]


def test_removed_legacy_migrations_are_not_active() -> None:
    for filename in REMOVED_MIGRATIONS:
        assert not (MIGRATIONS_DIR / filename).exists(), filename


def test_removed_phase_1_tests_and_evidence_tool_are_absent() -> None:
    for relative_path in REMOVED_PHASE_1_TESTS_AND_TOOLS:
        assert not (ROOT / relative_path).exists(), relative_path


def test_active_sql_files_exist_and_have_no_split_cast_tokens() -> None:
    for path in (*INIT_SQL_FILES, FINAL_MIGRATION):
        assert path.exists(), path
        assert_no_split_postgres_casts(read_text(path))


def test_active_sql_files_have_expected_jsonb_casts() -> None:
    sql = read_text(FINAL_MIGRATION)

    for fragment in (
            "'[]'::jsonb",
            "'{}'::jsonb",
            "gen_random_uuid()::text",
            "metric_json <> '{}'::jsonb",
    ):
        assert fragment in sql


def test_extension_sql_has_no_typo_debt() -> None:
    sql = read_text(INIT_SQL_FILES[0])

    assert "faoundation" not in sql
    assert "foundation" in sql


def test_extensions_file_declares_required_and_inert_extensions() -> None:
    sql = normalized(read_text(INIT_SQL_FILES[0]))

    assert "CREATE EXTENSION IF NOT EXISTS pgcrypto;" in sql
    assert "CREATE EXTENSION IF NOT EXISTS vector;" in sql
    assert "active vector query path" in sql


def test_bootstrap_declares_final_metadata_schemas_without_model_runtime() -> None:
    sql = normalized(read_text(INIT_SQL_FILES[1]))

    for fragment in (
            "CREATE SCHEMA IF NOT EXISTS core;",
            "CREATE SCHEMA IF NOT EXISTS local_llm;",
            "CREATE SCHEMA IF NOT EXISTS eval;",
            "CREATE TABLE IF NOT EXISTS core.schema_version",
            "CREATE TABLE IF NOT EXISTS core.applied_migrations",
            "CREATE TABLE IF NOT EXISTS core.boot_checks",
            "'legacy_schema_form_preserved', false",
    ):
        assert fragment in sql

    assert "CREATE SCHEMA IF NOT EXISTS model_runtime" not in sql


def test_final_migration_has_guarded_destructive_cleanup() -> None:
    sql = normalized(read_text(FINAL_MIGRATION))

    for fragment in (
            "WHERE migration_id = '010_final_phase_1_5_schema'",
            "DROP SCHEMA IF EXISTS model_runtime CASCADE;",
            "DROP SCHEMA IF EXISTS eval CASCADE;",
            "DROP SCHEMA IF EXISTS local_llm CASCADE;",
            "DELETE FROM core.applied_migrations",
            "'010_local_llm_schema'",
            "'020_postgres_fts'",
            "'030_eval_runtime_catalog'",
            "'040_always_on_eval_capture'",
            "DELETE FROM core.schema_version",
            "DELETE FROM core.boot_checks",
    ):
        assert fragment in sql


def test_final_migration_is_idempotent_after_self_registration() -> None:
    sql = normalized(read_text(FINAL_MIGRATION))

    assert "IF NOT EXISTS ( SELECT 1 FROM core.applied_migrations WHERE migration_id = '010_final_phase_1_5_schema' ) THEN" in sql
    assert "ON CONFLICT (migration_id) DO UPDATE" in sql
    assert "ON CONFLICT (component) DO UPDATE" in sql
    assert "ON CONFLICT (check_name) DO UPDATE" in sql


def test_discover_migrations_orders_by_filename(tmp_path: Path) -> None:
    module = load_module()

    (tmp_path / "020_second.sql").write_text("-- second", encoding="utf-8")
    (tmp_path / "010_first.sql").write_text("-- first", encoding="utf-8")
    (tmp_path / "README.md").write_text("ignored", encoding="utf-8")

    migrations = module.discover_migrations(tmp_path)

    assert [item.migration_id for item in migrations] == ["010_first", "020_second"]


def test_discover_migrations_rejects_invalid_sql_filename(tmp_path: Path) -> None:
    module = load_module()

    (tmp_path / "bad_name.sql").write_text("-- invalid", encoding="utf-8")

    try:
        module.discover_migrations(tmp_path)
    except ValueError as exc:
        assert "invalid migration filename" in str(exc)
    else:
        raise AssertionError("invalid migration filename was accepted")


def test_discover_migrations_rejects_empty_directory(tmp_path: Path) -> None:
    module = load_module()

    try:
        module.discover_migrations(tmp_path)
    except RuntimeError as exc:
        assert "no SQL migrations found" in str(exc)
    else:
        raise AssertionError("empty migration directory was accepted")


def test_real_migration_discovery_uses_final_phase_1_5_migration_only() -> None:
    module = load_module()

    migrations = module.discover_migrations(MIGRATIONS_DIR)

    assert [item.migration_id for item in migrations] == ["010_final_phase_1_5_schema"]
    assert [item.relative_path for item in migrations] == [
        "db/migrations/010_final_phase_1_5_schema.sql"
    ]


def test_target_migrations_stops_at_requested_target(tmp_path: Path) -> None:
    module = load_module()

    migrations = [
        module.MigrationFile("010_first", tmp_path / "010_first.sql"),
        module.MigrationFile("020_second", tmp_path / "020_second.sql"),
        module.MigrationFile("030_third", tmp_path / "030_third.sql"),
    ]

    selected = module.target_migrations(migrations, target="020_second")

    assert [item.migration_id for item in selected] == ["010_first", "020_second"]


def test_target_migrations_rejects_unknown_target(tmp_path: Path) -> None:
    module = load_module()

    migrations = [module.MigrationFile("010_first", tmp_path / "010_first.sql")]

    try:
        module.target_migrations(migrations, target="999_missing")
    except RuntimeError as exc:
        assert "target migration not found" in str(exc)
    else:
        raise AssertionError("unknown target was accepted")


def test_migration_relative_path_is_repo_relative() -> None:
    module = load_module()

    migration = module.MigrationFile("010_final_phase_1_5_schema", FINAL_MIGRATION)

    assert migration.relative_path == "db/migrations/010_final_phase_1_5_schema.sql"


def test_apply_one_requires_migration_self_recording(tmp_path: Path) -> None:
    module = load_module()

    migration = module.MigrationFile("010_test", tmp_path / "010_test.sql")
    migration.path.write_text("SELECT 1;", encoding="utf-8")

    class FakeResult:
        def fetchone(self):
            return None

    class FakeTransaction:
        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    class FakeConnection:
        def transaction(self):
            return FakeTransaction()

        def execute(self, _sql, _params=None):
            return FakeResult()

    try:
        module.apply_one(FakeConnection(), migration, dry_run=False)
    except RuntimeError as exc:
        assert "did not record itself" in str(exc)
    else:
        raise AssertionError("migration without self-record was accepted")


def test_apply_one_dry_run_does_not_execute_sql(tmp_path: Path) -> None:
    module = load_module()

    migration = module.MigrationFile("010_test", tmp_path / "010_test.sql")
    migration.path.write_text("SELECT 1;", encoding="utf-8")

    class FakeConnection:
        def transaction(self):
            raise AssertionError("dry run must not open a transaction")

        def execute(self, *_args, **_kwargs):
            raise AssertionError("dry run must not execute SQL")

    assert module.apply_one(FakeConnection(), migration, dry_run=True) == "pending"