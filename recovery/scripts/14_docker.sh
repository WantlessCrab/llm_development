#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PYCODE'
from __future__ import annotations

import argparse
import fnmatch
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
SCRIPT_NAME = "14_docker.sh"
SCHEMA_NAME = "recovery.docker.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {"name": "docker", "verified_docker_version": "29.4.2", "verified_compose_version": "v5.1.3", "layer": "14_container_runtime_compose_workload_selected_artifacts"},
    "project": {"root": str(PROJECT_ROOT), "output_root": "state/dry_runs/14_docker", "generated_root": "state/generated/14_docker", "export_root": "state/exports/14_docker"},
    "commands": {"docker": "/usr/bin/docker", "systemctl": "/usr/bin/systemctl", "journalctl": "/usr/bin/journalctl", "sha256sum": "/usr/bin/sha256sum", "python": "/usr/bin/python3"},
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "docker_report.json",
        "restore_plan_name": "docker_compose_restore_plan.md",
        "generated_script_mode": "0600",
        "fail_if_docker_missing": True,
        "fail_if_daemon_unavailable": False,
        "redact_env_values": True,
        "redact_secret_like_labels": True,
        "env_name_capture_only": True,
        "copy_compose_files": True,
        "copy_compose_files_redacted": True,
        "copy_env_files": False,
        "env_file_names_only": True,
        "max_compose_file_bytes": 2097152,
        "max_env_file_bytes": 1048576,
        "max_daemon_file_bytes": 1048576,
        "copy_sensitive_daemon_files": False,
        "selected_image_export_requires_execute": True,
        "selected_image_export_guard_prefix": "DOCKER_IMAGE_EXPORT",
        "image_export_guard_env": "CONFIRM_DOCKER_IMAGE_EXPORT",
        "image_export_guard_value": "I_UNDERSTAND_THIS_EXPORTS_DOCKER_IMAGES",
        "volume_export_requires_execute": True,
        "volume_export_guard_prefix": "DOCKER_VOLUME_EXPORT",
        "volume_export_guard_env": "CONFIRM_DOCKER_VOLUME_EXPORT",
        "volume_export_guard_value": "I_UNDERSTAND_THIS_EXPORTS_A_STOPPED_DOCKER_VOLUME",
        "database_secondary_volume_export_guard_prefix": "DOCKER_DB_VOLUME_SECONDARY_EXPORT",
        "volume_export_helper_image": "busybox:latest",
        "helper_image_must_exist_locally": True,
        "no_auto_pull": True,
        "block_database_volume_export_by_default": True,
        "require_quiesced_volume_export": True,
        "postgres_primary_logical_owner": "Row 16 PostgreSQL logical dump layer",
        "no_container_start_stop_remove_by_default": True,
    },
    "docker": {
        "root_dir_expected": "/var/lib/docker",
        "protected_database_volume_names": "llm_database_pgdata;postgres_data;pgdata;portainer_postgres_data",
        "protected_database_container_names": "llm-postgres;postgres;postgresql",
        "compose_label_keys": "com.docker.compose.project;com.docker.compose.project.working_dir;com.docker.compose.project.config_files;com.docker.compose.service;com.docker.compose.version",
        "gpu_device_paths": "/dev/kfd;/dev/dri",
        "gpu_env_name_patterns": "ROCR_VISIBLE_DEVICES;HIP_VISIBLE_DEVICES;CUDA_VISIBLE_DEVICES;NVIDIA_VISIBLE_DEVICES;HSA_OVERRIDE_GFX_VERSION",
        "model_runtime_keywords": "rocm;vllm;llama;llamacpp;qwen;model;gpu",
    },
    "paths": {
        "daemon_config_files": "/etc/docker/daemon.json;/etc/default/docker;/etc/docker/key.json",
        "sensitive_daemon_config_files": "/etc/docker/key.json",
        "docker_systemd_units": "docker.service;docker.socket;containerd.service",
        "docker_cli_config": "~/.docker/config.json",
        "compose_search_roots": "/home/wantless/PycharmProjects/automation;/home/wantless/PycharmProjects/browser;/home/wantless/PycharmProjects/tts_app",
        "compose_exclude_dir_parts": "/home/wantless/PycharmProjects/automation/recovery/state;/home/wantless/PycharmProjects/automation/recovery/.venv;/.git/;/.venv/;/node_modules/;__pycache__",
        "compose_file_names": "compose.yaml;compose.yml;docker-compose.yaml;docker-compose.yml;compose*.yaml;compose*.yml;docker-compose*.yaml;docker-compose*.yml",
        "compose_env_names": ".env;.env.local;.env.production;.env.development",
        "compose_extra_env_globs": "*.env;*.env.*",
        "model_runtime_roots": "/home/wantless/PycharmProjects/automation/model_runtimes;/home/wantless/PycharmProjects/automation/data_stack;/home/wantless/PycharmProjects/automation/local_llm;/home/wantless/PycharmProjects/automation/local_llm_router",
        "legacy_stack_roots": "/home/wantless/PycharmProjects/tts_app;/home/wantless/PycharmProjects/browser",
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
    path = PROJECT_ROOT / "configs" / "14_docker.yaml"
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
SYSTEMCTL = cmd_path("systemctl")
JOURNALCTL = cmd_path("journalctl")
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


def safe_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value).strip())
    return cleaned.strip("_") or "unnamed"


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/14_docker")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "14_docker.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "14_docker.config.snapshot.yaml")
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


