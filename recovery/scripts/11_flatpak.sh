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
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "11_flatpak.sh"
SCHEMA_NAME = "recovery.flatpak.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "flatpak",
        "verified_flatpak_version": "1.14.6",
        "layer": "11_flatpak_app_runtime_remote_override_reinstall",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/11_flatpak",
        "generated_root": "state/generated/11_flatpak",
    },
    "commands": {
        "flatpak": "/usr/bin/flatpak",
        "sha256sum": "/usr/bin/sha256sum",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "flatpak_report.json",
        "restore_plan_name": "flatpak_restore_plan.md",
        "reinstall_script_name": "reinstall_flatpaks.review.sh",
        "generated_script_mode": "0600",
        "reinstall_execution_guard_env": "CONFIRM_FLATPAK_REINSTALL",
        "reinstall_execution_guard_value": "I_UNDERSTAND_THIS_REINSTALLS_FLATPAKS",
        "include_system_scope": True,
        "include_user_scope": True,
        "include_all_scope_summary": True,
        "include_disabled_remotes": True,
        "fail_if_flatpak_missing": True,
        "fail_if_flatpak_version_unexpected": False,
        "app_data_inventory_max_entries_per_app": 4000,
        "app_data_hash_small_files": True,
        "app_data_hash_max_bytes": 1048576,
        "app_data_warn_if_missing": True,
        "offline_export_plan_only": True,
        "offline_artifact_required": False,
        "reinstall_script_installs_apps": True,
        "reinstall_script_installs_explicit_runtimes": False,
        "reinstall_script_restores_overrides_as_comments": True,
        "package_install_chunk_size": 40,
    },
    "paths": {
        "system_installation_root": "/var/lib/flatpak",
        "user_installation_root": "~/.local/share/flatpak",
        "user_app_data_root": "~/.var/app",
        "system_config_dirs": "/etc/flatpak;/var/lib/flatpak/repo/config;/var/lib/flatpak/repo/refs/remotes",
        "user_config_dirs": "~/.local/share/flatpak/repo/config;~/.local/share/flatpak/repo/refs/remotes",
        "offline_artifact_roots": "state/offline_flatpak;/mnt/wantless_recovery/offline_flatpak",
        "app_data_subdirs": "config;data;cache",
    },
    "capture": {
        "remote_columns": "name;url;collection-id;priority;options;installation;title",
        "app_columns": "application;ref;origin;branch;arch;version;installation;size;options",
        "runtime_columns": "application;ref;origin;branch;arch;version;installation;size;options",
        "info_fields": "ref;origin;collection;runtime;sdk;branch;arch;version;license;installed-size;location",
        "permission_commands_enabled": True,
    },
    "generated_restore": {
        "default_install_scope": "preserve",
        "remote_add_mode": "if-not-exists",
        "app_install_mode": "noninteractive_assumeyes",
        "include_remote_add_commands": True,
        "include_app_install_commands": True,
        "include_runtime_install_commands": False,
        "include_override_review_block": True,
        "include_app_data_restore_note": True,
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


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    result = deepcopy(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config() -> dict[str, Any]:
    path = PROJECT_ROOT / "configs" / "11_flatpak.yaml"
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


FLATPAK = cmd_path("flatpak")
SHA256SUM = cmd_path("sha256sum")


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


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/11_flatpak")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "11_flatpak.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "11_flatpak.config.snapshot.yaml")
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
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def file_record(path: Path, *, include_hash: bool = True) -> dict[str, Any]:
    try:
        st = path.lstat()
    except OSError as exc:
        return {"path": str(path), "exists": False, "error": str(exc)}
    payload: dict[str, Any] = {
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
    }
    if path.is_symlink():
        try:
            payload["symlink_target"] = os.readlink(path)
        except OSError as exc:
            payload["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink():
        payload["sha256"] = sha256_file(path)
    return payload


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "flatpak",
            "script": SCRIPT_NAME,
            "flatpak_path": FLATPAK,
            "flatpak_version": None,
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
    report_path = run_dir / str(cfg_get("policy.report_name", "flatpak_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    run_dir = resolve_path(report["run_dir"])
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    record = {
        "argv": argv[:],
        "returncode": proc.returncode,
        "stdout_path": rel(stdout_path),
        "stderr_path": rel(stderr_path),
        "stderr": proc.stderr,
    }
    report["commands"].append(record)
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(argv)} :: {proc.stderr.strip()}")
    return {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "record": record}


def run_flatpak(report: dict[str, Any], args: list[str], *, label: str, check: bool = False) -> dict[str, Any]:
    return run_cmd([FLATPAK, *args], report, label=label, check=check)


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def preflight(report: dict[str, Any]) -> None:
    if not command_exists(FLATPAK):
        msg = f"flatpak command not found at configured path: {FLATPAK}"
        if boolish(cfg_get("policy.fail_if_flatpak_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
        return
    version = run_cmd([FLATPAK, "--version"], report, label="flatpak_version", check=False)
    if version["returncode"] == 0:
        text = (version["stdout"] or version["stderr"]).strip()
        report["tool"]["flatpak_version"] = text
        expected = str(cfg_get("tool.verified_flatpak_version", "")).strip()
        if expected and expected not in text:
            msg = f"flatpak version differs from verified target {expected!r}: {text!r}"
            if boolish(cfg_get("policy.fail_if_flatpak_version_unexpected", False)):
                report["failures"].append(msg)
            else:
                report["warnings"].append(msg)
    else:
        report["failures"].append("flatpak --version failed")


def tabular_lines(stdout: str) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in stdout.splitlines():
        if not line.strip():
            continue
        if "\t" in line:
            rows.append(line.split("\t"))
        else:
            rows.append(re.split(r"\s{2,}", line.strip()))
    return rows


def row_to_dict(row: list[str], columns: list[str]) -> dict[str, str]:
    return {columns[index]: row[index] if index < len(row) else "" for index in range(len(columns))}


def remotes_command(prefix: list[str], *, columns: str | None = None, show_disabled: bool = True) -> list[str]:
    argv = [*prefix, "remotes", "--show-details"]
    if show_disabled:
        argv.append("--show-disabled")
    if columns:
        argv.append(f"--columns={columns}")
    return argv


def run_remotes_capture(report: dict[str, Any], scope: str, *, columns: str | None, label_prefix: str) -> dict[str, Any]:
    prefix = scoped_prefix(scope)
    show_disabled = boolish(cfg_get("policy.include_disabled_remotes", True))
    result = run_flatpak(report, remotes_command(prefix, columns=columns, show_disabled=show_disabled), label=f"{label_prefix}_{scope}", check=False)
    if result["returncode"] != 0 and show_disabled:
        report["warnings"].append(f"remote capture with --show-disabled failed for {scope}; retrying without --show-disabled")
        result = run_flatpak(report, remotes_command(prefix, columns=columns, show_disabled=False), label=f"{label_prefix}_{scope}_no_disabled", check=False)
    if result["returncode"] != 0 and columns:
        report["warnings"].append(f"remote column capture failed for {scope}; retrying without explicit columns")
        result = run_flatpak(report, remotes_command(prefix, columns=None, show_disabled=False), label=f"{label_prefix}_{scope}_fallback", check=False)
    return result


def remote_is_disabled(remote: dict[str, Any]) -> bool:
    options = str(remote.get("options", "") or "")
    return bool(re.search(r"(^|[,;\s])disabled($|[,;\s])", options, re.IGNORECASE))


def scoped_prefix(scope: str) -> list[str]:
    if scope == "system":
        return ["--system"]
    if scope == "user":
        return ["--user"]
    return []


def enabled_scopes(*, include_all: bool = False) -> list[str]:
    scopes: list[str] = []
    if include_all and boolish(cfg_get("policy.include_all_scope_summary", True)):
        scopes.append("all")
    if boolish(cfg_get("policy.include_system_scope", True)):
        scopes.append("system")
    if boolish(cfg_get("policy.include_user_scope", True)):
        scopes.append("user")
    return scopes


def columns_csv(key: str) -> str:
    return ",".join(split_semicolon(cfg_get(f"capture.{key}", "")))


def capture_path_set(report: dict[str, Any], key: str, *, include_contents: bool = False, sensitive: bool = False) -> list[dict[str, Any]]:
    run_dir = resolve_path(report["run_dir"])
    out_root = run_dir / key
    records: list[dict[str, Any]] = []
    max_bytes = int(cfg_get("policy.max_file_copy_bytes", 52428800))
    for raw in split_semicolon(cfg_get(f"paths.{key}", "")):
        path = resolve_path(raw)
        if not path.exists() and raw.startswith("~"):
            path = Path(raw).expanduser().resolve()
        if not path.exists():
            records.append({"path": str(path), "exists": False, "sensitive": sensitive})
            continue
        candidates = [path]
        if path.is_dir():
            candidates = sorted([p for p in path.rglob("*") if p.is_file() or p.is_symlink()])
        for item in candidates:
            rec = file_record(item)
            rec["sensitive"] = sensitive
            if include_contents and item.is_file() and not item.is_symlink() and rec.get("size_bytes", 0) <= max_bytes:
                try:
                    dest = out_root / item.relative_to(item.anchor if item.is_absolute() else PROJECT_ROOT)
                except Exception:
                    dest = out_root / re.sub(r"[^A-Za-z0-9_.-]+", "_", str(item).strip("/"))
                dest.parent.mkdir(parents=True, exist_ok=True)
                try:
                    shutil.copy2(item, dest)
                    rec["copied_to"] = rel(dest)
                except OSError as exc:
                    rec["copy_error"] = str(exc)
                    report["warnings"].append(f"could not copy {item}: {exc}")
            records.append(rec)
    return records


def capture_remotes(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-remotes")
    report = report_base("capture-remotes", run_dir)
    report["mode"] = "capture"
    preflight(report)
    report["remotes"] = {"scopes": {}}
    if not report["failures"]:
        cols = columns_csv("remote_columns")
        for scope in enabled_scopes(include_all=True):
            result = run_remotes_capture(report, scope, columns=cols, label_prefix="remotes")
            rows = tabular_lines(result["stdout"]) if result["returncode"] == 0 else []
            report["remotes"]["scopes"][scope] = {
                "returncode": result["returncode"],
                "row_count": len(rows),
                "rows": rows,
            }
        report["remotes"]["config_paths"] = capture_path_set(report, "system_config_dirs", include_contents=False, sensitive=False) + capture_path_set(report, "user_config_dirs", include_contents=False, sensitive=False)
    return finalize_report(report, run_dir)


def capture_refs(kind: str) -> int:
    command = "capture-apps" if kind == "app" else "capture-runtimes"
    run_dir = make_run_dir(command)
    report = report_base(command, run_dir)
    report["mode"] = "capture"
    preflight(report)
    key = "apps" if kind == "app" else "runtimes"
    report[key] = {"scopes": {}, "info": {}}
    if not report["failures"]:
        col_key = "app_columns" if kind == "app" else "runtime_columns"
        cols = columns_csv(col_key)
        for scope in enabled_scopes(include_all=True):
            prefix = scoped_prefix(scope)
            kind_flag = "--app" if kind == "app" else "--runtime"
            primary = [*prefix, "list", kind_flag]
            if cols:
                primary.append(f"--columns={cols}")
            result = run_flatpak(report, primary, label=f"{key}_{scope}", check=False)
            if result["returncode"] != 0 and cols:
                report["warnings"].append(f"{key} column capture failed for {scope}; retrying without explicit columns")
                result = run_flatpak(report, [*prefix, "list", kind_flag], label=f"{key}_{scope}_fallback", check=False)
            rows = tabular_lines(result["stdout"]) if result["returncode"] == 0 else []
            report[key]["scopes"][scope] = {"returncode": result["returncode"], "row_count": len(rows), "rows": rows}
            configured_columns = split_semicolon(cfg_get(f"capture.{col_key}", ""))
            for row in rows:
                parsed = row_to_dict(row, configured_columns) if configured_columns else {}
                app_id = parsed.get("application") or (row[0] if row else "")
                full_ref = parsed.get("ref") or app_id
                info_target = full_ref or app_id
                info_key = f"{scope}:{info_target}"
                if not app_id or info_key in report[key]["info"]:
                    continue
                info = run_flatpak(report, [*prefix, "info", info_target], label=f"info_{scope}_{app_id}", check=False)
                report[key]["info"][info_key] = {
                    "target": info_target,
                    "application": app_id,
                    "returncode": info["returncode"],
                    "stdout_path": info["record"]["stdout_path"],
                    "stderr_path": info["record"]["stderr_path"],
                }
    return finalize_report(report, run_dir)


def capture_apps(args: argparse.Namespace) -> int:
    return capture_refs("app")


def capture_runtimes(args: argparse.Namespace) -> int:
    return capture_refs("runtime")


def installed_app_ids(report: dict[str, Any]) -> list[str]:
    ids: list[str] = []
    for scope in enabled_scopes(include_all=False):
        result = run_flatpak(report, [*scoped_prefix(scope), "list", "--app", "--columns=application"], label=f"installed_app_ids_{scope}", check=False)
        if result["returncode"] != 0:
            result = run_flatpak(report, [*scoped_prefix(scope), "list", "--app"], label=f"installed_app_ids_{scope}_fallback", check=False)
        for row in tabular_lines(result["stdout"]):
            if row and row[0] and row[0] not in ids:
                ids.append(row[0])
    return ids


def app_data_inventory_ids(root: Path, report: dict[str, Any]) -> list[dict[str, Any]]:
    installed = set(installed_app_ids(report))
    from_dirs: set[str] = set()
    if root.exists():
        for item in sorted(root.iterdir()):
            if item.is_dir():
                from_dirs.add(item.name)
    ids = sorted(installed | from_dirs)
    return [
        {
            "app_id": app_id,
            "installed": app_id in installed,
            "app_data_dir_exists": app_id in from_dirs,
            "source": "installed_and_app_data" if app_id in installed and app_id in from_dirs else "installed_only" if app_id in installed else "app_data_only",
        }
        for app_id in ids
    ]


def capture_overrides(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-overrides")
    report = report_base("capture-overrides", run_dir)
    report["mode"] = "capture"
    preflight(report)
    report["overrides"] = {"global": {}, "apps": {}, "permissions": {}}
    if not report["failures"]:
        for scope in enabled_scopes(include_all=False):
            prefix = scoped_prefix(scope)
            result = run_flatpak(report, [*prefix, "override", "--show"], label=f"override_global_{scope}", check=False)
            report["overrides"]["global"][scope] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"]}
        for app_id in installed_app_ids(report):
            report["overrides"]["apps"][app_id] = {}
            for scope in enabled_scopes(include_all=False):
                prefix = scoped_prefix(scope)
                result = run_flatpak(report, [*prefix, "override", "--show", app_id], label=f"override_{scope}_{app_id}", check=False)
                report["overrides"]["apps"][app_id][scope] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"]}
        if boolish(cfg_get("capture.permission_commands_enabled", True)):
            perms = run_flatpak(report, ["permissions"], label="permissions", check=False)
            report["overrides"]["permissions"]["permissions"] = {"returncode": perms["returncode"], "stdout_path": perms["record"]["stdout_path"]}
            for app_id in installed_app_ids(report):
                ps = run_flatpak(report, ["permission-show", app_id], label=f"permission_show_{app_id}", check=False)
                report["overrides"]["permissions"][app_id] = {"returncode": ps["returncode"], "stdout_path": ps["record"]["stdout_path"]}
    return finalize_report(report, run_dir)


def capture_scopes(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-scopes")
    report = report_base("capture-scopes", run_dir)
    report["mode"] = "capture"
    preflight(report)
    report["scopes"] = {
        "installations_command": None,
        "paths": {
            "system_installation_root": file_record(resolve_path(str(cfg_get("paths.system_installation_root")))) ,
            "user_installation_root": file_record(Path(str(cfg_get("paths.user_installation_root"))).expanduser().resolve()),
            "user_app_data_root": file_record(Path(str(cfg_get("paths.user_app_data_root"))).expanduser().resolve()),
        },
        "environment": {
            "XDG_DATA_HOME": os.environ.get("XDG_DATA_HOME"),
            "XDG_CONFIG_HOME": os.environ.get("XDG_CONFIG_HOME"),
            "HOME": os.environ.get("HOME"),
        },
    }
    if not report["failures"]:
        result = run_flatpak(report, ["--installations"], label="flatpak_installations", check=False)
        if result["returncode"] != 0:
            report["warnings"].append("flatpak --installations failed or is unsupported on this build; path records remain the scope authority")
        report["scopes"]["installations_command"] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"]}
        for scope in enabled_scopes(include_all=False):
            prefix = scoped_prefix(scope)
            run_flatpak(report, [*prefix, "list"], label=f"scope_list_{scope}", check=False)
            run_flatpak(report, [*prefix, "remotes", "--show-details"], label=f"scope_remotes_{scope}", check=False)
    return finalize_report(report, run_dir)


def inventory_app_dir(app_id: str, root: Path, report: dict[str, Any]) -> dict[str, Any]:
    app_dir = root / app_id
    max_entries = int(cfg_get("policy.app_data_inventory_max_entries_per_app", 4000))
    hash_small = boolish(cfg_get("policy.app_data_hash_small_files", True))
    hash_max = int(cfg_get("policy.app_data_hash_max_bytes", 1048576))
    rec: dict[str, Any] = {"app_id": app_id, "path": str(app_dir), "exists": app_dir.exists(), "file_count": 0, "dir_count": 0, "total_bytes": 0, "truncated": False, "entries": []}
    if not app_dir.exists():
        if boolish(cfg_get("policy.app_data_warn_if_missing", True)):
            report["warnings"].append(f"app data directory missing for {app_id}: {app_dir}")
        return rec
    for index, path in enumerate(sorted(app_dir.rglob("*"))):
        if index >= max_entries:
            rec["truncated"] = True
            break
        try:
            st = path.lstat()
        except OSError as exc:
            rec["entries"].append({"path": str(path), "error": str(exc)})
            continue
        try:
            rel_path = str(path.relative_to(app_dir))
        except ValueError:
            rel_path = str(path)
        entry: dict[str, Any] = {"relative_path": rel_path, "is_file": path.is_file(), "is_dir": path.is_dir(), "is_symlink": path.is_symlink(), "mode": oct(stat.S_IMODE(st.st_mode)), "size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        if path.is_dir():
            rec["dir_count"] += 1
        elif path.is_file():
            rec["file_count"] += 1
            rec["total_bytes"] += st.st_size
            if hash_small and st.st_size <= hash_max and not path.is_symlink():
                entry["sha256"] = sha256_file(path)
        if path.is_symlink():
            try:
                entry["symlink_target"] = os.readlink(path)
            except OSError as exc:
                entry["symlink_error"] = str(exc)
        rec["entries"].append(entry)
    for subdir in split_semicolon(cfg_get("paths.app_data_subdirs", "config;data;cache")):
        sub = app_dir / subdir
        rec[f"{subdir}_exists"] = sub.exists()
    return rec


def capture_app_data_manifest(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-app-data-manifest")
    report = report_base("capture-app-data-manifest", run_dir)
    report["mode"] = "capture"
    preflight(report)
    report["app_data"] = {"root": None, "apps": []}
    root = Path(str(cfg_get("paths.user_app_data_root", "~/.var/app"))).expanduser().resolve()
    report["app_data"]["root"] = file_record(root, include_hash=False)
    if not report["failures"]:
        report["app_data"]["inventory_sources"] = []
        for item in app_data_inventory_ids(root, report):
            app_id = item["app_id"]
            rec = inventory_app_dir(app_id, root, report)
            rec["installed"] = item["installed"]
            rec["app_data_dir_exists"] = item["app_data_dir_exists"]
            rec["source"] = item["source"]
            report["app_data"]["apps"].append(rec)
            report["app_data"]["inventory_sources"].append(item)
        manifest_path = run_dir / "flatpak_app_data_manifest.json"
        write_json(manifest_path, report["app_data"])
        report["outputs"].append({"kind": "app_data_manifest", "path": rel(manifest_path), "payload_owner": "borg", "note": "Row 11 inventories ~/.var/app; Row 06/07 Borg owns byte payload backup."})
    return finalize_report(report, run_dir)


def offline_export_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("offline-export-plan")
    report = report_base("offline-export-plan", run_dir)
    report["mode"] = "plan"
    preflight(report)
    lines = [
        "# Flatpak offline export plan",
        "",
        "Row 11 does not create offline Flatpak exports during capture.",
        "",
        "Flatpak restore authority is, in order:",
        "",
        "1. captured remotes and installed refs for normal online reinstall,",
        "2. optional future `.flatpakrepo`, `.flatpakref`, bundle, or USB export artifacts if deliberately produced,",
        "3. Borg-owned `~/.var/app` payload restoration after apps are reinstalled.",
        "",
        "Candidate offline artifact roots:",
    ]
    roots = []
    for raw in split_semicolon(cfg_get("paths.offline_artifact_roots", "")):
        root = resolve_path(raw)
        roots.append(file_record(root, include_hash=False))
        lines.append(f"- `{root}`")
    lines.extend([
        "",
        "Review-only commands for future manual offline preparation:",
        "",
        "~~~bash",
        "flatpak remotes --show-details",
        "flatpak list --app --columns=application,origin,branch,arch,installation",
        "flatpak list --runtime --columns=application,origin,branch,arch,installation",
        "# Optional future offline media workflow, only after explicit review:",
        "# flatpak create-usb /path/to/usb REMOTE APP_ID",
        "# flatpak build-bundle REPOSITORY APP_ID.flatpak APP_ID BRANCH",
        "~~~",
        "",
    ])
    plan_path = run_dir / str(cfg_get("policy.restore_plan_name", "flatpak_restore_plan.md")).replace("restore", "offline_export")
    write_text(plan_path, "\n".join(lines))
    report["restore_plan"] = {"offline_artifact_roots": roots, "plan_path": rel(plan_path), "plan_only": True}
    report["outputs"].append({"kind": "offline_export_plan", "path": rel(plan_path)})
    return finalize_report(report, run_dir)


def verify_offline_artifacts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-offline-artifacts")
    report = report_base("verify-offline-artifacts", run_dir)
    report["mode"] = "verify"
    preflight(report)
    artifacts: list[dict[str, Any]] = []
    suffixes = {".flatpak", ".flatpakref", ".flatpakrepo", ".bundle"}
    for raw in split_semicolon(cfg_get("paths.offline_artifact_roots", "")):
        root = resolve_path(raw)
        root_rec = file_record(root, include_hash=False)
        if not root.exists():
            report["warnings"].append(f"offline artifact root does not exist: {root}")
            artifacts.append({"root": root_rec, "artifacts": []})
            continue
        found = []
        for item in sorted(root.rglob("*")):
            if item.is_file() and (item.suffix in suffixes or item.name.endswith(".flatpak.tar.gz")):
                found.append(file_record(item, include_hash=True))
        artifacts.append({"root": root_rec, "artifacts": found})
    manifest_path = run_dir / "flatpak_offline_artifacts_manifest.json"
    write_json(manifest_path, {"artifact_groups": artifacts})
    report["flatpak"] = {"offline_artifacts": artifacts, "manifest_path": rel(manifest_path)}
    report["outputs"].append({"kind": "flatpak_offline_artifacts_manifest", "path": rel(manifest_path)})
    if boolish(cfg_get("policy.offline_artifact_required", False)) and not any(group["artifacts"] for group in artifacts):
        report["failures"].append("offline artifacts are required by policy but none were found")
    return finalize_report(report, run_dir)


def build_current_state(report: dict[str, Any]) -> dict[str, Any]:
    state: dict[str, Any] = {"remotes": [], "apps": [], "runtimes": [], "overrides": {"global": {}, "apps": {}}, "scope_source": "scoped_system_user_queries"}

    # Preserve system/user scope by querying each scope explicitly. Do not depend on
    # aggregate Flatpak output to expose an installation/scope column consistently.
    for scope in enabled_scopes(include_all=False):
        remote_columns = ["name", "url", "options"]
        remote_result = run_remotes_capture(report, scope, columns=",".join(remote_columns), label_prefix="restore_state_remotes")
        for row in tabular_lines(remote_result["stdout"]) if remote_result["returncode"] == 0 else []:
            if not row:
                continue
            parsed = row_to_dict(row, remote_columns)
            state["remotes"].append({
                "name": parsed.get("name", row[0] if row else ""),
                "url": parsed.get("url", ""),
                "options": parsed.get("options", ""),
                "disabled": remote_is_disabled(parsed),
                "installation": scope,
                "raw": row,
            })

    ref_columns = ["application", "origin", "branch", "arch", "ref"]
    ref_cols = ",".join(ref_columns)
    for scope in enabled_scopes(include_all=False):
        apps = run_flatpak(report, [*scoped_prefix(scope), "list", "--app", f"--columns={ref_cols}"], label=f"restore_state_apps_{scope}", check=False)
        if apps["returncode"] != 0:
            apps = run_flatpak(report, [*scoped_prefix(scope), "list", "--app"], label=f"restore_state_apps_{scope}_fallback", check=False)
        for row in tabular_lines(apps["stdout"]) if apps["returncode"] == 0 else []:
            if not row:
                continue
            parsed = row_to_dict(row, ref_columns)
            state["apps"].append({
                "application": parsed.get("application", row[0] if row else ""),
                "origin": parsed.get("origin", ""),
                "branch": parsed.get("branch", ""),
                "arch": parsed.get("arch", ""),
                "ref": parsed.get("ref", ""),
                "installation": scope,
                "raw": row,
            })

    for scope in enabled_scopes(include_all=False):
        runtimes = run_flatpak(report, [*scoped_prefix(scope), "list", "--runtime", f"--columns={ref_cols}"], label=f"restore_state_runtimes_{scope}", check=False)
        if runtimes["returncode"] != 0:
            runtimes = run_flatpak(report, [*scoped_prefix(scope), "list", "--runtime"], label=f"restore_state_runtimes_{scope}_fallback", check=False)
        for row in tabular_lines(runtimes["stdout"]) if runtimes["returncode"] == 0 else []:
            if not row:
                continue
            parsed = row_to_dict(row, ref_columns)
            state["runtimes"].append({
                "application": parsed.get("application", row[0] if row else ""),
                "origin": parsed.get("origin", ""),
                "branch": parsed.get("branch", ""),
                "arch": parsed.get("arch", ""),
                "ref": parsed.get("ref", ""),
                "installation": scope,
                "raw": row,
            })

    for scope in enabled_scopes(include_all=False):
        result = run_flatpak(report, [*scoped_prefix(scope), "override", "--show"], label=f"restore_state_global_override_{scope}", check=False)
        state["overrides"]["global"][scope] = result["stdout"] if result["returncode"] == 0 else ""
    for app in state["apps"]:
        app_id = app["application"]
        state["overrides"]["apps"][app_id] = {}
        for scope in enabled_scopes(include_all=False):
            result = run_flatpak(report, [*scoped_prefix(scope), "override", "--show", app_id], label=f"restore_state_override_{scope}_{app_id}", check=False)
            state["overrides"]["apps"][app_id][scope] = result["stdout"] if result["returncode"] == 0 else ""
    return state


def scope_flag(installation: str) -> str:
    text = str(installation).strip().lower()
    if text == "user":
        return "--user"
    if text == "system":
        return "--system"
    return ""


def app_install_ref(item: dict[str, Any]) -> str:
    app_id = item.get("application", "")
    branch = item.get("branch", "")
    return f"{app_id}//{branch}" if app_id and branch else app_id


def restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-plan")
    report = report_base("restore-plan", run_dir)
    report["mode"] = "plan"
    preflight(report)
    state = build_current_state(report) if not report["failures"] else {"remotes": [], "apps": [], "runtimes": []}
    state_path = run_dir / "restore_input_flatpak_bundle.json"
    write_json(state_path, state)
    report["outputs"].append({"kind": "restore_input_flatpak_bundle", "path": rel(state_path)})
    lines = [
        "# Flatpak restore plan",
        "",
        "This plan is review-only. Row 11 does not install or update Flatpaks during capture.",
        "",
        "## Restore order",
        "",
        "1. Reinstall Flatpak itself through Row 10 native packages.",
        "2. Add Flatpak remotes from captured remote authority.",
        "3. Install captured Flatpak applications by app ID, origin, branch, and preserved user/system scope.",
        "4. Let Flatpak resolve runtime dependencies, unless an explicit runtime reinstall is later reviewed.",
        "5. Review captured overrides and permissions before replaying them.",
        "6. Restore `~/.var/app` payloads from Borg after application IDs exist again.",
        "",
        "## Captured remotes",
        "",
    ]
    for remote in state.get("remotes", []):
        lines.append(f"- `{remote.get('name')}` scope=`{remote.get('installation')}` url=`{remote.get('url')}`")
    lines.extend(["", "## Captured applications", ""])
    for app in state.get("apps", []):
        lines.append(f"- `{app.get('application')}` origin=`{app.get('origin')}` branch=`{app.get('branch')}` arch=`{app.get('arch')}` scope=`{app.get('installation')}`")
    lines.extend(["", "## Captured runtimes", ""])
    for runtime in state.get("runtimes", []):
        lines.append(f"- `{runtime.get('application')}` origin=`{runtime.get('origin')}` branch=`{runtime.get('branch')}` arch=`{runtime.get('arch')}` scope=`{runtime.get('installation')}`")
    lines.extend(["", "## App data payload boundary", "", "`~/.var/app` is inventoried by Row 11, but byte-level backup and restore are owned by Borg Rows 06/07.", ""])
    path = run_dir / str(cfg_get("policy.restore_plan_name", "flatpak_restore_plan.md"))
    write_text(path, "\n".join(lines))
    report["restore_plan"] = {"path": rel(path), "remote_count": len(state.get("remotes", [])), "app_count": len(state.get("apps", [])), "runtime_count": len(state.get("runtimes", []))}
    report["outputs"].append({"kind": "restore_plan", "path": rel(path)})
    return finalize_report(report, run_dir)


def shell_line(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv if part != "")


def generate_reinstall_script(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-reinstall-script")
    report = report_base("generate-reinstall-script", run_dir)
    report["mode"] = "plan"
    preflight(report)
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/11_flatpak")))
    generated_root.mkdir(parents=True, exist_ok=True)
    state = build_current_state(report) if not report["failures"] else {"remotes": [], "apps": [], "runtimes": [], "overrides": {"global": {}, "apps": {}}}
    state_path = run_dir / "restore_input_flatpak_bundle.json"
    write_json(state_path, state)
    report["outputs"].append({"kind": "restore_input_flatpak_bundle", "path": rel(state_path)})
    generated_state_path = generated_root / "restore_input_flatpak_bundle.json"
    write_json(generated_state_path, state)
    report["outputs"].append({"kind": "generated_restore_input_flatpak_bundle", "path": rel(generated_state_path)})
    guard_env = str(cfg_get("policy.reinstall_execution_guard_env", "CONFIRM_FLATPAK_REINSTALL"))
    guard_value = str(cfg_get("policy.reinstall_execution_guard_value", "I_UNDERSTAND_THIS_REINSTALLS_FLATPAKS"))
    lines: list[str] = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        f"REQUIRED_TOKEN={shlex.quote(guard_value)}",
        f"if [[ \"${{{guard_env}:-}}\" != \"$REQUIRED_TOKEN\" ]]; then",
        f"  echo \"Refusing to run. Set {guard_env}=$REQUIRED_TOKEN after reviewing this script.\" >&2",
        "  exit 2",
        "fi",
        "",
        "command -v flatpak >/dev/null || { echo 'flatpak is not installed; restore native packages first.' >&2; exit 1; }",
        "flatpak --version",
        "",
        "# Remotes",
    ]
    if boolish(cfg_get("generated_restore.include_remote_add_commands", True)):
        for remote in state.get("remotes", []):
            name = remote.get("name") or ""
            url = remote.get("url") or ""
            if not name or not url:
                lines.append(f"# Skipped remote with incomplete captured fields: {remote!r}")
                continue
            cmd = ["flatpak"]
            sf = scope_flag(str(remote.get("installation", "")))
            if sf:
                cmd.append(sf)
            cmd.extend(["remote-add", "--if-not-exists", name, url])
            lines.append(shell_line(cmd))
            if remote_is_disabled(remote):
                disable_cmd = ["flatpak"]
                sf = scope_flag(str(remote.get("installation", "")))
                if sf:
                    disable_cmd.append(sf)
                disable_cmd.extend(["remote-modify", "--disable", name])
                lines.append(shell_line(disable_cmd))
    lines.extend(["", "# Applications"])
    if boolish(cfg_get("generated_restore.include_app_install_commands", True)):
        for app in state.get("apps", []):
            app_id = app.get("application") or ""
            origin = app.get("origin") or ""
            if not app_id or not origin:
                lines.append(f"# Skipped app with incomplete captured fields: {app!r}")
                continue
            cmd = ["flatpak"]
            sf = scope_flag(str(app.get("installation", "")))
            if sf:
                cmd.append(sf)
            cmd.extend(["install", "--assumeyes", origin, app_install_ref(app)])
            lines.append(shell_line(cmd))
    if boolish(cfg_get("generated_restore.include_runtime_install_commands", False)):
        lines.extend(["", "# Explicit runtime reinstall commands are disabled by default; Flatpak normally resolves runtime dependencies."])
        for runtime in state.get("runtimes", []):
            runtime_id = runtime.get("application") or ""
            origin = runtime.get("origin") or ""
            if not runtime_id or not origin:
                continue
            cmd = ["flatpak"]
            sf = scope_flag(str(runtime.get("installation", "")))
            if sf:
                cmd.append(sf)
            cmd.extend(["install", "--assumeyes", origin, app_install_ref(runtime)])
            lines.append("# " + shell_line(cmd))
    if boolish(cfg_get("generated_restore.include_override_review_block", True)):
        lines.extend(["", "# Overrides / permissions", "# Review captured override files before replay. They can grant filesystem, device, socket, or environment access."])
        for scope, text in state.get("overrides", {}).get("global", {}).items():
            if text.strip():
                lines.append(f"# Global {scope} override captured; review capture-overrides output.")
        for app_id, scoped in state.get("overrides", {}).get("apps", {}).items():
            if any(str(v).strip() for v in scoped.values()):
                lines.append(f"# App override captured for {app_id}; review capture-overrides output before replay.")
    if boolish(cfg_get("generated_restore.include_app_data_restore_note", True)):
        lines.extend(["", "# App data", "# Restore ~/.var/app payloads from Borg after apps are installed. Row 11 only inventories that payload."])
    lines.append("")
    script_path = generated_root / str(cfg_get("policy.reinstall_script_name", "reinstall_flatpaks.review.sh"))
    write_text(script_path, "\n".join(lines))
    mode_text = str(cfg_get("policy.generated_script_mode", "0600"))
    os.chmod(script_path, int(mode_text, 8))
    script_rec = file_record(script_path, include_hash=True)
    report["restore_plan"] = {"script_path": rel(script_path), "script_mode": script_rec.get("mode"), "remote_count": len(state.get("remotes", [])), "app_count": len(state.get("apps", [])), "runtime_count": len(state.get("runtimes", [])), "guard_env": guard_env, "guard_value": guard_value}
    report["outputs"].append({"kind": "reinstall_script", "path": rel(script_path), "mode": script_rec.get("mode")})
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("capture-remotes").set_defaults(func=capture_remotes)
    sub.add_parser("capture-apps").set_defaults(func=capture_apps)
    sub.add_parser("capture-runtimes").set_defaults(func=capture_runtimes)
    sub.add_parser("capture-overrides").set_defaults(func=capture_overrides)
    sub.add_parser("capture-scopes").set_defaults(func=capture_scopes)
    sub.add_parser("capture-app-data-manifest").set_defaults(func=capture_app_data_manifest)
    sub.add_parser("offline-export-plan").set_defaults(func=offline_export_plan)
    sub.add_parser("verify-offline-artifacts").set_defaults(func=verify_offline_artifacts)
    sub.add_parser("restore-plan").set_defaults(func=restore_plan)
    sub.add_parser("generate-reinstall-script").set_defaults(func=generate_reinstall_script)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(ARGS))
PYCODE