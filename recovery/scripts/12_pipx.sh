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
SCRIPT_NAME = "12_pipx.sh"
SCHEMA_NAME = "recovery.pipx.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "pipx",
        "verified_pipx_version": "1.4.3",
        "layer": "12_user_python_cli_reinstall",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/12_pipx",
        "generated_root": "state/generated/12_pipx",
        "wheelhouse_root": "state/wheelhouse/12_pipx",
    },
    "commands": {
        "pipx": "/usr/bin/pipx",
        "python3": "/usr/bin/python3",
        "pip": "/usr/bin/pip3",
        "readlink": "/usr/bin/readlink",
        "sha256sum": "/usr/bin/sha256sum",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "pipx_report.json",
        "restore_plan_name": "pipx_restore_plan.md",
        "reinstall_input_name": "pipx_reinstall_input.json",
        "reinstall_script_name": "reinstall_pipx.review.sh",
        "wheelhouse_manifest_name": "pipx_wheelhouse_manifest.json",
        "generated_script_mode": "0600",
        "reinstall_execution_guard_env": "CONFIRM_PIPX_REINSTALL",
        "reinstall_execution_guard_value": "I_UNDERSTAND_THIS_REINSTALLS_PIPX_APPS",
        "wheelhouse_build_guard_env": "CONFIRM_PIPX_WHEELHOUSE_BUILD",
        "wheelhouse_build_guard_value": "I_UNDERSTAND_THIS_DOWNLOADS_PYTHON_WHEELS",
        "fail_if_pipx_missing": True,
        "fail_if_pipx_version_unexpected": False,
        "include_user_scope": True,
        "include_global_scope": False,
        "include_recovery_tool_roots": False,
        "scan_local_bin": True,
        "scan_global_bin": False,
        "scan_recovery_bins": False,
        "hash_entrypoint_targets": False,
        "entrypoint_hash_max_bytes": 1048576,
        "include_venv_file_inventory": True,
        "venv_inventory_max_entries_per_venv": 2500,
        "venv_inventory_hash_max_bytes": 262144,
        "include_runpip_freeze": True,
        "include_runpip_list_json": True,
        "generated_script_prefers_captured_specs": True,
        "generated_script_reinstalls_injections": True,
        "generated_script_notes_interpreter_drift": True,
        "wheelhouse_build_requires_execute": True,
        "wheelhouse_include_captured_apps": True,
        "wheelhouse_include_injected_packages": True,
        "wheelhouse_no_binary": False,
        "no_execute": True,
    },
    "paths": {
        "user_pipx_home": "~/.local/share/pipx",
        "legacy_user_pipx_home": "~/.local/pipx",
        "user_pipx_bin_dir": "~/.local/bin",
        "user_pipx_man_dir": "~/.local/share/man",
        "global_pipx_home": "/opt/pipx",
        "global_pipx_bin_dir": "/usr/local/bin",
        "global_pipx_man_dir": "/usr/local/share/man",
        "recovery_tool_roots": "/opt/recovery-pipx;/opt/recovery-tools",
        "recovery_bin_dirs": "/usr/local/bin",
        "critical_wheelhouse_roots": "state/wheelhouse/12_pipx;/mnt/wantless_recovery/12_pipx/wheelhouse",
    },
    "capture": {
        "environment_variables": "PIPX_HOME;PIPX_BIN_DIR;PIPX_MAN_DIR;PIPX_GLOBAL_HOME;PIPX_GLOBAL_BIN_DIR;PIPX_GLOBAL_MAN_DIR;PIPX_DEFAULT_PYTHON;PATH;VIRTUAL_ENV;PYTHONPATH",
        "critical_package_specs": "pipx",
        "critical_entrypoints": "pipx",
        "ignore_entrypoint_names": "python;python3;pip;pip3;activate",
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
    path = PROJECT_ROOT / "configs" / "12_pipx.yaml"
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


PIPX = cmd_path("pipx")
PYTHON3 = cmd_path("python3")
PIP = cmd_path("pip")
READLINK = cmd_path("readlink")
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
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/12_pipx")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "12_pipx.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "12_pipx.config.snapshot.yaml")
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


