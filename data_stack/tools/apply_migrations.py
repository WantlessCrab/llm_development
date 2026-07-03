#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urlsplit

import psycopg
from psycopg.rows import dict_row

DEFAULT_DATABASE_URL = "postgresql://llm_database@127.0.0.1:8032/llm_database"
DEFAULT_DATABASE_PASSWORD_ENV = "LOCAL_LLM_POSTGRES_PASSWORD"
DEFAULT_MIGRATIONS_DIR = Path(__file__).resolve().parents[1] / "db" / "migrations"

MIGRATION_FILE_RE = re.compile(r"^(?P<id>\d{3}_[A-Za-z0-9_]+)\.sql$")


@dataclass(frozen=True)
class PgConfig:
    database_url: str
    password_env: str


@dataclass(frozen=True)
class MigrationFile:
    migration_id: str
    path: Path

    @property
    def relative_path(self) -> str:
        root = Path(__file__).resolve().parents[1]
        try:
            return self.path.relative_to(root).as_posix()
        except ValueError:
            return self.path.as_posix()


def parse_pg_config(args: argparse.Namespace) -> PgConfig:
    return PgConfig(
        database_url=args.database_url,
        password_env=args.database_password_env,
    )


def connect_pg(config: PgConfig) -> psycopg.Connection:
    parts = urlsplit(config.database_url)
    password = os.environ.get(config.password_env) or os.environ.get("POSTGRES_PASSWORD")

    if not password:
        raise RuntimeError(
            f"PostgreSQL password missing. Set {config.password_env} or POSTGRES_PASSWORD."
        )
    if parts.password:
        raise RuntimeError("database_url must be passwordless; use a password env var instead")
    if parts.scheme not in {"postgresql", "postgres"}:
        raise RuntimeError("database_url must use postgresql:// or postgres://")
    if not parts.username:
        raise RuntimeError("database_url must include a database user")
    if not parts.hostname:
        raise RuntimeError("database_url must include a host")
    if not parts.path or parts.path == "/":
        raise RuntimeError("database_url must include a database name")

    return psycopg.connect(
        dbname=parts.path.lstrip("/"),
        user=parts.username,
        password=password,
        host=parts.hostname,
        port=parts.port or 5432,
        row_factory=dict_row,
    )


def discover_migrations(migrations_dir: Path) -> list[MigrationFile]:
    if not migrations_dir.exists():
        raise FileNotFoundError(f"migrations directory not found: {migrations_dir}")
    if not migrations_dir.is_dir():
        raise NotADirectoryError(f"migrations path is not a directory: {migrations_dir}")

    migrations: list[MigrationFile] = []

    for path in sorted(migrations_dir.iterdir()):
        if not path.is_file() or path.suffix != ".sql":
            continue

        match = MIGRATION_FILE_RE.match(path.name)
        if not match:
            raise ValueError(
                f"invalid migration filename: {path.name}; expected NNN_name.sql"
            )

        migrations.append(MigrationFile(migration_id=match.group("id"), path=path))

    if not migrations:
        raise RuntimeError(f"no SQL migrations found in {migrations_dir}")

    ids = [item.migration_id for item in migrations]
    duplicates = sorted({item for item in ids if ids.count(item) > 1})
    if duplicates:
        raise RuntimeError(f"duplicate migration ids: {duplicates}")

    return migrations


def target_migrations(
        migrations: Iterable[MigrationFile],
        *,
        target: str | None,
) -> list[MigrationFile]:
    migrations = list(migrations)
    if target is None:
        return migrations

    selected: list[MigrationFile] = []
    found = False

    for migration in migrations:
        selected.append(migration)
        if migration.migration_id == target:
            found = True
            break

    if not found:
        known = ", ".join(item.migration_id for item in migrations)
        raise RuntimeError(f"target migration not found: {target}; known: {known}")

    return selected


