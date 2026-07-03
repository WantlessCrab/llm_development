#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PYCODE'
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
SCRIPT_NAME = "09_journalctl.sh"
SCHEMA_NAME = "recovery.journalctl.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "journalctl",
        "verified_systemd_version": "255.4-1ubuntu8.15",
        "layer": "09_execution_evidence_failure_diagnostics",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/09_journalctl",
        "local_test_root": "state/local_test/09_journalctl",
    },
    "commands": {
        "journalctl": "/usr/bin/journalctl",
        "systemctl": "/usr/bin/systemctl",
    },
    "policy": {
        "default_since": "24 hours ago",
        "default_lines": 800,
        "failure_context_since": "72 hours ago",
        "previous_boot_lines": 1200,
        "export_json_lines": 1000,
        "export_native_lines": 1000,
        "priority_warning": "warning..alert",
        "priority_error": "err..alert",
        "copy_config_snapshot_into_run": True,
        "report_name": "journalctl_report.json",
        "text_suffix": ".txt",
        "json_suffix": ".jsonl",
        "export_suffix": ".journal-export",
        "use_sudo_for_system_journal": False,
        "capture_previous_boot_if_available": True,
        "fail_if_journalctl_missing": True,
    },
    "recovery_units": {
        "system": "wantless-recovery-preflight.service;wantless-recovery-backup.service;wantless-recovery-backup.timer;wantless-recovery-verify.service",
        "user": "wantless-desktop-capture.service",
        "timer": "wantless-recovery-backup.timer",
        "backup_service": "wantless-recovery-backup.service",
        "verify_service": "wantless-recovery-verify.service",
        "preflight_service": "wantless-recovery-preflight.service",
    },
    "related_units": {
        "docker": "docker.service;containerd.service;portainer.service",
        "libvirt": "libvirtd.service;virtqemud.service;virtlogd.service;virtlockd.service;qemu-kvm.service;libvirt-guests.service;run-qemu.mount",
        "postgres": "postgresql.service;llm-postgres.service",
    },
    "patterns": {
        "storage_kernel_regex": r"(?i)(nvme|ata[0-9]|ahci|sd[a-z]|scsi|usb|uas|blk_update_request|i/o error|buffer i/o|ext4-fs error|ext4-fs warning|btrfs|xfs|dm-|device-mapper|crypt|luks|filesystem|read-only file system|reset high-speed usb|failed command|medium error|uncorrectable|timeout|link is slow|read error|write error|smart|temperature)",
        "docker_libvirt_regex": r"(?i)(docker|containerd|portainer|libvirt|libvirtd|virtqemud|virtlogd|virtlockd|qemu|kvm|swtpm|dnsmasq|virbr0|tap|vnet)",
        "postgres_dump_regex": r"(?i)(postgres|postgresql|pg_dump|pg_restore|pg_dumpall|llm-postgres|pgvector|database system|checkpoint|schema|relation|role|permission denied|connection refused|fatal|panic|error)",
        "recovery_failure_regex": r"(?i)(wantless-recovery|borg|borgmatic|cryptsetup|luks|rescuezilla|rsync|sha256sum|b3sum|smartctl|journalctl|failed|failure|error|timeout|permission denied|no such file|not mounted|mountpoint)",
    },
    "exports": {
        "default_output_mode": "short-iso",
        "json_mode": "json",
        "native_mode": "export",
        "include_boots_in_failure_context": "0;-1",
    },
    "kernel_storage": {
        "include_full_kernel_pattern_scan": True,
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
    path = PROJECT_ROOT / "configs" / "09_journalctl.yaml"
    return deep_merge(DEFAULT_CONFIG, parse_simple_yaml(path)) if path.exists() else deepcopy(DEFAULT_CONFIG)


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
    return value if "/" in value else (shutil.which(value) or value)


JOURNALCTL = cmd_path("journalctl")
SYSTEMCTL = cmd_path("systemctl")


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
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/09_journalctl")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "09_journalctl.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "09_journalctl.config.snapshot.yaml")
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "journalctl",
            "script": SCRIPT_NAME,
            "journalctl_path": JOURNALCTL,
            "systemctl_path": SYSTEMCTL,
            "journalctl_version": None,
            "systemd_version": None,
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
        "exports": [],
        "summaries": [],
    }


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_path = run_dir / str(cfg_get("policy.report_name", "journalctl_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def sudo_prefix() -> list[str] | None:
    if os.geteuid() == 0:
        return []
    sudo = shutil.which("sudo")
    if sudo:
        return [sudo]
    return None


def decode_lossy(value: bytes) -> str:
    return value.decode("utf-8", errors="replace")


def run_cmd(
    argv: list[str],
    report: dict[str, Any],
    *,
    label: str,
    sudo: bool = False,
    check: bool = False,
    binary_stdout: bool = False,
) -> dict[str, Any]:
    final_argv = argv[:]
    if sudo:
        prefix = sudo_prefix()
        if prefix is None:
            result = {"argv": argv, "returncode": 127, "stdout": b"" if binary_stdout else "", "stderr": "sudo required but unavailable"}
            report["commands"].append({"argv": argv, "returncode": 127, "stderr": result["stderr"]})
            if check:
                report["failures"].append(result["stderr"])
            return result
        final_argv = prefix + final_argv
    proc = subprocess.run(final_argv, capture_output=True)
    run_dir = resolve_path(report["run_dir"])
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    stdout_suffix = "stdout.bin" if binary_stdout else "stdout.txt"
    stdout_path = run_dir / f"{safe}.{stdout_suffix}"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    if binary_stdout:
        write_bytes(stdout_path, proc.stdout)
        stdout_value: bytes | str = proc.stdout
    else:
        stdout_text = decode_lossy(proc.stdout)
        write_text(stdout_path, stdout_text)
        stdout_value = stdout_text
    stderr_text = decode_lossy(proc.stderr)
    write_text(stderr_path, stderr_text)
    result = {"argv": final_argv, "returncode": proc.returncode, "stdout": stdout_value, "stderr": stderr_text}
    report["commands"].append({
        "argv": final_argv,
        "returncode": proc.returncode,
        "stdout_path": rel(stdout_path),
        "stderr_path": rel(stderr_path),
        "stderr": stderr_text,
    })
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(final_argv)} :: {stderr_text.strip()}")
    return result


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    msg = f"{label} not found: {path}"
    if boolish(cfg_get("policy.fail_if_journalctl_missing", True)) or label != "journalctl":
        report["failures"].append(msg)
    else:
        report["warnings"].append(msg)
    return False


def capture_versions(report: dict[str, Any]) -> None:
    if require_tool(JOURNALCTL, report, "journalctl"):
        result = run_cmd([JOURNALCTL, "--version"], report, label="journalctl_version")
        first = str(result["stdout"]).splitlines()[0] if str(result["stdout"]).splitlines() else str(result["stderr"]).strip()
        report["tool"]["journalctl_version"] = first
        report["tool"]["systemd_version"] = first


def default_since(args: argparse.Namespace) -> str:
    return args.since or str(cfg_get("policy.default_since", "24 hours ago"))


def default_lines(args: argparse.Namespace, key: str = "policy.default_lines") -> int:
    return int(args.lines if args.lines is not None else cfg_get(key, cfg_get("policy.default_lines", 800)))


def command_sudo(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "sudo", False)) or boolish(cfg_get("policy.use_sudo_for_system_journal", False))


