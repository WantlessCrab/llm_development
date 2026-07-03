#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PYCODE'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import time
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "16_postgresql.sh"
SCHEMA_NAME = "recovery.postgresql.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "postgresql",
        "verified_active_server": "18.4",
        "verified_dump_tooling": "18.4",
        "verified_pgvector_image": "pgvector/pgvector:0.8.2-pg18-trixie",
        "layer": "16_logical_database_recovery",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/16_postgresql",
        "generated_root": "state/generated/16_postgresql",
        "dump_root": "state/exports/16_postgresql/dumps",
        "restore_test_root": "state/disposable_restore/16_postgresql",
    },
    "commands": {"docker": "/usr/bin/docker", "python": "/usr/bin/python3", "sha256sum": "/usr/bin/sha256sum"},
    "postgresql": {
        "active_container_name": "llm-postgres",
        "active_service_name": "llm-postgres",
        "active_runtime_image": "localproject/llm-postgres:pg18-pgvector082",
        "active_upstream_image": "pgvector/pgvector:0.8.2-pg18-trixie",
        "active_volume_name": "llm_database_pgdata",
        "active_host_port": "8032",
        "container_port": "5432",
        "server_user": "llm_database",
        "required_database": "llm_database",
        "maintenance_database": "postgres",
        "required_databases": "llm_database;postgres",
        "expected_server_major": 18,
        "expected_server_version_prefix": "18.",
        "required_client_major": 18,
        "fallback_client_image": "postgres:18.4-trixie",
        "disposable_restore_image": "pgvector/pgvector:0.8.2-pg18-trixie",
        "data_stack_root": "/home/wantless/PycharmProjects/automation/data_stack",
        "data_stack_compose": "/home/wantless/PycharmProjects/automation/data_stack/docker-compose.postgres.yml",
        "data_stack_dockerfile": "/home/wantless/PycharmProjects/automation/data_stack/dockerfile.postgres",
        "data_stack_env_path": "/home/wantless/PycharmProjects/automation/data_stack/.env",
        "data_stack_env_example_path": "/home/wantless/PycharmProjects/automation/data_stack/.env.example",
        "schema_authority_migration": "/home/wantless/PycharmProjects/automation/data_stack/db/migrations/010_final_phase_1_5_schema.sql",
        "init_sql_paths": "/home/wantless/PycharmProjects/automation/data_stack/db/init/001_extensions.sql;/home/wantless/PycharmProjects/automation/data_stack/db/init/002_bootstrap.sql",
        "local_llm_config_path": "/home/wantless/.config/local-llm/config.yaml",
        "local_llm_runtime_env_path": "/home/wantless/.config/local-llm/local-llm.env",
        "disposable_host_auth_method": "trust",
    },
    "schema_authority": {
        "required_schemas": "core;local_llm;eval",
        "required_core_tables": "schema_version;applied_migrations;boot_checks",
        "required_local_llm_tables": "corpora;sources;documents;chunks;sessions",
        "required_eval_tables": "turn_packets;turn_attempts;turn_events;turn_content_refs;turn_artifacts;metric_registry;turn_metric_facts;packet_groups;packet_group_members",
        "required_extensions": "pgcrypto;vector",
        "forbidden_schemas": "model_runtime",
        "forbidden_local_llm_tables": "runs;run_retrievals;run_artifacts;turns",
        "forbidden_eval_tables": "evidence_batches;comparison_groups;eval_reports;eval_metrics;eval_artifacts",
        "forbidden_model_runtime_tables": "model_files;runtime_artifacts;runtime_snapshots",
        "forbidden_eval_views": "model_runtime_summary_v;privacy_capture_summary_v;report_summary_v;run_capture_summary_v;tuning_comparison_v",
        "expected_retrieval_method": "postgres_fts",
        "expected_fts_config": "simple",
    },
    "dump_policy": {
        "dump_format": "custom",
        "dump_extension": ".dump",
        "globals_extension": ".globals.sql",
        "dump_jobs": 1,
        "dump_compress": 6,
        "include_blobs": True,
        "no_role_passwords_for_globals": True,
        "include_clean_restore_list": True,
        "verify_restore_list_after_dump": True,
        "dump_required_databases": "llm_database",
        "allow_dump_postgres_maintenance_db": False,
        "generated_restore_plan_name": "postgresql_restore_plan.md",
        "generated_script_mode": "0600",
    },
    "restore_test_policy": {
        "restore_disposable_requires_execute": True,
        "restore_guard_prefix": "POSTGRES_DISPOSABLE_RESTORE",
        "restore_guard_env": "CONFIRM_POSTGRES_DISPOSABLE_RESTORE",
        "restore_guard_value": "I_UNDERSTAND_THIS_CREATES_A_DISPOSABLE_POSTGRES_RESTORE",
        "disposable_container_prefix": "recovery-postgres-restore",
        "disposable_volume_prefix": "recovery-postgres-restore-pgdata",
        "disposable_database_name": "llm_database_restore",
        "keep_disposable_container": False,
        "helper_image_must_exist_locally": True,
        "no_auto_pull": True,
        "cleanup_disposable_container": True,
        "restore_with_no_owner": True,
        "restore_with_no_privileges": True,
        "restore_with_exit_on_error": True,
        "restore_timeout_seconds": 120,
        "smoke_required_schemas": "core;local_llm;eval",
        "smoke_required_extensions": "pgcrypto;vector",
    },
    "security": {
        "copy_env_files": False,
        "hash_env_files_only": True,
        "redact_password_like_values": True,
        "record_secret_paths_only": True,
        "globals_dump_no_role_passwords_required": True,
        "never_copy_raw_docker_volume_as_primary": True,
    },
}


def strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    out: list[str] = []
    for ch in line:
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            break
        out.append(ch)
    return "".join(out).rstrip()


def parse_scalar(value: str) -> Any:
    v = value.strip()
    if not v:
        return ""
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]
    if v.lower() in {"true", "false"}:
        return v.lower() == "true"
    if v.lower() in {"null", "none"}:
        return None
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    if re.fullmatch(r"-?\d+\.\d+", v):
        return float(v)
    return v


def parse_simple_yaml(path: Path) -> dict[str, Any]:
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, root)]
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = strip_comment(raw)
        if not line.strip():
            continue
        if line.lstrip().startswith("- "):
            raise SystemExit(f"{path}: list-item YAML is unsupported. Use semicolon-delimited scalar strings.")
        indent = len(line) - len(line.lstrip(" "))
        text = line.strip()
        if ":" not in text:
            raise SystemExit(f"{path}: unsupported YAML line: {raw!r}")
        key, value = text.split(":", 1)
        key = key.strip()
        value = value.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if value == "":
            child: dict[str, Any] = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = parse_scalar(value)
    return root


def parse_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists() or not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = strip_comment(raw).strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key:
            continue
        values[key] = value.strip().strip('"').strip("'")
    return values


def value_key_is_secret(key: str) -> bool:
    return bool(re.search(r"(PASSWORD|PASS|SECRET|TOKEN|KEY|CREDENTIAL|AUTH)", key, re.IGNORECASE))


def redacted_env(values: dict[str, str]) -> dict[str, str]:
    return {key: ("<redacted>" if value_key_is_secret(key) else value) for key, value in sorted(values.items())}


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config() -> dict[str, Any]:
    path = PROJECT_ROOT / "configs" / "16_postgresql.yaml"
    return deep_merge(DEFAULT_CONFIG, parse_simple_yaml(path)) if path.exists() else deepcopy(DEFAULT_CONFIG)


CFG = load_config()


def cfg_get(path: str, default: Any = None) -> Any:
    cur: Any = CFG
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def split_semicolon(value: Any) -> list[str]:
    return [part.strip() for part in str(value or "").split(";") if part.strip()]


def cmd_path(name: str) -> str:
    value = str(cfg_get(f"commands.{name}", name))
    if Path(value).exists() or shutil.which(value):
        return value
    return value if "/" in value else (shutil.which(value) or value)


DOCKER = cmd_path("docker")


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def resolve_path(value: str | Path) -> Path:
    p = Path(str(value)).expanduser()
    return p.resolve() if p.is_absolute() else (PROJECT_ROOT / p).resolve()


def rel(path: str | Path) -> str:
    p = Path(path).resolve()
    try:
        return str(p.relative_to(PROJECT_ROOT))
    except ValueError:
        return str(p)


def safe_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value).strip())
    return cleaned.strip("_") or "unnamed"


def shell_join(argv: list[str]) -> str:
    return " ".join(shlex.quote(str(part)) for part in argv)


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/16_postgresql")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "16_postgresql.yaml"
    if config_path.exists():
        shutil.copy2(config_path, run_dir / "16_postgresql.config.snapshot.yaml")
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def sha256_file(path: Path) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        return h.hexdigest()
    except OSError:
        return None


