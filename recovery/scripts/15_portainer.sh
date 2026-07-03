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
import ssl
import stat
import subprocess
import sys
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "15_portainer.sh"
SCHEMA_NAME = "recovery.portainer.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "portainer",
        "verified_active_image": "portainer/portainer-ce:latest",
        "verified_staged_lts_image": "portainer/portainer-ce:2.39.2",
        "layer": "15_portainer_management_ui_workload",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/15_portainer",
        "generated_root": "state/generated/15_portainer",
        "export_root": "state/exports/15_portainer",
    },
    "commands": {"docker": "/usr/bin/docker", "python": "/usr/bin/python3"},
    "portainer": {
        "active_container_name": "portainer",
        "active_image_observed": "portainer/portainer-ce:latest",
        "staged_lts_image": "portainer/portainer-ce:2.39.2",
        "restore_image_authority": "portainer/portainer-ce:2.39.2",
        "disallowed_restore_tags": "latest;lts",
        "data_volume_name": "portainer_data",
        "data_volume_target": "/data",
        "expected_https_ui": "https://127.0.0.1:9443",
        "expected_legacy_http_ui": "http://127.0.0.1:9000",
        "status_paths": "/api/status;/api/system/status",
        "management_ports": "9443;9000;8000",
        "docker_socket_source": "/var/run/docker.sock",
        "docker_socket_target": "/var/run/docker.sock",
        "active_image_aliases": "portainer/portainer-ce:latest;portainer/portainer-ce:lts",
        "staged_image_aliases": "portainer/portainer-ce:2.39.2;portainer/portainer-ce:lts",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "portainer_report.json",
        "restore_plan_name": "portainer_restore_plan.md",
        "recreate_command_name": "portainer_recreate_review.sh",
        "generated_script_mode": "0600",
        "fail_if_docker_missing": True,
        "fail_if_daemon_unavailable": False,
        "active_latest_is_runtime_state_only": True,
        "restore_image_must_be_pinned": True,
        "require_staged_lts_image_for_restore_gate": True,
        "redact_env_values": True,
        "env_name_capture_only": True,
        "redact_secret_like_labels": True,
        "copy_bind_mount_payloads": False,
        "hash_bind_mount_files": False,
        "export_staged_image_requires_execute": True,
        "staged_image_export_guard_prefix": "PORTAINER_IMAGE_EXPORT",
        "staged_image_export_guard_env": "CONFIRM_PORTAINER_IMAGE_EXPORT",
        "staged_image_export_guard_value": "I_UNDERSTAND_THIS_EXPORTS_PORTAINER_IMAGE_TAR",
        "volume_export_requires_execute": True,
        "volume_export_guard_prefix": "PORTAINER_VOLUME_EXPORT",
        "volume_export_guard_env": "CONFIRM_PORTAINER_VOLUME_EXPORT",
        "volume_export_guard_value": "I_UNDERSTAND_THIS_EXPORTS_STOPPED_PORTAINER_DATA_VOLUME",
        "require_quiesced_volume_export": True,
        "volume_export_helper_image": "busybox:latest",
        "helper_image_must_exist_locally": True,
        "no_auto_pull": True,
        "no_container_start_stop_remove_by_default": True,
        "portainer_restores_after": "Row 14 Docker healthy; Row 10 Docker package installed; Borg file payload restored as needed",
    },
    "sensitive": {
        "label_key_patterns": "secret;token;password;passwd;credential;apikey;api_key;auth;license;key",
        "env_name_patterns": "SECRET;TOKEN;PASSWORD;PASSWD;CREDENTIAL;APIKEY;API_KEY;AUTH;LICENSE;KEY",
        "bind_path_sensitive_parts": "/certs;/ssl;/secrets;/keys;.pem;.key;.crt;/run/secrets",
        "command_secret_flags": "--password;--passwd;--token;--secret;--key;--api-key;--apikey;--auth;--jwt",
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
    path = PROJECT_ROOT / "configs" / "15_portainer.yaml"
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


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/15_portainer")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "15_portainer.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "15_portainer.config.snapshot.yaml")
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
        "tool": {"name": "portainer", "script": SCRIPT_NAME, "docker_path": DOCKER, "docker_version": None},
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
    report_path = run_dir / str(cfg_get("policy.report_name", "portainer_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True)
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
    rows: list[Any] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            rows.append({"raw": line, "json_error": True})
    return rows


def sensitive_key_regex() -> re.Pattern[str]:
    parts = [re.escape(p) for p in split_semicolon(cfg_get("sensitive.label_key_patterns", ""))]
    return re.compile("|".join(parts or ["secret"]), re.IGNORECASE)


def secret_flags() -> set[str]:
    return {flag.lower() for flag in split_semicolon(cfg_get("sensitive.command_secret_flags", ""))}


CREDENTIAL_URL_RE = re.compile(r"://[^\s/@:]+:[^\s/@]+@", re.IGNORECASE)


def value_looks_sensitive(value: Any) -> bool:
    return bool(CREDENTIAL_URL_RE.search(str(value or "")))


def should_redact_key_value(key: Any, value: Any = "") -> bool:
    return bool(sensitive_key_regex().search(str(key)) or value_looks_sensitive(value))


def redact_env_list(env_values: Any) -> list[str]:
    if not isinstance(env_values, list):
        return []
    names = []
    for item in env_values:
        text = str(item)
        names.append(text.split("=", 1)[0] if "=" in text else text)
    return sorted(set(names))


def redact_json_secretish(payload: Any) -> Any:
    if isinstance(payload, dict):
        redacted: dict[str, Any] = {}
        for key, value in payload.items():
            redacted[key] = "<redacted>" if should_redact_key_value(key, value) else redact_json_secretish(value)
        return redacted
    if isinstance(payload, list):
        result: list[Any] = []
        for item in payload:
            if isinstance(item, str) and "=" in item:
                name, value = item.split("=", 1)
                result.append(f"{name}=<redacted>" if should_redact_key_value(name, value) else item)
            else:
                result.append(redact_json_secretish(item))
        return result
    if isinstance(payload, str) and value_looks_sensitive(payload):
        return CREDENTIAL_URL_RE.sub("://<redacted-credentials>@", payload)
    return payload


def sanitize_labels(labels: Any) -> dict[str, Any]:
    if not isinstance(labels, dict):
        return {}
    result = {}
    for key, value in labels.items():
        result[key] = "<redacted>" if boolish(cfg_get("policy.redact_secret_like_labels", True)) and should_redact_key_value(key, value) else value
    return result


def sanitize_command_token(text: str, flags: set[str]) -> str:
    lower = text.lower()
    if "=" in text:
        key, value = text.split("=", 1)
        if key.lower() in flags or should_redact_key_value(key, value):
            return f"{key}=<redacted>"
    if value_looks_sensitive(text):
        return CREDENTIAL_URL_RE.sub("://<redacted-credentials>@", text)
    return text


def sanitize_command(value: Any) -> Any:
    if isinstance(value, str):
        try:
            tokens = shlex.split(value)
        except ValueError:
            tokens = [value]
        if len(tokens) > 1:
            return shell_join([str(token) for token in sanitize_command(tokens)])
        return sanitize_command_token(value, secret_flags())
    if not isinstance(value, list):
        return value
    result: list[Any] = []
    skip_next = False
    flags = secret_flags()
    for item in value:
        text = str(item)
        lower = text.lower()
        if skip_next:
            result.append("<redacted>")
            skip_next = False
            continue
        if lower in flags:
            result.append(text)
            skip_next = True
            continue
        redacted = sanitize_command_token(text, flags)
        result.append(redacted if redacted != text else item)
    return result


def sanitize_container(item: dict[str, Any]) -> dict[str, Any]:
    config = item.get("Config") if isinstance(item.get("Config"), dict) else {}
    host = item.get("HostConfig") if isinstance(item.get("HostConfig"), dict) else {}
    state = item.get("State") if isinstance(item.get("State"), dict) else {}
    net = item.get("NetworkSettings") if isinstance(item.get("NetworkSettings"), dict) else {}
    labels = sanitize_labels(config.get("Labels") or {})
    return {
        "Id": item.get("Id"),
        "Name": str(item.get("Name", "")).lstrip("/"),
        "Created": item.get("Created"),
        "Path": sanitize_command(item.get("Path")),
        "Args": sanitize_command(item.get("Args")),
        "Image": item.get("Image"),
        "ImageName": config.get("Image"),
        "State": {
            "Status": state.get("Status"),
            "Running": state.get("Running"),
            "ExitCode": state.get("ExitCode"),
            "StartedAt": state.get("StartedAt"),
            "FinishedAt": state.get("FinishedAt"),
            "Health": redact_json_secretish(state.get("Health")),
        },
        "RestartPolicy": host.get("RestartPolicy"),
        "AutoRemove": host.get("AutoRemove"),
        "Privileged": host.get("Privileged"),
        "User": config.get("User"),
        "WorkingDir": config.get("WorkingDir"),
        "Entrypoint": sanitize_command(config.get("Entrypoint")),
        "Cmd": sanitize_command(config.get("Cmd")),
        "EnvNames": redact_env_list(config.get("Env")),
        "Labels": labels,
        "ExposedPorts": config.get("ExposedPorts"),
        "PortBindings": host.get("PortBindings"),
        "PublishedPorts": net.get("Ports"),
        "Mounts": item.get("Mounts", []),
        "Binds": host.get("Binds"),
        "NetworkMode": host.get("NetworkMode"),
        "Networks": list((net.get("Networks") or {}).keys()) if isinstance(net.get("Networks"), dict) else [],
        "LogConfig": redact_json_secretish(host.get("LogConfig")),
        "SecurityOpt": host.get("SecurityOpt"),
        "CapAdd": host.get("CapAdd"),
        "CapDrop": host.get("CapDrop"),
        "Healthcheck": redact_json_secretish(config.get("Healthcheck")),
    }


def sanitize_image(item: dict[str, Any]) -> dict[str, Any]:
    safe = deepcopy(item)
    for key in ("Config", "ContainerConfig"):
        config = safe.get(key) if isinstance(safe.get(key), dict) else {}
        if config:
            env_names = redact_env_list(config.get("Env"))
            config["EnvNames"] = env_names
            if "Env" in config:
                config["Env"] = [f"{name}=<redacted>" for name in env_names]
            if isinstance(config.get("Labels"), dict):
                config["Labels"] = sanitize_labels(config.get("Labels"))
            for command_key in ("Cmd", "Entrypoint", "Shell", "Healthcheck"):
                if command_key in config:
                    config[command_key] = redact_json_secretish(sanitize_command(config[command_key]))
    return safe


def sanitize_network(item: dict[str, Any]) -> dict[str, Any]:
    safe = deepcopy(item)
    if isinstance(safe.get("Labels"), dict):
        safe["Labels"] = sanitize_labels(safe["Labels"])
    if isinstance(safe.get("Options"), dict):
        safe["Options"] = redact_json_secretish(safe["Options"])
    return safe


def sanitize_volume(item: dict[str, Any]) -> dict[str, Any]:
    safe = deepcopy(item)
    if isinstance(safe.get("Labels"), dict):
        safe["Labels"] = sanitize_labels(safe["Labels"])
    if isinstance(safe.get("Options"), dict):
        safe["Options"] = redact_json_secretish(safe["Options"])
    return safe


def docker_inspect(kind: str, names: list[str], report: dict[str, Any], label: str) -> list[Any]:
    if not names:
        return []
    collected: list[Any] = []
    seen: set[str] = set()
    for name in names:
        if not name or name in seen:
            continue
        seen.add(name)
        item_label = f"{label}_{safe_name(name)}"
        result = docker_cmd([kind, "inspect", name], report, label=item_label)
        if result["returncode"] != 0:
            report["warnings"].append(f"docker {kind} inspect failed for {name}")
            continue
        parsed = parse_json(result["stdout"], [])
        sanitized: Any = parsed
        if isinstance(parsed, list):
            if kind == "container":
                sanitized = [sanitize_container(item) if isinstance(item, dict) else item for item in parsed]
            elif kind == "image":
                sanitized = [sanitize_image(item) if isinstance(item, dict) else item for item in parsed]
            elif kind == "network":
                sanitized = [sanitize_network(item) if isinstance(item, dict) else item for item in parsed]
            elif kind == "volume":
                sanitized = [sanitize_volume(item) if isinstance(item, dict) else item for item in parsed]
        stdout_rel = result.get("record", {}).get("stdout_path")
        if stdout_rel and sanitized is not parsed:
            stdout_path = resolve_path(stdout_rel)
            write_json(stdout_path, sanitized)
            result["stdout"] = json.dumps(sanitized, indent=2, sort_keys=True, default=str) + "\n"
            result["record"]["stdout_redacted"] = True
            result["record"]["redaction_kind"] = f"docker-{kind}-inspect-sanitized"
        if isinstance(sanitized, list):
            collected.extend(sanitized)
    return collected


def list_containers(report: dict[str, Any]) -> list[dict[str, Any]]:
    result = docker_cmd(["ps", "-a", "--no-trunc", "--format", "{{json .}}"], report, label="docker_ps_all_json")
    if result["returncode"] != 0:
        report["warnings"].append("docker ps -a failed")
        return []
    return [row for row in parse_ndjson(result["stdout"]) if isinstance(row, dict)]


def discover_portainer_container(report: dict[str, Any]) -> str | None:
    configured = str(cfg_get("portainer.active_container_name", "portainer"))
    rows = list_containers(report)
    for row in rows:
        if str(row.get("Names", "")) == configured:
            return configured
    for row in rows:
        name = str(row.get("Names", ""))
        image = str(row.get("Image", ""))
        if "portainer" in name.lower() or "portainer/portainer-ce" in image.lower():
            return name or str(row.get("ID", ""))
    return None


def get_portainer_container(report: dict[str, Any]) -> dict[str, Any] | None:
    name = discover_portainer_container(report)
    if not name:
        report["warnings"].append("Portainer container was not discovered")
        return None
    inspect = docker_inspect("container", [name], report, "portainer_container_inspect")
    return inspect[0] if inspect and isinstance(inspect[0], dict) else None


def image_refs_for_portainer(container: dict[str, Any] | None = None) -> list[str]:
    refs: list[str] = []
    refs.extend(split_semicolon(cfg_get("portainer.staged_image_aliases", "")))
    refs.append(str(cfg_get("portainer.staged_lts_image", "portainer/portainer-ce:2.39.2")))
    refs.extend(split_semicolon(cfg_get("portainer.active_image_aliases", "")))
    observed = str(cfg_get("portainer.active_image_observed", ""))
    if observed:
        refs.append(observed)
    if container:
        image_name = str(container.get("ImageName") or "")
        image_id = str(container.get("Image") or "")
        if image_name:
            refs.append(image_name)
        if image_id:
            refs.append(image_id)
    return sorted(set(ref for ref in refs if ref and ref != "None"))


def volume_name() -> str:
    return str(cfg_get("portainer.data_volume_name", "portainer_data"))


def volume_target() -> str:
    return str(cfg_get("portainer.data_volume_target", "/data"))


def containers_using_volume(volume: str, report: dict[str, Any]) -> list[dict[str, Any]]:
    users = []
    for row in list_containers(report):
        identifier = str(row.get("ID") or row.get("Names") or "")
        if not identifier:
            continue
        inspect = docker_inspect("container", [identifier], report, f"container_volume_user_{safe_name(identifier)}")
        item = inspect[0] if inspect and isinstance(inspect[0], dict) else None
        if not item:
            continue
        for mount in item.get("Mounts", []) or []:
            if mount.get("Type") == "volume" and mount.get("Name") == volume:
                users.append({"container": item.get("Name"), "image": item.get("ImageName"), "running": bool((item.get("State") or {}).get("Running")), "status": (item.get("State") or {}).get("Status"), "mount": mount})
    return users


def image_exists(image: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(["image", "inspect", image], report, label=f"image_exists_{safe_name(image)}")
    return result["returncode"] == 0


def volume_exists(volume: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(["volume", "inspect", volume], report, label=f"volume_exists_{safe_name(volume)}")
    return result["returncode"] == 0


def helper_image_available(helper_image: str, report: dict[str, Any]) -> bool:
    result = docker_cmd(["image", "inspect", helper_image], report, label=f"helper_image_inspect_{safe_name(helper_image)}")
    return result["returncode"] == 0


def require_env_guard(report: dict[str, Any], *, env_key: str, value_key: str, label: str) -> bool:
    env_name = str(cfg_get(env_key, "")).strip()
    expected = str(cfg_get(value_key, "")).strip()
    if not env_name:
        return True
    if os.environ.get(env_name) != expected:
        report["failures"].append(f"{label} requires {env_name}={expected}")
        return False
    return True


def probe_portainer_status(report: dict[str, Any]) -> list[dict[str, Any]]:
    bases = [str(cfg_get("portainer.expected_https_ui", "")), str(cfg_get("portainer.expected_legacy_http_ui", ""))]
    paths = split_semicolon(cfg_get("portainer.status_paths", ""))
    ctx = ssl._create_unverified_context()
    probes: list[dict[str, Any]] = []
    for base in [b.rstrip("/") for b in bases if b]:
        for path in paths:
            url = f"{base}{path}"
            rec: dict[str, Any] = {"url": url, "ok": False}
            try:
                req = Request(url, headers={"User-Agent": "wantless-recovery-portainer-capture/1"})
                with urlopen(req, timeout=5, context=ctx if url.startswith("https://") else None) as response:
                    data = response.read(65536)
                    rec["status_code"] = response.status
                    rec["content_type"] = response.headers.get("content-type")
                    text = data.decode("utf-8", errors="replace")
                    payload = parse_json(text, None)
                    rec["payload"] = redact_json_secretish(payload) if payload is not None else text[:2000]
                    rec["ok"] = 200 <= response.status < 400
            except HTTPError as exc:
                rec["status_code"] = exc.code
                rec["error"] = str(exc)
            except (URLError, TimeoutError, OSError, ssl.SSLError) as exc:
                rec["error"] = str(exc)
            probes.append(rec)
    return probes


def bind_path_record(path_text: str) -> dict[str, Any]:
    path = Path(path_text)
    rec = file_record(path, include_hash=boolish(cfg_get("policy.hash_bind_mount_files", False)))
    sensitive_parts = split_semicolon(cfg_get("sensitive.bind_path_sensitive_parts", ""))
    lowered = str(path).lower()
    rec["sensitive_path_hint"] = any(part.lower() in lowered for part in sensitive_parts)
    rec["payload_owner"] = "Borg/file backup layer; Row 15 records identity only"
    return rec


def cmd_capture_container(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-container")
    report = report_base("capture-container", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    probes = probe_portainer_status(report)
    manifest = {"container": container, "ui_status_probes": probes, "env_policy": "environment variable names only; values redacted/omitted", "latest_policy": "active latest is observed runtime state only, not restore authority"}
    path = run_dir / "portainer_container_manifest.json"
    write_json(path, manifest)
    report["container"] = {"manifest": rel(path), "found": bool(container), "name": container.get("Name") if container else None}
    output_file(report, path, "json", "portainer_container_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_image(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-image")
    report = report_base("capture-image", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    refs = image_refs_for_portainer(container)
    inspect = docker_inspect("image", refs, report, "portainer_image_inspect") if refs and not report["failures"] else []
    manifest = {"image_refs_requested": refs, "images": inspect, "active_latest_note": "latest is captured as observed runtime state only", "restore_image_authority": cfg_get("portainer.restore_image_authority")}
    path = run_dir / "portainer_image_manifest.json"
    write_json(path, manifest)
    report["image"] = {"manifest": rel(path), "requested_ref_count": len(refs), "inspect_count": len(inspect)}
    output_file(report, path, "json", "portainer_image_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_image_digest(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-image-digest")
    report = report_base("capture-image-digest", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    refs = image_refs_for_portainer(container)
    inspect = docker_inspect("image", refs, report, "portainer_image_digest_inspect") if refs and not report["failures"] else []
    digest_records = []
    for item in inspect:
        if isinstance(item, dict):
            digest_records.append({"Id": item.get("Id"), "RepoTags": item.get("RepoTags"), "RepoDigests": item.get("RepoDigests"), "Architecture": item.get("Architecture"), "Os": item.get("Os"), "Created": item.get("Created"), "Size": item.get("Size"), "RootFS": item.get("RootFS"), "Labels": sanitize_labels((item.get("Config") or {}).get("Labels")) if isinstance(item.get("Config"), dict) else {}})
    path = run_dir / "portainer_image_digest_manifest.json"
    write_json(path, {"image_digests": digest_records, "restore_image_authority": cfg_get("portainer.restore_image_authority")})
    report["image"] = {"digest_manifest": rel(path), "count": len(digest_records)}
    output_file(report, path, "json", "portainer_image_digest_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_volume(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-volume")
    report = report_base("capture-volume", run_dir)
    report["mode"] = "capture"
    preflight(report)
    volume = volume_name()
    inspect = docker_inspect("volume", [volume], report, "portainer_volume_inspect") if not report["failures"] else []
    users = containers_using_volume(volume, report) if not report["failures"] else []
    manifest = {"volume_name": volume, "volume": inspect[0] if inspect else None, "containers_using_volume": users, "export_policy": "quiesced/token-guarded secondary volume artifact; no automatic stop"}
    path = run_dir / "portainer_volume_manifest.json"
    write_json(path, manifest)
    report["volume"] = {"manifest": rel(path), "volume": volume, "found": bool(inspect), "running_user_count": sum(1 for u in users if u.get("running"))}
    output_file(report, path, "json", "portainer_volume_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_ports(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-ports")
    report = report_base("capture-ports", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    ports = {"expected_management_ports": split_semicolon(cfg_get("portainer.management_ports", "")), "published_ports": container.get("PublishedPorts") if container else None, "port_bindings": container.get("PortBindings") if container else None, "exposed_ports": container.get("ExposedPorts") if container else None, "ui_status_probes": probe_portainer_status(report)}
    path = run_dir / "portainer_ports_manifest.json"
    write_json(path, ports)
    report["ports"] = {"manifest": rel(path), "container_found": bool(container)}
    output_file(report, path, "json", "portainer_ports_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_mounts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-mounts")
    report = report_base("capture-mounts", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    records = []
    if container:
        for mount in container.get("Mounts", []) or []:
            rec = {"mount": mount}
            if mount.get("Type") == "bind":
                rec["source_record"] = bind_path_record(str(mount.get("Source", "")))
            elif mount.get("Type") == "volume":
                rec["volume_name"] = mount.get("Name")
                rec["is_portainer_data"] = mount.get("Name") == volume_name()
            records.append(rec)
    path = run_dir / "portainer_mounts_manifest.json"
    write_json(path, {"mounts": records, "payload_boundary": "bind/cert payload bytes are Borg-owned; Row 15 records identity and relationships"})
    report["mounts"] = {"manifest": rel(path), "mount_count": len(records)}
    output_file(report, path, "json", "portainer_mounts_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_networks(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-networks")
    report = report_base("capture-networks", run_dir)
    report["mode"] = "capture"
    preflight(report)
    container = get_portainer_container(report) if not report["failures"] else None
    networks = container.get("Networks", []) if container else []
    inspect = docker_inspect("network", networks, report, "portainer_network_inspect") if networks else []
    path = run_dir / "portainer_networks_manifest.json"
    write_json(path, {"container_networks": networks, "networks": inspect})
    report["networks"] = {"manifest": rel(path), "network_count": len(networks)}
    output_file(report, path, "json", "portainer_networks_manifest")
    return finalize_report(report, run_dir)


def image_export_token(image: str) -> str:
    return f"{cfg_get('policy.staged_image_export_guard_prefix', 'PORTAINER_IMAGE_EXPORT')}:{image}"


def cmd_export_staged_lts_image(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-staged-lts-image")
    report = report_base("export-staged-lts-image", run_dir)
    report["mode"] = "guarded-export" if args.execute else "plan"
    preflight(report)
    image = args.image or str(cfg_get("portainer.staged_lts_image", "portainer/portainer-ce:2.39.2"))
    expected = image_export_token(image)
    guard_env = str(cfg_get("policy.staged_image_export_guard_env", "CONFIRM_PORTAINER_IMAGE_EXPORT"))
    guard_value = str(cfg_get("policy.staged_image_export_guard_value", "I_UNDERSTAND_THIS_EXPORTS_PORTAINER_IMAGE_TAR"))
    local_image = image_exists(image, report) if not report["failures"] else False
    if not local_image:
        msg = f"staged Portainer LTS image is not available locally: {image}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    if boolish(cfg_get("policy.export_staged_image_requires_execute", True)) and not args.execute:
        report["warnings"].append("staged LTS image export not executed because --execute was not supplied")
    else:
        if args.confirm_token != expected:
            report["failures"].append(f"staged image export requires --confirm-token {expected}")
        require_env_guard(report, env_key="policy.staged_image_export_guard_env", value_key="policy.staged_image_export_guard_value", label="Portainer staged image export")
    if report["failures"] or not args.execute:
        plan_path = run_dir / "portainer_image_export_plan.json"
        write_json(plan_path, {"image": image, "image_exists_locally": local_image, "required_token": expected, "required_env": {"name": guard_env, "value": guard_value}, "execute": bool(args.execute)})
        output_file(report, plan_path, "json", "portainer_image_export_plan")
        return finalize_report(report, run_dir)
    export_dir = resolve_path(str(cfg_get("project.export_root", "state/exports/15_portainer"))) / "images"
    export_dir.mkdir(parents=True, exist_ok=True)
    tar_path = export_dir / f"{safe_name(image)}.tar"
    result = docker_cmd(["image", "save", "--output", str(tar_path), image], report, label=f"portainer_image_save_{safe_name(image)}")
    if result["returncode"] != 0:
        report["failures"].append(f"docker image save failed for {image}")
    manifest = {"image": image, "tar_path": str(tar_path), "sha256": sha256_file(tar_path) if tar_path.exists() else None, "bytes": tar_path.stat().st_size if tar_path.exists() else 0}
    manifest_path = run_dir / "portainer_image_export_manifest.json"
    write_json(manifest_path, manifest)
    report["exports"] = {"image_export_manifest": rel(manifest_path), "tar_path": str(tar_path)}
    output_file(report, manifest_path, "json", "portainer_image_export_manifest")
    if tar_path.exists():
        output_file(report, tar_path, "tar", "portainer_image_tar", {"sha256": manifest["sha256"]})
    return finalize_report(report, run_dir)


def volume_export_token(volume: str) -> str:
    return f"{cfg_get('policy.volume_export_guard_prefix', 'PORTAINER_VOLUME_EXPORT')}:{volume}"


def cmd_volume_export_quiesced(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("volume-export-quiesced")
    report = report_base("volume-export-quiesced", run_dir)
    report["mode"] = "guarded-export" if args.execute else "plan"
    preflight(report)
    volume = args.volume or volume_name()
    local_volume = volume_exists(volume, report) if not report["failures"] else False
    users = containers_using_volume(volume, report) if not report["failures"] else []
    running_users = [u for u in users if u.get("running")]
    if not local_volume:
        msg = f"Portainer data volume is not inspectable locally: {volume}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    if running_users and boolish(cfg_get("policy.require_quiesced_volume_export", True)):
        msg = f"Portainer data volume is not quiesced; running containers use it: {[u['container'] for u in running_users]}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    helper = str(cfg_get("policy.volume_export_helper_image", "busybox:latest"))
    helper_exists = helper_image_available(helper, report) if command_exists(DOCKER) else False
    if boolish(cfg_get("policy.helper_image_must_exist_locally", True)) and not helper_exists:
        msg = f"volume export helper image is not available locally and Row 15 will not auto-pull: {helper}"
        if args.execute:
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    expected = volume_export_token(volume)
    guard_env = str(cfg_get("policy.volume_export_guard_env", "CONFIRM_PORTAINER_VOLUME_EXPORT"))
    guard_value = str(cfg_get("policy.volume_export_guard_value", "I_UNDERSTAND_THIS_EXPORTS_STOPPED_PORTAINER_DATA_VOLUME"))
    if boolish(cfg_get("policy.volume_export_requires_execute", True)) and not args.execute:
        report["warnings"].append("Portainer volume export not executed because --execute was not supplied")
    else:
        if args.confirm_token != expected:
            report["failures"].append(f"Portainer volume export requires --confirm-token {expected}")
        require_env_guard(report, env_key="policy.volume_export_guard_env", value_key="policy.volume_export_guard_value", label="Portainer volume export")
    if report["failures"] or not args.execute:
        plan_path = run_dir / "portainer_volume_export_plan.json"
        write_json(plan_path, {"volume": volume, "volume_exists": local_volume, "users": users, "running_users": running_users, "required_token": expected, "required_env": {"name": guard_env, "value": guard_value}, "helper_image": helper, "helper_image_exists_locally": helper_exists, "execute": bool(args.execute)})
        output_file(report, plan_path, "json", "portainer_volume_export_plan")
        return finalize_report(report, run_dir)
    export_dir = resolve_path(str(cfg_get("project.export_root", "state/exports/15_portainer"))) / "volumes"
    export_dir.mkdir(parents=True, exist_ok=True)
    tar_path = export_dir / f"{safe_name(volume)}.tar"
    pull_policy = ["--pull", "never"] if boolish(cfg_get("policy.no_auto_pull", True)) else []
    result = docker_cmd(["run", "--rm", *pull_policy, "--name", f"recovery-portainer-volume-export-{safe_name(volume)}", "--mount", f"source={volume},target=/volume,readonly", "--mount", f"type=bind,source={export_dir},target=/backup", helper, "tar", "-C", "/volume", "-cpf", f"/backup/{tar_path.name}", "."], report, label=f"portainer_volume_export_{safe_name(volume)}")
    if result["returncode"] != 0:
        report["failures"].append(f"docker volume export failed for {volume}")
    manifest = {"volume": volume, "users": users, "tar_path": str(tar_path), "sha256": sha256_file(tar_path) if tar_path.exists() else None, "bytes": tar_path.stat().st_size if tar_path.exists() else 0}
    manifest_path = run_dir / "portainer_volume_export_manifest.json"
    write_json(manifest_path, manifest)
    report["exports"] = {"volume_export_manifest": rel(manifest_path), "tar_path": str(tar_path)}
    output_file(report, manifest_path, "json", "portainer_volume_export_manifest")
    if tar_path.exists():
        output_file(report, tar_path, "tar", "portainer_volume_tar", {"sha256": manifest["sha256"]})
    return finalize_report(report, run_dir)


def image_ref_parts(image: str) -> tuple[str | None, str | None]:
    """Return (tag, digest) from a Docker image reference without treating digest colons as tags."""
    ref = str(image or "").strip()
    before_digest, sep, digest = ref.partition("@")
    leaf = before_digest.rsplit("/", 1)[-1]
    tag = leaf.rsplit(":", 1)[1].lower() if ":" in leaf else None
    return tag, (digest.lower() if sep and digest else None)


def image_tag(image: str) -> str | None:
    return image_ref_parts(image)[0]


def restore_image_is_pinned(image: str) -> bool:
    tag, digest = image_ref_parts(image)
    disallowed = {value.lower() for value in split_semicolon(cfg_get("portainer.disallowed_restore_tags", "latest;lts"))}
    if tag and tag in disallowed:
        return False
    if digest:
        return True
    return bool(tag and tag not in disallowed)


def gate_latest(report: dict[str, Any], *, fail_missing_staged: bool) -> dict[str, Any]:
    container = get_portainer_container(report) if not report["failures"] else None
    active_image = str(container.get("ImageName") if container else cfg_get("portainer.active_image_observed", ""))
    restore_image = str(cfg_get("portainer.restore_image_authority", ""))
    staged = str(cfg_get("portainer.staged_lts_image", ""))
    latest_active = image_tag(active_image) == "latest" or active_image == "portainer/portainer-ce:latest"
    restore_is_pinned = restore_image_is_pinned(restore_image)
    staged_present = image_exists(staged, report) if staged and not report["failures"] else False
    if latest_active:
        report["warnings"].append("active Portainer image is :latest; recorded as observed runtime state only")
    if boolish(cfg_get("policy.restore_image_must_be_pinned", True)) and not restore_is_pinned:
        report["failures"].append(f"restore_image_authority must be version-pinned and must not be latest/lts/unversioned: {restore_image}")
    if fail_missing_staged and boolish(cfg_get("policy.require_staged_lts_image_for_restore_gate", True)) and not staged_present:
        report["failures"].append(f"staged Portainer LTS restore image is not locally inspectable: {staged}")
    return {"active_image": active_image, "active_image_is_latest": latest_active, "restore_image_authority": restore_image, "restore_image_is_pinned": restore_is_pinned, "staged_lts_image": staged, "staged_lts_image_present": staged_present, "decision": "latest is runtime state only; restore authority is configured staged LTS image"}


def cmd_gate_latest_not_authority(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("gate-latest-not-authority")
    report = report_base("gate-latest-not-authority", run_dir)
    report["mode"] = "verify"
    preflight(report)
    gate = gate_latest(report, fail_missing_staged=True)
    path = run_dir / "portainer_latest_authority_gate.json"
    write_json(path, gate)
    report["portainer"] = {"latest_authority_gate": rel(path), **gate}
    output_file(report, path, "json", "portainer_latest_authority_gate")
    return finalize_report(report, run_dir)


def current_state(report: dict[str, Any], *, fail_missing_staged: bool = False) -> dict[str, Any]:
    container = get_portainer_container(report) if not report["failures"] else None
    volume = volume_name()
    volume_inspect = docker_inspect("volume", [volume], report, "portainer_restore_state_volume") if not report["failures"] else []
    networks = container.get("Networks", []) if container else []
    return {"container": container, "volume": volume_inspect[0] if volume_inspect else None, "networks": networks, "gate": gate_latest(report, fail_missing_staged=fail_missing_staged)}


def cmd_generate_restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-restore-plan")
    report = report_base("generate-restore-plan", run_dir)
    report["mode"] = "plan"
    preflight(report, require_daemon=False)
    state = current_state(report, fail_missing_staged=False) if command_exists(DOCKER) else {"container": None, "volume": None, "networks": [], "gate": {}}
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/15_portainer")))
    generated_root.mkdir(parents=True, exist_ok=True)
    plan_path = generated_root / str(cfg_get("policy.restore_plan_name", "portainer_restore_plan.md"))
    image = str(cfg_get("portainer.restore_image_authority"))
    volume = volume_name()
    lines = [
        "# Portainer restore plan",
        "",
        "Portainer is restored only after Docker itself is healthy. Row 15 does not install Docker and does not make Portainer the restore authority for other workloads.",
        "",
        "## Authority boundary",
        "",
        "- Active `portainer/portainer-ce:latest` is observed runtime state only.",
        f"- Restore image authority is `{image}` unless a later reviewed decision changes it.",
        f"- Data volume authority is Docker volume `{volume}` plus any guarded quiesced export produced by this row.",
        "- Docker/Compose workload authority remains Row 14. PostgreSQL logical recovery remains the PostgreSQL/database row, not Portainer.",
        "- Bind/cert payload bytes remain Borg/file-payload-owned when they live outside `portainer_data`.",
        "",
        "## Restore order",
        "",
        "1. Restore/install Docker through Row 10/Row 14 prerequisites and validate Docker daemon health.",
        "2. Load the staged Portainer LTS image tar if registry access is unavailable, or pull the pinned LTS image after review.",
        f"3. Recreate the `{volume}` Docker volume or restore the guarded quiesced volume tar into it.",
        "4. Restore any external certificate/bind mount payloads through Borg/file-payload recovery.",
        "5. Recreate the Portainer container using the generated review command; do not use `latest` as the restore image authority.",
        "6. Open the UI and validate endpoint status before using Portainer to inspect workloads.",
        "7. Restore/manage other workloads from their own row artifacts, not from Portainer UI memory.",
        "",
        "## Current observed state summary",
        "",
        "~~~json",
        json.dumps(state, indent=2, sort_keys=True, default=str),
        "~~~",
        "",
    ]
    write_text(plan_path, "\n".join(lines))
    plan_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["restore_plan"] = {"path": rel(plan_path)}
    output_file(report, plan_path, "markdown", "portainer_restore_plan")
    return finalize_report(report, run_dir)


def shell_join(argv: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in argv)


def restart_arg(container: dict[str, Any] | None) -> str:
    restart = ((container or {}).get("RestartPolicy") or {})
    name = restart.get("Name") or "unless-stopped"
    retries = restart.get("MaximumRetryCount")
    if name == "on-failure" and retries:
        return f"{name}:{retries}"
    return str(name)


def port_args_from_container(container: dict[str, Any] | None) -> list[str]:
    args: list[str] = []
    published = container.get("PublishedPorts") if container else None
    if isinstance(published, dict):
        for container_port in sorted(published):
            binds = published.get(container_port) or []
            for bind in binds:
                if not isinstance(bind, dict):
                    continue
                host_ip = str(bind.get("HostIp") or "")
                host_port = str(bind.get("HostPort") or "")
                if not host_port:
                    continue
                host_prefix = f"{host_ip}:" if host_ip and host_ip not in {"0.0.0.0", "::"} else ""
                args += ["-p", f"{host_prefix}{host_port}:{container_port}"]
    if not args:
        args = ["-p", "9443:9443"]
    return args


def mount_args_from_container(container: dict[str, Any] | None) -> list[str]:
    args: list[str] = []
    seen_data = False
    if container:
        for mount in container.get("Mounts", []) or []:
            mtype = mount.get("Type")
            dest = mount.get("Destination")
            readonly = ":ro" if mount.get("RW") is False else ""
            if not dest:
                continue
            if mtype == "volume":
                name = mount.get("Name")
                if not name:
                    continue
                if dest == volume_target() or name == volume_name():
                    name = volume_name()
                    seen_data = True
                args += ["-v", f"{name}:{dest}{readonly}"]
            elif mtype == "bind":
                source = mount.get("Source")
                if source:
                    args += ["-v", f"{source}:{dest}{readonly}"]
    if not seen_data:
        args += ["-v", f"{volume_name()}:{volume_target()}"]
    return args


def network_commands(container: dict[str, Any] | None, container_name: str) -> tuple[list[str], list[str]]:
    networks = list((container or {}).get("Networks") or [])
    primary_args: list[str] = []
    post_lines: list[str] = []
    non_default = [n for n in networks if n not in {"bridge", "host", "none"}]
    if non_default:
        primary_args = ["--network", non_default[0]]
        for network in non_default[1:]:
            post_lines.append(shell_join(["docker", "network", "connect", network, container_name]))
    return primary_args, post_lines


def observed_portainer_command_args(container: dict[str, Any] | None) -> list[str]:
    if not container:
        return []

    def normalize(value: Any) -> list[str]:
        if isinstance(value, list):
            return [str(item) for item in value if str(item)]
        if isinstance(value, str) and value:
            try:
                return [str(item) for item in shlex.split(value)]
            except ValueError:
                return [value]
        return []

    cmd = normalize(container.get("Cmd"))
    if cmd:
        return cmd
    args = normalize(container.get("Args"))
    if args:
        return args
    return []


def contains_redacted_marker(value: Any) -> bool:
    if isinstance(value, str):
        return "<redacted" in value
    if isinstance(value, list):
        return any(contains_redacted_marker(item) for item in value)
    if isinstance(value, dict):
        return any(contains_redacted_marker(k) or contains_redacted_marker(v) for k, v in value.items())
    return False


def cmd_generate_recreate_command(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-recreate-command")
    report = report_base("generate-recreate-command", run_dir)
    report["mode"] = "plan"
    preflight(report, require_daemon=False)
    state = current_state(report, fail_missing_staged=False) if command_exists(DOCKER) else {"container": None, "volume": None, "networks": [], "gate": {}}
    container = state.get("container") if isinstance(state.get("container"), dict) else None
    image = str(cfg_get("portainer.restore_image_authority", "portainer/portainer-ce:2.39.2"))
    if boolish(cfg_get("policy.restore_image_must_be_pinned", True)) and not restore_image_is_pinned(image):
        report["failures"].append(f"restore image is not pinned enough for recreate command: {image}")
    name = str(cfg_get("portainer.active_container_name", "portainer"))
    primary_network_args, post_network_lines = network_commands(container, name)
    run_args = ["docker", "run", "-d", "--name", name, f"--restart={restart_arg(container)}"]
    run_args += port_args_from_container(container)
    run_args += mount_args_from_container(container)
    run_args += primary_network_args
    run_args.append(image)
    observed_args = observed_portainer_command_args(container)
    if observed_args:
        run_args.extend(str(x) for x in observed_args)
    redacted_in_recreate = contains_redacted_marker(run_args)
    if redacted_in_recreate:
        report["warnings"].append("Portainer recreate command contains redacted placeholders; restore operator must recover those values from the owning secret source before execution")
    generated_root = resolve_path(str(cfg_get("project.generated_root", "state/generated/15_portainer")))
    generated_root.mkdir(parents=True, exist_ok=True)
    script_path = generated_root / str(cfg_get("policy.recreate_command_name", "portainer_recreate_review.sh"))
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Review-only Portainer recreate command generated by Row 15.",
        "# This script is intentionally not executed by Row 15.",
        "# Confirm Docker is healthy, the pinned Portainer image is available, external bind/cert paths exist, and portainer_data has been restored before use.",
        "",
    ]
    if redacted_in_recreate:
        lines += [
            "# WARNING: This review script contains <redacted> placeholders.",
            "# Recover those values from the owning secret/certificate source before execution.",
            "",
        ]
    lines += [
        shell_join(["docker", "volume", "create", volume_name()]),
        shell_join(run_args),
    ]
    if post_network_lines:
        lines += ["", "# Additional observed Portainer network attachments.", *post_network_lines]
    lines.append("")
    write_text(script_path, "\n".join(lines))
    script_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["recreate_command"] = {"path": rel(script_path), "image": image, "volume": volume_name(), "container": name, "post_network_commands": post_network_lines}
    output_file(report, script_path, "shell", "portainer_recreate_review_script")
    return finalize_report(report, run_dir)


def cmd_validate_restore_prereqs(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("validate-restore-prereqs")
    report = report_base("validate-restore-prereqs", run_dir)
    report["mode"] = "verify"
    preflight(report)
    image = str(cfg_get("portainer.restore_image_authority"))
    staged = str(cfg_get("portainer.staged_lts_image"))
    volume = volume_name()
    staged_present = image_exists(staged, report) if not report["failures"] else False
    volume_present = volume_exists(volume, report) if not report["failures"] else False
    gate = gate_latest(report, fail_missing_staged=True)
    prereqs = {"docker_command": DOCKER, "restore_image_authority": image, "staged_lts_image_present": staged_present, "data_volume_present": volume_present, "latest_gate": gate, "restore_after": cfg_get("policy.portainer_restores_after")}
    if not volume_present:
        report["warnings"].append(f"Portainer data volume is not currently inspectable: {volume}; acceptable on a fresh restore before volume recreation")
    path = run_dir / "portainer_restore_prereqs.json"
    write_json(path, prereqs)
    report["portainer"] = {"restore_prereqs": rel(path), **prereqs}
    output_file(report, path, "json", "portainer_restore_prereqs")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("capture-container").set_defaults(func=cmd_capture_container)
    sub.add_parser("capture-image").set_defaults(func=cmd_capture_image)
    sub.add_parser("capture-image-digest").set_defaults(func=cmd_capture_image_digest)
    sub.add_parser("capture-volume").set_defaults(func=cmd_capture_volume)
    sub.add_parser("capture-ports").set_defaults(func=cmd_capture_ports)
    sub.add_parser("capture-mounts").set_defaults(func=cmd_capture_mounts)
    sub.add_parser("capture-networks").set_defaults(func=cmd_capture_networks)

    p = sub.add_parser("export-staged-lts-image")
    p.add_argument("--image", default=None)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.set_defaults(func=cmd_export_staged_lts_image)

    p = sub.add_parser("volume-export-quiesced")
    p.add_argument("--volume", default=None)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.set_defaults(func=cmd_volume_export_quiesced)

    sub.add_parser("generate-restore-plan").set_defaults(func=cmd_generate_restore_plan)
    sub.add_parser("generate-recreate-command").set_defaults(func=cmd_generate_recreate_command)
    sub.add_parser("validate-restore-prereqs").set_defaults(func=cmd_validate_restore_prereqs)
    sub.add_parser("gate-latest-not-authority").set_defaults(func=cmd_gate_latest_not_authority)
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