def journal_base(
    *,
    boot: str | int | None = None,
    since: str | None = None,
    lines: int | None = None,
    output: str | None = None,
    priority: str | None = None,
    user: bool = False,
) -> list[str]:
    argv = [JOURNALCTL, "--no-pager"]
    if user:
        argv.append("--user")
    if boot is not None:
        argv.extend(["-b", str(boot)])
    if since:
        argv.extend(["--since", since])
    if lines is not None:
        argv.extend(["-n", str(lines)])
    if output:
        argv.extend(["-o", output])
    if priority:
        argv.extend(["-p", priority])
    return argv


def export_result(report: dict[str, Any], label: str, result: dict[str, Any], *, kind: str, run_dir: Path) -> Path:
    suffix = str(cfg_get("policy.text_suffix", ".txt"))
    if kind == "json":
        suffix = str(cfg_get("policy.json_suffix", ".jsonl"))
    elif kind == "native":
        suffix = str(cfg_get("policy.export_suffix", ".journal-export"))
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    path = run_dir / f"{safe}{suffix}"
    stdout = result.get("stdout", b"" if kind == "native" else "")
    if isinstance(stdout, bytes):
        write_bytes(path, stdout)
        line_count = None
        byte_count = len(stdout)
    else:
        write_text(path, stdout)
        line_count = len(stdout.splitlines())
        byte_count = len(stdout.encode("utf-8"))
    summary = {"label": label, "kind": kind, "path": rel(path), "bytes": byte_count, "returncode": result["returncode"]}
    if line_count is not None:
        summary["line_count"] = line_count
    report.setdefault("exports", []).append(summary)
    return path