def ensure_bootstrap_ready(conn: psycopg.Connection) -> None:
    required_tables = {
        ("core", "schema_version"),
        ("core", "applied_migrations"),
        ("core", "boot_checks"),
    }

    rows = conn.execute(
        """
        SELECT table_schema, table_name
        FROM information_schema.tables
        WHERE table_schema = 'core'
          AND table_name IN ('schema_version', 'applied_migrations', 'boot_checks')
        """
    ).fetchall()

    found = {(row["table_schema"], row["table_name"]) for row in rows}
    missing = sorted(required_tables - found)

    if missing:
        rendered = ", ".join(f"{schema}.{table}" for schema, table in missing)
        raise RuntimeError(
            "database bootstrap is incomplete; missing foundation table(s): "
            f"{rendered}. Apply db/init/001_extensions.sql and "
            "db/init/002_bootstrap.sql first."
        )


def applied_migration_ids(conn: psycopg.Connection) -> set[str]:
    rows = conn.execute(
        """
        SELECT migration_id
        FROM core.applied_migrations
        ORDER BY migration_id
        """
    ).fetchall()
    return {row["migration_id"] for row in rows}


def apply_one(
        conn: psycopg.Connection,
        migration: MigrationFile,
        *,
        dry_run: bool,
) -> str:
    if dry_run:
        return "pending"

    sql = migration.path.read_text(encoding="utf-8")

    with conn.transaction():
        conn.execute(sql)

        row = conn.execute(
            """
            SELECT migration_id
            FROM core.applied_migrations
            WHERE migration_id = %s
            """,
            (migration.migration_id,),
        ).fetchone()

        if row is None:
            raise RuntimeError(
                f"migration {migration.migration_id} did not record itself in "
                "core.applied_migrations"
            )

    return "applied"


def run_apply(args: argparse.Namespace) -> int:
    migrations_dir = Path(args.migrations_dir).expanduser().resolve()
    migrations = target_migrations(discover_migrations(migrations_dir), target=args.target)
    config = parse_pg_config(args)

    with connect_pg(config) as conn:
        ensure_bootstrap_ready(conn)
        already_applied = applied_migration_ids(conn)
        plan: list[dict[str, str]] = []

        for migration in migrations:
            if migration.migration_id in already_applied and not args.reapply:
                plan.append(
                    {
                        "migration_id": migration.migration_id,
                        "file": migration.relative_path,
                        "status": "already_applied",
                    }
                )
                continue

            status = apply_one(conn, migration, dry_run=args.dry_run)
            plan.append(
                {
                    "migration_id": migration.migration_id,
                    "file": migration.relative_path,
                    "status": status,
                }
            )

    for item in plan:
        print(f"{item['status']:<16} {item['migration_id']} {item['file']}")

    if args.check and any(item["status"] == "pending" for item in plan):
        return 1

    return 0


def run_list(args: argparse.Namespace) -> int:
    migrations_dir = Path(args.migrations_dir).expanduser().resolve()
    migrations = target_migrations(discover_migrations(migrations_dir), target=args.target)
    config = parse_pg_config(args)

    with connect_pg(config) as conn:
        ensure_bootstrap_ready(conn)
        already_applied = applied_migration_ids(conn)

    for migration in migrations:
        status = "applied" if migration.migration_id in already_applied else "pending"
        print(f"{status:<8} {migration.migration_id} {migration.relative_path}")

    return 0


def add_db_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--database-url", default=DEFAULT_DATABASE_URL)
    parser.add_argument("--database-password-env", default=DEFAULT_DATABASE_PASSWORD_ENV)
    parser.add_argument("--migrations-dir", default=str(DEFAULT_MIGRATIONS_DIR))
    parser.add_argument("--target", default=None)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="apply_migrations.py")
    sub = parser.add_subparsers(dest="command", required=True)

    apply_parser = sub.add_parser("apply")
    add_db_args(apply_parser)
    apply_parser.add_argument("--dry-run", action="store_true")
    apply_parser.add_argument(
        "--check",
        action="store_true",
        help="Return non-zero if any targeted migration is pending during --dry-run.",
    )
    apply_parser.add_argument(
        "--reapply",
        action="store_true",
        help="Re-run migrations even when core.applied_migrations already contains the id.",
    )
    apply_parser.set_defaults(func=run_apply)

    list_parser = sub.add_parser("list")
    add_db_args(list_parser)
    list_parser.set_defaults(func=run_list)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        return int(args.func(args))
    except Exception as exc:
        print(f"apply_migrations error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())