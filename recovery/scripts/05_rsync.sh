#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PY'
from __future__ import annotations

import argparse
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
SCRIPT_NAME = "05_rsync.sh"
SCHEMA_NAME = "recovery.rsync.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "rsync",
        "verified_rsync_version": "3.2.7-1ubuntu1.4",
        "layer": "05_controlled_staging_cold_copy_transport",
    },
    "project": {
        "output_root": "state/dry_runs/05_rsync",
        "local_test_root": "state/local_test/05_rsync",
    },
    "commands": {
        "rsync": "/usr/bin/rsync",
        "virsh": "/usr/bin/virsh",
        "stat": "/usr/bin/stat",
    },
    "policy": {
        "default_mode": "dry_run",
        "require_execute_for_writes": True,
        "require_delete_confirmation": True,
        "delete_confirmation_phrase": "ALLOW_RSYNC_DELETE",
        "delete_confirmation_prefix": "RSYNC_DELETE",
        "restore_confirmation_prefix": "RESTORE_RSYNC",
        "vm_cold_copy_confirmation_prefix": "COLD_COPY_VM",
        "delete_destination_must_be_under_local_test": True,
        "refuse_root_destination": True,
        "refuse_source_equals_destination": True,
        "refuse_destination_inside_source": True,
        "refuse_source_inside_destination": True,
        "copy_config_snapshot_into_run": True,
        "report_name": "rsync_report.json",
        "itemized_name": "itemized.log",
        "stdout_name": "rsync.stdout.txt",
        "stderr_name": "rsync.stderr.txt",
        "stable_sort_local_test": True,
    },
    "rsync_defaults": {
        "archive": True,
        "xattrs": True,
        "acls": True,
        "numeric_ids": True,
        "itemize_changes": True,
        "stats": True,
        "human_readable": True,
        "protect_args": True,
        "delete": False,
        "checksum": False,
        "sparse": True,
        "one_file_system": False,
        "copy_links": False,
        "preserve_hard_links": True,
        "partial": False,
        "inplace": False,
        "extra_args": "",
        "out_format": "%i %n%L",
    },
    "protected_destinations": {
        "paths": "/;/home;/home/wantless;/etc;/usr;/bin;/sbin;/lib;/lib64;/boot;/var;/opt;/mnt;/media",
    },
    "profiles": {
        "local-scratch-copy": {
            "source": "state/local_test/05_rsync/source",
            "destination": "state/local_test/05_rsync/dest/copy",
            "generate_local_test_artifacts": True,
            "delete": False,
            "allow_delete": False,
            "require_source_exists": True,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": True,
            "copy_contents": True,
            "sudo_read": False,
        },
        "local-scratch-mirror-no-delete": {
            "source": "state/local_test/05_rsync/source",
            "destination": "state/local_test/05_rsync/dest/mirror_no_delete",
            "generate_local_test_artifacts": True,
            "generate_destination_extra": True,
            "delete": False,
            "allow_delete": False,
            "require_source_exists": True,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": True,
            "copy_contents": True,
            "sudo_read": False,
        },
        "local-scratch-mirror-delete-explicit": {
            "source": "state/local_test/05_rsync/source",
            "destination": "state/local_test/05_rsync/dest/mirror_delete_explicit",
            "generate_local_test_artifacts": True,
            "generate_destination_extra": True,
            "delete": True,
            "allow_delete": True,
            "require_source_exists": True,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": True,
            "copy_contents": True,
            "sudo_read": False,
        },
        "rescuezilla-image-staging": {
            "source": "state/rescuezilla_images",
            "destination": "state/staging/rescuezilla_images",
            "delete": False,
            "allow_delete": False,
            "required": False,
            "require_source_exists": False,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": False,
            "copy_contents": True,
            "sudo_read": False,
        },
        "manifest-tree-staging": {
            "source": "state/dry_runs;state/integrity_manifests",
            "destination": "state/staging/manifest_tree",
            "delete": False,
            "allow_delete": False,
            "required": False,
            "require_source_exists": False,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": False,
            "copy_contents": True,
            "sudo_read": False,
        },
        "large-artifact-staging": {
            "source": "state/exports",
            "destination": "state/staging/large_artifacts",
            "delete": False,
            "allow_delete": False,
            "required": False,
            "require_source_exists": False,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": False,
            "copy_contents": True,
            "sudo_read": False,
        },
        "vm-cold-copy": {
            "source": "",
            "destination": "",
            "delete": False,
            "allow_delete": False,
            "required": False,
            "require_source_exists": True,
            "require_destination_parent_exists": False,
            "destination_must_be_under_project": False,
            "copy_contents": False,
            "sudo_read": True,
            "vm_disk_guard": True,
        },
    },
    "vm_guard": {
        "libvirt_uri": "qemu:///system",
        "allowed_extensions": ".qcow2;.raw;.img;.vdi;.vmdk",
        "known_disk_roots": "/var/lib/libvirt/images;/home/wantless/PycharmProjects/automation/recovery/state/vm_cold_copies",
        "require_regular_file": True,
        "fail_if_extension_not_allowed": True,
        "fail_if_domain_running": True,
        "fail_if_source_matches_running_domain_disk": True,
        "require_domain_for_known_vm_roots": False,
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
    path = PROJECT_ROOT / "configs" / "05_rsync.yaml"
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


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def cmd_path(name: str) -> str:
    value = str(cfg_get(f"commands.{name}", name))
    if "/" in value:
        return value
    return shutil.which(value) or value


RSYNC = cmd_path("rsync")
VIRSH = cmd_path("virsh")


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def resolve_path(value: str | Path) -> Path:
    p = Path(str(value)).expanduser()
    if not p.is_absolute():
        p = PROJECT_ROOT / p
    return p.resolve()


def rel(path: str | Path) -> str:
    p = Path(path).resolve()
    try:
        return str(p.relative_to(PROJECT_ROOT))
    except ValueError:
        return str(p)


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/05_rsync")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)):
        config_path = PROJECT_ROOT / "configs" / "05_rsync.yaml"
        if config_path.exists():
            shutil.copy2(config_path, run_dir / "05_rsync.config.snapshot.yaml")
    return run_dir


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
            "name": "rsync",
            "script": SCRIPT_NAME,
            "rsync_path": RSYNC,
            "virsh_path": VIRSH,
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
    }


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_path = run_dir / str(cfg_get("policy.report_name", "rsync_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], *, sudo: bool = False, cwd: Path | None = None) -> dict[str, Any]:
    final_argv = argv[:]
    if sudo and os.geteuid() != 0:
        sudo_path = shutil.which("sudo")
        if not sudo_path:
            return {"argv": argv, "returncode": 127, "stdout": "", "stderr": "sudo is required but unavailable"}
        final_argv = [sudo_path] + final_argv
    proc = subprocess.run(final_argv, text=True, capture_output=True, cwd=str(cwd) if cwd else None)
    return {"argv": final_argv, "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    report["failures"].append(f"required tool missing for {label}: {path}")
    return False


def scoped_delete_token(profile_name: str | None) -> str:
    prefix = str(cfg_get("policy.delete_confirmation_prefix", "RSYNC_DELETE"))
    return f"{prefix}:{profile_name or 'manual'}"


def restore_token(destination: Path) -> str:
    return f"{cfg_get('policy.restore_confirmation_prefix', 'RESTORE_RSYNC')}:{destination.resolve()}"


def vm_cold_copy_token(source: Path) -> str:
    return f"{cfg_get('policy.vm_cold_copy_confirmation_prefix', 'COLD_COPY_VM')}:{source.resolve()}"


def local_test_root() -> Path:
    return resolve_path(str(cfg_get("project.local_test_root", "state/local_test/05_rsync")))


def profile_config(name: str) -> dict[str, Any]:
    profiles = cfg_get("profiles", {})
    if not isinstance(profiles, dict) or name not in profiles:
        raise SystemExit(f"unknown rsync profile: {name}")
    return deepcopy(profiles[name])


def protected_destinations() -> list[Path]:
    paths = split_semicolon(cfg_get("protected_destinations.paths", ""))
    return [Path(p).resolve() for p in paths]


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def validate_source_destination(source: Path, destination: Path, profile: dict[str, Any], report: dict[str, Any], *, delete_enabled: bool) -> None:
    if boolish(profile.get("require_source_exists", True)) and not source.exists():
        report["failures"].append(f"source does not exist: {source}")
    if not source.exists() and not boolish(profile.get("require_source_exists", True)):
        report["warnings"].append(f"source absent; command is a no-op until owning row produces artifacts: {source}")

    if boolish(profile.get("require_destination_parent_exists", False)) and not destination.parent.exists():
        report["failures"].append(f"destination parent does not exist: {destination.parent}")

    if boolish(profile.get("destination_must_be_under_project", False)) and not is_under(destination, PROJECT_ROOT):
        report["failures"].append(f"profile requires destination under project root: {destination}")

    if boolish(cfg_get("policy.refuse_root_destination", True)):
        for protected in protected_destinations():
            if destination.resolve() == protected:
                report["failures"].append(f"refusing protected destination: {destination}")

    if source.exists() and destination.exists():
        if boolish(cfg_get("policy.refuse_source_equals_destination", True)) and source.resolve() == destination.resolve():
            report["failures"].append(f"source and destination are the same path: {source}")
        if boolish(cfg_get("policy.refuse_destination_inside_source", True)) and is_under(destination, source):
            report["failures"].append(f"refusing destination inside source because it can recurse: {destination} inside {source}")
        if boolish(cfg_get("policy.refuse_source_inside_destination", False)) and is_under(source, destination):
            report["failures"].append(f"refusing source inside destination: {source} inside {destination}")

    if delete_enabled:
        if not boolish(profile.get("allow_delete", False)):
            report["failures"].append("delete requested but profile does not allow delete")
        for protected in protected_destinations():
            if destination.resolve() == protected or is_under(protected, destination):
                report["failures"].append(f"delete destination overlaps protected path {protected}: {destination}")


def ensure_local_test_artifacts(profile: dict[str, Any]) -> None:
    if not boolish(profile.get("generate_local_test_artifacts", False)):
        return
    source = resolve_path(str(profile.get("source")))
    nested = source / "nested"
    nested.mkdir(parents=True, exist_ok=True)
    (source / "alpha.txt").write_text("wantless recovery rsync local scratch alpha\n", encoding="utf-8")
    (nested / "beta with spaces.txt").write_text("wantless recovery rsync local scratch beta\n", encoding="utf-8")
    (source / "deterministic.bin").write_bytes(bytes((i * 31) % 256 for i in range(8192)))
    (source / "README.local_test.txt").write_text(
        "Generated by Row 05 rsync local scratch proof. Safe to recreate.\n",
        encoding="utf-8",
    )
    if boolish(profile.get("generate_destination_extra", False)):
        destination = resolve_path(str(profile.get("destination")))
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "destination_only_extra.txt").write_text(
            "Destination-only file used to prove delete/no-delete behavior.\n",
            encoding="utf-8",
        )


def source_args_for_rsync(source: Path, profile: dict[str, Any]) -> list[str]:
    if source.is_dir() and boolish(profile.get("copy_contents", True)):
        return [str(source) + "/"]
    return [str(source)]


def rsync_flags(*, dry_run: bool, delete_enabled: bool) -> list[str]:
    defaults = cfg_get("rsync_defaults", {})
    flags: list[str] = []
    if boolish(defaults.get("archive", True)):
        flags.append("--archive")
    if boolish(defaults.get("xattrs", True)):
        flags.append("--xattrs")
    if boolish(defaults.get("acls", True)):
        flags.append("--acls")
    if boolish(defaults.get("numeric_ids", True)):
        flags.append("--numeric-ids")
    if boolish(defaults.get("preserve_hard_links", True)):
        flags.append("--hard-links")
    if boolish(defaults.get("sparse", True)):
        flags.append("--sparse")
    if boolish(defaults.get("itemize_changes", True)):
        flags.append("--itemize-changes")
        out_format = str(defaults.get("out_format", "%i %n%L") or "")
        if out_format:
            flags.append(f"--out-format={out_format}")
    if boolish(defaults.get("stats", True)):
        flags.append("--stats")
    if boolish(defaults.get("human_readable", True)):
        flags.append("--human-readable")
    if boolish(defaults.get("protect_args", True)):
        flags.append("--protect-args")
    if boolish(defaults.get("checksum", False)):
        flags.append("--checksum")
    if boolish(defaults.get("one_file_system", False)):
        flags.append("--one-file-system")
    if boolish(defaults.get("copy_links", False)):
        flags.append("--copy-links")
    if boolish(defaults.get("partial", False)):
        flags.append("--partial")
    if boolish(defaults.get("inplace", False)):
        flags.append("--inplace")
    if dry_run:
        flags.append("--dry-run")
    if delete_enabled:
        flags.append("--delete")
    extra = split_semicolon(defaults.get("extra_args", ""))
    flags.extend(extra)
    return flags


def parse_itemized_text(text: str) -> dict[str, Any]:
    lines = [line for line in text.splitlines() if line.strip()]
    deleted = [line for line in lines if line.startswith("*deleting")]
    itemized = [line for line in lines if re.match(r"^[<>ch.*]", line)]
    created = [line for line in itemized if line.startswith(">f+++++++++") or line.startswith("cd+++++++++")]
    updated = [line for line in itemized if line.startswith(">") and not line.startswith(">f+++++++++")]
    changed = [line for line in itemized if not line.startswith(".")]
    return {
        "line_count": len(lines),
        "itemized_count": len(itemized),
        "changed_count": len(changed),
        "deleted_count": len(deleted),
        "created_count": len(created),
        "updated_count": len(updated),
        "sample": lines[:50],
    }


def write_itemized_summary(path: Path, run_dir: Path) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "line_count": 0, "changed_count": 0, "deleted_count": 0, "created_count": 0, "updated_count": 0, "error": "path missing"}
    summary = parse_itemized_text(path.read_text(encoding="utf-8", errors="replace"))
    summary["path"] = rel(path)
    write_json(run_dir / "itemized_summary.json", summary)
    return summary


def execute_rsync(profile_name: str, profile: dict[str, Any], source: Path, destination: Path, run_dir: Path, report: dict[str, Any], *, dry_run: bool, allow_delete: bool, confirm_delete: str | None) -> None:
    if not source.exists() and not boolish(profile.get("require_source_exists", True)):
        skip = {
            "profile": profile_name,
            "source": str(source),
            "destination": str(destination),
            "dry_run": dry_run,
            "reason": "source absent and profile require_source_exists=false",
        }
        report.setdefault("skipped_transfers", []).append(skip)
        report["warnings"].append(f"skipping absent optional source: {source}")
        return

    require_tool(RSYNC, report, "rsync")
    delete_enabled = boolish(profile.get("delete", False)) and allow_delete
    if boolish(profile.get("delete", False)) and not allow_delete:
        report["warnings"].append("profile has delete=true but delete was not enabled for this invocation; running without --delete")
    if delete_enabled and boolish(cfg_get("policy.require_delete_confirmation", True)):
        legacy_phrase = str(cfg_get("policy.delete_confirmation_phrase", "ALLOW_RSYNC_DELETE"))
        scoped_token = scoped_delete_token(profile_name)
        if confirm_delete not in {scoped_token, legacy_phrase}:
            report["failures"].append(f"delete requires --confirm-delete {scoped_token!r}")
        if boolish(cfg_get("policy.delete_destination_must_be_under_local_test", True)) and not is_under(destination, local_test_root()):
            report["failures"].append(f"delete is limited to local rsync proof root unless policy is changed: {destination}")
    validate_source_destination(source, destination, profile, report, delete_enabled=delete_enabled)
    if report["failures"]:
        return

    if not dry_run:
        destination.mkdir(parents=True, exist_ok=True)
    elif is_under(destination, local_test_root()):
        destination.parent.mkdir(parents=True, exist_ok=True)

    argv = [RSYNC] + rsync_flags(dry_run=dry_run, delete_enabled=delete_enabled) + source_args_for_rsync(source, profile) + [str(destination)]
    result = run_cmd(argv, sudo=boolish(profile.get("sudo_read", False)))

    stdout_path = run_dir / str(cfg_get("policy.stdout_name", "rsync.stdout.txt"))
    stderr_path = run_dir / str(cfg_get("policy.stderr_name", "rsync.stderr.txt"))
    itemized_path = run_dir / str(cfg_get("policy.itemized_name", "itemized.log"))
    write_text(stdout_path, result["stdout"])
    write_text(stderr_path, result["stderr"])
    write_text(itemized_path, result["stdout"])

    report["commands"].append({
        "argv": result["argv"],
        "returncode": result["returncode"],
        "stdout_path": rel(stdout_path),
        "stderr_path": rel(stderr_path),
    })
    report["rsync"] = {
        "argv": result["argv"],
        "returncode": result["returncode"],
        "dry_run": dry_run,
        "delete_enabled": delete_enabled,
        "stdout_path": rel(stdout_path),
        "stderr_path": rel(stderr_path),
        "itemized_path": rel(itemized_path),
    }
    report["itemized_summary"] = write_itemized_summary(itemized_path, run_dir)
    if result["returncode"] != 0:
        report["failures"].append(f"rsync exited with status {result['returncode']}")


def execute_profile(profile_name: str, args: argparse.Namespace, command: str, *, force_dry_run: bool | None = None) -> int:
    profile_name = profile_name or "local-scratch-copy"
    profile = profile_config(profile_name)

    explicit_transfer = bool(args.source or args.destination)
    if explicit_transfer and args.profile is None and profile_name == "local-scratch-copy":
        profile["generate_local_artifacts"] = False
        profile["generate_local_test_artifacts"] = False
        profile["generate_destination_extra"] = False
        profile["destination_must_be_under_project"] = False
        profile["require_source_exists"] = True

    if explicit_transfer and profile_name in {"rescuezilla-image-staging", "manifest-tree-staging", "large-artifact-staging"}:
        profile["destination_must_be_under_project"] = False

    if command in {"restore-preview", "restore-guarded"} and args.source and args.destination:
        profile["generate_local_artifacts"] = False
        profile["generate_local_test_artifacts"] = False
        profile["generate_destination_extra"] = False
        profile["destination_must_be_under_project"] = False
        profile["require_source_exists"] = True
        profile["copy_contents"] = True

    ensure_local_test_artifacts(profile)
    run_dir = make_run_dir(command)
    report = report_base(command, run_dir)
    report["profile"] = profile_name
    report["mode"] = "dry-run" if not args.execute else "execute"

    source_text = args.source or str(profile.get("source", ""))
    destination_text = args.destination or str(profile.get("destination", ""))
    sources = split_semicolon(source_text)
    if not sources:
        report["failures"].append("source is required through --source or profile source")
        return finalize_report(report, run_dir)
    if not destination_text:
        report["failures"].append("destination is required through --destination or profile destination")
        return finalize_report(report, run_dir)

    dry_run = not boolish(args.execute)
    if force_dry_run is not None:
        dry_run = force_dry_run
        report["mode"] = "dry-run" if dry_run else "execute"

    destination_base = resolve_path(destination_text)

    if command == "restore-guarded" and not dry_run:
        expected = restore_token(destination_base)
        token = getattr(args, "confirm_token", None) or getattr(args, "confirm_restore", None)
        if token != expected:
            report["failures"].append(f"restore-guarded --execute requires --confirm-token {expected}")
            return finalize_report(report, run_dir)

    attempted_transfers = 0
    skipped_sources: list[dict[str, Any]] = []

    for source_part in sources:
        source = resolve_path(source_part)
        destination = destination_base
        if len(sources) > 1:
            destination = destination_base / source.name

        if not source.exists() and not boolish(profile.get("require_source_exists", True)):
            skip = {
                "source": str(source),
                "destination": str(destination),
                "dry_run": dry_run,
                "reason": "source_absent_optional_profile",
            }
            skipped_sources.append(skip)
            report.setdefault("transfers", []).append(skip)
            report["warnings"].append(f"source absent; skipped optional transfer until owning row produces artifacts: {source}")
            continue

        attempted_transfers += 1
        report.setdefault("transfers", []).append({"source": str(source), "destination": str(destination), "dry_run": dry_run})
        execute_rsync(
            profile_name,
            profile,
            source,
            destination,
            run_dir,
            report,
            dry_run=dry_run,
            allow_delete=boolish(args.allow_delete),
            confirm_delete=args.confirm_delete,
        )

    report["source"] = source_text
    report["destination"] = destination_text
    report["attempted_transfer_count"] = attempted_transfers
    if skipped_sources:
        report["skipped_sources"] = skipped_sources

    return finalize_report(report, run_dir)

def vm_extension_allowed(source: Path) -> bool:
    allowed = {item.lower() for item in split_semicolon(cfg_get("vm_guard.allowed_extensions", ""))}
    if not allowed:
        return True
    return source.suffix.lower() in allowed


def virsh_available() -> bool:
    return Path(VIRSH).exists() or shutil.which(VIRSH) is not None


def virsh_cmd(args: list[str]) -> dict[str, Any]:
    uri = str(cfg_get("vm_guard.libvirt_uri", "qemu:///system"))
    return run_cmd([VIRSH, "-c", uri] + args)


def assert_no_live_vm_disk_impl(source: Path, domain: str | None, run_dir: Path, report: dict[str, Any]) -> dict[str, Any]:
    guard = {"ok": True, "source": str(source.resolve()), "domain": domain, "failures": [], "warnings": [], "running_domains": []}
    if boolish(cfg_get("vm_guard.require_regular_file", True)) and (not source.exists() or not source.is_file()):
        guard["failures"].append(f"VM disk guard requires an existing regular file: {source}")
    if boolish(cfg_get("vm_guard.fail_if_extension_not_allowed", True)) and source.exists() and not vm_extension_allowed(source):
        guard["failures"].append(f"source extension {source.suffix!r} is not configured as a VM disk extension")
    if not virsh_available():
        guard["warnings"].append(f"virsh is not available at {VIRSH}; live-domain matching skipped")
        guard["ok"] = not guard["failures"]
        report["vm_guard"] = guard
        report["failures"].extend(guard["failures"])
        report["warnings"].extend(guard["warnings"])
        write_json(run_dir / "vm_guard.json", guard)
        return guard

    if domain:
        state_result = virsh_cmd(["domstate", domain])
        report["commands"].append({"argv": state_result["argv"], "returncode": state_result["returncode"], "stderr": state_result["stderr"]})
        if state_result["returncode"] != 0:
            guard["failures"].append(f"could not determine domain state for {domain}: {state_result['stderr'].strip()}")
        else:
            state = state_result["stdout"].strip().lower()
            guard["domain_state"] = state
            if state not in {"shut off", "shutoff"}:
                guard["failures"].append(f"domain {domain} is not shut off: {state}")

    list_result = virsh_cmd(["list", "--name", "--state-running"])
    report["commands"].append({"argv": list_result["argv"], "returncode": list_result["returncode"], "stderr": list_result["stderr"]})
    running = [line.strip() for line in list_result["stdout"].splitlines() if line.strip()]
    guard["running_domains"] = running
    source_text = str(source.resolve())

    for running_domain in running:
        xml_result = virsh_cmd(["dumpxml", running_domain])
        report["commands"].append({"argv": xml_result["argv"], "returncode": xml_result["returncode"], "stderr": xml_result["stderr"]})
        if xml_result["returncode"] != 0:
            guard["warnings"].append(f"could not dumpxml running domain {running_domain}")
            continue
        if source_text in xml_result["stdout"]:
            guard["failures"].append(f"source path belongs to running domain {running_domain}: {source_text}")

    known_roots = [resolve_path(p) for p in split_semicolon(cfg_get("vm_guard.known_disk_roots", ""))]
    if not domain and boolish(cfg_get("vm_guard.require_domain_for_known_vm_roots", False)):
        for root in known_roots:
            if is_under(source, root):
                guard["failures"].append(f"--domain is required for known VM disk root: {source}")

    guard["ok"] = not guard["failures"]
    report["vm_guard"] = guard
    report["failures"].extend(guard["failures"])
    report["warnings"].extend(guard["warnings"])
    write_json(run_dir / "vm_guard.json", guard)
    return guard


def cmd_assert_no_live_vm_disk(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-no-live-vm-disk")
    report = report_base("assert-no-live-vm-disk", run_dir)
    report["mode"] = "assert"
    source = resolve_path(args.source)
    assert_no_live_vm_disk_impl(source, args.domain, run_dir, report)
    return finalize_report(report, run_dir)


def cmd_cold_copy_vm_disk(args: argparse.Namespace) -> int:
    profile = profile_config("vm-cold-copy")
    if not args.source or not args.destination:
        raise SystemExit("cold-copy-vm-disk requires --source and --destination")
    run_dir = make_run_dir("cold-copy-vm-disk")
    report = report_base("cold-copy-vm-disk", run_dir)
    report["profile"] = "vm-cold-copy"
    report["mode"] = "execute" if args.execute else "dry-run"
    source = resolve_path(args.source)
    destination = resolve_path(args.destination)
    assert_no_live_vm_disk_impl(source, args.domain, run_dir, report)

    if not vm_extension_allowed(source):
        report["failures"].append(f"cold-copy-vm-disk source extension {source.suffix!r} is not allowed by vm_guard.allowed_extensions")

    if boolish(args.execute):
        expected = vm_cold_copy_token(source)
        token = getattr(args, "confirm_token", None) or getattr(args, "confirm_cold_copy", None)
        if token != expected:
            report["failures"].append(f"cold-copy-vm-disk --execute requires --confirm-token {expected}")
        if not virsh_available():
            report["failures"].append("cold-copy-vm-disk --execute requires virsh/libvirt guard availability")

    if not report["failures"]:
        execute_rsync(
            "vm-cold-copy",
            profile,
            source,
            destination,
            run_dir,
            report,
            dry_run=not boolish(args.execute),
            allow_delete=False,
            confirm_delete=None,
        )
    report["source"] = str(source)
    report["destination"] = str(destination)
    return finalize_report(report, run_dir)


def cmd_log_itemized(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("log-itemized")
    report = report_base("log-itemized", run_dir)
    report["mode"] = "summary"
    path = resolve_path(args.path)
    summary = write_itemized_summary(path, run_dir)
    report["itemized_summary"] = summary
    if summary.get("error"):
        report["failures"].append(str(summary["error"]))
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_transfer_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--profile", default=None)
        p.add_argument("--source", default=None)
        p.add_argument("--destination", default=None)
        p.add_argument("--execute", action="store_true", help="Perform the copy. Without this, rsync runs with --dry-run.")
        p.add_argument("--allow-delete", action="store_true", help="Allow --delete only for profiles that explicitly allow delete.")
        p.add_argument("--delete", dest="allow_delete", action="store_true", help="Compatibility alias for --allow-delete; still requires exact confirmation.")
        p.add_argument("--confirm-delete", default=None)
        p.add_argument("--confirm-token", default=None)
        p.add_argument("--confirm-restore", default=None, help=argparse.SUPPRESS)

    p = sub.add_parser("dry-run")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "local-scratch-copy", a, "dry-run", force_dry_run=True))

    p = sub.add_parser("stage-directory")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "local-scratch-copy", a, "stage-directory"))

    p = sub.add_parser("stage-rescuezilla-image")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "rescuezilla-image-staging", a, "stage-rescuezilla-image"))

    p = sub.add_parser("stage-manifest-tree")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "manifest-tree-staging", a, "stage-manifest-tree"))

    p = sub.add_parser("stage-large-artifact")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "large-artifact-staging", a, "stage-large-artifact"))

    p = sub.add_parser("restore-preview")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "local-scratch-copy", a, "restore-preview", force_dry_run=True))

    p = sub.add_parser("restore-guarded")
    add_transfer_args(p)
    p.set_defaults(func=lambda a: execute_profile(a.profile or "local-scratch-copy", a, "restore-guarded"))

    p = sub.add_parser("assert-no-live-vm-disk")
    p.add_argument("--source", required=True)
    p.add_argument("--domain", default=None)
    p.set_defaults(func=cmd_assert_no_live_vm_disk)

    p = sub.add_parser("cold-copy-vm-disk")
    p.add_argument("--source", required=True)
    p.add_argument("--destination", required=True)
    p.add_argument("--domain", default=None)
    p.add_argument("--confirm-token", default=None)
    p.add_argument("--confirm-cold-copy", default=None, help=argparse.SUPPRESS)
    p.add_argument("--execute", action="store_true")
    p.set_defaults(func=cmd_cold_copy_vm_disk)

    p = sub.add_parser("log-itemized")
    p.add_argument("--path", required=True)
    p.set_defaults(func=cmd_log_itemized)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args(ARGS)
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