def run_journal(
    report: dict[str, Any],
    run_dir: Path,
    label: str,
    argv: list[str],
    *,
    kind: str = "text",
    warn_on_error: bool = True,
    sudo: bool = False,
) -> dict[str, Any]:
    result = run_cmd(argv, report, label=f"journal_{label}", sudo=sudo, binary_stdout=(kind == "native"))
    export_result(report, label, result, kind=kind, run_dir=run_dir)
    if result["returncode"] != 0:
        msg = f"journal capture returned {result['returncode']} for {label}: {result['stderr'].strip()}"
        if warn_on_error:
            report["warnings"].append(msg)
        else:
            report["failures"].append(msg)
    return result


def run_systemctl(report: dict[str, Any], label: str, args: list[str], *, user: bool = False, warn_on_error: bool = True, sudo: bool = False) -> dict[str, Any]:
    argv = [SYSTEMCTL]
    if user:
        argv.append("--user")
    argv.extend(args)
    result = run_cmd(argv, report, label=f"systemctl_{label}", sudo=(sudo and not user))
    if result["returncode"] != 0 and warn_on_error:
        report["warnings"].append(f"systemctl returned {result['returncode']} for {label}: {result['stderr'].strip()}")
    return result


def configured_units(scope: str) -> list[str]:
    return split_semicolon(cfg_get(f"recovery_units.{scope}", ""))


def related_units(kind: str) -> list[str]:
    return split_semicolon(cfg_get(f"related_units.{kind}", ""))


def filter_text_to_file(source_text: str, pattern: str, output_path: Path) -> dict[str, Any]:
    regex = re.compile(pattern)
    matched = [line for line in source_text.splitlines() if regex.search(line)]
    write_text(output_path, "\n".join(matched) + ("\n" if matched else ""))
    return {"path": rel(output_path), "match_count": len(matched), "pattern": pattern, "sample": matched[:50]}