def file_record(path: Path, *, include_hash: bool = True, copy_payload: bool = False) -> dict[str, Any]:
    try:
        st = path.lstat()
    except OSError as exc:
        return {"path": str(path), "exists": False, "error": str(exc)}
    rec: dict[str, Any] = {
        "path": str(path),
        "exists": path.exists(),
        "is_file": path.is_file(),
        "is_dir": path.is_dir(),
        "is_symlink": path.is_symlink(),
        "mode": oct(stat.S_IMODE(st.st_mode)),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "size_bytes": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "payload_copied": bool(copy_payload),
    }
    if path.is_symlink():
        try:
            rec["symlink_target"] = os.readlink(path)
            rec["target_resolved"] = str(path.resolve(strict=False))
            rec["target_exists"] = path.resolve(strict=False).exists()
        except OSError as exc:
            rec["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink():
        rec["sha256"] = sha256_file(path)
    return rec


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "postgresql",
            "script": SCRIPT_NAME,
            "docker_path": DOCKER,
            "docker_version": None,
            "active_container": str(cfg_get("postgresql.active_container_name", "llm-postgres")),
            "server_version": None,
            "pg_dump_version": None,
            "pg_restore_version": None,
        },
        "command": command,
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": True,
        "failures": [],
        "warnings": [],
        "commands": [],
        "outputs": [],
    }


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_path = run_dir / "postgresql_report.json"
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False, env: dict[str, str] | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, env=env)
    safe = safe_name(label)
    run_dir = resolve_path(report["run_dir"])
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    record = {"argv": argv[:], "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr}
    report["commands"].append(record)
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {shell_join(argv)} :: {proc.stderr.strip()}")
    return {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "record": record}


def run_cmd_binary_stdout_to_file(argv: list[str], out_file: Path, report: dict[str, Any], *, label: str) -> dict[str, Any]:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    safe = safe_name(label)
    run_dir = resolve_path(report["run_dir"])
    stderr_path = run_dir / f"{safe}.stderr.txt"
    with out_file.open("wb") as stdout_target:
        proc = subprocess.run(argv, stdout=stdout_target, stderr=subprocess.PIPE)
    stderr_text = proc.stderr.decode("utf-8", errors="replace")
    write_text(stderr_path, stderr_text)
    record = {
        "argv": argv[:],
        "returncode": proc.returncode,
        "binary_stdout_path": rel(out_file),
        "stderr_path": rel(stderr_path),
        "stderr": stderr_text,
    }
    report["commands"].append(record)
    return {"argv": argv[:], "returncode": proc.returncode, "stdout_path": out_file, "stderr": stderr_text, "record": record}


def docker_cmd(args: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    return run_cmd([DOCKER, *args], report, label=label, check=check)


def active_container() -> str:
    return str(cfg_get("postgresql.active_container_name", "llm-postgres"))


def pg_user() -> str:
    return str(cfg_get("postgresql.server_user", "llm_database"))


def required_database() -> str:
    return str(cfg_get("postgresql.required_database", "llm_database"))


def maintenance_database() -> str:
    return str(cfg_get("postgresql.maintenance_database", "postgres"))


def docker_exec(args: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    return docker_cmd(["exec", active_container(), *args], report, label=label, check=check)


def psql_query(sql: str, report: dict[str, Any], *, database: str | None = None, label: str = "psql_query", check: bool = False) -> dict[str, Any]:
    db = database or required_database()
    return docker_exec(
        ["psql", "-U", pg_user(), "-d", db, "-v", "ON_ERROR_STOP=1", "-At", "-F", "\t", "-c", sql],
        report,
        label=label,
        check=check,
    )


def psql_json(sql: str, report: dict[str, Any], *, database: str | None = None, label: str = "psql_json") -> Any:
    result = psql_query(sql, report, database=database, label=label)
    if result["returncode"] != 0:
        report["warnings"].append(f"psql JSON query failed: {label}")
        return None
    text = result["stdout"].strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        report["warnings"].append(f"psql JSON query did not return JSON: {label}")
        return {"raw": text}


def single_value(sql: str, report: dict[str, Any], *, database: str | None = None, label: str = "psql_value") -> str | None:
    result = psql_query(sql, report, database=database, label=label)
    if result["returncode"] != 0:
        return None
    return result["stdout"].strip().splitlines()[0] if result["stdout"].strip() else None


def parse_pg_major_from_version(text: str | None) -> int | None:
    if not text:
        return None
    match = re.search(r"\b(\d+)(?:\.\d+)?\b", text)
    return int(match.group(1)) if match else None


def parse_pg_major_from_version_num(value: str | None) -> int | None:
    if not value or not value.strip().isdigit():
        return None
    n = int(value.strip())
    return n // 10000 if n >= 10000 else n


def collect_versions(report: dict[str, Any]) -> dict[str, Any]:
    versions: dict[str, Any] = {}
    server_version = single_value("SHOW server_version;", report, database=required_database(), label="show_server_version")
    server_version_num = single_value("SHOW server_version_num;", report, database=required_database(), label="show_server_version_num")
    pg_dump_version = docker_exec(["pg_dump", "--version"], report, label="pg_dump_version")
    pg_restore_version = docker_exec(["pg_restore", "--version"], report, label="pg_restore_version")
    pg_dumpall_version = docker_exec(["pg_dumpall", "--version"], report, label="pg_dumpall_version")
    versions["server_version"] = server_version
    versions["server_version_num"] = server_version_num
    versions["server_major"] = parse_pg_major_from_version_num(server_version_num) or parse_pg_major_from_version(server_version)
    versions["pg_dump_version"] = (pg_dump_version["stdout"] or pg_dump_version["stderr"]).strip()
    versions["pg_dump_major"] = parse_pg_major_from_version(versions["pg_dump_version"])
    versions["pg_restore_version"] = (pg_restore_version["stdout"] or pg_restore_version["stderr"]).strip()
    versions["pg_restore_major"] = parse_pg_major_from_version(versions["pg_restore_version"])
    versions["pg_dumpall_version"] = (pg_dumpall_version["stdout"] or pg_dumpall_version["stderr"]).strip()
    versions["pg_dumpall_major"] = parse_pg_major_from_version(versions["pg_dumpall_version"])
    report["tool"]["server_version"] = server_version
    report["tool"]["pg_dump_version"] = versions["pg_dump_version"]
    report["tool"]["pg_restore_version"] = versions["pg_restore_version"]
    return versions



def preflight(report: dict[str, Any], *, require_daemon: bool = True, require_container: bool = True) -> None:
    if not command_exists(DOCKER):
        report["failures"].append(f"docker command not found at configured path: {DOCKER}")
        return
    version = docker_cmd(["--version"], report, label="docker_version")
    report["tool"]["docker_version"] = (version["stdout"] or version["stderr"]).strip()
    if require_daemon:
        info = docker_cmd(["info", "--format", "{{json .}}"], report, label="docker_info_probe")
        if info["returncode"] != 0:
            report["failures"].append("docker daemon unavailable or current user cannot access it")
            return
    if require_container:
        if not docker_container_exists(active_container(), report):
            report["failures"].append(f"active PostgreSQL container is not inspectable: {active_container()}")
            return
        ready = docker_exec(["pg_isready", "-U", pg_user(), "-d", required_database(), "-h", "localhost"], report, label="pg_isready")
        if ready["returncode"] != 0:
            report["failures"].append(f"active PostgreSQL container is not ready for {required_database()}")

def redact_env_list(env_values: Any) -> list[str]:
    if not isinstance(env_values, list):
        return []
    names = []
    for item in env_values:
        text = str(item)
        names.append(text.split("=", 1)[0] if "=" in text else text)
    return sorted(set(names))


def sanitize_container_inspect(items: Any) -> Any:
    if not isinstance(items, list):
        return items
    sanitized = []
    for item in items:
        if not isinstance(item, dict):
            sanitized.append(item)
            continue
        safe = deepcopy(item)
        config = safe.get("Config") if isinstance(safe.get("Config"), dict) else {}
        if config and "Env" in config:
            config["EnvNames"] = redact_env_list(config.get("Env"))
            config["Env"] = [f"{name}=<redacted>" for name in config["EnvNames"]]
        sanitized.append(safe)
    return sanitized


def sanitize_image_inspect(items: Any) -> Any:
    if not isinstance(items, list):
        return items
    sanitized = []
    for item in items:
        if not isinstance(item, dict):
            sanitized.append(item)
            continue
        safe = deepcopy(item)
        for key in ("Config", "ContainerConfig"):
            config = safe.get(key) if isinstance(safe.get(key), dict) else {}
            if config and "Env" in config:
                env_names = redact_env_list(config.get("Env"))
                config["EnvNames"] = env_names
                config["Env"] = [f"{name}=<redacted>" for name in env_names]
        sanitized.append(safe)
    return sanitized



def docker_inspect(kind: str, names: list[str], report: dict[str, Any], label: str) -> list[Any]:
    rows: list[Any] = []
    for name in names:
        if not name:
            continue
        result = docker_cmd([kind, "inspect", name], report, label=f"{label}_{safe_name(name)}")
        if result["returncode"] != 0:
            report["warnings"].append(f"docker {kind} inspect failed for {name}")
            continue
        parsed = json.loads(result["stdout"] or "[]")
        sanitized = parsed
        if kind == "container":
            sanitized = sanitize_container_inspect(parsed)
        elif kind == "image":
            sanitized = sanitize_image_inspect(parsed)
        stdout_rel = result.get("record", {}).get("stdout_path")
        if stdout_rel:
            stdout_path = resolve_path(stdout_rel)
            write_json(stdout_path, sanitized)
            result["record"]["stdout_redacted"] = kind in {"container", "image"}
            if kind in {"container", "image"}:
                result["record"]["redaction_kind"] = f"docker-{kind}-inspect-env-redacted"
        if isinstance(sanitized, list):
            rows.extend(sanitized)
    return rows


def docker_container_exists(name: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(
        ["container", "inspect", "--format", "{{.Id}}", name],
        report,
        label=f"container_exists_{safe_name(name)}",
    )
    return result["returncode"] == 0 and bool(result["stdout"].strip())


def image_exists(image: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(
        ["image", "inspect", "--format", "{{.Id}}", image],
        report,
        label=f"image_exists_{safe_name(image)}",
    )
    return result["returncode"] == 0 and bool(result["stdout"].strip())

def required_schema_table_map() -> dict[str, list[str]]:
    return {
        "core": split_semicolon(cfg_get("schema_authority.required_core_tables", "")),
        "local_llm": split_semicolon(cfg_get("schema_authority.required_local_llm_tables", "")),
        "eval": split_semicolon(cfg_get("schema_authority.required_eval_tables", "")),
    }


def required_extensions() -> list[str]:
    return split_semicolon(cfg_get("schema_authority.required_extensions", ""))


def discover_state(report: dict[str, Any]) -> dict[str, Any]:
    container_rows = docker_inspect("container", [active_container()], report, "postgres_container_inspect") if not report.get("failures") else []
    images = []
    for image in [
        str(cfg_get("postgresql.active_runtime_image", "")),
        str(cfg_get("postgresql.active_upstream_image", "")),
        str(cfg_get("postgresql.fallback_client_image", "")),
        str(cfg_get("postgresql.disposable_restore_image", "")),
    ]:
        if image:
            images.extend(docker_inspect("image", [image], report, "postgres_image_inspect"))
    versions = collect_versions(report) if not report.get("failures") else {}
    return {
        "container_name": active_container(),
        "container": container_rows[0] if container_rows else None,
        "images": images,
        "versions": versions,
        "ports": {"host": cfg_get("postgresql.active_host_port"), "container": cfg_get("postgresql.container_port")},
        "volume_name": cfg_get("postgresql.active_volume_name"),
        "authority_paths": authority_path_records(),
    }


def authority_path_records() -> dict[str, Any]:
    paths = {
        "data_stack_root": cfg_get("postgresql.data_stack_root"),
        "compose": cfg_get("postgresql.data_stack_compose"),
        "dockerfile": cfg_get("postgresql.data_stack_dockerfile"),
        "env_path_secret_reference_only": cfg_get("postgresql.data_stack_env_path"),
        "env_example": cfg_get("postgresql.data_stack_env_example_path"),
        "schema_authority_migration": cfg_get("postgresql.schema_authority_migration"),
        "local_llm_config": cfg_get("postgresql.local_llm_config_path"),
        "local_llm_runtime_env_secret_reference_only": cfg_get("postgresql.local_llm_runtime_env_path"),
    }
    records = {}
    for key, value in paths.items():
        path = Path(str(value)).expanduser()
        copy_payload = boolish(cfg_get("security.copy_env_files", False)) and "secret_reference_only" not in key and not str(path).endswith(".env")
        records[key] = file_record(path, include_hash=True, copy_payload=copy_payload)
        if str(path).endswith(".env") or "secret_reference_only" in key:
            records[key]["payload_copied"] = False
            records[key]["secret_boundary"] = "path/hash/metadata only; secret values are not copied by Row 16"
            env_values = parse_dotenv(path)
            records[key]["env_keys"] = sorted(env_values)
            records[key]["env_redacted"] = redacted_env(env_values)
    init_records = []
    for item in split_semicolon(cfg_get("postgresql.init_sql_paths", "")):
        init_records.append(file_record(Path(item).expanduser(), include_hash=True))
    records["init_sql_paths"] = init_records
    return records


def compare_major_versions(versions: dict[str, Any], report: dict[str, Any]) -> dict[str, Any]:
    expected_server = int(cfg_get("postgresql.expected_server_major", 18))
    required_client = int(cfg_get("postgresql.required_client_major", 18))
    checks = {
        "expected_server_major": expected_server,
        "required_client_major": required_client,
        "server_major": versions.get("server_major"),
        "pg_dump_major": versions.get("pg_dump_major"),
        "pg_restore_major": versions.get("pg_restore_major"),
        "pg_dumpall_major": versions.get("pg_dumpall_major"),
        "server_matches_expected": versions.get("server_major") == expected_server,
        "pg_dump_matches_server": versions.get("pg_dump_major") == versions.get("server_major"),
        "pg_restore_matches_server": versions.get("pg_restore_major") == versions.get("server_major"),
        "pg_dumpall_matches_server": versions.get("pg_dumpall_major") == versions.get("server_major"),
    }
    if not checks["server_matches_expected"]:
        report["failures"].append(f"server major mismatch: expected {expected_server}, observed {versions.get('server_major')}")
    for key in ("pg_dump_matches_server", "pg_restore_matches_server", "pg_dumpall_matches_server"):
        if not checks[key]:
            report["failures"].append(f"{key} failed: versions={versions}")
    if versions.get("pg_dump_major") != required_client:
        report["failures"].append(f"pg_dump major must be {required_client}; observed {versions.get('pg_dump_major')}")
    return checks


def json_agg_sql(inner: str) -> str:
    return f"SELECT COALESCE(jsonb_agg(to_jsonb(q)), '[]'::jsonb)::text FROM ({inner}) q;"


def cmd_discover_active_server(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("discover-active-server")
    report = report_base("discover-active-server", run_dir)
    report["mode"] = "capture"
    preflight(report)
    state = discover_state(report) if not report.get("failures") else {}
    path = run_dir / "postgresql_active_server_discovery.json"
    write_json(path, state)
    report["postgresql"] = {"discovery": rel(path), "container": active_container(), "database": required_database()}
    output_file(report, path, "json", "postgresql_active_server_discovery")
    return finalize_report(report, run_dir)


def cmd_assert_major_match(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-major-match")
    report = report_base("assert-major-match", run_dir)
    report["mode"] = "verify"
    preflight(report)
    versions = collect_versions(report) if not report.get("failures") else {}
    check = compare_major_versions(versions, report) if versions else {}
    path = run_dir / "postgresql_major_match.json"
    write_json(path, {"versions": versions, "check": check})
    report["postgresql"] = {"major_match": rel(path), **check}
    output_file(report, path, "json", "postgresql_major_match")
    return finalize_report(report, run_dir)


def cmd_capture_server(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-server")
    report = report_base("capture-server", run_dir)
    report["mode"] = "capture"
    preflight(report)
    state = discover_state(report) if not report.get("failures") else {}
    settings = {}
    for setting in ["server_version", "server_version_num", "data_directory", "config_file", "hba_file", "ident_file", "port", "listen_addresses", "shared_preload_libraries", "TimeZone"]:
        settings[setting] = single_value(f"SHOW {setting};", report, database=required_database(), label=f"show_{setting}") if not report.get("failures") else None
    roles = psql_json(json_agg_sql("""
        SELECT rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin,
               rolreplication, rolbypassrls, rolconnlimit, rolvaliduntil
        FROM pg_roles
        ORDER BY rolname
    """), report, database=maintenance_database(), label="role_inventory") if not report.get("failures") else []
    memberships = psql_json(json_agg_sql("""
        SELECT roleid::regrole::text AS role_name, member::regrole::text AS member_name,
               grantor::regrole::text AS grantor_name, admin_option, inherit_option, set_option
        FROM pg_auth_members
        ORDER BY role_name, member_name
    """), report, database=maintenance_database(), label="role_membership_inventory") if not report.get("failures") else []
    path = run_dir / "postgresql_server_capture.json"
    write_json(path, {"server": state, "settings": settings, "roles_no_passwords": roles or [], "memberships": memberships or [], "secret_boundary": "role password hashes are not captured"})
    report["server"] = {"capture": rel(path)}
    output_file(report, path, "json", "postgresql_server_capture")
    return finalize_report(report, run_dir)


def cmd_capture_extensions(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-extensions")
    report = report_base("capture-extensions", run_dir)
    report["mode"] = "capture"
    preflight(report)
    extensions = psql_json(json_agg_sql("""
        SELECT e.extname, e.extversion, n.nspname AS schema,
               e.extrelocatable
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        ORDER BY e.extname
    """), report, label="extension_inventory") if not report.get("failures") else []
    installed = {row.get("extname") for row in extensions or [] if isinstance(row, dict)}
    for required in required_extensions():
        if required not in installed:
            report["failures"].append(f"required PostgreSQL extension is missing: {required}")
    path = run_dir / "postgresql_extensions.json"
    write_json(path, {"extensions": extensions or [], "required_extensions": required_extensions(), "installed_required_extensions": sorted(installed.intersection(required_extensions()))})
    report["extensions"] = {"manifest": rel(path), "required_extensions": required_extensions()}
    output_file(report, path, "json", "postgresql_extensions")
    return finalize_report(report, run_dir)


def cmd_capture_schema_inventory(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-schema-inventory")
    report = report_base("capture-schema-inventory", run_dir)
    report["mode"] = "capture"
    preflight(report)
    payload = schema_inventory_payload(report) if not report.get("failures") else {}
    checks = validate_schema_authority(payload, report) if payload else {}
    path = run_dir / "postgresql_schema_inventory.json"
    write_json(path, {"inventory": payload, "schema_authority_checks": checks})
    report["schema_inventory"] = {"manifest": rel(path), "checks": checks}
    output_file(report, path, "json", "postgresql_schema_inventory")
    return finalize_report(report, run_dir)


def dump_root() -> Path:
    root = resolve_path(str(cfg_get("project.dump_root", "state/exports/16_postgresql/dumps")))
    root.mkdir(parents=True, exist_ok=True)
    return root


def latest_dump_for_database(database: str) -> Path | None:
    root = dump_root()
    safe = safe_name(database)
    candidates: list[Path] = []
    for pattern in (f"{safe}_*.dump", f"{safe}.dump"):
        candidates.extend(path for path in root.rglob(pattern) if path.is_file())
    unique = sorted(set(candidates), key=lambda path: (path.stat().st_mtime_ns, str(path)))
    return unique[-1] if unique else None


def cmd_dump_globals(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("dump-globals")
    report = report_base("dump-globals", run_dir)
    report["mode"] = "guarded-dump"
    preflight(report)
    if report.get("failures"):
        return finalize_report(report, run_dir)
    out = dump_root() / f"globals_{now_stamp()}{cfg_get('dump_policy.globals_extension', '.globals.sql')}"
    cmd = ["pg_dumpall", "--globals-only", "-U", pg_user()]
    if boolish(cfg_get("dump_policy.no_role_passwords_for_globals", True)):
        cmd.append("--no-role-passwords")
    result = run_cmd_binary_stdout_to_file([DOCKER, "exec", active_container(), *cmd], out, report, label="pg_dumpall_globals")
    if result["returncode"] != 0:
        report["failures"].append("pg_dumpall --globals-only failed")
    manifest = {"globals_dump": str(out), "sha256": sha256_file(out) if out.exists() else None, "no_role_passwords": boolish(cfg_get("dump_policy.no_role_passwords_for_globals", True)), "secret_boundary": "role password hashes intentionally excluded"}
    manifest_path = run_dir / "postgresql_globals_dump_manifest.json"
    write_json(manifest_path, manifest)
    report["dumps"] = {"globals_manifest": rel(manifest_path), "globals_dump": str(out)}
    output_file(report, manifest_path, "json", "postgresql_globals_dump_manifest")
    if out.exists():
        output_file(report, out, "sql", "postgresql_globals_dump", {"sha256": manifest["sha256"]})
    return finalize_report(report, run_dir)


def dump_database(database: str, report: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    out = dump_root() / f"{safe_name(database)}_{now_stamp()}{cfg_get('dump_policy.dump_extension', '.dump')}"
    cmd = ["pg_dump", "-Fc", "-Z", str(cfg_get("dump_policy.dump_compress", 6)), "-U", pg_user(), "-d", database]
    if boolish(cfg_get("dump_policy.include_blobs", True)):
        cmd.append("--blobs")
    result = run_cmd_binary_stdout_to_file([DOCKER, "exec", active_container(), *cmd], out, report, label=f"pg_dump_custom_{safe_name(database)}")
    record = {"database": database, "dump_path": str(out), "returncode": result["returncode"], "sha256": sha256_file(out) if out.exists() else None, "bytes": out.stat().st_size if out.exists() else 0}
    if result["returncode"] != 0:
        report["failures"].append(f"pg_dump custom-format failed for database: {database}")
    return record


def cmd_dump_database_custom(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("dump-database-custom")
    report = report_base("dump-database-custom", run_dir)
    report["mode"] = "guarded-dump"
    preflight(report)
    database = args.database or required_database()
    if database == maintenance_database() and not boolish(cfg_get("dump_policy.allow_dump_postgres_maintenance_db", False)):
        report["failures"].append("refusing to dump maintenance database unless dump_policy.allow_dump_postgres_maintenance_db=true")
    record = dump_database(database, report, run_dir) if not report.get("failures") else {"database": database}
    if boolish(cfg_get("dump_policy.verify_restore_list_after_dump", True)) and record.get("dump_path") and not report.get("failures"):
        verify_restore_list_for_dump(Path(record["dump_path"]), report, run_dir)
    manifest_path = run_dir / f"postgresql_{safe_name(database)}_dump_manifest.json"
    write_json(manifest_path, record)
    report["dumps"] = {"dump_manifest": rel(manifest_path), **record}
    output_file(report, manifest_path, "json", "postgresql_database_dump_manifest")
    if record.get("dump_path") and Path(record["dump_path"]).exists():
        output_file(report, Path(record["dump_path"]), "pg_dump_custom", f"postgresql_{database}_custom_dump", {"sha256": record.get("sha256")})
    return finalize_report(report, run_dir)


def cmd_dump_all_required(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("dump-all-required")
    report = report_base("dump-all-required", run_dir)
    report["mode"] = "guarded-dump"
    preflight(report)
    records: list[dict[str, Any]] = []
    bundle_dir = dump_root() / now_stamp()
    bundle_dir.mkdir(parents=True, exist_ok=True)

    if not report.get("failures"):
        globals_path = bundle_dir / f"globals{cfg_get('dump_policy.globals_extension', '.globals.sql')}"
        globals_cmd = ["pg_dumpall", "--globals-only", "-U", pg_user()]
        if boolish(cfg_get("dump_policy.no_role_passwords_for_globals", True)):
            globals_cmd.append("--no-role-passwords")
        globals_result = run_cmd_binary_stdout_to_file(
            [DOCKER, "exec", active_container(), *globals_cmd],
            globals_path,
            report,
            label="pg_dumpall_globals",
        )
        records.append({
            "kind": "globals",
            "path": str(globals_path),
            "returncode": globals_result["returncode"],
            "sha256": sha256_file(globals_path) if globals_path.exists() else None,
            "bytes": globals_path.stat().st_size if globals_path.exists() else 0,
            "no_role_passwords": boolish(cfg_get("dump_policy.no_role_passwords_for_globals", True)),
        })
        if globals_result["returncode"] != 0:
            report["failures"].append("pg_dumpall globals failed")

        for database in split_semicolon(cfg_get("dump_policy.dump_required_databases", required_database())):
            dump_path = bundle_dir / f"{safe_name(database)}{cfg_get('dump_policy.dump_extension', '.dump')}"
            dump_cmd = ["pg_dump", "-Fc", "-Z", str(cfg_get("dump_policy.dump_compress", 6)), "-U", pg_user(), "-d", database]
            if boolish(cfg_get("dump_policy.include_blobs", True)):
                dump_cmd.append("--blobs")
            dump_result = run_cmd_binary_stdout_to_file(
                [DOCKER, "exec", active_container(), *dump_cmd],
                dump_path,
                report,
                label=f"pg_dump_custom_{safe_name(database)}",
            )
            records.append({
                "kind": "database",
                "database": database,
                "dump_path": str(dump_path),
                "returncode": dump_result["returncode"],
                "sha256": sha256_file(dump_path) if dump_path.exists() else None,
                "bytes": dump_path.stat().st_size if dump_path.exists() else 0,
                "format": "custom",
            })
            if dump_result["returncode"] != 0:
                report["failures"].append(f"pg_dump custom-format failed for database: {database}")
                continue

            if boolish(cfg_get("dump_policy.verify_restore_list_after_dump", True)) and dump_path.exists():
                restore_list_record = verify_restore_list_for_dump(dump_path, report, bundle_dir)
                records.append({"kind": "restore_list", **restore_list_record})

    manifest_payload = {
        "generated_at": iso_now(),
        "schema": SCHEMA_NAME,
        "bundle_dir": str(bundle_dir),
        "active_container": active_container(),
        "required_database": required_database(),
        "maintenance_database": maintenance_database(),
        "raw_volume_primary_recovery": "forbidden; logical dumps are primary authority",
        "records": records,
    }
    manifest_path = bundle_dir / "postgresql_dump_manifest.json"
    write_json(manifest_path, manifest_payload)
    report["dumps"] = {"manifest": rel(manifest_path), "bundle_dir": rel(bundle_dir), "record_count": len(records)}
    output_file(report, manifest_path, "json", "postgresql_dump_manifest")

    for record in records:
        artifact_path = Path(str(record.get("path") or record.get("dump_path") or record.get("list_path") or ""))
        if artifact_path.exists():
            kind = "sql" if record.get("kind") == "globals" else "pg_dump_custom" if record.get("kind") == "database" else "text"
            output_file(report, artifact_path, kind, f"postgresql_{record.get('kind')}_artifact", {"sha256": sha256_file(artifact_path)})
    return finalize_report(report, run_dir)

def client_image() -> str:
    return str(cfg_get("postgresql.fallback_client_image", "postgres:18.4-trixie"))


def cmd_verify_restore_list(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-restore-list")
    report = report_base("verify-restore-list", run_dir)
    report["mode"] = "verify"
    preflight(report, require_container=False)
    dump_path = Path(args.dump).expanduser().resolve() if args.dump else latest_dump_for_database(args.database or required_database())
    if not dump_path or not dump_path.exists():
        report["failures"].append("no dump file supplied/found for pg_restore --list verification")
        result = {}
    else:
        result = verify_restore_list_for_dump(dump_path, report, run_dir)
    manifest_path = run_dir / "postgresql_restore_list_verification.json"
    write_json(manifest_path, result)
    report["restore"] = {"restore_list_verification": rel(manifest_path), **result}
    output_file(report, manifest_path, "json", "postgresql_restore_list_verification")
    return finalize_report(report, run_dir)


def restore_guard_token(database: str) -> str:
    return f"{cfg_get('restore_test_policy.restore_guard_prefix', 'POSTGRES_DISPOSABLE_RESTORE')}:{database}"


def require_restore_guard(args: argparse.Namespace, report: dict[str, Any], database: str) -> None:
    expected_token = restore_guard_token(database)
    env_name = str(cfg_get("restore_test_policy.restore_guard_env", "CONFIRM_POSTGRES_DISPOSABLE_RESTORE"))
    env_value = str(cfg_get("restore_test_policy.restore_guard_value", "I_UNDERSTAND_THIS_CREATES_A_DISPOSABLE_POSTGRES_RESTORE"))
    if args.confirm_token != expected_token:
        report["failures"].append(f"disposable restore requires --confirm-token {expected_token}")
    if os.environ.get(env_name) != env_value:
        report["failures"].append(f"disposable restore requires {env_name}={env_value}")


def disposable_container_name() -> str:
    return f"{cfg_get('restore_test_policy.disposable_container_prefix', 'recovery-postgres-restore')}-{now_stamp().lower()}"


def cmd_restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-plan")
    report = report_base("restore-plan", run_dir)
    report["mode"] = "plan"
    preflight(report, require_daemon=False, require_container=False)
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/16_postgresql")))
    generated_root.mkdir(parents=True, exist_ok=True)
    plan_path = generated_root / str(cfg_get("dump_policy.generated_restore_plan_name", "postgresql_restore_plan.md"))
    lines = [
        "# PostgreSQL logical restore plan",
        "",
        "Row 16 owns semantic database recoverability. It does not use the raw Docker volume as primary recovery authority.",
        "",
        "## Authority inputs",
        "",
        f"- Active container: `{active_container()}`",
        f"- Required database: `{required_database()}`",
        f"- Maintenance database visibility: `{maintenance_database()}`",
        f"- Required schemas: `{cfg_get('schema_authority.required_schemas')}`",
        f"- Required extensions: `{cfg_get('schema_authority.required_extensions')}`",
        f"- Schema authority migration: `{cfg_get('postgresql.schema_authority_migration')}`",
        "",
        "## Restore order",
        "",
        "1. Restore Docker availability through the Docker row, but do not treat `llm_database_pgdata` as the primary database recovery artifact.",
        "2. Recreate or start the PostgreSQL 18 + pgvector runtime from the data_stack authority.",
        "3. Restore globals from the Row 16 globals dump. Password hashes are intentionally not captured.",
        "4. Create the required database if it does not exist.",
        "5. Restore the custom-format database dump using matching-major `pg_restore`.",
        "6. Run `pg_restore --list` verification, schema/extension smoke checks, and row-count sanity.",
        "7. Start dependent apps only after the database gate passes.",
        "",
        "## Current configured paths",
        "",
        "~~~json",
        json.dumps(authority_path_records(), indent=2, sort_keys=True, default=str),
        "~~~",
        "",
    ]
    write_text(plan_path, "\n".join(lines))
    plan_path.chmod(int(str(cfg_get("dump_policy.generated_script_mode", "0600")), 8))
    report["restore"] = {"plan": rel(plan_path)}
    output_file(report, plan_path, "markdown", "postgresql_restore_plan")
    return finalize_report(report, run_dir)


def cmd_restore_smoke(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-smoke")
    report = report_base("restore-smoke", run_dir)
    report["mode"] = "verify"
    preflight(report)
    payload = {}
    payload["extensions"] = psql_json(json_agg_sql("SELECT extname, extversion FROM pg_extension ORDER BY extname"), report, label="smoke_extensions") or []
    payload["schemas"] = psql_json(json_agg_sql("SELECT nspname AS schema_name FROM pg_namespace WHERE nspname IN ('core','local_llm','eval') ORDER BY nspname"), report, label="smoke_schemas") or []
    payload["tables"] = psql_json(json_agg_sql("SELECT table_schema || '.' || table_name AS qualified_table FROM information_schema.tables WHERE table_schema IN ('core','local_llm','eval') ORDER BY 1"), report, label="smoke_tables") or []
    payload["boot_checks"] = psql_json(json_agg_sql("SELECT check_name, check_value, last_verified_at FROM core.boot_checks ORDER BY check_name"), report, label="smoke_boot_checks") or []
    payload["schema_versions"] = psql_json(json_agg_sql("SELECT component, version_label, phase, status FROM core.schema_version ORDER BY component"), report, label="smoke_schema_versions") or []
    required_tables = [
        f"{schema}.{table}"
        for schema, tables in required_schema_table_map().items()
        for table in tables
    ]
    installed_exts = {row.get("extname") for row in payload["extensions"] if isinstance(row, dict)}
    schema_names = {row.get("schema_name") for row in payload["schemas"] if isinstance(row, dict)}
    table_names = {row.get("qualified_table") for row in payload["tables"] if isinstance(row, dict)}
    payload["required_tables"] = required_tables
    payload["missing_required_tables"] = sorted(set(required_tables) - table_names)
    for ext in required_extensions():
        if ext not in installed_exts:
            report["failures"].append(f"restore smoke missing extension: {ext}")
    for schema in split_semicolon(cfg_get("schema_authority.required_schemas", "")):
        if schema not in schema_names:
            report["failures"].append(f"restore smoke missing schema: {schema}")
    if payload["missing_required_tables"]:
        report["failures"].append(f"restore smoke missing required tables: {payload['missing_required_tables']}")
    path = run_dir / "postgresql_restore_smoke.json"
    write_json(path, payload)
    report["restore"] = {
        "smoke": rel(path),
        "missing_required_tables": payload["missing_required_tables"],
    }
    output_file(report, path, "json", "postgresql_restore_smoke")
    return finalize_report(report, run_dir)


def cmd_row_count_sanity(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("row-count-sanity")
    report = report_base("row-count-sanity", run_dir)
    report["mode"] = "verify"
    preflight(report)
    rows = []
    missing = []
    for schema, tables in required_schema_table_map().items():
        for table in tables:
            qualified = f"{schema}.{table}"
            exists = single_value(
                f"SELECT to_regclass('{schema}.{table}') IS NOT NULL;",
                report,
                label=f"row_count_exists_{schema}_{table}",
            )
            if exists != "t":
                rows.append({"table": qualified, "exists": False, "row_count": None})
                missing.append(qualified)
                continue
            sql = f'SELECT count(*)::text FROM "{schema}"."{table}";'
            value = single_value(sql, report, label=f"row_count_{schema}_{table}")
            if value is None or not value.isdigit():
                rows.append({"table": qualified, "exists": True, "row_count": None, "count_query_ok": False})
                report["failures"].append(f"row-count query failed for required table: {qualified}")
                continue
            rows.append({"table": qualified, "exists": True, "row_count": int(value), "count_query_ok": True})
    if missing:
        report["failures"].append(f"row-count sanity missing required tables: {missing}")
    path = run_dir / "postgresql_row_count_sanity.json"
    write_json(path, {"row_counts": rows, "missing_tables": missing})
    report["row_counts"] = {"manifest": rel(path), "table_count": len(rows), "missing_tables": missing}
    output_file(report, path, "json", "postgresql_row_count_sanity")
    return finalize_report(report, run_dir)

def schema_inventory_payload(report: dict[str, Any]) -> dict[str, Any]:
    schemas = psql_json(json_agg_sql("""
        SELECT schema_name
        FROM information_schema.schemata
        WHERE schema_name NOT LIKE 'pg_%' AND schema_name <> 'information_schema'
        ORDER BY schema_name
    """), report, label="schema_inventory") or []
    tables = psql_json(json_agg_sql("""
        SELECT table_schema, table_name, table_type
        FROM information_schema.tables
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name
    """), report, label="table_inventory") or []
    sequences = psql_json(json_agg_sql("""
        SELECT sequence_schema, sequence_name, data_type, start_value, minimum_value,
               maximum_value, increment
        FROM information_schema.sequences
        WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY sequence_schema, sequence_name
    """), report, label="sequence_inventory") or []
    columns = psql_json(json_agg_sql("""
        SELECT table_schema, table_name, column_name, ordinal_position, data_type, udt_name,
               is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name, ordinal_position
    """), report, label="column_inventory") or []
    indexes = psql_json(json_agg_sql("""
        SELECT schemaname, tablename, indexname, indexdef
        FROM pg_indexes
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ORDER BY schemaname, tablename, indexname
    """), report, label="index_inventory") or []
    constraints = psql_json(json_agg_sql("""
        SELECT tc.constraint_schema, tc.table_schema, tc.table_name,
               tc.constraint_name, tc.constraint_type
        FROM information_schema.table_constraints tc
        WHERE tc.table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY tc.table_schema, tc.table_name, tc.constraint_name
    """), report, label="constraint_inventory") or []
    routines = psql_json(json_agg_sql("""
        SELECT routine_schema, routine_name, routine_type, data_type
        FROM information_schema.routines
        WHERE routine_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY routine_schema, routine_name
    """), report, label="routine_inventory") or []
    triggers = psql_json(json_agg_sql("""
        SELECT trigger_schema, event_object_schema, event_object_table, trigger_name,
               event_manipulation, action_timing
        FROM information_schema.triggers
        WHERE trigger_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY trigger_schema, event_object_table, trigger_name
    """), report, label="trigger_inventory") or []
    grants = psql_json(json_agg_sql("""
        SELECT grantee, table_schema, table_name, privilege_type
        FROM information_schema.role_table_grants
        WHERE table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY table_schema, table_name, grantee, privilege_type
    """), report, label="grant_inventory") or []
    comments = psql_json(json_agg_sql("""
        SELECT n.nspname AS schema_name, c.relname AS object_name, c.relkind,
               obj_description(c.oid, 'pg_class') AS comment
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND obj_description(c.oid, 'pg_class') IS NOT NULL
        ORDER BY n.nspname, c.relname
    """), report, label="comment_inventory") or []
    fts = psql_json(json_agg_sql("""
        SELECT n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name,
               t.typname AS type_name
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND t.typname = 'tsvector'
          AND a.attnum > 0
        ORDER BY n.nspname, c.relname, a.attname
    """), report, label="fts_tsvector_columns") or []
    vector_columns = psql_json(json_agg_sql("""
        SELECT n.nspname AS schema_name, c.relname AS table_name, a.attname AS column_name,
               t.typname AS type_name, format_type(a.atttypid, a.atttypmod) AS formatted_type
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
          AND t.typname = 'vector'
          AND a.attnum > 0
        ORDER BY n.nspname, c.relname, a.attname
    """), report, label="pgvector_columns") or []
    vector_indexes = psql_json(json_agg_sql("""
        SELECT schemaname, tablename, indexname, indexdef
        FROM pg_indexes
        WHERE indexdef ILIKE '% USING hnsw %'
           OR indexdef ILIKE '% USING ivfflat %'
           OR indexdef ILIKE '% vector_%'
        ORDER BY schemaname, tablename, indexname
    """), report, label="vector_index_inventory") or []
    return {
        "schemas": schemas,
        "tables": tables,
        "sequences": sequences,
        "columns": columns,
        "indexes": indexes,
        "constraints": constraints,
        "routines": routines,
        "triggers": triggers,
        "grants": grants,
        "comments": comments,
        "fts_tsvector_columns": fts,
        "pgvector_columns": vector_columns,
        "vector_indexes": vector_indexes,
    }


def validate_schema_authority(payload: dict[str, Any], report: dict[str, Any]) -> dict[str, Any]:
    table_set = {(row.get("table_schema"), row.get("table_name")) for row in payload.get("tables", []) if isinstance(row, dict)}
    schema_set = {row.get("schema_name") for row in payload.get("schemas", []) if isinstance(row, dict)}
    index_set = {(row.get("schemaname"), row.get("indexname")) for row in payload.get("indexes", []) if isinstance(row, dict)}
    checks: dict[str, Any] = {"required": {}, "forbidden": {}, "fts": {}, "pgvector": {}, "ok": True}
    for schema in split_semicolon(cfg_get("schema_authority.required_schemas", "")):
        present = schema in schema_set
        checks["required"][f"schema:{schema}"] = present
        if not present:
            report["failures"].append(f"required schema missing: {schema}")
    for schema, tables in required_schema_table_map().items():
        for table in tables:
            present = (schema, table) in table_set
            checks["required"][f"table:{schema}.{table}"] = present
            if not present:
                report["failures"].append(f"required table missing: {schema}.{table}")
    for schema in split_semicolon(cfg_get("schema_authority.forbidden_schemas", "")):
        present = schema in schema_set
        checks["forbidden"][f"schema:{schema}"] = not present
        if present:
            report["failures"].append(f"forbidden legacy schema present: {schema}")
    for table in split_semicolon(cfg_get("schema_authority.forbidden_local_llm_tables", "")):
        if ("local_llm", table) in table_set:
            checks["forbidden"][f"table:local_llm.{table}"] = False
            report["failures"].append(f"forbidden local_llm table present: local_llm.{table}")
    for table in split_semicolon(cfg_get("schema_authority.forbidden_eval_tables", "")):
        if ("eval", table) in table_set:
            checks["forbidden"][f"table:eval.{table}"] = False
            report["failures"].append(f"forbidden eval table present: eval.{table}")
    for table in split_semicolon(cfg_get("schema_authority.forbidden_model_runtime_tables", "")):
        if ("model_runtime", table) in table_set:
            checks["forbidden"][f"table:model_runtime.{table}"] = False
            report["failures"].append(f"forbidden model_runtime table present: model_runtime.{table}")
    for view in split_semicolon(cfg_get("schema_authority.forbidden_eval_views", "")):
        if ("eval", view) in table_set:
            checks["forbidden"][f"view:eval.{view}"] = False
            report["failures"].append(f"forbidden eval view present: eval.{view}")
    fts_cols = payload.get("fts_tsvector_columns", [])
    checks["fts"]["local_llm_chunks_search_vector_present"] = any(
        row.get("schema_name") == "local_llm" and row.get("table_name") == "chunks" and row.get("column_name") == "search_vector"
        for row in fts_cols if isinstance(row, dict)
    )
    if not checks["fts"]["local_llm_chunks_search_vector_present"]:
        report["failures"].append("required PostgreSQL FTS column missing: local_llm.chunks.search_vector")
    checks["pgvector"]["vector_columns_count"] = len(payload.get("pgvector_columns", []) or [])
    checks["pgvector"]["vector_indexes_count"] = len(payload.get("vector_indexes", []) or [])
    checks["pgvector"]["vector_indexes_required"] = False
    checks["ok"] = not report.get("failures")
    return checks


def cmd_list_databases(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("list-databases")
    report = report_base("list-databases", run_dir)
    report["mode"] = "capture"
    preflight(report)
    dbs = psql_json(json_agg_sql("""
        SELECT d.datname, pg_catalog.pg_get_userbyid(d.datdba) AS owner,
               pg_encoding_to_char(d.encoding) AS encoding,
               d.datcollate, d.datctype, d.datistemplate, d.datallowconn,
               pg_database_size(d.datname) AS size_bytes
        FROM pg_database d
        ORDER BY d.datname
    """), report, database=maintenance_database(), label="database_inventory") if not report.get("failures") else []
    names = {row.get("datname") for row in (dbs or []) if isinstance(row, dict)}
    required = split_semicolon(cfg_get("postgresql.required_databases", required_database() + ";" + maintenance_database()))
    missing = [db for db in required if db not in names]
    if required_database() not in names:
        report["failures"].append(f"required database is missing: {required_database()}")
    if maintenance_database() not in names:
        report["failures"].append(f"maintenance database is not visible: {maintenance_database()}")
    path = run_dir / "postgresql_database_inventory.json"
    write_json(path, {"databases": dbs or [], "required_databases": required, "missing_databases": missing})
    report["databases"] = {"inventory": rel(path), "missing_databases": missing}
    output_file(report, path, "json", "postgresql_database_inventory")
    return finalize_report(report, run_dir)



def verify_restore_list_for_dump(dump_path: Path, report: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    list_path = run_dir / f"{dump_path.name}.pg_restore_list.txt"
    active_attempt: dict[str, Any] | None = None

    if command_exists(DOCKER) and docker_container_exists(active_container(), report):
        active_result = run_cmd_binary_file_input(
            [DOCKER, "exec", "-i", active_container(), "pg_restore", "--list"],
            dump_path,
            list_path,
            report,
            label=f"pg_restore_list_active_{safe_name(dump_path.name)}",
        )
        active_ok = active_result["returncode"] == 0 and list_path.exists() and list_path.stat().st_size > 0
        active_attempt = {
            "tool_source": "active_container",
            "returncode": active_result["returncode"],
            "list_path": rel(list_path) if list_path.exists() else None,
            "verified": active_ok,
        }
        if active_ok:
            output_file(report, list_path, "text", f"pg_restore_list_{dump_path.name}")
            return {"dump_path": str(dump_path), **active_attempt}
        report["warnings"].append(
            f"active-container pg_restore --list did not verify dump; attempting fallback client image: {dump_path}"
        )

    image = client_image()
    if boolish(cfg_get("restore_test_policy.helper_image_must_exist_locally", True)) and not image_exists(image, report):
        report["warnings"].append(f"client image not locally inspectable; cannot run fallback pg_restore --list: {image}")
        return {"dump_path": str(dump_path), "verified": False, "reason": "client image unavailable", "active_attempt": active_attempt}
    mount_dir = dump_path.parent.resolve()
    inside = f"/backup/{dump_path.name}"
    args = ["run", "--rm"]
    if boolish(cfg_get("restore_test_policy.no_auto_pull", True)):
        args += ["--pull", "never"]
    args += ["-v", f"{mount_dir}:/backup:ro", image, "pg_restore", "--list", inside]
    result = docker_cmd(args, report, label=f"pg_restore_list_fallback_{safe_name(dump_path.name)}")
    write_text(list_path, result["stdout"])
    ok = result["returncode"] == 0 and bool(result["stdout"].strip())
    if not ok:
        report["failures"].append(f"fallback pg_restore --list failed for dump: {dump_path}")
    output_file(report, list_path, "text", f"pg_restore_list_{dump_path.name}")
    return {
        "dump_path": str(dump_path),
        "list_path": rel(list_path),
        "verified": ok,
        "returncode": result["returncode"],
        "tool_source": "fallback_client_image",
        "active_attempt": active_attempt,
    }

def run_cmd_binary_file_input(argv: list[str], input_file: Path, out_file: Path, report: dict[str, Any], *, label: str) -> dict[str, Any]:
    out_file.parent.mkdir(parents=True, exist_ok=True)
    safe = safe_name(label)
    run_dir = resolve_path(report["run_dir"])
    stderr_path = run_dir / f"{safe}.stderr.txt"
    with input_file.open("rb") as stdin_source, out_file.open("wb") as stdout_target:
        proc = subprocess.run(argv, stdin=stdin_source, stdout=stdout_target, stderr=subprocess.PIPE)
    stderr_text = proc.stderr.decode("utf-8", errors="replace")
    write_text(stderr_path, stderr_text)
    record = {
        "argv": argv[:],
        "returncode": proc.returncode,
        "binary_input_path": rel(input_file),
        "binary_stdout_path": rel(out_file),
        "stderr_path": rel(stderr_path),
        "stderr": stderr_text,
        "streaming_stdin": True,
        "streaming_stdout": True,
    }
    report["commands"].append(record)
    return {"argv": argv[:], "returncode": proc.returncode, "stdout_path": out_file, "stderr": stderr_text, "record": record}

def docker_exec_named(container: str, args: list[str], report: dict[str, Any], *, label: str) -> dict[str, Any]:
    return docker_cmd(["exec", container, *args], report, label=label)


def run_restore_smoke_queries(container: str, database: str, report: dict[str, Any]) -> dict[str, Any]:
    required_schemas = split_semicolon(cfg_get("restore_test_policy.smoke_required_schemas", "core;local_llm;eval"))
    required_exts = split_semicolon(cfg_get("restore_test_policy.smoke_required_extensions", "pgcrypto;vector"))
    required_tables = [
        f"{schema}.{table}"
        for schema, tables in required_schema_table_map().items()
        for table in tables
    ]
    schema_sql = "SELECT nspname FROM pg_namespace WHERE nspname IN (" + ",".join("'" + s.replace("'", "''") + "'" for s in required_schemas) + ") ORDER BY nspname;"
    ext_sql = "SELECT extname FROM pg_extension WHERE extname IN (" + ",".join("'" + e.replace("'", "''") + "'" for e in required_exts) + ") ORDER BY extname;"
    table_sql = "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema IN ('core','local_llm','eval') ORDER BY 1;"
    results = {}
    for label, sql in [("schemas", schema_sql), ("extensions", ext_sql), ("tables", table_sql)]:
        res = docker_exec_named(container, ["psql", "-U", "postgres", "-d", database, "-At", "-c", sql], report, label=f"restore_smoke_{label}")
        lines = [line.strip() for line in res["stdout"].splitlines() if line.strip()]
        results[label] = {"returncode": res["returncode"], "rows": lines}
    missing_schemas = sorted(set(required_schemas) - set(results["schemas"]["rows"]))
    missing_exts = sorted(set(required_exts) - set(results["extensions"]["rows"]))
    missing_tables = sorted(set(required_tables) - set(results["tables"]["rows"]))
    results["required_schemas"] = required_schemas
    results["required_extensions"] = required_exts
    results["required_tables"] = required_tables
    results["missing_schemas"] = missing_schemas
    results["missing_extensions"] = missing_exts
    results["missing_tables"] = missing_tables
    if missing_schemas:
        report["failures"].append(f"disposable restore smoke missing schemas: {missing_schemas}")
    if missing_exts:
        report["failures"].append(f"disposable restore smoke missing extensions: {missing_exts}")
    if missing_tables:
        report["failures"].append(f"disposable restore smoke missing required tables: {missing_tables}")
    return results


def cmd_restore_disposable(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-disposable")
    report = report_base("restore-disposable", run_dir)
    report["mode"] = "guarded-restore" if args.execute else "plan"
    preflight(report, require_container=False)
    source_database = args.database or required_database()
    dump_path = Path(args.dump).expanduser().resolve() if args.dump else latest_dump_for_database(source_database)
    image = str(cfg_get("postgresql.disposable_restore_image", "pgvector/pgvector:0.8.2-pg18-trixie"))
    image_ok = image_exists(image, report) if not report.get("failures") else False
    container = disposable_container_name()
    restore_db = str(cfg_get("restore_test_policy.disposable_database_name", "llm_database_restore"))
    volume_prefix = str(cfg_get("restore_test_policy.disposable_volume_prefix", "recovery-postgres-restore-pgdata"))
    pgdata_volume = f"{volume_prefix}-{now_stamp().lower()}"

    if not dump_path or not dump_path.exists():
        report["failures"].append(f"no custom dump found for disposable restore: database={source_database}")
    if not image_ok:
        msg = f"disposable restore image is not available locally and Row 16 will not auto-pull: {image}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    if boolish(cfg_get("restore_test_policy.restore_disposable_requires_execute", True)) and not args.execute:
        report["warnings"].append("disposable restore was not executed because --execute was not supplied")
    else:
        require_restore_guard(args, report, source_database)

    plan = {
        "source_database": source_database,
        "dump_path": str(dump_path) if dump_path else None,
        "dump_exists": bool(dump_path and dump_path.exists()),
        "disposable_restore_image": image,
        "image_exists_locally": image_ok,
        "container": container,
        "pgdata_volume": pgdata_volume,
        "required_token": restore_guard_token(source_database),
        "required_env": {
            "name": cfg_get("restore_test_policy.restore_guard_env"),
            "value": cfg_get("restore_test_policy.restore_guard_value"),
        },
        "execute": bool(args.execute),
        "auth_method": cfg_get("postgresql.disposable_host_auth_method", "trust"),
        "password_persistence": "none; disposable container uses POSTGRES_HOST_AUTH_METHOD=trust under explicit guard",
        "storage_model": "named disposable Docker volume; removed by default after verification",
    }
    if report.get("failures") or not args.execute:
        plan_path = run_dir / "postgresql_disposable_restore_plan.json"
        write_json(plan_path, plan)
        output_file(report, plan_path, "json", "postgresql_disposable_restore_plan")
        report["restore"] = {"plan": rel(plan_path), **plan}
        return finalize_report(report, run_dir)

    pull_policy = ["--pull", "never"] if boolish(cfg_get("restore_test_policy.no_auto_pull", True)) else []
    mount_dir = dump_path.parent.resolve()
    created_container = False
    created_volume = False
    keep = boolish(cfg_get("restore_test_policy.keep_disposable_container", False)) or bool(args.keep_container)

    try:
        volume_create = docker_cmd(["volume", "create", pgdata_volume], report, label="disposable_pgdata_volume_create")
        if volume_create["returncode"] != 0:
            report["failures"].append(f"failed to create disposable PostgreSQL data volume: {pgdata_volume}")
            return finalize_report(report, run_dir)
        created_volume = True

        rm_policy = [] if keep else ["--rm"]
        run_args = [
            "run", "-d", *rm_policy, *pull_policy, "--name", container,
            "-e", f"POSTGRES_HOST_AUTH_METHOD={cfg_get('postgresql.disposable_host_auth_method', 'trust')}",
            "-e", "POSTGRES_DB=postgres",
            "-v", f"{pgdata_volume}:/var/lib/postgresql/data",
            "-v", f"{mount_dir}:/backup:ro",
            image,
        ]
        result = docker_cmd(run_args, report, label="disposable_postgres_run")
        if result["returncode"] != 0:
            report["failures"].append(f"failed to start disposable PostgreSQL restore container: {result['stderr'].strip()}")
            return finalize_report(report, run_dir)
        created_container = True

        deadline = time.time() + int(cfg_get("restore_test_policy.restore_timeout_seconds", 120))
        ready = False
        while time.time() < deadline:
            pg_ready = docker_exec_named(container, ["pg_isready", "-U", "postgres", "-d", "postgres", "-h", "localhost"], report, label="disposable_pg_isready")
            if pg_ready["returncode"] == 0:
                ready = True
                break
            time.sleep(2)
        if not ready:
            report["failures"].append("disposable PostgreSQL restore container did not become ready")
        else:
            createdb = docker_exec_named(container, ["createdb", "-U", "postgres", restore_db], report, label="disposable_createdb")
            if createdb["returncode"] != 0:
                report["failures"].append("failed to create disposable restore database")
            restore_cmd = ["pg_restore", "-U", "postgres", "-d", restore_db]
            if boolish(cfg_get("restore_test_policy.restore_with_exit_on_error", True)):
                restore_cmd.append("--exit-on-error")
            if boolish(cfg_get("restore_test_policy.restore_with_no_owner", True)):
                restore_cmd.append("--no-owner")
            if boolish(cfg_get("restore_test_policy.restore_with_no_privileges", True)):
                restore_cmd.append("--no-privileges")
            restore_cmd.append(f"/backup/{dump_path.name}")
            restore = docker_exec_named(container, restore_cmd, report, label="disposable_pg_restore")
            if restore["returncode"] != 0:
                report["failures"].append("pg_restore into disposable PostgreSQL container failed")
            smoke = run_restore_smoke_queries(container, restore_db, report)
            result_payload = {**plan, "container": container, "restored_database": restore_db, "pgdata_volume": pgdata_volume, "smoke": smoke, "kept": keep}
            result_path = run_dir / "postgresql_disposable_restore_result.json"
            write_json(result_path, result_payload)
            output_file(report, result_path, "json", "postgresql_disposable_restore_result")
            report["restore"] = {"result": rel(result_path), "container": container, "restored_database": restore_db, "pgdata_volume": pgdata_volume, "kept": keep}
    finally:
        if not keep:
            if created_container:
                docker_cmd(["rm", "-f", container], report, label="cleanup_disposable_restore_container")
            if created_volume:
                docker_cmd(["volume", "rm", "-f", pgdata_volume], report, label="cleanup_disposable_restore_volume")
        else:
            report["warnings"].append(f"disposable restore container/volume kept by request: {container} :: {pgdata_volume}")
    return finalize_report(report, run_dir)

def cmd_gate(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("gate")
    report = report_base("gate", run_dir)
    report["mode"] = "verify"
    preflight(report)
    state: dict[str, Any] = {}
    if not report.get("failures"):
        versions = collect_versions(report)
        state["major_match"] = compare_major_versions(versions, report)
        dbs = psql_json(json_agg_sql("""
            SELECT datname FROM pg_database ORDER BY datname
        """), report, database=maintenance_database(), label="gate_database_inventory") or []
        names = {row.get("datname") for row in dbs if isinstance(row, dict)}
        required_dbs = split_semicolon(cfg_get("postgresql.required_databases", required_database() + ";" + maintenance_database()))
        missing_dbs = [db for db in required_dbs if db not in names]
        if missing_dbs:
            report["failures"].append(f"gate missing required databases: {missing_dbs}")
        extensions = psql_json(json_agg_sql("SELECT extname, extversion FROM pg_extension ORDER BY extname"), report, label="gate_extensions") or []
        installed_exts = {row.get("extname") for row in extensions if isinstance(row, dict)}
        for ext in required_extensions():
            if ext not in installed_exts:
                report["failures"].append(f"gate missing required extension: {ext}")
        inventory = schema_inventory_payload(report)
        state["database_inventory"] = {"required_databases": required_dbs, "missing_databases": missing_dbs}
        state["schema_authority"] = validate_schema_authority(inventory, report)
        state["extension_inventory"] = {"required_extensions": required_extensions(), "installed_required_extensions": sorted(installed_exts.intersection(required_extensions()))}
        state["database"] = required_database()
        state["raw_volume_primary_recovery"] = "forbidden; logical dumps are primary authority"
    path = run_dir / "postgresql_gate.json"
    write_json(path, state)
    report["gate"] = {"manifest": rel(path), **state}
    output_file(report, path, "json", "postgresql_gate")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("discover-active-server").set_defaults(func=cmd_discover_active_server)
    sub.add_parser("assert-major-match").set_defaults(func=cmd_assert_major_match)
    sub.add_parser("list-databases").set_defaults(func=cmd_list_databases)
    sub.add_parser("capture-server").set_defaults(func=cmd_capture_server)
    sub.add_parser("capture-extensions").set_defaults(func=cmd_capture_extensions)
    sub.add_parser("capture-schema-inventory").set_defaults(func=cmd_capture_schema_inventory)
    sub.add_parser("dump-globals").set_defaults(func=cmd_dump_globals)

    p = sub.add_parser("dump-database-custom")
    p.add_argument("--database", default=None)
    p.set_defaults(func=cmd_dump_database_custom)

    sub.add_parser("dump-all-required").set_defaults(func=cmd_dump_all_required)

    p = sub.add_parser("verify-restore-list")
    p.add_argument("--dump", default=None)
    p.add_argument("--database", default=None)
    p.set_defaults(func=cmd_verify_restore_list)

    sub.add_parser("restore-plan").set_defaults(func=cmd_restore_plan)

    p = sub.add_parser("restore-disposable")
    p.add_argument("--dump", default=None)
    p.add_argument("--database", default=None)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--keep-container", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.set_defaults(func=cmd_restore_disposable)

    sub.add_parser("restore-smoke").set_defaults(func=cmd_restore_smoke)
    sub.add_parser("row-count-sanity").set_defaults(func=cmd_row_count_sanity)
    sub.add_parser("gate").set_defaults(func=cmd_gate)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:
        run_dir = make_run_dir("error")
        report = report_base(getattr(args, "command", "error"), run_dir)
        report["failures"].append(str(exc))
        return finalize_report(report, run_dir)


if __name__ == "__main__":
    raise SystemExit(main(ARGS))
PYCODE