def file_record(path: Path, *, include_hash: bool = False, hash_max: int = 0) -> dict[str, Any]:
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
            resolved = path.resolve(strict=False)
            payload["resolved_target"] = str(resolved)
            payload["target_exists"] = resolved.exists()
        except OSError as exc:
            payload["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink() and st.st_size <= hash_max:
        payload["sha256"] = sha256_file(path)
    return payload


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "pipx",
            "script": SCRIPT_NAME,
            "pipx_path": PIPX,
            "pipx_version": None,
            "python3_path": PYTHON3,
            "python3_version": None,
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
    report_path = run_dir / str(cfg_get("policy.report_name", "pipx_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False, env: dict[str, str] | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, env=env)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    run_dir = resolve_path(report["run_dir"])
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    record = {"argv": argv[:], "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr}
    report["commands"].append(record)
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(argv)} :: {proc.stderr.strip()}")
    return {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "record": record}


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def preflight(report: dict[str, Any]) -> None:
    if not command_exists(PIPX):
        msg = f"pipx command not found at configured path: {PIPX}"
        if boolish(cfg_get("policy.fail_if_pipx_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
        return
    version = run_cmd([PIPX, "--version"], report, label="pipx_version", check=False)
    if version["returncode"] == 0:
        text = (version["stdout"] or version["stderr"]).strip()
        report["tool"]["pipx_version"] = text
        expected = str(cfg_get("tool.verified_pipx_version", "")).strip()
        if expected and expected not in text:
            msg = f"pipx version differs from verified target {expected!r}: {text!r}"
            if boolish(cfg_get("policy.fail_if_pipx_version_unexpected", False)):
                report["failures"].append(msg)
            else:
                report["warnings"].append(msg)
    else:
        report["failures"].append("pipx --version failed")
    py = run_cmd([PYTHON3, "--version"], report, label="python3_version", check=False)
    if py["returncode"] == 0:
        report["tool"]["python3_version"] = (py["stdout"] or py["stderr"]).strip()


def pipx_env() -> dict[str, str]:
    return os.environ.copy()


def default_pipx_paths() -> dict[str, str]:
    home = Path.home()
    user_home = Path(os.environ.get("PIPX_HOME") or str(Path(str(cfg_get("paths.user_pipx_home", "~/.local/share/pipx"))).expanduser()))
    legacy_home = Path(str(cfg_get("paths.legacy_user_pipx_home", "~/.local/pipx"))).expanduser()
    if "PIPX_HOME" not in os.environ and legacy_home.exists() and not user_home.exists():
        user_home = legacy_home
    return {
        "user_pipx_home": str(user_home.resolve()),
        "legacy_user_pipx_home": str(legacy_home.resolve()),
        "user_pipx_bin_dir": str(Path(os.environ.get("PIPX_BIN_DIR") or str(Path(str(cfg_get("paths.user_pipx_bin_dir", "~/.local/bin"))).expanduser())).resolve()),
        "user_pipx_man_dir": str(Path(os.environ.get("PIPX_MAN_DIR") or str(Path(str(cfg_get("paths.user_pipx_man_dir", "~/.local/share/man"))).expanduser())).resolve()),
        "global_pipx_home": str(Path(os.environ.get("PIPX_GLOBAL_HOME") or str(cfg_get("paths.global_pipx_home", "/opt/pipx"))).resolve()),
        "global_pipx_bin_dir": str(Path(os.environ.get("PIPX_GLOBAL_BIN_DIR") or str(cfg_get("paths.global_pipx_bin_dir", "/usr/local/bin"))).resolve()),
        "global_pipx_man_dir": str(Path(os.environ.get("PIPX_GLOBAL_MAN_DIR") or str(cfg_get("paths.global_pipx_man_dir", "/usr/local/share/man"))).resolve()),
        "home": str(home),
    }


def pipx_list_json(report: dict[str, Any], *, global_scope: bool = False) -> dict[str, Any]:
    argv = [PIPX]
    if global_scope:
        argv.append("--global")
    argv.extend(["list", "--json"])
    result = run_cmd(argv, report, label="pipx_global_list_json" if global_scope else "pipx_user_list_json", check=False)
    if result["returncode"] != 0:
        report["warnings"].append(f"pipx {'global ' if global_scope else ''}list --json failed: {result['stderr'].strip()}")
        return {"venvs": {}}
    try:
        return json.loads(result["stdout"] or "{}")
    except json.JSONDecodeError as exc:
        report["warnings"].append(f"pipx list --json output was not valid JSON: {exc}")
        return {"venvs": {}, "decode_error": str(exc)}


def all_captured_venvs(report: dict[str, Any]) -> dict[str, Any]:
    data = {"user": pipx_list_json(report, global_scope=False)}
    if boolish(cfg_get("policy.include_global_scope", False)):
        data["global"] = pipx_list_json(report, global_scope=True)
    return data


def venvs_mapping(list_json: dict[str, Any]) -> dict[str, Any]:
    venvs = list_json.get("venvs")
    return venvs if isinstance(venvs, dict) else {}


def package_spec_from_record(app_name: str, record: dict[str, Any]) -> str:
    metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
    main = metadata.get("main_package") if isinstance(metadata.get("main_package"), dict) else {}
    return str(main.get("package_or_url") or main.get("package") or app_name)


def package_version_from_record(record: dict[str, Any]) -> str:
    metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
    main = metadata.get("main_package") if isinstance(metadata.get("main_package"), dict) else {}
    return str(main.get("package_version") or "")


def injected_package_records(record: dict[str, Any]) -> dict[str, Any]:
    metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
    injected = metadata.get("injected_packages")
    if not isinstance(injected, dict):
        injected = record.get("injected_packages")
    return injected if isinstance(injected, dict) else {}


def venv_path(app_name: str, scope: str) -> Path:
    paths = default_pipx_paths()
    home = Path(paths["global_pipx_home"] if scope == "global" else paths["user_pipx_home"])
    return home / "venvs" / app_name


def inventory_dir(root: Path, report: dict[str, Any]) -> dict[str, Any]:
    max_entries = int(cfg_get("policy.venv_inventory_max_entries_per_venv", 2500))
    hash_max = int(cfg_get("policy.venv_inventory_hash_max_bytes", 262144))
    rec: dict[str, Any] = {"path": str(root), "exists": root.exists(), "entries": [], "file_count": 0, "dir_count": 0, "total_bytes": 0, "truncated": False}
    if not root.exists():
        return rec
    for index, path in enumerate(sorted(root.rglob("*"))):
        if index >= max_entries:
            rec["truncated"] = True
            break
        try:
            st = path.lstat()
        except OSError as exc:
            rec["entries"].append({"path": str(path), "error": str(exc)})
            continue
        try:
            rel_path = str(path.relative_to(root))
        except ValueError:
            rel_path = str(path)
        entry: dict[str, Any] = {"relative_path": rel_path, "is_file": path.is_file(), "is_dir": path.is_dir(), "is_symlink": path.is_symlink(), "mode": oct(stat.S_IMODE(st.st_mode)), "size_bytes": st.st_size, "mtime_ns": st.st_mtime_ns}
        if path.is_dir():
            rec["dir_count"] += 1
        elif path.is_file():
            rec["file_count"] += 1
            rec["total_bytes"] += st.st_size
            if st.st_size <= hash_max and not path.is_symlink():
                entry["sha256"] = sha256_file(path)
        if path.is_symlink():
            try:
                entry["symlink_target"] = os.readlink(path)
            except OSError as exc:
                entry["symlink_error"] = str(exc)
        rec["entries"].append(entry)
    return rec


def capture_environment(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-environment")
    report = report_base("capture-environment", run_dir)
    report["mode"] = "capture"
    preflight(report)
    env_vars = {name: os.environ.get(name) for name in split_semicolon(cfg_get("capture.environment_variables", ""))}
    paths = default_pipx_paths()
    path_records = {name: file_record(Path(value), include_hash=False) for name, value in paths.items() if name != "home"}
    report["environment"] = {"variables": env_vars, "resolved_paths": paths, "path_records": path_records}
    if not report["failures"]:
        env_result = run_cmd([PIPX, "environment"], report, label="pipx_environment", check=False)
        report["environment"]["pipx_environment_returncode"] = env_result["returncode"]
    write_json(run_dir / "pipx_environment_manifest.json", report["environment"])
    report["outputs"].append({"kind": "pipx_environment_manifest", "path": rel(run_dir / "pipx_environment_manifest.json")})
    return finalize_report(report, run_dir)


def capture_list_json(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-list-json")
    report = report_base("capture-list-json", run_dir)
    report["mode"] = "capture"
    preflight(report)
    data = all_captured_venvs(report) if not report["failures"] else {}
    manifest = {"scopes": data, "scope_note": "Row 12 defaults to user pipx. Global pipx capture is opt-in."}
    path = run_dir / "pipx_list_manifest.json"
    write_json(path, manifest)
    report["apps"] = {scope: {"venv_count": len(venvs_mapping(payload))} for scope, payload in data.items()}
    report["outputs"].append({"kind": "pipx_list_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def capture_injected(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-injected")
    report = report_base("capture-injected", run_dir)
    report["mode"] = "capture"
    preflight(report)
    data = all_captured_venvs(report) if not report["failures"] else {}
    manifest: dict[str, Any] = {"apps": {}, "note": "pipx runpip calls are read-only introspection here."}
    if not report["failures"]:
        for scope, payload in data.items():
            for app_name, record in venvs_mapping(payload).items():
                app_key = f"{scope}:{app_name}"
                injected = injected_package_records(record)
                manifest["apps"][app_key] = {"injected_packages": injected, "runpip": {}}
                pipx_prefix = [PIPX]
                if scope == "global":
                    pipx_prefix.append("--global")
                if boolish(cfg_get("policy.include_runpip_freeze", True)):
                    freeze = run_cmd([*pipx_prefix, "runpip", app_name, "freeze"], report, label=f"runpip_freeze_{scope}_{app_name}", check=False)
                    manifest["apps"][app_key]["runpip"]["freeze_returncode"] = freeze["returncode"]
                    manifest["apps"][app_key]["runpip"]["freeze_stdout_path"] = freeze["record"]["stdout_path"]
                if boolish(cfg_get("policy.include_runpip_list_json", True)):
                    plist = run_cmd([*pipx_prefix, "runpip", app_name, "list", "--format=json"], report, label=f"runpip_list_json_{scope}_{app_name}", check=False)
                    manifest["apps"][app_key]["runpip"]["list_json_returncode"] = plist["returncode"]
                    manifest["apps"][app_key]["runpip"]["list_json_stdout_path"] = plist["record"]["stdout_path"]
    path = run_dir / "pipx_injected_manifest.json"
    write_json(path, manifest)
    report["apps"] = {"app_count": len(manifest["apps"]), "injected_app_count": sum(1 for app in manifest["apps"].values() if app.get("injected_packages"))}
    report["outputs"].append({"kind": "pipx_injected_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def configured_bin_dirs() -> list[Path]:
    paths = default_pipx_paths()
    dirs: list[Path] = []
    if boolish(cfg_get("policy.scan_local_bin", True)):
        dirs.append(Path(paths["user_pipx_bin_dir"]))
    if boolish(cfg_get("policy.scan_global_bin", False)):
        dirs.append(Path(paths["global_pipx_bin_dir"]))
    if boolish(cfg_get("policy.scan_recovery_bins", False)):
        dirs.extend(resolve_path(p) for p in split_semicolon(cfg_get("paths.recovery_bin_dirs", "")))
    return [] if not dirs else sorted(dict.fromkeys(dirs))


def capture_entrypoints(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-entrypoints")
    report = report_base("capture-entrypoints", run_dir)
    report["mode"] = "capture"
    preflight(report)
    ignore = set(split_semicolon(cfg_get("capture.ignore_entrypoint_names", "")))
    hash_targets = boolish(cfg_get("policy.hash_entrypoint_targets", False))
    hash_max = int(cfg_get("policy.entrypoint_hash_max_bytes", 1048576))
    paths = default_pipx_paths()
    pipx_home_candidates = [Path(paths["user_pipx_home"]), Path(paths["legacy_user_pipx_home"]), Path(paths["global_pipx_home"])]
    manifest: dict[str, Any] = {"bin_dirs": [], "entrypoints": [], "broken_symlinks": [], "pipx_linked": []}
    for bin_dir in configured_bin_dirs():
        dir_rec = file_record(bin_dir, include_hash=False)
        manifest["bin_dirs"].append(dir_rec)
        if not bin_dir.exists():
            report["warnings"].append(f"bin directory does not exist: {bin_dir}")
            continue
        for item in sorted(bin_dir.iterdir()):
            if item.name in ignore:
                continue
            rec = file_record(item, include_hash=hash_targets, hash_max=hash_max)
            if item.is_symlink():
                target_exists = bool(rec.get("target_exists", False))
                if not target_exists:
                    manifest["broken_symlinks"].append(rec)
                resolved = Path(str(rec.get("resolved_target", ""))) if rec.get("resolved_target") else None
                if resolved and any(str(resolved).startswith(str(home)) for home in pipx_home_candidates):
                    rec["pipx_managed_target"] = True
                    manifest["pipx_linked"].append(rec)
            elif item.is_file():
                try:
                    with item.open("rb") as f:
                        head = f.read(200)
                    if head.startswith(b"#!"):
                        rec["shebang"] = head.splitlines()[0].decode("utf-8", "replace")
                except OSError as exc:
                    rec["read_error"] = str(exc)
            manifest["entrypoints"].append(rec)
    path = run_dir / "pipx_entrypoints_manifest.json"
    write_json(path, manifest)
    report["entrypoints"] = {"entrypoint_count": len(manifest["entrypoints"]), "pipx_linked_count": len(manifest["pipx_linked"]), "broken_symlink_count": len(manifest["broken_symlinks"])}
    report["outputs"].append({"kind": "pipx_entrypoints_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def python_probe(path: Path, report: dict[str, Any], label: str) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False}
    result = run_cmd([str(path), "-c", "import sys, json, platform; print(json.dumps({'executable': sys.executable, 'version': sys.version, 'prefix': sys.prefix, 'base_prefix': sys.base_prefix, 'platform': platform.platform()}))"], report, label=label, check=False)
    payload = {"path": str(path), "exists": True, "returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"], "stderr_path": result["record"]["stderr_path"]}
    try:
        payload["details"] = json.loads(result["stdout"] or "{}") if result["returncode"] == 0 else {}
    except json.JSONDecodeError:
        payload["details_decode_error"] = True
    return payload


def capture_interpreter(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-interpreter")
    report = report_base("capture-interpreter", run_dir)
    report["mode"] = "capture"
    preflight(report)
    data = all_captured_venvs(report) if not report["failures"] else {}
    manifest: dict[str, Any] = {"system_python": {}, "venvs": {}}
    manifest["system_python"] = python_probe(Path(PYTHON3), report, "system_python_probe")
    if not report["failures"]:
        for scope, payload in data.items():
            for app_name, record in venvs_mapping(payload).items():
                root = venv_path(app_name, scope)
                py = root / "bin" / "python"
                key = f"{scope}:{app_name}"
                venv_rec: dict[str, Any] = {"venv_path": str(root), "python": python_probe(py, report, f"venv_python_{scope}_{app_name}")}
                pyvenv = root / "pyvenv.cfg"
                venv_rec["pyvenv_cfg"] = file_record(pyvenv, include_hash=True, hash_max=1048576)
                if pyvenv.exists():
                    try:
                        venv_rec["pyvenv_cfg_text"] = pyvenv.read_text(encoding="utf-8", errors="replace")
                    except OSError as exc:
                        venv_rec["pyvenv_cfg_error"] = str(exc)
                if boolish(cfg_get("policy.include_venv_file_inventory", True)):
                    venv_rec["inventory"] = inventory_dir(root, report)
                manifest["venvs"][key] = venv_rec
    path = run_dir / "pipx_interpreter_manifest.json"
    write_json(path, manifest)
    report["interpreters"] = {"venv_count": len(manifest["venvs"])}
    report["outputs"].append({"kind": "pipx_interpreter_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def critical_specs_from_state(report: dict[str, Any]) -> list[str]:
    specs: list[str] = split_semicolon(cfg_get("capture.critical_package_specs", ""))
    data = all_captured_venvs(report)
    if boolish(cfg_get("policy.wheelhouse_include_captured_apps", True)):
        for payload in data.values():
            for app_name, record in venvs_mapping(payload).items():
                spec = package_spec_from_record(app_name, record)
                if spec and spec not in specs:
                    specs.append(spec)
    if boolish(cfg_get("policy.wheelhouse_include_injected_packages", True)):
        for payload in data.values():
            for record in venvs_mapping(payload).values():
                for name, injected in injected_package_records(record).items():
                    spec = str(injected.get("package_or_url") or injected.get("package") or name) if isinstance(injected, dict) else str(name)
                    if spec and spec not in specs:
                        specs.append(spec)
    return specs


def build_critical_wheelhouse(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("build-critical-wheelhouse")
    report = report_base("build-critical-wheelhouse", run_dir)
    report["mode"] = "build"
    preflight(report)
    wheelhouse = resolve_path(str(cfg_get("project.wheelhouse_root", "state/wheelhouse/12_pipx")))
    wheelhouse.mkdir(parents=True, exist_ok=True)
    specs = critical_specs_from_state(report) if not report["failures"] else []
    manifest: dict[str, Any] = {"wheelhouse": str(wheelhouse), "specs": specs, "executed": False, "requires_execute": boolish(cfg_get("policy.wheelhouse_build_requires_execute", True))}
    guard_env = str(cfg_get("policy.wheelhouse_build_guard_env", "CONFIRM_PIPX_WHEELHOUSE_BUILD"))
    guard_value = str(cfg_get("policy.wheelhouse_build_guard_value", "I_UNDERSTAND_THIS_DOWNLOADS_PYTHON_WHEELS"))
    if boolish(cfg_get("policy.wheelhouse_build_requires_execute", True)):
        if not getattr(args, "execute", False) or os.environ.get(guard_env) != guard_value:
            report["warnings"].append(f"wheelhouse build not executed. Re-run with --execute and {guard_env}={guard_value}")
            plan_path = run_dir / "pipx_wheelhouse_build_plan.md"
            lines = ["# pipx critical wheelhouse build plan", "", "This command did not download wheels.", "", f"Wheelhouse target: `{wheelhouse}`", "", "Specs:"]
            lines.extend(f"- `{spec}`" for spec in specs)
            write_text(plan_path, "\n".join(lines) + "\n")
            report["outputs"].append({"kind": "pipx_wheelhouse_build_plan", "path": rel(plan_path)})
            write_json(run_dir / str(cfg_get("policy.wheelhouse_manifest_name", "pipx_wheelhouse_manifest.json")), manifest)
            return finalize_report(report, run_dir)
    if not specs:
        report["warnings"].append("no critical pipx package specs configured or captured")
    else:
        argv = [PYTHON3, "-m", "pip", "download", "--dest", str(wheelhouse)]
        if boolish(cfg_get("policy.wheelhouse_no_binary", False)):
            argv.extend(["--no-binary", ":all:"])
        argv.extend(specs)
        result = run_cmd(argv, report, label="pip_download_wheelhouse", check=False)
        manifest["executed"] = True
        manifest["returncode"] = result["returncode"]
        if result["returncode"] != 0:
            report["failures"].append("pip wheelhouse download failed")
    artifacts = [file_record(p, include_hash=True, hash_max=10**12) for p in sorted(wheelhouse.glob("*")) if p.is_file()]
    manifest["artifacts"] = artifacts
    path = run_dir / str(cfg_get("policy.wheelhouse_manifest_name", "pipx_wheelhouse_manifest.json"))
    write_json(path, manifest)
    report["wheelhouse"] = {"path": str(wheelhouse), "artifact_count": len(artifacts), "executed": manifest["executed"]}
    report["outputs"].append({"kind": "pipx_wheelhouse_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def verify_wheelhouse(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-wheelhouse")
    report = report_base("verify-wheelhouse", run_dir)
    report["mode"] = "verify"
    preflight(report)
    roots = [resolve_path(raw) for raw in split_semicolon(cfg_get("paths.critical_wheelhouse_roots", ""))]
    critical_names = [name.lower().replace("_", "-") for name in split_semicolon(cfg_get("capture.critical_package_specs", ""))]
    manifest: dict[str, Any] = {"roots": [], "artifacts": [], "critical_specs": critical_names, "coverage": {}}
    for root in roots:
        root_rec = file_record(root, include_hash=False)
        manifest["roots"].append(root_rec)
        if not root.exists():
            report["warnings"].append(f"wheelhouse root missing: {root}")
            continue
        for item in sorted(root.glob("*")):
            if item.is_file() and item.suffix in {".whl", ".gz", ".zip", ".bz2", ".xz"}:
                manifest["artifacts"].append(file_record(item, include_hash=True, hash_max=10**12))
    artifact_names = [Path(rec["path"]).name.lower().replace("_", "-") for rec in manifest["artifacts"]]
    for spec in critical_names:
        package = re.split(r"[<=>~!\[]", spec, 1)[0].strip().lower().replace("_", "-")
        if not package:
            continue
        manifest["coverage"][spec] = any(name.startswith(package + "-") or name.startswith(package + "_") or name == package for name in artifact_names)
    if critical_names and not all(manifest["coverage"].values()):
        report["warnings"].append("one or more configured critical pipx specs have no obvious wheelhouse artifact")
    path = run_dir / str(cfg_get("policy.wheelhouse_manifest_name", "pipx_wheelhouse_manifest.json"))
    write_json(path, manifest)
    report["wheelhouse"] = {"artifact_count": len(manifest["artifacts"]), "coverage": manifest["coverage"]}
    report["outputs"].append({"kind": "pipx_wheelhouse_manifest", "path": rel(path)})
    return finalize_report(report, run_dir)


def build_reinstall_input(report: dict[str, Any]) -> dict[str, Any]:
    data = all_captured_venvs(report)
    state: dict[str, Any] = {"generated_at": iso_now(), "pipx_path": PIPX, "scopes": {}, "apps": [], "entrypoints_note": "pipx recreates entrypoint symlinks during install. Row 12 captures them for audit and drift detection."}
    for scope, payload in data.items():
        state["scopes"][scope] = {"venv_count": len(venvs_mapping(payload))}
        for app_name, record in venvs_mapping(payload).items():
            metadata = record.get("metadata") if isinstance(record.get("metadata"), dict) else {}
            main = metadata.get("main_package") if isinstance(metadata.get("main_package"), dict) else {}
            injections = []
            for inj_name, inj in injected_package_records(record).items():
                if isinstance(inj, dict):
                    injections.append({"name": inj_name, "package_spec": str(inj.get("package_or_url") or inj.get("package") or inj_name), "package_version": str(inj.get("package_version") or "")})
                else:
                    injections.append({"name": inj_name, "package_spec": str(inj_name), "package_version": ""})
            state["apps"].append({
                "scope": scope,
                "app_name": app_name,
                "package_spec": package_spec_from_record(app_name, record),
                "package_version": package_version_from_record(record),
                "suffix": str(main.get("suffix") or ""),
                "include_apps": bool(main.get("include_apps", True)),
                "include_dependencies": bool(main.get("include_dependencies", False)),
                "pip_args": main.get("pip_args") if isinstance(main.get("pip_args"), list) else [],
                "venv_args": metadata.get("venv_args") if isinstance(metadata.get("venv_args"), list) else [],
                "python_version": str(metadata.get("python_version") or ""),
                "python_path": str(metadata.get("python_path") or ""),
                "apps": main.get("apps") if isinstance(main.get("apps"), list) else [],
                "injected_packages": injections,
            })
    return state


def restore_plan_text(state: dict[str, Any]) -> str:
    lines = [
        "# pipx restore plan",
        "",
        "This plan is review-only. Row 12 does not install, upgrade, or remove pipx apps during capture.",
        "",
        "## Restore order",
        "",
        "1. Restore native Python and pipx packages through Row 10 native packages.",
        "2. Confirm `pipx environment` paths on the restored system.",
        "3. Reinstall pipx apps from the generated input/script after review.",
        "4. Reinstall injected packages after each owning app exists.",
        "5. Confirm entrypoints in `~/.local/bin` and PATH.",
        "6. Restore project virtualenvs separately from their source projects; pipx does not own project venvs.",
        "",
        "## Captured pipx apps",
        "",
    ]
    for app in state.get("apps", []):
        lines.append(f"- `{app.get('scope')}` `{app.get('app_name')}` spec=`{app.get('package_spec')}` version=`{app.get('package_version')}` injections={len(app.get('injected_packages', []))}")
    if not state.get("apps"):
        lines.append("- none captured")
    lines.extend(["", "## Boundary", "", "Project virtualenvs, PyCharm interpreters, apt Python packages, and Docker Python environments are outside Row 12.", ""])
    return "\n".join(lines)


def restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-plan")
    report = report_base("restore-plan", run_dir)
    report["mode"] = "plan"
    preflight(report)
    state = build_reinstall_input(report) if not report["failures"] else {"apps": []}
    input_path = run_dir / str(cfg_get("policy.reinstall_input_name", "pipx_reinstall_input.json"))
    write_json(input_path, state)
    plan_path = run_dir / str(cfg_get("policy.restore_plan_name", "pipx_restore_plan.md"))
    write_text(plan_path, restore_plan_text(state))
    report["restore_plan"] = {"path": rel(plan_path), "input_path": rel(input_path), "app_count": len(state.get("apps", []))}
    report["outputs"].append({"kind": "pipx_reinstall_input", "path": rel(input_path)})
    report["outputs"].append({"kind": "pipx_restore_plan", "path": rel(plan_path)})
    return finalize_report(report, run_dir)


def generate_reinstall_input(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-reinstall-input")
    report = report_base("generate-reinstall-input", run_dir)
    report["mode"] = "plan"
    preflight(report)
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/12_pipx")))
    generated_root.mkdir(parents=True, exist_ok=True)
    state = build_reinstall_input(report) if not report["failures"] else {"apps": []}
    run_input = run_dir / str(cfg_get("policy.reinstall_input_name", "pipx_reinstall_input.json"))
    generated_input = generated_root / str(cfg_get("policy.reinstall_input_name", "pipx_reinstall_input.json"))
    write_json(run_input, state)
    write_json(generated_input, state)
    report["restore_plan"] = {"generated_input": rel(generated_input), "run_input": rel(run_input), "app_count": len(state.get("apps", []))}
    report["outputs"].append({"kind": "pipx_reinstall_input", "path": rel(run_input)})
    report["outputs"].append({"kind": "generated_pipx_reinstall_input", "path": rel(generated_input)})
    return finalize_report(report, run_dir)


def install_command_for_app(app: dict[str, Any]) -> list[str]:
    cmd = ["pipx"]
    if app.get("scope") == "global":
        cmd.append("--global")
    cmd.append("install")
    suffix = str(app.get("suffix") or "")
    if suffix:
        cmd.extend(["--suffix", suffix])
    if app.get("include_dependencies"):
        cmd.append("--include-deps")
    for pip_arg in app.get("pip_args") or []:
        cmd.extend(["--pip-args", str(pip_arg)])
    cmd.append(str(app.get("package_spec") or app.get("app_name")))
    return cmd


def inject_command_for_app(app: dict[str, Any], injection: dict[str, Any]) -> list[str]:
    cmd = ["pipx"]
    if app.get("scope") == "global":
        cmd.append("--global")
    cmd.extend(["inject", str(app.get("app_name")), str(injection.get("package_spec") or injection.get("name"))])
    return cmd


def shell_line(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv if part != "")


def generate_reinstall_script(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-reinstall-script")
    report = report_base("generate-reinstall-script", run_dir)
    report["mode"] = "plan"
    preflight(report)
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/12_pipx")))
    generated_root.mkdir(parents=True, exist_ok=True)
    state = build_reinstall_input(report) if not report["failures"] else {"apps": []}
    input_path = generated_root / str(cfg_get("policy.reinstall_input_name", "pipx_reinstall_input.json"))
    write_json(input_path, state)
    guard_env = str(cfg_get("policy.reinstall_execution_guard_env", "CONFIRM_PIPX_REINSTALL"))
    guard_value = str(cfg_get("policy.reinstall_execution_guard_value", "I_UNDERSTAND_THIS_REINSTALLS_PIPX_APPS"))
    lines: list[str] = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Generated by Row 12 pipx. Review before running on a restored system.",
        "# This script restores pipx-managed CLI apps only; it does not restore project virtualenvs or Docker Python environments.",
        "",
        f"REQUIRED_TOKEN={shlex.quote(guard_value)}",
        f"if [[ \"${{{guard_env}:-}}\" != \"$REQUIRED_TOKEN\" ]]; then",
        f"  echo \"Refusing to run. Set {guard_env}=$REQUIRED_TOKEN after reviewing this script.\" >&2",
        "  exit 2",
        "fi",
        "",
        "command -v pipx >/dev/null || { echo 'pipx is not installed; restore native packages first.' >&2; exit 1; }",
        "pipx --version",
        "pipx environment || true",
        "",
        "# pipx app reinstalls",
    ]
    for app in state.get("apps", []):
        if app.get("scope") == "global":
            lines.append("# Global pipx app captured. Review whether sudo/root context is required before running this line.")
        if boolish(cfg_get("policy.generated_script_notes_interpreter_drift", True)) and app.get("python_version"):
            lines.append(f"# Captured interpreter for {app.get('app_name')}: {app.get('python_version')}")
        lines.append(shell_line(install_command_for_app(app)))
        if boolish(cfg_get("policy.generated_script_reinstalls_injections", True)):
            for injection in app.get("injected_packages", []):
                lines.append(shell_line(inject_command_for_app(app, injection)))
    if not state.get("apps"):
        lines.append("# No pipx apps captured.")
    lines.extend(["", "# Verify entrypoints after review:", "pipx list", ""])
    script_path = generated_root / str(cfg_get("policy.reinstall_script_name", "reinstall_pipx.review.sh"))
    write_text(script_path, "\n".join(lines))
    mode_text = str(cfg_get("policy.generated_script_mode", "0600"))
    os.chmod(script_path, int(mode_text, 8))
    report["restore_plan"] = {"script_path": rel(script_path), "input_path": rel(input_path), "script_mode": oct(script_path.stat().st_mode & 0o777), "app_count": len(state.get("apps", [])), "guard_env": guard_env, "guard_value": guard_value}
    report["outputs"].append({"kind": "generated_pipx_reinstall_input", "path": rel(input_path)})
    report["outputs"].append({"kind": "pipx_reinstall_script", "path": rel(script_path), "mode": oct(script_path.stat().st_mode & 0o777)})
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("capture-environment").set_defaults(func=capture_environment)
    sub.add_parser("capture-list-json").set_defaults(func=capture_list_json)
    sub.add_parser("capture-injected").set_defaults(func=capture_injected)
    sub.add_parser("capture-entrypoints").set_defaults(func=capture_entrypoints)
    sub.add_parser("capture-interpreter").set_defaults(func=capture_interpreter)
    p = sub.add_parser("build-critical-wheelhouse"); p.add_argument("--execute", action="store_true"); p.set_defaults(func=build_critical_wheelhouse)
    sub.add_parser("verify-wheelhouse").set_defaults(func=verify_wheelhouse)
    sub.add_parser("restore-plan").set_defaults(func=restore_plan)
    sub.add_parser("generate-reinstall-input").set_defaults(func=generate_reinstall_input)
    sub.add_parser("generate-reinstall-script").set_defaults(func=generate_reinstall_script)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(ARGS))
PYCODE