def file_record(path: Path, *, include_hash: bool = False) -> dict[str, Any]:
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
    }
    if path.is_symlink():
        try:
            target = path.resolve(strict=False)
            rec["symlink_target"] = os.readlink(path)
            rec["target_resolved"] = str(target)
            rec["target_exists"] = target.exists()
        except OSError as exc:
            rec["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink():
        rec["sha256"] = sha256_file(path)
    return rec


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {"name": "docker", "script": SCRIPT_NAME, "docker_path": DOCKER, "docker_version": None, "compose_version": None},
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
    report_path = run_dir / str(cfg_get("policy.report_name", "docker_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False, input_text: str | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, input=input_text)
    safe = safe_name(label)
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


def docker_cmd(args: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    return run_cmd([DOCKER, *args], report, label=label, check=check)


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def preflight(report: dict[str, Any], *, require_daemon: bool = True) -> None:
    if not command_exists(DOCKER):
        msg = f"docker command not found at configured path: {DOCKER}"
        if boolish(cfg_get("policy.fail_if_docker_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
        return
    version = docker_cmd(["--version"], report, label="docker_version")
    report["tool"]["docker_version"] = (version["stdout"] or version["stderr"]).strip()
    compose = docker_cmd(["compose", "version"], report, label="docker_compose_version")
    report["tool"]["compose_version"] = (compose["stdout"] or compose["stderr"]).strip()
    if require_daemon:
        info = docker_cmd(["info", "--format", "{{json .}}"], report, label="docker_info_probe")
        if info["returncode"] != 0:
            msg = "docker daemon unavailable or current user cannot access it"
            if boolish(cfg_get("policy.fail_if_daemon_unavailable", False)):
                report["failures"].append(msg)
            else:
                report["warnings"].append(msg)


def parse_json(text: str, default: Any) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return default


def parse_ndjson(text: str) -> list[Any]:
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            rows.append({"raw": line, "json_error": True})
    return rows


def docker_inspect(kind: str, names: list[str], report: dict[str, Any], label: str) -> list[Any]:
    if not names:
        return []
    result = docker_cmd([kind, "inspect", *names], report, label=label)
    if result["returncode"] != 0:
        report["warnings"].append(f"docker {kind} inspect failed for {len(names)} objects")
        return []
    parsed = parse_json(result["stdout"], [])
    if kind in {"container", "image", "network", "volume"} and isinstance(parsed, list):
        sanitized: list[Any] = []
        for item in parsed:
            if not isinstance(item, dict):
                sanitized.append(item)
            elif kind == "container":
                sanitized.append(sanitize_container_inspect(item))
            elif kind == "image":
                sanitized.append(sanitize_image_inspect(item))
            elif kind in {"network", "volume"}:
                sanitized.append(sanitize_generic_docker_inspect(kind, item))
        stdout_rel = result.get("record", {}).get("stdout_path")
        if stdout_rel:
            stdout_path = resolve_path(stdout_rel)
            write_json(stdout_path, sanitized)
            result["stdout"] = json.dumps(sanitized, indent=2, sort_keys=True, default=str) + "\n"
            result["record"]["stdout_redacted"] = True
            result["record"]["redaction_kind"] = f"docker-{kind}-inspect-sanitized"
            report["warnings"].append(f"sanitized raw docker {kind} inspect stdout before persistence: {label}")
        return sanitized
    return parsed


def redact_env_list(env_values: Any) -> list[str]:
    if not isinstance(env_values, list):
        return []
    names = []
    for item in env_values:
        text = str(item)
        if "=" in text:
            names.append(text.split("=", 1)[0])
        else:
            names.append(text)
    return sorted(set(names))


SECRET_LABEL_RE = re.compile(r"(secret|token|password|passwd|credential|apikey|api_key|auth)", re.IGNORECASE)
CREDENTIAL_URL_RE = re.compile(r"://[^\s/@:]+:[^\s/@]+@", re.IGNORECASE)


def value_looks_sensitive(value: Any) -> bool:
    return bool(CREDENTIAL_URL_RE.search(str(value or "")))


def should_redact_key_value(key: Any, value: Any = "") -> bool:
    return bool(SECRET_LABEL_RE.search(str(key)) or value_looks_sensitive(value))


def sanitize_labels(labels: Any) -> dict[str, Any]:
    if not isinstance(labels, dict):
        return {}
    result = {}
    for key, value in labels.items():
        if boolish(cfg_get("policy.redact_secret_like_labels", False)) and should_redact_key_value(key, value):
            result[key] = "<redacted>"
        else:
            result[key] = value
    return result


def sanitize_container_inspect(item: dict[str, Any]) -> dict[str, Any]:
    config = item.get("Config") if isinstance(item.get("Config"), dict) else {}
    host = item.get("HostConfig") if isinstance(item.get("HostConfig"), dict) else {}
    state = item.get("State") if isinstance(item.get("State"), dict) else {}
    net = item.get("NetworkSettings") if isinstance(item.get("NetworkSettings"), dict) else {}
    labels = sanitize_labels(config.get("Labels") or {})
    env_names = redact_env_list(config.get("Env"))
    compose = {k: labels.get(k) for k in split_semicolon(cfg_get("docker.compose_label_keys", "")) if k in labels}
    return {
        "Id": item.get("Id"),
        "Name": str(item.get("Name", "")).lstrip("/"),
        "Created": item.get("Created"),
        "Path": redact_command_payload(item.get("Path")),
        "Args": redact_command_payload(item.get("Args")),
        "Image": item.get("Image"),
        "ImageName": config.get("Image"),
        "State": {"Status": state.get("Status"), "Running": state.get("Running"), "ExitCode": state.get("ExitCode"), "Health": state.get("Health")},
        "RestartPolicy": host.get("RestartPolicy"),
        "AutoRemove": host.get("AutoRemove"),
        "Privileged": host.get("Privileged"),
        "User": config.get("User"),
        "WorkingDir": config.get("WorkingDir"),
        "Entrypoint": redact_command_payload(config.get("Entrypoint")),
        "Cmd": redact_command_payload(config.get("Cmd")),
        "EnvNames": env_names,
        "Labels": labels,
        "Compose": compose,
        "ExposedPorts": config.get("ExposedPorts"),
        "PortBindings": host.get("PortBindings"),
        "PublishedPorts": net.get("Ports"),
        "Mounts": item.get("Mounts", []),
        "Binds": host.get("Binds"),
        "VolumesFrom": host.get("VolumesFrom"),
        "NetworkMode": host.get("NetworkMode"),
        "Networks": list((net.get("Networks") or {}).keys()) if isinstance(net.get("Networks"), dict) else [],
        "Healthcheck": redact_json_secretish(config.get("Healthcheck"), "Healthcheck"),
        "Devices": host.get("Devices"),
        "DeviceRequests": host.get("DeviceRequests"),
        "DeviceCgroupRules": host.get("DeviceCgroupRules"),
        "Runtime": host.get("Runtime"),
        "GroupAdd": host.get("GroupAdd"),
        "ShmSize": host.get("ShmSize"),
        "LogConfig": redact_json_secretish(host.get("LogConfig"), "LogConfig"),
        "SecurityOpt": host.get("SecurityOpt"),
        "CapAdd": host.get("CapAdd"),
        "CapDrop": host.get("CapDrop"),
        "ExtraHosts": host.get("ExtraHosts"),
        "Dns": host.get("Dns"),
        "IpcMode": host.get("IpcMode"),
        "PidMode": host.get("PidMode"),
        "CgroupnsMode": host.get("CgroupnsMode"),
    }


def normalized_container_record(item: dict[str, Any]) -> dict[str, Any]:
    """Return Row 14's sanitized container record without losing fields.

    docker_inspect("container", ...) already returns sanitized records and rewrites
    the captured stdout before persistence. Some later callers receive those
    sanitized records rather than raw Docker inspect objects. Re-sanitizing a
    sanitized record would drop HostConfig-derived GPU fields such as Devices,
    DeviceRequests, and Runtime because there is no longer a HostConfig object.
    """
    if "EnvNames" in item and "Config" not in item:
        return item
    return sanitize_container_inspect(item)


def container_list(report: dict[str, Any]) -> list[dict[str, Any]]:
    result = docker_cmd(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], report, label="docker_ps_all_json")
    if result["returncode"] != 0:
        report["warnings"].append("docker ps -a failed")
        return []
    return parse_ndjson(result["stdout"])


def container_names_or_ids(report: dict[str, Any]) -> list[str]:
    rows = container_list(report)
    ids = []
    for row in rows:
        value = row.get("ID") or row.get("Names") or row.get("Names")
        if value:
            ids.append(str(value))
    return sorted(set(ids))


def image_refs(report: dict[str, Any]) -> list[str]:
    result = docker_cmd(["image", "ls", "--no-trunc", "--format", "{{.ID}}"], report, label="docker_image_ids")
    if result["returncode"] != 0:
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def volume_names(report: dict[str, Any]) -> list[str]:
    result = docker_cmd(["volume", "ls", "--format", "{{.Name}}"], report, label="docker_volume_names")
    if result["returncode"] != 0:
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def network_names(report: dict[str, Any]) -> list[str]:
    result = docker_cmd(["network", "ls", "--no-trunc", "--format", "{{.Name}}"], report, label="docker_network_names")
    if result["returncode"] != 0:
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def cmd_capture_info(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-info")
    report = report_base("capture-info", run_dir)
    report["mode"] = "capture"
    preflight(report)
    if not report["failures"]:
        info = docker_cmd(["info", "--format", "{{json .}}"], report, label="docker_info_json")
        version = docker_cmd(["version", "--format", "{{json .}}"], report, label="docker_version_json")
        df = docker_cmd(["system", "df", "-v"], report, label="docker_system_df_verbose")
        plugin_ls = docker_cmd(["plugin", "ls", "--format", "{{json .}}"], report, label="docker_plugin_ls_json")
        buildx_version = docker_cmd(["buildx", "version"], report, label="docker_buildx_version")
        buildx_ls = docker_cmd(["buildx", "ls"], report, label="docker_buildx_ls")
        compose_ls = docker_cmd(["compose", "ls", "--format", "json"], report, label="docker_compose_ls_json")
        payload = {
            "docker_info": parse_json(info["stdout"], {}) if info["returncode"] == 0 else {},
            "docker_version": parse_json(version["stdout"], {}) if version["returncode"] == 0 else {},
            "system_df_stdout": df["record"]["stdout_path"],
            "plugins": parse_ndjson(plugin_ls["stdout"]) if plugin_ls["returncode"] == 0 else [],
            "buildx_version_stdout": buildx_version["record"]["stdout_path"],
            "buildx_ls_stdout": buildx_ls["record"]["stdout_path"],
            "compose_ls": parse_json(compose_ls["stdout"], []) if compose_ls["returncode"] == 0 else [],
        }
        path = run_dir / "docker_info_manifest.json"
        write_json(path, payload)
        report["docker"] = {"manifest": rel(path), "root_dir": payload["docker_info"].get("DockerRootDir")}
        output_file(report, path, "json", "docker_info_manifest")
    return finalize_report(report, run_dir)


def maybe_copy_file(path: Path, dest_root: Path, max_bytes: int, report: dict[str, Any], label: str, *, redact_json: bool = False, redact_text: bool = False) -> dict[str, Any]:
    rec = file_record(path, include_hash=True)
    rec["label"] = label
    if not path.exists() or not path.is_file():
        return rec
    try:
        if path.stat().st_size <= max_bytes:
            dest = dest_root / safe_name(str(path).lstrip("/"))
            dest.parent.mkdir(parents=True, exist_ok=True)
            if redact_json:
                payload = parse_json(path.read_text(encoding="utf-8", errors="replace"), {})
                if isinstance(payload, dict):
                    for key in ("auths", "HttpHeaders", "credsStore", "credHelpers"):
                        if key in payload:
                            payload[key] = "<redacted-or-captured-by-reference>"
                    write_json(dest, payload)
                    rec["copy_redacted"] = True
                else:
                    shutil.copy2(path, dest)
            elif redact_text:
                original = path.read_text(encoding="utf-8", errors="replace")
                parsed = parse_json(original, None)
                if parsed is not None:
                    write_json(dest, redact_json_secretish(parsed))
                    rec["redaction_kind"] = "json-structural"
                else:
                    write_text(dest, redact_compose_text(original))
                    rec["redaction_kind"] = "text-line"
                rec["copy_redacted"] = True
                rec["exact_source_payload_owner"] = "Borg rows 06/07"
            else:
                shutil.copy2(path, dest)
            rec["copied_to"] = rel(dest)
        else:
            rec["copy_skipped"] = "larger than configured maximum"
    except OSError as exc:
        rec["copy_error"] = str(exc)
        report["warnings"].append(f"could not copy {path}: {exc}")
    return rec


def cmd_capture_daemon_config(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-daemon-config")
    report = report_base("capture-daemon-config", run_dir)
    report["mode"] = "capture"
    preflight(report, require_daemon=False)
    copied_root = run_dir / "daemon_config_snapshot"
    records = []
    max_bytes = int(cfg_get("policy.max_daemon_file_bytes", 1048576))
    sensitive_daemon_paths = {str(resolve_path(p)) for p in split_semicolon(cfg_get("paths.sensitive_daemon_config_files", ""))}
    for raw in split_semicolon(cfg_get("paths.daemon_config_files", "")):
        path = resolve_path(raw)
        if str(path) in sensitive_daemon_paths and not boolish(cfg_get("policy.copy_sensitive_daemon_files", False)):
            rec = file_record(path, include_hash=True)
            rec["label"] = "daemon_config_sensitive_no_copy"
            rec["sensitive"] = True
            rec["copy_skipped"] = "sensitive daemon file; hash/identity captured only"
            records.append(rec)
        else:
            records.append(maybe_copy_file(path, copied_root, max_bytes, report, "daemon_config_redacted", redact_text=True))
    cli_config = resolve_path(str(cfg_get("paths.docker_cli_config", "~/.docker/config.json")))
    records.append(maybe_copy_file(cli_config, copied_root, max_bytes, report, "docker_cli_config_redacted", redact_json=True))
    manifest = {"config_files": records, "note": "Docker CLI auth material is redacted; restore credentials through explicit credential setup, not this manifest."}
    path = run_dir / "docker_daemon_config_manifest.json"
    write_json(path, manifest)
    report["docker"] = {"daemon_config_manifest": rel(path)}
    output_file(report, path, "json", "docker_daemon_config_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_systemd_overrides(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-systemd-overrides")
    report = report_base("capture-systemd-overrides", run_dir)
    report["mode"] = "capture"
    units = split_semicolon(cfg_get("paths.docker_systemd_units", ""))
    manifest: dict[str, Any] = {"units": {}}
    for unit in units:
        unit_payload: dict[str, Any] = {}
        if command_exists(SYSTEMCTL):
            for label, argv in [
                ("status", [SYSTEMCTL, "--no-pager", "--full", "status", unit]),
                ("cat", [SYSTEMCTL, "cat", unit]),
                ("show", [SYSTEMCTL, "show", unit]),
                ("list_dependencies", [SYSTEMCTL, "list-dependencies", unit, "--no-pager"]),
            ]:
                result = run_cmd(argv, report, label=f"systemd_{unit}_{label}")
                unit_payload[label] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"]}
        manifest["units"][unit] = unit_payload
    path = run_dir / "docker_systemd_manifest.json"
    write_json(path, manifest)
    report["docker"] = {"systemd_manifest": rel(path)}
    output_file(report, path, "json", "docker_systemd_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_contexts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-contexts")
    report = report_base("capture-contexts", run_dir)
    report["mode"] = "capture"
    preflight(report, require_daemon=False)
    context_ls = docker_cmd(["context", "ls", "--format", "{{json .}}"], report, label="docker_context_ls_json")
    context_names = [row.get("Name", "").replace("*", "").strip() for row in parse_ndjson(context_ls["stdout"])]
    context_names = [name for name in context_names if name]
    inspect = docker_cmd(["context", "inspect", *context_names], report, label="docker_context_inspect_json") if context_names else {"stdout": "[]", "returncode": 0, "record": {}}
    if context_names:
        redact_command_stdout(report, inspect, label="docker_context_inspect_json")
    current = docker_cmd(["context", "show"], report, label="docker_context_show")
    manifest = {"contexts": parse_ndjson(context_ls["stdout"]), "inspect": parse_json(inspect["stdout"], []), "current": current["stdout"].strip()}
    path = run_dir / "docker_contexts_manifest.json"
    write_json(path, manifest)
    report["docker"] = {"contexts_manifest": rel(path), "context_count": len(context_names)}
    output_file(report, path, "json", "docker_contexts_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_containers(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-containers")
    report = report_base("capture-containers", run_dir)
    report["mode"] = "capture"
    preflight(report)
    ids = container_names_or_ids(report) if not report["failures"] else []
    inspect = docker_inspect("container", ids, report, "docker_container_inspect_json") if ids else []
    sanitized = [normalized_container_record(item) for item in inspect if isinstance(item, dict)]
    path = run_dir / "docker_containers_manifest.json"
    write_json(path, {"containers": sanitized, "env_policy": "environment variable names only; values redacted/omitted"})
    report["containers"] = {"manifest": rel(path), "count": len(sanitized)}
    output_file(report, path, "json", "docker_containers_manifest", {"container_count": len(sanitized)})
    return finalize_report(report, run_dir)


def cmd_capture_images(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-images")
    report = report_base("capture-images", run_dir)
    report["mode"] = "capture"
    preflight(report)
    rows_result = docker_cmd(["image", "ls", "--digests", "--no-trunc", "--format", "{{json .}}"], report, label="docker_image_ls_json")
    rows = parse_ndjson(rows_result["stdout"])
    refs = image_refs(report) if not report["failures"] else []
    inspect = docker_inspect("image", refs, report, "docker_image_inspect_json") if refs else []
    sanitized_inspect = [sanitize_image_inspect(item) for item in inspect if isinstance(item, dict)]
    path = run_dir / "docker_images_manifest.json"
    write_json(path, {"images": rows, "inspect": sanitized_inspect, "image_env_policy": "image Config.Env values redacted; names preserved"})
    report["images"] = {"manifest": rel(path), "image_count": len(rows), "inspect_count": len(sanitized_inspect)}
    output_file(report, path, "json", "docker_images_manifest", {"image_count": len(rows)})
    return finalize_report(report, run_dir)


def cmd_capture_image_digests(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-image-digests")
    report = report_base("capture-image-digests", run_dir)
    report["mode"] = "capture"
    preflight(report)
    refs = image_refs(report) if not report["failures"] else []
    inspect = docker_inspect("image", refs, report, "docker_image_digest_inspect_json") if refs else []
    digest_records = []
    for item in inspect:
        digest_records.append({
            "Id": item.get("Id"),
            "RepoTags": item.get("RepoTags"),
            "RepoDigests": item.get("RepoDigests"),
            "Architecture": item.get("Architecture"),
            "Os": item.get("Os"),
            "RootFS": item.get("RootFS"),
            "ConfigLabels": sanitize_labels((item.get("Config") or {}).get("Labels")) if isinstance(item.get("Config"), dict) else {},
        })
    path = run_dir / "docker_image_digests_manifest.json"
    write_json(path, {"image_digests": digest_records})
    report["images"] = {"digest_manifest": rel(path), "count": len(digest_records)}
    output_file(report, path, "json", "docker_image_digests_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_networks(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-networks")
    report = report_base("capture-networks", run_dir)
    report["mode"] = "capture"
    preflight(report)
    names = network_names(report) if not report["failures"] else []
    inspect = docker_inspect("network", names, report, "docker_network_inspect_json") if names else []
    path = run_dir / "docker_networks_manifest.json"
    write_json(path, {"networks": inspect})
    report["networks"] = {"manifest": rel(path), "count": len(inspect)}
    output_file(report, path, "json", "docker_networks_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_volumes(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-volumes")
    report = report_base("capture-volumes", run_dir)
    report["mode"] = "capture"
    preflight(report)
    names = volume_names(report) if not report["failures"] else []
    inspect = docker_inspect("volume", names, report, "docker_volume_inspect_json") if names else []
    protected = set(split_semicolon(cfg_get("docker.protected_database_volume_names", "")))
    records = []
    for item in inspect:
        name = item.get("Name")
        rec = dict(item)
        rec["protected_database_volume_name_match"] = name in protected
        records.append(rec)
    path = run_dir / "docker_volumes_manifest.json"
    write_json(path, {"volumes": records, "database_volume_note": cfg_get("policy.postgres_primary_logical_owner")})
    report["volumes"] = {"manifest": rel(path), "count": len(records), "protected_count": sum(1 for r in records if r.get("protected_database_volume_name_match"))}
    output_file(report, path, "json", "docker_volumes_manifest")
    return finalize_report(report, run_dir)


def container_inspects(report: dict[str, Any]) -> list[dict[str, Any]]:
    ids = container_names_or_ids(report)
    return [item for item in docker_inspect("container", ids, report, "docker_container_inspect_for_mounts") if isinstance(item, dict)] if ids else []


def cmd_capture_bind_mounts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-bind-mounts")
    report = report_base("capture-bind-mounts", run_dir)
    report["mode"] = "capture"
    preflight(report)
    binds: list[dict[str, Any]] = []
    volumes: list[dict[str, Any]] = []
    for item in container_inspects(report) if not report["failures"] else []:
        cname = str(item.get("Name", "")).lstrip("/")
        for mnt in item.get("Mounts", []) or []:
            rec = {"container": cname, "mount": mnt}
            if mnt.get("Type") == "bind":
                source = Path(str(mnt.get("Source", "")))
                rec["source_record"] = file_record(source, include_hash=False)
                binds.append(rec)
            elif mnt.get("Type") == "volume":
                volumes.append(rec)
    path = run_dir / "docker_bind_mounts_manifest.json"
    write_json(path, {"bind_mounts": binds, "volume_mounts": volumes})
    report["mounts"] = {"manifest": rel(path), "bind_count": len(binds), "volume_mount_count": len(volumes)}
    output_file(report, path, "json", "docker_bind_mounts_manifest")
    return finalize_report(report, run_dir)


def compose_path_excluded(path: Path) -> bool:
    normalized = str(path.resolve()).replace("\\", "/")
    parts = set(Path(normalized).parts)
    for raw in split_semicolon(cfg_get("paths.compose_exclude_dir_parts", "")):
        marker = raw.strip().replace("\\", "/")
        if not marker:
            continue
        if marker.startswith("/") and normalized.startswith(marker.rstrip("/")):
            return True
        marker_part = marker.strip("/")
        if marker_part and marker_part in parts:
            return True
        if marker and marker in normalized:
            return True
    return False


def compose_name_matches(filename: str) -> bool:
    patterns = split_semicolon(cfg_get("paths.compose_file_names", ""))
    return any(fnmatch.fnmatch(filename, pattern) for pattern in patterns)


def find_compose_files() -> list[Path]:
    roots = [resolve_path(p) for p in split_semicolon(cfg_get("paths.compose_search_roots", ""))]
    found: list[Path] = []
    seen: set[str] = set()
    for root in roots:
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            current = Path(dirpath)
            if compose_path_excluded(current):
                dirnames[:] = []
                continue
            dirnames[:] = [d for d in dirnames if not compose_path_excluded(current / d)]
            for filename in filenames:
                if not compose_name_matches(filename):
                    continue
                path = (current / filename).resolve()
                if compose_path_excluded(path):
                    continue
                key = str(path)
                if key not in seen:
                    seen.add(key)
                    found.append(path)
    return sorted(found)


def redact_compose_text(text: str) -> str:
    redacted_lines: list[str] = []
    env_indent_stack: list[int] = []
    for raw in text.splitlines():
        stripped = raw.strip()
        indent = len(raw) - len(raw.lstrip(" "))

        # Leave an environment: block when indentation returns to the parent level.
        while env_indent_stack and stripped and indent <= env_indent_stack[-1]:
            env_indent_stack.pop()

        if re.match(r"^\s*environment\s*:\s*$", raw):
            env_indent_stack.append(indent)
            redacted_lines.append(raw)
            continue

        in_environment_block = bool(env_indent_stack and indent > env_indent_stack[-1])

        if in_environment_block:
            match = re.match(r"^(\s*-\s*)([A-Za-z_][A-Za-z0-9_]*)(=)(.*)$", raw)
            if match:
                redacted_lines.append(f"{match.group(1)}{match.group(2)}=<redacted>")
                continue
            match = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*:\s*)(.+)$", raw)
            if match and not match.group(4).startswith("|"):
                redacted_lines.append(f"{match.group(1)}{match.group(2)}{match.group(3)}<redacted>")
                continue

        # Redact any secret-looking key or credentialed URL outside environment blocks.
        match = re.match(r"^(\s*-\s*)([A-Za-z_][A-Za-z0-9_]*)(=)(.*)$", raw)
        if match and should_redact_key_value(match.group(2), match.group(4)):
            redacted_lines.append(f"{match.group(1)}{match.group(2)}=<redacted>")
            continue
        match = re.match(r"^(\s*)([A-Za-z_][A-Za-z0-9_.-]*)(\s*:\s*)(.+)$", raw)
        if match and should_redact_key_value(match.group(2), match.group(4)) and not match.group(4).startswith("|"):
            redacted_lines.append(f"{match.group(1)}{match.group(2)}{match.group(3)}<redacted>")
            continue
        if value_looks_sensitive(raw):
            redacted_lines.append(CREDENTIAL_URL_RE.sub("://<redacted-credentials>@", raw))
            continue

        redacted_lines.append(raw)
    return "\n".join(redacted_lines) + ("\n" if text.endswith("\n") else "")




def redact_environment_payload(payload: Any) -> Any:
    if isinstance(payload, dict):
        return {str(key): "<redacted>" for key in payload.keys()}
    if isinstance(payload, list):
        result: list[Any] = []
        for item in payload:
            if isinstance(item, str) and "=" in item:
                name = item.split("=", 1)[0]
                result.append(f"{name}=<redacted>")
            elif isinstance(item, str):
                result.append(item)
            else:
                result.append("<redacted>")
        return result
    if isinstance(payload, str) and "=" in payload:
        name = payload.split("=", 1)[0]
        return f"{name}=<redacted>"
    if isinstance(payload, str):
        return "<redacted>"
    return "<redacted>"


def redact_json_secretish(payload: Any, parent_key: str = "") -> Any:
    parent = str(parent_key).lower()
    if parent in {"environment", "env"}:
        return redact_environment_payload(payload)
    if isinstance(payload, dict):
        redacted: dict[str, Any] = {}
        for key, value in payload.items():
            key_text = str(key)
            key_lower = key_text.lower()
            if key_lower in {"environment", "env"}:
                redacted[key] = redact_environment_payload(value)
            elif should_redact_key_value(key, value):
                redacted[key] = "<redacted>"
            else:
                redacted[key] = redact_json_secretish(value, key_text)
        return redacted
    if isinstance(payload, list):
        result: list[Any] = []
        for item in payload:
            if isinstance(item, str) and "=" in item:
                name, value = item.split("=", 1)
                if should_redact_key_value(name, value):
                    result.append(f"{name}=<redacted>")
                else:
                    result.append(item)
            else:
                result.append(redact_json_secretish(item, parent_key))
        return result
    if isinstance(payload, str) and value_looks_sensitive(payload):
        return "<redacted>"
    return payload


SECRET_ARG_RE = re.compile(r"(password|passwd|token|secret|apikey|api_key|api-key|credential|auth)", re.IGNORECASE)


def redact_command_arg(value: Any) -> str:
    text = str(value)
    text = CREDENTIAL_URL_RE.sub("://<redacted-credentials>@", text)
    if "=" in text:
        left, _right = text.split("=", 1)
        if SECRET_ARG_RE.search(left):
            return f"{left}=<redacted>"
    return text


def redact_command_payload(payload: Any) -> Any:
    if isinstance(payload, list):
        result: list[str] = []
        redact_next = False
        for item in payload:
            text = str(item)
            if redact_next:
                result.append("<redacted>")
                redact_next = False
                continue
            if SECRET_ARG_RE.search(text) and "=" not in text:
                result.append(redact_command_arg(text))
                redact_next = True
                continue
            result.append(redact_command_arg(text))
        return result
    if isinstance(payload, str):
        return redact_command_arg(payload)
    return payload


def redact_command_stdout(report: dict[str, Any], result: dict[str, Any], *, label: str) -> None:
    record = result.get("record", {})
    stdout_rel = record.get("stdout_path")
    if not stdout_rel:
        return
    stdout_path = resolve_path(stdout_rel)
    if not stdout_path.exists():
        return
    try:
        original = stdout_path.read_text(encoding="utf-8", errors="replace")
        parsed = parse_json(original, None)
        if parsed is not None:
            redacted = json.dumps(redact_json_secretish(parsed), indent=2, sort_keys=True, default=str) + "\n"
            redaction_kind = "json-structural"
        else:
            redacted = redact_compose_text(original)
            redaction_kind = "text-line"
        if redacted != original:
            write_text(stdout_path, redacted)
            result["stdout"] = redacted
            record["stdout_redacted"] = True
            record["redaction_kind"] = redaction_kind
            report["warnings"].append(f"redacted secret/environment-looking values from command stdout: {label}")
    except OSError as exc:
        report["warnings"].append(f"could not redact command stdout for {label}: {exc}")




def sanitize_image_inspect(item: dict[str, Any]) -> dict[str, Any]:
    safe = deepcopy(item)
    config = safe.get("Config") if isinstance(safe.get("Config"), dict) else {}
    if config:
        env_payload = redact_env_list(config.get("Env"))
        config["EnvNames"] = env_payload
        if "Env" in config:
            config["Env"] = [f"{name}=<redacted>" for name in env_payload]
        if isinstance(config.get("Labels"), dict):
            config["Labels"] = sanitize_labels(config.get("Labels"))
        for command_key in ("Cmd", "Entrypoint", "Shell"):
            if command_key in config:
                config[command_key] = redact_command_payload(config.get(command_key))
        if "Healthcheck" in config:
            config["Healthcheck"] = redact_json_secretish(config.get("Healthcheck"), "Healthcheck")
    container_config = safe.get("ContainerConfig") if isinstance(safe.get("ContainerConfig"), dict) else {}
    if container_config:
        env_payload = redact_env_list(container_config.get("Env"))
        container_config["EnvNames"] = env_payload
        if "Env" in container_config:
            container_config["Env"] = [f"{name}=<redacted>" for name in env_payload]
        if isinstance(container_config.get("Labels"), dict):
            container_config["Labels"] = sanitize_labels(container_config.get("Labels"))
        for command_key in ("Cmd", "Entrypoint", "Shell"):
            if command_key in container_config:
                container_config[command_key] = redact_command_payload(container_config.get(command_key))
        if "Healthcheck" in container_config:
            container_config["Healthcheck"] = redact_json_secretish(container_config.get("Healthcheck"), "Healthcheck")
    return safe



def sanitize_generic_docker_inspect(kind: str, item: dict[str, Any]) -> dict[str, Any]:
    safe = deepcopy(item)
    if isinstance(safe.get("Labels"), dict):
        safe["Labels"] = sanitize_labels(safe.get("Labels"))
    if isinstance(safe.get("Options"), dict):
        safe["Options"] = redact_json_secretish(safe.get("Options"))
    if isinstance(safe.get("IPAM"), dict):
        safe["IPAM"] = redact_json_secretish(safe.get("IPAM"))
    safe["redaction_note"] = f"docker {kind} inspect labels/options redacted when secret-like"
    return safe


def copy_compose_file(path: Path, dest_root: Path, report: dict[str, Any]) -> dict[str, Any]:
    rec = file_record(path, include_hash=True)
    max_bytes = int(cfg_get("policy.max_compose_file_bytes", 2097152))
    if boolish(cfg_get("policy.copy_compose_files", True)) and path.exists() and path.is_file():
        if path.stat().st_size <= max_bytes:
            try:
                dest = dest_root / str(path).lstrip("/")
                dest.parent.mkdir(parents=True, exist_ok=True)
                if boolish(cfg_get("policy.copy_compose_files_redacted", True)):
                    original = path.read_text(encoding="utf-8", errors="replace")
                    write_text(dest, redact_compose_text(original))
                    rec["copied_to"] = rel(dest)
                    rec["copy_redacted"] = True
                    rec["exact_source_payload_owner"] = "Borg rows 06/07"
                else:
                    shutil.copy2(path, dest)
                    rec["copied_to"] = rel(dest)
                    rec["copy_redacted"] = False
            except OSError as exc:
                rec["copy_error"] = str(exc)
                report["warnings"].append(f"could not copy compose file {path}: {exc}")
        else:
            rec["copy_skipped"] = "larger than max_compose_file_bytes"
    return rec


def compose_project_config(path: Path, report: dict[str, Any], label_prefix: str) -> dict[str, Any]:
    result = docker_cmd(["compose", "-f", str(path), "config", "--no-interpolate"], report, label=f"{label_prefix}_config_no_interpolate")
    redact_command_stdout(report, result, label=f"{label_prefix}_config_no_interpolate")
    payload: dict[str, Any] = {
        "returncode": result["returncode"],
        "stdout_path": result["record"]["stdout_path"],
        "stderr_path": result["record"]["stderr_path"],
        "stdout_redacted": bool(result["record"].get("stdout_redacted")),
    }
    if result["returncode"] != 0:
        report["warnings"].append(f"docker compose config failed for {path}")
    json_result = docker_cmd(["compose", "-f", str(path), "config", "--no-interpolate", "--format", "json"], report, label=f"{label_prefix}_config_json_no_interpolate")
    redact_command_stdout(report, json_result, label=f"{label_prefix}_config_json_no_interpolate")
    payload["json_returncode"] = json_result["returncode"]
    payload["json_stdout_path"] = json_result["record"]["stdout_path"]
    payload["json_stdout_redacted"] = bool(json_result["record"].get("stdout_redacted"))
    return payload


def cmd_capture_compose_sources(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-compose-sources")
    report = report_base("capture-compose-sources", run_dir)
    report["mode"] = "capture"
    preflight(report, require_daemon=False)
    files = find_compose_files()
    copy_root = run_dir / "compose_sources_copy"
    records = []
    for index, path in enumerate(files, 1):
        rec = copy_compose_file(path, copy_root, report)
        rec["project_dir"] = str(path.parent)
        rec["compose_config"] = compose_project_config(path, report, f"compose_{index}_{safe_name(path.parent.name)}") if command_exists(DOCKER) else {}
        records.append(rec)
    manifest = {"compose_files": records, "search_roots": split_semicolon(cfg_get("paths.compose_search_roots", "")), "model_runtime_roots": split_semicolon(cfg_get("paths.model_runtime_roots", "")), "legacy_stack_roots": split_semicolon(cfg_get("paths.legacy_stack_roots", ""))}
    path = run_dir / "docker_compose_sources_manifest.json"
    write_json(path, manifest)
    report["compose"] = {"manifest": rel(path), "compose_file_count": len(records)}
    output_file(report, path, "json", "docker_compose_sources_manifest", {"compose_file_count": len(records)})
    return finalize_report(report, run_dir)


def parse_env_file_names(path: Path) -> dict[str, Any]:
    rec = file_record(path, include_hash=True)
    names: list[str] = []
    if path.exists() and path.is_file():
        try:
            for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
                line = strip_comment(raw).strip()
                if not line or "=" not in line or line.startswith("export "):
                    if line.startswith("export ") and "=" in line:
                        line = line[len("export "):]
                    else:
                        continue
                name = line.split("=", 1)[0].strip()
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                    names.append(name)
        except OSError as exc:
            rec["read_error"] = str(exc)
    rec["variable_names"] = sorted(set(names))
    rec["values_redacted"] = True
    return rec


def find_env_files_near_compose() -> list[Path]:
    env_names = set(split_semicolon(cfg_get("paths.compose_env_names", "")))
    extra_globs = split_semicolon(cfg_get("paths.compose_extra_env_globs", ""))
    dirs = {path.parent for path in find_compose_files()}
    files: list[Path] = []
    for directory in dirs:
        for name in env_names:
            p = directory / name
            if p.exists() and p.is_file():
                files.append(p.resolve())
        for glob in extra_globs:
            for p in directory.glob(glob):
                if p.is_file():
                    files.append(p.resolve())
    return sorted(dict.fromkeys(files))


def cmd_capture_compose_env(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-compose-env")
    report = report_base("capture-compose-env", run_dir)
    report["mode"] = "capture"
    env_files = find_env_files_near_compose()
    copy_root = run_dir / "compose_env_copy"
    records = []
    for env_file in env_files:
        rec = parse_env_file_names(env_file)
        if boolish(cfg_get("policy.copy_env_files", False)):
            max_bytes = int(cfg_get("policy.max_env_file_bytes", 1048576))
            if env_file.stat().st_size <= max_bytes:
                dest = copy_root / str(env_file).lstrip("/")
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(env_file, dest)
                rec["copied_to"] = rel(dest)
                rec["contains_values"] = True
            else:
                rec["copy_skipped"] = "larger than max_env_file_bytes"
        records.append(rec)
    path = run_dir / "docker_compose_env_manifest.json"
    write_json(path, {"env_files": records, "values_redacted": not boolish(cfg_get("policy.copy_env_files", False))})
    report["compose"] = {"env_manifest": rel(path), "env_file_count": len(records)}
    output_file(report, path, "json", "docker_compose_env_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_gpu_runtime_contracts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-gpu-runtime-contracts")
    report = report_base("capture-gpu-runtime-contracts", run_dir)
    report["mode"] = "capture"
    preflight(report)
    gpu_paths = [Path(p) for p in split_semicolon(cfg_get("docker.gpu_device_paths", ""))]
    contracts: dict[str, Any] = {"host_device_paths": {str(p): file_record(p, include_hash=False) for p in gpu_paths}, "daemon_runtimes": {}, "containers": [], "compose_matches": []}
    info = docker_cmd(["info", "--format", "{{json .}}"], report, label="docker_info_gpu")
    if info["returncode"] == 0:
        info_payload = parse_json(info["stdout"], {})
        contracts["daemon_runtimes"] = info_payload.get("Runtimes") or info_payload.get("DefaultRuntime")
    env_patterns = split_semicolon(cfg_get("docker.gpu_env_name_patterns", ""))
    path_strings = [str(p) for p in gpu_paths]
    keywords = [kw.lower() for kw in split_semicolon(cfg_get("docker.model_runtime_keywords", ""))]
    for item in container_inspects(report) if not report["failures"] else []:
        safe = normalized_container_record(item)
        haystack = json.dumps(safe, default=str).lower()
        has_gpu_mount = any(path in haystack for path in path_strings)
        has_gpu_env = any(name in safe.get("EnvNames", []) for name in env_patterns)
        has_keyword = any(kw in haystack for kw in keywords)
        if has_gpu_mount or has_gpu_env or has_keyword:
            contracts["containers"].append({"Name": safe.get("Name"), "ImageName": safe.get("ImageName"), "EnvNames": safe.get("EnvNames"), "Devices": safe.get("Devices"), "DeviceRequests": safe.get("DeviceRequests"), "DeviceCgroupRules": safe.get("DeviceCgroupRules"), "Mounts": safe.get("Mounts"), "Runtime": safe.get("Runtime"), "GroupAdd": safe.get("GroupAdd"), "ShmSize": safe.get("ShmSize"), "SecurityOpt": safe.get("SecurityOpt"), "CapAdd": safe.get("CapAdd"), "IpcMode": safe.get("IpcMode"), "matched": {"gpu_mount": has_gpu_mount, "gpu_env": has_gpu_env, "keyword": has_keyword}})
    for compose_file in find_compose_files():
        try:
            text = compose_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lowered = text.lower()
        if any(path in text for path in path_strings) or any(kw in lowered for kw in keywords):
            contracts["compose_matches"].append({"path": str(compose_file), "sha256": sha256_file(compose_file), "matched_keywords": [kw for kw in keywords if kw in lowered], "matched_device_paths": [p for p in path_strings if p in text]})
    path = run_dir / "docker_gpu_runtime_contracts_manifest.json"
    write_json(path, contracts)
    report["gpu"] = {"manifest": rel(path), "container_match_count": len(contracts["containers"]), "compose_match_count": len(contracts["compose_matches"])}
    output_file(report, path, "json", "docker_gpu_runtime_contracts_manifest")
    return finalize_report(report, run_dir)


def image_export_token(image: str) -> str:
    return f"{cfg_get('policy.selected_image_export_guard_prefix', 'DOCKER_IMAGE_EXPORT')}:{image}"


def require_env_guard(report: dict[str, Any], *, env_key: str, value_key: str, label: str) -> bool:
    env_name = str(cfg_get(env_key, "")).strip()
    expected = str(cfg_get(value_key, "")).strip()
    if not env_name:
        return True
    if os.environ.get(env_name) != expected:
        report["failures"].append(f"{label} requires {env_name}={expected}")
        return False
    return True


def cmd_export_selected_image(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-selected-image")
    report = report_base("export-selected-image", run_dir)
    report["mode"] = "guarded-export" if args.execute else "plan"
    preflight(report)
    if not args.image:
        report["failures"].append("export-selected-image requires --image")
        return finalize_report(report, run_dir)
    expected = image_export_token(args.image)
    guard_env = str(cfg_get("policy.image_export_guard_env", "CONFIRM_DOCKER_IMAGE_EXPORT"))
    guard_value = str(cfg_get("policy.image_export_guard_value", "I_UNDERSTAND_THIS_EXPORTS_DOCKER_IMAGES"))
    if boolish(cfg_get("policy.selected_image_export_requires_execute", True)) and not args.execute:
        report["warnings"].append("image export not executed because --execute was not supplied")
    else:
        if args.confirm_token != expected:
            report["failures"].append(f"image export requires --confirm-token {expected}")
        require_env_guard(report, env_key="policy.image_export_guard_env", value_key="policy.image_export_guard_value", label="image export")
    if report["failures"] or not args.execute:
        plan_path = run_dir / "docker_image_export_plan.json"
        write_json(plan_path, {"image": args.image, "required_token": expected, "required_env": {"name": guard_env, "value": guard_value}, "execute": bool(args.execute)})
        output_file(report, plan_path, "json", "docker_image_export_plan")
        return finalize_report(report, run_dir)
    export_dir = resolve_path(str(cfg_get("project.export_root", "state/exports/14_docker"))) / "images"
    export_dir.mkdir(parents=True, exist_ok=True)
    tar_path = export_dir / f"{safe_name(args.image)}.tar"
    result = docker_cmd(["image", "save", "--output", str(tar_path), args.image], report, label=f"docker_image_save_{safe_name(args.image)}")
    if result["returncode"] != 0:
        report["failures"].append(f"docker image save failed for {args.image}")
    manifest = {"image": args.image, "tar_path": str(tar_path), "sha256": sha256_file(tar_path) if tar_path.exists() else None, "bytes": tar_path.stat().st_size if tar_path.exists() else 0}
    manifest_path = run_dir / "docker_image_export_manifest.json"
    write_json(manifest_path, manifest)
    report["exports"] = {"image_export_manifest": rel(manifest_path), "tar_path": str(tar_path)}
    output_file(report, manifest_path, "json", "docker_image_export_manifest")
    if tar_path.exists():
        output_file(report, tar_path, "tar", "docker_image_tar", {"sha256": manifest["sha256"]})
    return finalize_report(report, run_dir)




def is_protected_database_volume(volume: str) -> bool:
    protected = {v.lower() for v in split_semicolon(cfg_get("docker.protected_database_volume_names", ""))}
    lname = volume.lower()
    if lname in protected:
        return True
    if any(token in lname for token in ("postgres", "pgdata", "pg_", "database")):
        return True
    return False


def containers_using_volume(volume: str, report: dict[str, Any]) -> list[dict[str, Any]]:
    users = []
    for item in container_inspects(report):
        cname = str(item.get("Name", "")).lstrip("/")
        state = (item.get("State") or {}).get("Status")
        running = bool((item.get("State") or {}).get("Running"))
        for mount in item.get("Mounts", []) or []:
            if mount.get("Type") == "volume" and mount.get("Name") == volume:
                users.append({"container": cname, "status": state, "running": running, "mount": mount})
    return users


def volume_export_token(volume: str, *, database_secondary: bool = False) -> str:
    prefix_key = "policy.database_secondary_volume_export_guard_prefix" if database_secondary else "policy.volume_export_guard_prefix"
    return f"{cfg_get(prefix_key)}:{volume}"


def helper_image_available(helper_image: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(["image", "inspect", helper_image], report, label=f"helper_image_inspect_{safe_name(helper_image)}")
    return result["returncode"] == 0


def cmd_volume_export_quiesced(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("volume-export-quiesced")
    report = report_base("volume-export-quiesced", run_dir)
    report["mode"] = "guarded-export" if args.execute else "plan"
    preflight(report)
    volume = args.volume
    if not volume:
        report["failures"].append("volume-export-quiesced requires --volume")
        return finalize_report(report, run_dir)
    users = containers_using_volume(volume, report) if not report["failures"] else []
    running_users = [u for u in users if u.get("running")]
    database_protected = is_protected_database_volume(volume)
    if running_users and boolish(cfg_get("policy.require_quiesced_volume_export", True)):
        report["failures"].append(f"volume is not quiesced; running containers use it: {[u['container'] for u in running_users]}")
    required_token = volume_export_token(volume, database_secondary=database_protected)
    if database_protected and not args.allow_database_secondary:
        report["failures"].append(f"{volume} appears to be database/PostgreSQL volume. Primary recovery belongs to {cfg_get('policy.postgres_primary_logical_owner')}. Use --allow-database-secondary with {required_token} only for secondary raw evidence.")
    helper = str(cfg_get("policy.volume_export_helper_image", "busybox:latest"))
    helper_exists = helper_image_available(helper, report) if command_exists(DOCKER) else False
    if boolish(cfg_get("policy.helper_image_must_exist_locally", True)) and not helper_exists:
        msg = f"volume export helper image is not available locally and Row 14 will not auto-pull: {helper}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    guard_env = str(cfg_get("policy.volume_export_guard_env", "CONFIRM_DOCKER_VOLUME_EXPORT"))
    guard_value = str(cfg_get("policy.volume_export_guard_value", "I_UNDERSTAND_THIS_EXPORTS_A_STOPPED_DOCKER_VOLUME"))
    if boolish(cfg_get("policy.volume_export_requires_execute", True)) and not args.execute:
        report["warnings"].append("volume export not executed because --execute was not supplied")
    else:
        if args.confirm_token != required_token:
            report["failures"].append(f"volume export requires --confirm-token {required_token}")
        require_env_guard(report, env_key="policy.volume_export_guard_env", value_key="policy.volume_export_guard_value", label="volume export")
    if report["failures"] or not args.execute:
        plan_path = run_dir / "docker_volume_export_plan.json"
        write_json(plan_path, {"volume": volume, "users": users, "running_users": running_users, "database_protected": database_protected, "required_token": required_token, "required_env": {"name": guard_env, "value": guard_value}, "helper_image": helper, "helper_image_exists_locally": helper_exists, "execute": bool(args.execute)})
        output_file(report, plan_path, "json", "docker_volume_export_plan")
        return finalize_report(report, run_dir)
    export_dir = resolve_path(str(cfg_get("project.export_root", "state/exports/14_docker"))) / "volumes"
    export_dir.mkdir(parents=True, exist_ok=True)
    tar_path = export_dir / f"{safe_name(volume)}.tar"
    pull_policy = ["--pull", "never"] if boolish(cfg_get("policy.no_auto_pull", True)) else []
    result = docker_cmd(["run", "--rm", *pull_policy, "--name", f"recovery-volume-export-{safe_name(volume)}", "--mount", f"source={volume},target=/volume,readonly", "--mount", f"type=bind,source={export_dir},target=/backup", helper, "tar", "-C", "/volume", "-cpf", f"/backup/{tar_path.name}", "."], report, label=f"docker_volume_export_{safe_name(volume)}")
    if result["returncode"] != 0:
        report["failures"].append(f"docker volume export failed for {volume}")
    manifest = {"volume": volume, "users": users, "database_protected": database_protected, "tar_path": str(tar_path), "sha256": sha256_file(tar_path) if tar_path.exists() else None, "bytes": tar_path.stat().st_size if tar_path.exists() else 0}
    manifest_path = run_dir / "docker_volume_export_manifest.json"
    write_json(manifest_path, manifest)
    report["exports"] = {"volume_export_manifest": rel(manifest_path), "tar_path": str(tar_path)}
    output_file(report, manifest_path, "json", "docker_volume_export_manifest")
    if tar_path.exists():
        output_file(report, tar_path, "tar", "docker_volume_tar", {"sha256": manifest["sha256"]})
    return finalize_report(report, run_dir)




def cmd_assert_postgres_volume_not_primary(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-postgres-volume-not-primary")
    report = report_base("assert-postgres-volume-not-primary", run_dir)
    report["mode"] = "verify"
    preflight(report)
    volume = args.volume
    if not volume:
        report["failures"].append("assert-postgres-volume-not-primary requires --volume")
        return finalize_report(report, run_dir)
    protected = is_protected_database_volume(volume)
    users = containers_using_volume(volume, report) if not report["failures"] else []
    postgres_names = [n.lower() for n in split_semicolon(cfg_get("docker.protected_database_container_names", ""))]
    postgres_user = any(any(token in u["container"].lower() for token in postgres_names) for u in users)
    if protected or postgres_user:
        report["failures"].append(f"{volume} is database/PostgreSQL-adjacent. Row 14 raw volume export is not primary recovery; use PostgreSQL logical dump row.")
    manifest_path = run_dir / "postgres_volume_assertion.json"
    write_json(manifest_path, {"volume": volume, "is_protected_database_volume": protected, "containers_using_volume": users, "postgres_container_match": postgres_user})
    report["volumes"] = {"assertion": rel(manifest_path), "volume": volume, "is_database_adjacent": protected or postgres_user}
    output_file(report, manifest_path, "json", "postgres_volume_assertion")
    return finalize_report(report, run_dir)


def cmd_generate_compose_restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-compose-restore-plan")
    report = report_base("generate-compose-restore-plan", run_dir)
    report["mode"] = "plan"
    compose_files = find_compose_files()
    plan_lines = [
        "# Docker / Compose workload restore plan",
        "",
        "This plan reconstructs Docker workloads from source Compose files and captured Docker metadata.",
        "",
        "## Authority boundaries",
        "",
        "- Docker/Compose row owns workload reconstruction metadata, selected image tars, and guarded quiesced volume exports.",
        "- PostgreSQL logical dumps remain the primary database recovery authority.",
        "- Portainer UI state is not the restore controller.",
        "- Generic source files and bind mounts are backed up by Borg rows.",
        "",
        "## Restore order",
        "",
        "1. Restore native Docker package/install state through Row 10.",
        "2. Restore project/source trees and bind-mount payloads through Borg.",
        "3. Restore PostgreSQL through its logical dump row before starting DB-backed services.",
        "4. Review captured Compose files and `.env` variable-name manifests; recreate secrets manually.",
        "5. Pull or load required images from registries or selected image tar exports.",
        "6. Recreate networks/volumes through Compose where possible.",
        "7. Start Compose stacks one at a time and verify healthchecks/logs.",
        "",
        "## Compose files discovered",
        "",
    ]
    if compose_files:
        for path in compose_files:
            plan_lines.append(f"- `{path}`")
    else:
        plan_lines.append("- none discovered")
    plan_lines += [
        "",
        "## Review commands",
        "",
        "```bash",
        "docker compose -f <compose-file> config --no-interpolate",
        "docker compose -f <compose-file> pull",
        "docker compose -f <compose-file> up -d",
        "docker compose -f <compose-file> ps",
        "docker compose -f <compose-file> logs --tail=200",
        "```",
        "",
    ]
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/14_docker")))
    generated_root.mkdir(parents=True, exist_ok=True)
    plan_path = generated_root / str(cfg_get("policy.restore_plan_name", "docker_compose_restore_plan.md"))
    write_text(plan_path, "\n".join(plan_lines))
    plan_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["restore_plan"] = {"path": rel(plan_path), "compose_file_count": len(compose_files)}
    output_file(report, plan_path, "markdown", "docker_compose_restore_plan", {"compose_file_count": len(compose_files)})
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("capture-info").set_defaults(func=cmd_capture_info)
    sub.add_parser("capture-daemon-config").set_defaults(func=cmd_capture_daemon_config)
    sub.add_parser("capture-systemd-overrides").set_defaults(func=cmd_capture_systemd_overrides)
    sub.add_parser("capture-contexts").set_defaults(func=cmd_capture_contexts)
    sub.add_parser("capture-containers").set_defaults(func=cmd_capture_containers)
    sub.add_parser("capture-images").set_defaults(func=cmd_capture_images)
    sub.add_parser("capture-image-digests").set_defaults(func=cmd_capture_image_digests)
    sub.add_parser("capture-networks").set_defaults(func=cmd_capture_networks)
    sub.add_parser("capture-volumes").set_defaults(func=cmd_capture_volumes)
    sub.add_parser("capture-bind-mounts").set_defaults(func=cmd_capture_bind_mounts)
    sub.add_parser("capture-compose-sources").set_defaults(func=cmd_capture_compose_sources)
    sub.add_parser("capture-compose-env").set_defaults(func=cmd_capture_compose_env)
    sub.add_parser("capture-gpu-runtime-contracts").set_defaults(func=cmd_capture_gpu_runtime_contracts)

    p = sub.add_parser("export-selected-image")
    p.add_argument("--image", required=True)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.set_defaults(func=cmd_export_selected_image)

    p = sub.add_parser("volume-export-quiesced")
    p.add_argument("--volume", required=True)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.add_argument("--allow-database-secondary", action="store_true")
    p.set_defaults(func=cmd_volume_export_quiesced)

    p = sub.add_parser("assert-postgres-volume-not-primary")
    p.add_argument("--volume", required=True)
    p.set_defaults(func=cmd_assert_postgres_volume_not_primary)

    sub.add_parser("generate-compose-restore-plan").set_defaults(func=cmd_generate_compose_restore_plan)
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