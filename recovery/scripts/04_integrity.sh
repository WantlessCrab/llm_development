#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PY'
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "04_integrity.sh"
SCHEMA_NAME = "recovery.integrity.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "integrity",
        "verified_sha256sum_version": "coreutils 9.4",
        "verified_b3sum_version": "1.2.0",
        "layer": "04_artifact_integrity_restore_admissibility",
    },
    "project": {
        "output_root": "state/dry_runs/04_integrity",
        "local_test_root": "state/local_test/04_integrity",
        "manifest_index": "state/integrity_manifests/index.json",
    },
    "commands": {
        "sha256sum": "/usr/bin/sha256sum",
        "b3sum": "/usr/bin/b3sum",
        "stat": "/usr/bin/stat",
    },
    "policy": {
        "canonical_algorithm": "sha256",
        "fast_algorithm": "b3sum",
        "sha256_manifest_name": "SHA256SUMS",
        "b3sum_manifest_name": "B3SUMS",
        "json_sidecar_suffix": ".json",
        "report_name": "integrity_report.json",
        "require_relative_manifest_paths": True,
        "refuse_absolute_manifest_entries": True,
        "refuse_parent_path_entries": True,
        "refuse_newline_paths": True,
        "stable_sort": True,
        "fail_on_empty_write_set": True,
        "overwrite_existing_manifest": False,
        "copy_config_snapshot_into_run": True,
    },
    "artifact_aliases": {
        "configs": "recovery_source_controls",
        "luks_headers": "cryptsetup_headers",
    },
    "artifact_classes": {
        "local_test": {
            "description": "Generated scratch artifacts used to prove the integrity toolchain before hashing real recovery outputs.",
            "paths": "state/local_test/04_integrity/artifacts",
            "include_globs": "**/*",
            "exclude_globs": "",
            "required": True,
            "critical": False,
            "allow_missing": False,
            "sudo_read": False,
            "generate_local_test_artifacts": True,
        },
        "recovery_source_controls": {
            "description": "Recovery project source controls: configs, scripts, schemas, and current implementation contracts.",
            "paths": "configs;scripts;manifests/schema",
            "include_globs": "**/*",
            "exclude_globs": r"(^|/)(__pycache__|\.git|\.venv|venv|state|downloads)(/|$)|\.pyc$|~$|\.tmp$",
            "required": True,
            "critical": True,
            "allow_missing": False,
            "sudo_read": False,
            "exclude_mode": "regex",
        },
        "rescuezilla_iso": {
            "description": "Downloaded Rescuezilla ISO artifact.",
            "paths": "downloads/rescuezilla-2.6.2-64bit.resolute.iso",
            "include_globs": "**/*",
            "exclude_globs": "",
            "required": True,
            "critical": True,
            "allow_missing": False,
            "sudo_read": False,
        },
        "rescuezilla_images": {
            "description": "Future Rescuezilla image artifacts.",
            "paths": "state/dry_runs/02_rescuezilla/images;/mnt/wantless_recovery/01_rescuezilla_images",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp;**/.DS_Store",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": False,
        },
        "cryptsetup_headers": {
            "description": "LUKS header backup artifacts from Row 03.",
            "paths": "state/secrets/cryptsetup/header_backups",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": True,
        },
        "cryptsetup_emergency_packets": {
            "description": "Cryptsetup emergency packet artifacts from Row 03.",
            "paths": "state/secrets/cryptsetup/emergency_packets",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": True,
        },
        "borg_artifacts": {
            "description": "Future Borg exports, key material, and repository proof artifacts.",
            "paths": "state/secrets/borg;state/dry_runs/06_borg;state/exports/borg",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": True,
        },
        "database_dumps": {
            "description": "Future PostgreSQL logical dump artifacts.",
            "paths": "state/dry_runs/16_postgresql;state/exports/postgresql",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": False,
        },
        "docker_exports": {
            "description": "Future Docker and Portainer image/volume/export artifacts.",
            "paths": "state/dry_runs/14_docker;state/dry_runs/15_portainer;state/exports/docker",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": False,
        },
        "vm_cold_copies": {
            "description": "Future libvirt/QEMU stopped VM cold-copy artifacts.",
            "paths": "state/dry_runs/17_libvirt;state/exports/libvirt",
            "include_globs": "**/*",
            "exclude_globs": "**/SHA256SUMS;**/B3SUMS;**/*.tmp",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": True,
        },
        "runbooks": {
            "description": "Future canonical human restore workflow artifacts.",
            "paths": "runbooks",
            "include_globs": "**/*.md;**/*.txt;**/*.yaml;**/*.yml;**/*.json",
            "exclude_globs": "",
            "required": False,
            "critical": True,
            "allow_missing": True,
            "sudo_read": False,
        },
    },
    "restore_gate": {
        "algorithms": "sha256;b3sum",
        "required_classes": "recovery_source_controls;rescuezilla_iso",
        "optional_critical_classes": "rescuezilla_images;cryptsetup_headers;cryptsetup_emergency_packets;borg_artifacts;database_dumps;docker_exports;vm_cold_copies;runbooks",
        "require_local_test_proof": True,
        "require_sha256_for_portable_restore": True,
        "require_b3sum_for_local_fast_audit": True,
        "verify_optional_when_present": True,
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
    path = PROJECT_ROOT / "configs" / "04_integrity.yaml"
    if not path.exists():
        return deepcopy(DEFAULT_CONFIG)
    return deep_merge(DEFAULT_CONFIG, parse_simple_yaml(path))


CFG = load_config()


def cfg_get(path: str, default: Any = None) -> Any:
    cur: Any = CFG
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def split_semicolon(value: Any) -> list[str]:
    return [part.strip() for part in str(value or "").split(";") if part.strip()]


def cmd_path(name: str) -> str:
    value = str(cfg_get(f"commands.{name}", name))
    if "/" in value:
        return value
    return shutil.which(value) or value


SHA256SUM = cmd_path("sha256sum")
B3SUM = cmd_path("b3sum")
STAT = cmd_path("stat")


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def resolve_path(value: str | Path) -> Path:
    p = Path(str(value)).expanduser()
    if not p.is_absolute():
        p = PROJECT_ROOT / p
    return p.resolve()


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/04_integrity")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    if bool(cfg_get("policy.copy_config_snapshot_into_run", True)):
        config_path = PROJECT_ROOT / "configs" / "04_integrity.yaml"
        if config_path.exists():
            shutil.copy2(config_path, run_dir / "04_integrity.config.snapshot.yaml")
    return run_dir


def manifest_index_path() -> Path:
    return resolve_path(str(cfg_get("project.manifest_index", "state/integrity_manifests/index.json")))


def read_manifest_index() -> list[dict[str, Any]]:
    path = manifest_index_path()
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return []
    return payload if isinstance(payload, list) else []


def write_manifest_index(entries: list[dict[str, Any]]) -> None:
    path = manifest_index_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entries, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def add_manifest_index(manifest_report: dict[str, Any]) -> None:
    entries = read_manifest_index()
    entries.append({
        "created_at": iso_now(),
        "algorithm": manifest_report.get("algorithm"),
        "artifact_class": manifest_report.get("artifact_class"),
        "root": manifest_report.get("root"),
        "manifest_path": manifest_report.get("manifest_path"),
        "json_path": manifest_report.get("json_path"),
        "file_count": manifest_report.get("file_count", 0),
    })
    write_manifest_index(entries)


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "integrity",
            "script": SCRIPT_NAME,
            "sha256sum_path": SHA256SUM,
            "b3sum_path": B3SUM,
        },
        "command": command,
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": True,
        "failures": [],
        "warnings": [],
    }


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_name = str(cfg_get("policy.report_name", "integrity_report.json"))
    report_path = run_dir / report_name
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], *, sudo: bool = False) -> dict[str, Any]:
    final_argv = argv[:]
    if sudo and os.geteuid() != 0:
        sudo_path = shutil.which("sudo")
        if not sudo_path:
            return {"argv": argv, "returncode": 127, "stdout": "", "stderr": "sudo is required but unavailable"}
        final_argv = [sudo_path] + final_argv
    proc = subprocess.run(final_argv, text=True, capture_output=True)
    return {
        "argv": final_argv,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    report["failures"].append(f"required tool missing for {label}: {path}")
    return False


def validate_relative_path(relative_path: str) -> None:
    if "\n" in relative_path and bool(cfg_get("policy.refuse_newline_paths", True)):
        raise ValueError(f"manifest path contains newline: {relative_path!r}")
    path_obj = Path(relative_path)
    if path_obj.is_absolute() and bool(cfg_get("policy.refuse_absolute_manifest_entries", True)):
        raise ValueError(f"manifest path is absolute: {relative_path!r}")
    if ".." in path_obj.parts and bool(cfg_get("policy.refuse_parent_path_entries", True)):
        raise ValueError(f"manifest path contains parent traversal: {relative_path!r}")


def glob_match(relative_path: str, patterns: list[str]) -> bool:
    if not patterns:
        return True
    for pat in patterns:
        pat = pat.strip()
        if not pat:
            continue
        if pat in {"*", "**", "**/*"}:
            return True
        if fnmatch.fnmatch(relative_path, pat):
            return True
        if pat.startswith("**/") and fnmatch.fnmatch(relative_path, pat[3:]):
            return True
        if "/" not in pat and fnmatch.fnmatch(Path(relative_path).name, pat):
            return True
    return False


def excluded(relative_path: str, root_relative_path: str, patterns: list[str], exclude_regex: str | None, exclude_mode: str) -> bool:
    if exclude_mode == "regex":
        return bool(exclude_regex and re.search(exclude_regex, root_relative_path))
    if not patterns:
        return False
    return glob_match(relative_path, patterns)


def collect_files(
    root: Path,
    include_patterns: list[str],
    exclude_patterns: list[str],
    *,
    exclude_regex: str | None = None,
    exclude_mode: str = "glob",
) -> tuple[list[Path], list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    files: list[Path] = []

    if not root.exists():
        warnings.append(f"path absent: {root}")
        return files, failures, warnings

    if root.is_file():
        relative_path = root.name
        project_relative_path = rel(root)
        validate_relative_path(relative_path)
        if glob_match(relative_path, include_patterns) and not excluded(relative_path, project_relative_path, exclude_patterns, exclude_regex, exclude_mode):
            files.append(root)
        return files, failures, warnings

    if not root.is_dir():
        warnings.append(f"path is not file or directory and was skipped: {root}")
        return files, failures, warnings

    for item in root.rglob("*"):
        if not item.is_file():
            continue
        relative_path = item.relative_to(root).as_posix()
        project_relative_path = rel(item)
        try:
            validate_relative_path(relative_path)
        except ValueError as exc:
            failures.append(str(exc))
            continue
        if not glob_match(relative_path, include_patterns):
            continue
        if excluded(relative_path, project_relative_path, exclude_patterns, exclude_regex, exclude_mode):
            continue
        files.append(item)

    if bool(cfg_get("policy.stable_sort", True)):
        files.sort(key=lambda p: p.relative_to(root).as_posix())
    return files, failures, warnings


def digest_with_tool(algorithm: str, file_path: Path, report: dict[str, Any], *, sudo_read: bool = False) -> str:
    if algorithm == "sha256":
        if not require_tool(SHA256SUM, report, "sha256sum"):
            return ""
        argv = [SHA256SUM, str(file_path)]
    elif algorithm == "b3sum":
        if not require_tool(B3SUM, report, "b3sum"):
            return ""
        argv = [B3SUM, str(file_path)]
    else:
        report["failures"].append(f"unsupported algorithm: {algorithm}")
        return ""

    result = run_cmd(argv, sudo=sudo_read)
    report.setdefault("commands", []).append({
        "argv": result["argv"],
        "returncode": result["returncode"],
        "stderr": result["stderr"],
    })
    if result["returncode"] != 0:
        report["failures"].append(f"{algorithm} failed for {file_path}: {result['stderr'].strip()}")
        return ""
    stdout = result["stdout"].strip()
    return stdout.split()[0] if stdout else ""


def file_size(path: Path, report: dict[str, Any], *, sudo_read: bool = False) -> int:
    try:
        return path.stat().st_size
    except PermissionError:
        if sudo_read:
            result = run_cmd([STAT, "-c", "%s", str(path)], sudo=True)
            report.setdefault("commands", []).append({
                "argv": result["argv"],
                "returncode": result["returncode"],
                "stderr": result["stderr"],
            })
            if result["returncode"] == 0:
                try:
                    return int(result["stdout"].strip())
                except ValueError:
                    return -1
        return -1


def manifest_name_for_algorithm(algorithm: str) -> str:
    if algorithm == "sha256":
        return str(cfg_get("policy.sha256_manifest_name", "SHA256SUMS"))
    if algorithm == "b3sum":
        return str(cfg_get("policy.b3sum_manifest_name", "B3SUMS"))
    raise ValueError(f"unsupported algorithm: {algorithm}")


def common_root(roots: list[Path], fallback: Path) -> Path:
    existing = [p for p in roots if p.exists()]
    if not existing:
        return fallback.resolve()
    if len(existing) == 1:
        return existing[0].parent.resolve() if existing[0].is_file() else existing[0].resolve()
    try:
        return Path(os.path.commonpath([str(p.resolve()) for p in existing])).resolve()
    except ValueError:
        return fallback.resolve()


def write_manifest(
    *,
    algorithm: str,
    root: Path,
    manifest: Path,
    files: list[Path],
    report: dict[str, Any],
    artifact_class: str | None = None,
    label: str | None = None,
    sudo_read: bool = False,
) -> dict[str, Any] | None:
    if algorithm == "sha256":
        require_tool(SHA256SUM, report, "sha256sum")
    elif algorithm == "b3sum":
        require_tool(B3SUM, report, "b3sum")
    else:
        report["failures"].append(f"unsupported algorithm: {algorithm}")
        return None

    if not root.exists():
        report["failures"].append(f"root does not exist: {root}")
        return None
    if not files and bool(cfg_get("policy.fail_on_empty_write_set", True)):
        report["failures"].append(f"no files matched for manifest write under root: {root}")
        return None
    if manifest.exists() and not bool(cfg_get("policy.overwrite_existing_manifest", False)):
        report["failures"].append(f"manifest already exists and overwrite is disabled: {manifest}")
        return None

    entries: list[dict[str, Any]] = []
    lines: list[str] = []

    for file_path in files:
        try:
            relative_path = file_path.resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            # Multi-root classes intentionally use PROJECT_ROOT as their root.
            relative_path = rel(file_path)
        try:
            validate_relative_path(relative_path)
        except ValueError as exc:
            report["failures"].append(str(exc))
            continue

        digest = digest_with_tool(algorithm, file_path, report, sudo_read=sudo_read)
        if not digest:
            continue
        size = file_size(file_path, report, sudo_read=sudo_read)
        lines.append(f"{digest}  {relative_path}\n")
        entries.append({
            "algorithm": algorithm,
            "hash": digest,
            "relative_path": relative_path,
            "absolute_path": str(file_path.resolve()),
            "size_bytes": size,
        })

    if report.get("failures"):
        return None

    manifest.parent.mkdir(parents=True, exist_ok=True)
    write_text(manifest, "".join(lines))

    sidecar = manifest.with_name(manifest.name + str(cfg_get("policy.json_sidecar_suffix", ".json")))
    manifest_report = {
        "schema": "recovery.integrity.manifest.v1",
        "algorithm": algorithm,
        "artifact_class": artifact_class,
        "label": label or artifact_class or "manual",
        "created_at": iso_now(),
        "root": str(root.resolve()),
        "manifest_path": str(manifest.resolve()),
        "manifest_relative_path": rel(manifest),
        "json_path": str(sidecar.resolve()),
        "json_relative_path": rel(sidecar),
        "file_count": len(entries),
        "ok": True,
        "entries": entries,
    }
    write_json(sidecar, manifest_report)
    add_manifest_index(manifest_report)
    return manifest_report


def parse_manifest(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not raw.strip():
            continue
        if "  " not in raw:
            raise ValueError(f"{path}:{number}: unsupported manifest line; expected '<digest>  <relative_path>'")
        digest, relative_path = raw.split("  ", 1)
        digest = digest.strip()
        relative_path = relative_path.strip()
        validate_relative_path(relative_path)
        entries.append((digest, relative_path))
    return entries


def load_sidecar(manifest: Path) -> dict[str, Any] | None:
    sidecar = manifest.with_name(manifest.name + str(cfg_get("policy.json_sidecar_suffix", ".json")))
    if not sidecar.exists():
        return None
    try:
        return json.loads(sidecar.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def infer_root_from_index(manifest: Path) -> Path | None:
    manifest_resolved = str(manifest.resolve())
    for entry in reversed(read_manifest_index()):
        if str(entry.get("manifest_path", "")) == manifest_resolved and entry.get("root"):
            return Path(str(entry["root"])).resolve()
    return None


def check_manifest(
    *,
    algorithm: str,
    manifest: Path,
    root: Path | None,
    report: dict[str, Any],
    sudo_read: bool = False,
) -> dict[str, Any] | None:
    if not manifest.exists():
        report["failures"].append(f"manifest does not exist: {manifest}")
        return None
    if algorithm == "sha256":
        require_tool(SHA256SUM, report, "sha256sum")
    elif algorithm == "b3sum":
        require_tool(B3SUM, report, "b3sum")
    else:
        report["failures"].append(f"unsupported algorithm: {algorithm}")
        return None

    sidecar = load_sidecar(manifest)
    if root is None and sidecar and sidecar.get("root"):
        root = Path(str(sidecar["root"])).resolve()
    if root is None:
        root = infer_root_from_index(manifest)
    if root is None:
        root = manifest.parent.resolve()
    if not root.exists():
        report["failures"].append(f"root does not exist: {root}")
        return None

    results: list[dict[str, Any]] = []
    try:
        manifest_entries = parse_manifest(manifest)
    except ValueError as exc:
        report["failures"].append(str(exc))
        manifest_entries = []

    for expected, relative_path in manifest_entries:
        target = (root / relative_path).resolve()
        try:
            target.relative_to(root.resolve())
        except ValueError:
            results.append({"relative_path": relative_path, "expected": expected, "actual": None, "ok": False, "reason": "entry resolves outside root"})
            report["failures"].append(f"manifest entry resolves outside root: {relative_path}")
            continue
        if not target.exists() or not target.is_file():
            results.append({"relative_path": relative_path, "expected": expected, "actual": None, "ok": False, "reason": "file missing"})
            report["failures"].append(f"manifest file missing: {relative_path}")
            continue
        actual = digest_with_tool(algorithm, target, report, sudo_read=sudo_read)
        ok = actual == expected
        results.append({"relative_path": relative_path, "expected": expected, "actual": actual, "ok": ok, "reason": None if ok else "digest mismatch"})
        if not ok:
            report["failures"].append(f"digest mismatch: {relative_path}")

    if not results:
        report["failures"].append(f"manifest had no checkable entries: {manifest}")

    check_report = {
        "algorithm": algorithm,
        "manifest_path": str(manifest.resolve()),
        "manifest_relative_path": rel(manifest),
        "root": str(root.resolve()),
        "ok": not any(not item["ok"] for item in results) and bool(results),
        "checked_count": len(results),
        "results": results,
    }
    report.setdefault("checks", []).append(check_report)
    return check_report


def canonical_class_name(name: str) -> str:
    aliases = cfg_get("artifact_aliases", {})
    if isinstance(aliases, dict) and name in aliases:
        return str(aliases[name])
    return name


def class_config(name: str) -> dict[str, Any]:
    canonical = canonical_class_name(name)
    classes = CFG.get("artifact_classes", {})
    if not isinstance(classes, dict) or canonical not in classes:
        raise SystemExit(f"Unknown artifact class: {name}")
    value = deepcopy(classes[canonical])
    value["_canonical_name"] = canonical
    return value


def ensure_local_test_artifacts() -> Path:
    local_root = resolve_path(str(cfg_get("project.local_test_root", "state/local_test/04_integrity")))
    artifact_root = local_root / "artifacts"
    nested = artifact_root / "nested"
    nested.mkdir(parents=True, exist_ok=True)
    (artifact_root / "alpha.txt").write_text("wantless recovery integrity local proof alpha\n", encoding="utf-8")
    (nested / "beta with spaces.txt").write_text("wantless recovery integrity local proof beta\n", encoding="utf-8")
    (artifact_root / "deterministic.bin").write_bytes(bytes((i * 17) % 256 for i in range(4096)))
    (artifact_root / "MANIFEST_NOTE.txt").write_text(
        "These files are generated scratch artifacts for Row 04 integrity proof only.\n"
        "They are intentionally deterministic and may be recreated.\n",
        encoding="utf-8",
    )
    return artifact_root


def class_paths(class_name: str) -> list[Path]:
    c = class_config(class_name)
    if bool(c.get("generate_local_test_artifacts", False)):
        ensure_local_test_artifacts()
    return [resolve_path(part) for part in split_semicolon(c.get("paths"))]


def files_for_class(class_name: str, parent_report: dict[str, Any], *, record_messages: bool = True) -> tuple[Path, list[Path], dict[str, Any]]:
    c = class_config(class_name)
    canonical = str(c.get("_canonical_name", class_name))
    include_patterns = split_semicolon(c.get("include_globs")) or ["**/*"]
    exclude_patterns = split_semicolon(c.get("exclude_globs"))
    exclude_regex = str(c.get("exclude_globs", "") or "") if str(c.get("exclude_mode", "glob")) == "regex" else None
    exclude_mode = str(c.get("exclude_mode", "glob"))
    paths = class_paths(canonical)

    all_files: list[Path] = []
    existing_paths: list[Path] = []
    missing_paths: list[str] = []
    failures: list[str] = []
    warnings: list[str] = []

    for path in paths:
        if not path.exists():
            missing_paths.append(str(path))
            continue
        existing_paths.append(path)
        found, local_failures, local_warnings = collect_files(
            path,
            include_patterns,
            exclude_patterns,
            exclude_regex=exclude_regex,
            exclude_mode=exclude_mode,
        )
        all_files.extend(found)
        failures.extend(local_failures)
        warnings.extend(local_warnings)

    required = bool(c.get("required", False))
    allow_missing = bool(c.get("allow_missing", False))

    for missing in missing_paths:
        msg = f"artifact class root absent for {canonical}: {missing}"
        if required and not allow_missing:
            failures.append(msg)
        else:
            warnings.append(msg)

    if required and not all_files and not allow_missing:
        failures.append(f"required artifact class has no files: {canonical}")

    root = common_root(existing_paths, paths[0] if paths else PROJECT_ROOT)
    if len(existing_paths) > 1:
        root = PROJECT_ROOT

    files = sorted(set(all_files), key=lambda p: rel(p))
    class_report = {
        "class_name": canonical,
        "requested_class_name": class_name,
        "description": c.get("description", canonical),
        "required": required,
        "critical": bool(c.get("critical", False)),
        "allow_missing": allow_missing,
        "sudo_read": bool(c.get("sudo_read", False)),
        "paths": [str(p) for p in paths],
        "existing_paths": [str(p) for p in existing_paths],
        "missing_paths": missing_paths,
        "files": [str(p) for p in files],
        "file_count": len(files),
        "root": str(root.resolve()),
        "ok": not failures,
        "failures": failures,
        "warnings": warnings,
    }

    if record_messages:
        parent_report["failures"].extend(failures)
        parent_report["warnings"].extend(warnings)
    return root, files, class_report


def manifest_path_for(run_dir: Path, algorithm: str, class_name: str | None = None) -> Path:
    filename = manifest_name_for_algorithm(algorithm)
    if class_name:
        return run_dir / "classes" / class_name / filename
    return run_dir / filename


def write_for_class(class_name: str, algorithm: str, run_dir: Path, parent_report: dict[str, Any]) -> dict[str, Any]:
    canonical = canonical_class_name(class_name)
    class_fail_start = len(parent_report["failures"])
    root, files, class_report = files_for_class(canonical, parent_report)
    manifest = manifest_path_for(run_dir, algorithm, canonical)
    c = class_config(canonical)
    local_report = report_base(f"hash-class:{class_name}:{algorithm}", run_dir)
    manifest_report = None

    if class_report["ok"] and files:
        manifest_report = write_manifest(
            algorithm=algorithm,
            root=root,
            manifest=manifest,
            files=files,
            report=local_report,
            artifact_class=canonical,
            label=str(c.get("description", canonical)),
            sudo_read=bool(c.get("sudo_read", False)),
        )
        parent_report["failures"].extend([f"{canonical}/{algorithm}: {msg}" for msg in local_report.get("failures", [])])
        parent_report["warnings"].extend([f"{canonical}/{algorithm}: {msg}" for msg in local_report.get("warnings", [])])
        parent_report.setdefault("commands", []).extend(local_report.get("commands", []))

    class_report.setdefault("manifests", [])
    if manifest_report:
        class_report["manifests"].append(manifest_report)
        parent_report.setdefault("manifests", []).append(manifest_report)

    # Recompute after class-local write failures are copied.
    class_report["ok"] = len(parent_report["failures"]) == class_fail_start
    parent_report.setdefault("classes", {})[canonical] = class_report
    write_json(run_dir / "classes" / canonical / f"{algorithm}_class_report.json", class_report)
    return class_report


def expand_algorithms(value: str | None) -> list[str]:
    raw = str(value or "sha256").strip().lower()
    if raw == "both":
        return ["sha256", "b3sum"]
    if raw in {"sha256", "b3sum"}:
        return [raw]
    if ";" in raw:
        items = [item.strip() for item in raw.split(";") if item.strip()]
        if all(item in {"sha256", "b3sum"} for item in items):
            return items
    raise SystemExit("--algorithm must be sha256, b3sum, or both")


def infer_algorithm_from_manifest(manifest: Path, fallback: str = "sha256") -> str:
    upper = manifest.name.upper()
    if "B3" in upper:
        return "b3sum"
    if "SHA" in upper:
        return "sha256"
    sidecar = load_sidecar(manifest)
    if sidecar and sidecar.get("algorithm") in {"sha256", "b3sum"}:
        return str(sidecar["algorithm"])
    return fallback


def cmd_write_hash(args: argparse.Namespace, algorithm: str) -> int:
    run_dir = make_run_dir(f"write-{algorithm}")
    report = report_base(f"write-{algorithm}", run_dir)
    target = resolve_path(args.path or args.root)
    root = resolve_path(args.root) if args.path and args.root else (target.parent if target.is_file() else target)
    manifest = resolve_path(args.manifest) if args.manifest else manifest_path_for(run_dir, algorithm)
    include_patterns = split_semicolon(args.include) or ["**/*"]
    exclude_patterns = split_semicolon(args.exclude)

    files, failures, warnings = collect_files(target, include_patterns, exclude_patterns)
    report["failures"].extend(failures)
    report["warnings"].extend(warnings)

    manifest_report = None
    if not report["failures"]:
        manifest_report = write_manifest(
            algorithm=algorithm,
            root=root,
            manifest=manifest,
            files=files,
            report=report,
            artifact_class=args.artifact_class,
            label=args.label or args.artifact_class,
            sudo_read=bool(args.sudo_read),
        )
    if manifest_report:
        report["manifest"] = manifest_report
        report["manifests"] = [manifest_report]
    return finalize_report(report, run_dir)


def cmd_check_hash(args: argparse.Namespace, algorithm: str) -> int:
    run_dir = make_run_dir(f"check-{algorithm}")
    report = report_base(f"check-{algorithm}", run_dir)
    manifest = resolve_path(args.manifest)
    root = resolve_path(args.root) if args.root else None
    check_manifest(
        algorithm=algorithm,
        manifest=manifest,
        root=root,
        report=report,
        sudo_read=bool(args.sudo_read),
    )
    return finalize_report(report, run_dir)


def cmd_hash_class(args: argparse.Namespace) -> int:
    class_name = canonical_class_name(args.artifact_class)
    run_dir = make_run_dir(f"hash-class-{class_name}")
    report = report_base("hash-class", run_dir)
    report["artifact_class"] = class_name
    report["algorithm"] = args.algorithm
    report["classes"] = {}
    report["manifests"] = []
    for algorithm in expand_algorithms(args.algorithm):
        write_for_class(class_name, algorithm, run_dir, report)
    return finalize_report(report, run_dir)


def critical_class_names() -> list[str]:
    names: list[str] = []
    classes = CFG.get("artifact_classes", {})
    if not isinstance(classes, dict):
        return names
    for name, payload in classes.items():
        if isinstance(payload, dict) and bool(payload.get("critical", False)):
            names.append(name)
    return names


def cmd_hash_critical(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("hash-critical")
    report = report_base("hash-critical", run_dir)
    report["algorithm"] = args.algorithm
    report["classes"] = {}
    report["manifests"] = []
    for class_name in critical_class_names():
        _root, files, class_report = files_for_class(class_name, report, record_messages=False)
        if not files:
            if class_report["required"] and not class_report["allow_missing"]:
                report["failures"].extend(class_report["failures"])
            else:
                report["warnings"].append(f"optional critical artifact class has no files yet: {class_name}")
            continue
        for algorithm in expand_algorithms(args.algorithm):
            write_for_class(class_name, algorithm, run_dir, report)
    return finalize_report(report, run_dir)


def check_manifest_report(manifest_report: dict[str, Any], run_dir: Path, parent_report: dict[str, Any]) -> None:
    algorithm = str(manifest_report.get("algorithm"))
    manifest = Path(str(manifest_report.get("manifest_path"))).resolve()
    root = Path(str(manifest_report.get("root"))).resolve()
    class_name = str(manifest_report.get("artifact_class") or "manual")
    c = class_config(class_name) if class_name != "manual" else {}
    local_report = report_base(f"check:{class_name}:{algorithm}", run_dir)
    check_manifest(
        algorithm=algorithm,
        manifest=manifest,
        root=root,
        report=local_report,
        sudo_read=bool(c.get("sudo_read", False)),
    )
    parent_report.setdefault("checks", []).extend(local_report.get("checks", []))
    parent_report.setdefault("commands", []).extend(local_report.get("commands", []))
    parent_report["failures"].extend([f"{class_name}/{algorithm}: {msg}" for msg in local_report.get("failures", [])])
    parent_report["warnings"].extend([f"{class_name}/{algorithm}: {msg}" for msg in local_report.get("warnings", [])])


def check_fresh_class_manifest(class_name: str, algorithm: str, run_dir: Path, parent_report: dict[str, Any]) -> None:
    before = len(parent_report.get("manifests", []))
    failure_start = len(parent_report.get("failures", []))
    write_for_class(class_name, algorithm, run_dir, parent_report)
    if len(parent_report.get("failures", [])) != failure_start:
        return
    new_manifests = parent_report.get("manifests", [])[before:]
    if not new_manifests:
        parent_report["failures"].append(f"{canonical_class_name(class_name)} {algorithm} manifest was not produced for fresh check")
        return
    for manifest_report in new_manifests:
        if manifest_report.get("artifact_class") == canonical_class_name(class_name) and manifest_report.get("algorithm") == algorithm:
            check_manifest_report(manifest_report, run_dir, parent_report)
            return
    parent_report["failures"].append(f"{canonical_class_name(class_name)} {algorithm} manifest was not found after fresh write")


def cmd_verify_restore_gate(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-restore-gate")
    report = report_base("verify-restore-gate", run_dir)
    algorithms = expand_algorithms(args.algorithm)
    report["algorithm"] = args.algorithm
    report["restore_gate"] = {
        "local_only": bool(args.local_only),
        "algorithms": algorithms,
        "required_classes": split_semicolon(cfg_get("restore_gate.required_classes", "recovery_source_controls;rescuezilla_iso")),
        "optional_classes": split_semicolon(cfg_get("restore_gate.optional_classes", "")),
        "fresh_manifest_policy": "write_then_check_current_run",
    }

    # Local proof is always mandatory because it proves toolchain write/check behavior.
    for algorithm in ["sha256", "b3sum"]:
        check_fresh_class_manifest("local_test", algorithm, run_dir, report)

    if not args.local_only:
        required = report["restore_gate"]["required_classes"]
        optional = report["restore_gate"]["optional_classes"]

        for class_name in required:
            for algorithm in algorithms:
                check_fresh_class_manifest(class_name, algorithm, run_dir, report)

        if bool(cfg_get("restore_gate.verify_optional_when_present", True)):
            for class_name in optional:
                canonical = canonical_class_name(class_name)
                _root, files, class_report = files_for_class(canonical, report, record_messages=False)
                if not files:
                    report.setdefault("classes", {})[canonical] = class_report
                    for warning in class_report["warnings"]:
                        report["warnings"].append(warning)
                    report["warnings"].append(f"optional class has no files yet: {canonical}")
                    continue
                for algorithm in algorithms:
                    check_fresh_class_manifest(canonical, algorithm, run_dir, report)

    for manifest_value in args.manifest or []:
        manifest = resolve_path(manifest_value)
        algorithm = "b3sum" if manifest.name.upper().startswith("B3") else "sha256"
        root = resolve_path(args.root) if args.root else (infer_root_from_index(manifest) or manifest.parent)
        check_report = report_base(f"check-explicit:{manifest.name}", run_dir)
        check_manifest(algorithm=algorithm, manifest=manifest, root=root, report=check_report)
        report.setdefault("explicit_manifest_checks", []).append(check_report)
        if check_report.get("failures"):
            report["failures"].extend([f"explicit {manifest}: {msg}" for msg in check_report["failures"]])
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_write_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--path", default=None, help="File or directory to hash.")
        p.add_argument("--root", default=None, help="Manifest root. If --path is omitted, --root is also the path to hash.")
        p.add_argument("--manifest", default=None)
        p.add_argument("--include", default="**/*")
        p.add_argument("--exclude", default="")
        p.add_argument("--artifact-class", default="manual")
        p.add_argument("--label", default=None)
        p.add_argument("--sudo-read", action="store_true")

    def add_check_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--manifest", required=True)
        p.add_argument("--root", default=None)
        p.add_argument("--sudo-read", action="store_true")

    p = sub.add_parser("write-sha256")
    add_write_args(p)
    p.set_defaults(func=lambda a: cmd_write_hash(a, "sha256"))

    p = sub.add_parser("check-sha256")
    add_check_args(p)
    p.set_defaults(func=lambda a: cmd_check_hash(a, "sha256"))

    p = sub.add_parser("write-b3sum")
    add_write_args(p)
    p.set_defaults(func=lambda a: cmd_write_hash(a, "b3sum"))

    p = sub.add_parser("check-b3sum")
    add_check_args(p)
    p.set_defaults(func=lambda a: cmd_check_hash(a, "b3sum"))

    p = sub.add_parser("hash-class")
    p.add_argument("class_name", nargs="?", help="Artifact class name, for example local_test.")
    p.add_argument("--class", dest="class_option", default=None, help="Artifact class name; retained as a compatibility alias.")
    p.add_argument("--algorithm", choices=["sha256", "b3sum", "both"], default="both")
    p.set_defaults(func=cmd_hash_class)

    p = sub.add_parser("hash-critical")
    p.add_argument("--algorithm", choices=["sha256", "b3sum", "both"], default="both")
    p.set_defaults(func=cmd_hash_critical)

    p = sub.add_parser("verify-restore-gate")
    p.add_argument("--algorithm", choices=["sha256", "b3sum", "both"], default="both")
    p.add_argument("--local-only", action="store_true")
    p.add_argument("--manifest", action="append", default=[])
    p.add_argument("--root", default=None)
    p.add_argument("--sudo-read", action="store_true")
    p.set_defaults(func=cmd_verify_restore_gate)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args(ARGS)

    if getattr(args, "command", "") in {"write-sha256", "write-b3sum"} and not (args.path or args.root):
        parser.error(f"{args.command} requires --path PATH or --root PATH")

    if getattr(args, "command", "") == "hash-class":
        args.artifact_class = args.class_option or args.class_name
        if not args.artifact_class:
            parser.error("hash-class requires CLASS or --class CLASS")

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


raise SystemExit(main())
PY