def cmd_list_boots(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("list-boots")
    report = report_base("list-boots", run_dir)
    report["mode"] = "summary"
    capture_versions(report)
    if require_tool(JOURNALCTL, report, "journalctl"):
        run_journal(report, run_dir, "list_boots", [JOURNALCTL, "--list-boots", "--no-pager"], warn_on_error=False, sudo=command_sudo(args))
    return finalize_report(report, run_dir)


def cmd_capture_recovery_units(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-recovery-units")
    report = report_base("capture-recovery-units", run_dir)
    report.update({"mode": "evidence", "since": default_since(args)})
    capture_versions(report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    lines = default_lines(args)
    since = default_since(args)
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    for unit in configured_units("system"):
        report.setdefault("units", []).append({"scope": "system", "name": unit})
        run_systemctl(report, f"system_status_{unit}", ["--no-pager", "--full", "status", unit], sudo=sudo)
        run_systemctl(report, f"system_show_{unit}", ["show", unit], sudo=sudo)
        run_journal(report, run_dir, f"system_unit_{unit}", journal_base(since=since, lines=lines, output=output) + ["-u", unit], sudo=sudo)
        run_journal(report, run_dir, f"system_unit_{unit}_json", journal_base(since=since, lines=lines, output=str(cfg_get("exports.json_mode", "json"))) + ["-u", unit], kind="json", sudo=sudo)
    for unit in configured_units("user"):
        report.setdefault("units", []).append({"scope": "user", "name": unit})
        run_systemctl(report, f"user_status_{unit}", ["--no-pager", "--full", "status", unit], user=True)
        run_systemctl(report, f"user_show_{unit}", ["show", unit], user=True)
        run_journal(report, run_dir, f"user_unit_{unit}", journal_base(since=since, lines=lines, output=output, user=True) + ["-u", unit])
        run_journal(report, run_dir, f"user_unit_{unit}_json", journal_base(since=since, lines=lines, output=str(cfg_get("exports.json_mode", "json")), user=True) + ["-u", unit], kind="json")
    return finalize_report(report, run_dir)


def cmd_capture_timer_history(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-timer-history")
    report = report_base("capture-timer-history", run_dir)
    report.update({"mode": "evidence", "since": default_since(args)})
    capture_versions(report)
    sudo = command_sudo(args)
    timer = str(cfg_get("recovery_units.timer", "wantless-recovery-backup.timer"))
    service = str(cfg_get("recovery_units.backup_service", "wantless-recovery-backup.service"))
    run_systemctl(report, "list_timers", ["list-timers", "--all", "--no-pager"], sudo=sudo)
    run_systemctl(report, f"status_{timer}", ["--no-pager", "--full", "status", timer], sudo=sudo)
    run_systemctl(report, f"show_{timer}", ["show", timer], sudo=sudo)
    run_systemctl(report, f"status_{service}", ["--no-pager", "--full", "status", service], sudo=sudo)
    run_systemctl(report, f"show_{service}", ["show", service], sudo=sudo)
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    lines = default_lines(args)
    since = default_since(args)
    for unit in [timer, service]:
        run_journal(report, run_dir, f"timer_history_{unit}", journal_base(since=since, lines=lines, output=output) + ["-u", unit], sudo=sudo)
    return finalize_report(report, run_dir)


def cmd_capture_boot_warnings(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-boot-warnings")
    report = report_base("capture-boot-warnings", run_dir)
    report.update({"mode": "evidence", "boot": args.boot})
    capture_versions(report)
    boot = args.boot if args.boot is not None else 0
    lines = default_lines(args)
    priority = args.priority or str(cfg_get("policy.priority_warning", "warning..alert"))
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    run_journal(report, run_dir, f"boot_{boot}_warnings", journal_base(boot=boot, lines=lines, output=output, priority=priority), sudo=sudo)
    run_journal(report, run_dir, f"boot_{boot}_kernel_warnings", journal_base(boot=boot, lines=lines, output=output, priority=priority) + ["-k"], sudo=sudo)
    run_journal(report, run_dir, f"boot_{boot}_warnings_json", journal_base(boot=boot, lines=lines, output=str(cfg_get("exports.json_mode", "json")), priority=priority), kind="json", sudo=sudo)
    return finalize_report(report, run_dir)


def cmd_capture_kernel_storage_warnings(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-kernel-storage-warnings")
    report = report_base("capture-kernel-storage-warnings", run_dir)
    report.update({"mode": "evidence", "boot": args.boot})
    capture_versions(report)
    boot = args.boot if args.boot is not None else 0
    lines = default_lines(args)
    priority = args.priority or str(cfg_get("policy.priority_warning", "warning..alert"))
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    warn_result = run_journal(report, run_dir, f"kernel_boot_{boot}_warnings", journal_base(boot=boot, lines=lines, output=output, priority=priority) + ["-k"], sudo=sudo)
    pattern = str(cfg_get("patterns.storage_kernel_regex"))
    source_text = str(warn_result.get("stdout", ""))
    if boolish(cfg_get("kernel_storage.include_full_kernel_pattern_scan", True)):
        full_result = run_journal(report, run_dir, f"kernel_boot_{boot}_full_pattern_source", journal_base(boot=boot, lines=lines, output=output) + ["-k"], sudo=sudo)
        source_text = str(full_result.get("stdout", ""))
    summary = filter_text_to_file(source_text, pattern, run_dir / "kernel_storage_filtered.txt")
    report.setdefault("summaries", []).append({"kind": "kernel_storage_filter", **summary})
    return finalize_report(report, run_dir)


def cmd_capture_docker_libvirt_errors(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-docker-libvirt-errors")
    report = report_base("capture-docker-libvirt-errors", run_dir)
    report.update({"mode": "evidence", "since": default_since(args)})
    capture_versions(report)
    lines = default_lines(args)
    since = default_since(args)
    priority = args.priority or str(cfg_get("policy.priority_warning", "warning..alert"))
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    units = related_units("docker") + related_units("libvirt") + related_units("postgres")
    for unit in units:
        run_journal(report, run_dir, f"related_unit_{unit}", journal_base(since=since, lines=lines, output=output, priority=priority) + ["-u", unit], sudo=sudo)
    general = run_journal(report, run_dir, "system_warning_context", journal_base(since=since, lines=lines, output=output, priority=priority), sudo=sudo)
    for key in ["docker_libvirt_regex", "postgres_dump_regex"]:
        pattern = str(cfg_get(f"patterns.{key}"))
        summary = filter_text_to_file(str(general.get("stdout", "")), pattern, run_dir / f"{key}_filtered.txt")
        report.setdefault("summaries", []).append({"kind": key, **summary})
    return finalize_report(report, run_dir)


def cmd_capture_previous_boot(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-previous-boot")
    report = report_base("capture-previous-boot", run_dir)
    report.update({"mode": "evidence", "boot": -1})
    capture_versions(report)
    lines = default_lines(args, "policy.previous_boot_lines")
    priority = args.priority or str(cfg_get("policy.priority_warning", "warning..alert"))
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    run_journal(report, run_dir, "previous_boot_warnings", journal_base(boot=-1, lines=lines, output=output, priority=priority), sudo=sudo)
    run_journal(report, run_dir, "previous_boot_kernel_warnings", journal_base(boot=-1, lines=lines, output=output, priority=priority) + ["-k"], sudo=sudo)
    return finalize_report(report, run_dir)


def cmd_export_json(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-json")
    report = report_base("export-json", run_dir)
    report.update({"mode": "export", "since": default_since(args), "boot": args.boot})
    capture_versions(report)
    user = bool(args.user)
    argv = journal_base(
        boot=args.boot,
        since=default_since(args) if args.boot is None else None,
        lines=default_lines(args, "policy.export_json_lines"),
        output=str(cfg_get("exports.json_mode", "json")),
        priority=args.priority,
        user=user,
    )
    if args.unit:
        argv.extend(["-u", args.unit])
    run_journal(report, run_dir, "operator_export_json", argv, kind="json", warn_on_error=False, sudo=(command_sudo(args) and not user))
    return finalize_report(report, run_dir)


def cmd_export_native(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-native")
    report = report_base("export-native", run_dir)
    report.update({"mode": "export", "since": default_since(args), "boot": args.boot})
    capture_versions(report)
    user = bool(args.user)
    argv = journal_base(
        boot=args.boot,
        since=default_since(args) if args.boot is None else None,
        lines=default_lines(args, "policy.export_native_lines"),
        output=str(cfg_get("exports.native_mode", "export")),
        priority=args.priority,
        user=user,
    )
    if args.unit:
        argv.extend(["-u", args.unit])
    run_journal(report, run_dir, "operator_export_native", argv, kind="native", warn_on_error=False, sudo=(command_sudo(args) and not user))
    return finalize_report(report, run_dir)


def cmd_capture_failure_context(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-failure-context")
    report = report_base("capture-failure-context", run_dir)
    report.update({"mode": "evidence", "since": args.since or str(cfg_get("policy.failure_context_since", "72 hours ago"))})
    capture_versions(report)
    since = args.since or str(cfg_get("policy.failure_context_since", "72 hours ago"))
    lines = default_lines(args)
    priority = args.priority or str(cfg_get("policy.priority_warning", "warning..alert"))
    output = str(cfg_get("exports.default_output_mode", "short-iso"))
    sudo = command_sudo(args)
    run_systemctl(report, "system_failed_units", ["--failed", "--no-pager"], sudo=sudo)
    for unit in configured_units("system"):
        run_systemctl(report, f"failure_status_{unit}", ["--no-pager", "--full", "status", unit], sudo=sudo)
        run_systemctl(report, f"failure_show_{unit}", ["show", unit], sudo=sudo)
        run_journal(report, run_dir, f"failure_recovery_{unit}", journal_base(since=since, lines=lines, output=output) + ["-u", unit], sudo=sudo)
    for unit in configured_units("user"):
        run_systemctl(report, f"failure_user_status_{unit}", ["--no-pager", "--full", "status", unit], user=True)
        run_systemctl(report, f"failure_user_show_{unit}", ["show", unit], user=True)
        run_journal(report, run_dir, f"failure_user_{unit}", journal_base(since=since, lines=lines, output=output, user=True) + ["-u", unit])
    run_systemctl(report, "failure_list_timers", ["list-timers", "--all", "--no-pager"], sudo=sudo)
    current = run_journal(report, run_dir, "failure_current_boot_warnings", journal_base(boot=0, lines=lines, output=output, priority=priority), sudo=sudo)
    previous = run_journal(report, run_dir, "failure_previous_boot_warnings", journal_base(boot=-1, lines=lines, output=output, priority=priority), sudo=sudo)
    kernel = run_journal(report, run_dir, "failure_kernel_storage_context", journal_base(boot=0, lines=lines, output=output) + ["-k"], sudo=sudo)
    related = run_journal(report, run_dir, "failure_related_services_context", journal_base(since=since, lines=lines, output=output, priority=priority), sudo=sudo)
    for key, text in [
        ("storage_kernel_regex", str(kernel.get("stdout", ""))),
        ("docker_libvirt_regex", str(related.get("stdout", ""))),
        ("postgres_dump_regex", str(related.get("stdout", ""))),
        ("recovery_failure_regex", str(current.get("stdout", "")) + "\n" + str(previous.get("stdout", ""))),
    ]:
        pattern = str(cfg_get(f"patterns.{key}"))
        summary = filter_text_to_file(text, pattern, run_dir / f"failure_{key}_filtered.txt")
        report.setdefault("summaries", []).append({"kind": key, **summary})
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--since", default=None)
        p.add_argument("--lines", type=int, default=None)
        p.add_argument("--priority", default=None)
        p.add_argument("--sudo", action="store_true", help="Use sudo for system journal/systemctl reads. Never used for --user journal reads.")

    def add_boot(p: argparse.ArgumentParser) -> None:
        p.add_argument("--boot", default=None, help="journalctl boot selector, e.g. 0, -1, or boot ID")

    p = sub.add_parser("capture-recovery-units"); add_common(p); p.set_defaults(func=cmd_capture_recovery_units)
    p = sub.add_parser("capture-boot-warnings"); add_common(p); add_boot(p); p.set_defaults(func=cmd_capture_boot_warnings)
    p = sub.add_parser("capture-kernel-storage-warnings"); add_common(p); add_boot(p); p.set_defaults(func=cmd_capture_kernel_storage_warnings)
    p = sub.add_parser("capture-docker-libvirt-errors"); add_common(p); p.set_defaults(func=cmd_capture_docker_libvirt_errors)
    p = sub.add_parser("capture-timer-history"); add_common(p); p.set_defaults(func=cmd_capture_timer_history)
    p = sub.add_parser("export-json"); add_common(p); add_boot(p); p.add_argument("--unit", default=None); p.add_argument("--user", action="store_true"); p.set_defaults(func=cmd_export_json)
    p = sub.add_parser("export-native"); add_common(p); add_boot(p); p.add_argument("--unit", default=None); p.add_argument("--user", action="store_true"); p.set_defaults(func=cmd_export_native)
    p = sub.add_parser("list-boots"); p.add_argument("--sudo", action="store_true"); p.set_defaults(func=cmd_list_boots)
    p = sub.add_parser("capture-previous-boot"); add_common(p); p.set_defaults(func=cmd_capture_previous_boot)
    p = sub.add_parser("capture-failure-context"); add_common(p); p.set_defaults(func=cmd_capture_failure_context)
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
PYCODE