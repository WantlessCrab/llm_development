#!/usr/bin/env python3
"""
Row 19 workflow utility: prebackup refresh.

Purpose:
  1. Run all relevant health gates first.
  2. Run all health gates before deciding whether to stop.
  3. Stop cleanly if any health gate fails.
  4. If health passes, refresh current local recovery ingredients owned by
     non-backup-execution rows.
  5. Write a stable latest-artifacts manifest for the later backup execution wrapper.

This script is a workflow wrapper over existing rows. It does not replace row
authority. It does not run a real backup, Borgmatic backup, Row 08 manual-backup,
timer enablement, pruning, LUKS formatting, repo creation, or restore actions.

Intended next scripts:
  scripts/19_backup_execute.py
  scripts/19_state_prune.py

Outputs:
  state/dry_runs/19_prebackup_refresh/<timestamp>/prebackup_refresh_report.json
  state/generated/prebackup/latest_artifacts_manifest.json
  state/generated/prebackup/latest_artifacts_manifest.md
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tarfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_NAME = "19_prebackup_refresh.py"
SCHEMA_NAME = "recovery.prebackup_refresh.v1"

PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = PROJECT_ROOT / "state" / "dry_runs" / "19_prebackup_refresh"
GENERATED_ROOT = PROJECT_ROOT / "state" / "generated" / "prebackup"

DEFAULT_TARGET_DEVICE = "/dev/disk/by-id/wwn-0x5000c500fd981379"

# This script intentionally does not run these. They remain owned by backup
# execution, restore, setup, or manual recovery flows.
DEFERRED_TO_BACKUP_EXECUTE = [
    "scripts/07_borgmatic.sh dry-run --profile vault-primary",
    "scripts/07_borgmatic.sh backup --profile vault-primary --execute --confirm-token BORGMATIC_BACKUP:vault-primary",
    "scripts/07_borgmatic.sh validate --profile vault-primary",
    "scripts/08_systemd.sh manual-backup --unit-context system",
    "scripts/08_systemd.sh manual-backup --unit-context system --execute",
    "scripts/06_borg.sh repo-info --profile vault-primary",
    "scripts/06_borg.sh list-archives --profile vault-primary",
    "scripts/06_borg.sh capture-archive-inventory --profile vault-primary",
]

DEFERRED_SETUP_OR_RESTORE = [
    "scripts/03_cryptsetup.sh prepare-luks2-vault",
    "scripts/03_cryptsetup.sh backup-header",
    "scripts/03_cryptsetup.sh build-emergency-packet",
    "scripts/03_cryptsetup.sh discover-target --target-device /dev/disk/by-id/wwn-0x5000c500fd981379",
    "scripts/03_cryptsetup.sh assert-backup-hdd --target-device /dev/disk/by-id/wwn-0x5000c500fd981379",
    "scripts/06_borg.sh export-key --profile vault-primary --execute",
    "scripts/07_borgmatic.sh repo-create-guarded --profile vault-primary --execute",
    "scripts/11_flatpak.sh offline-export execution",
    "scripts/12_pipx.sh build-critical-wheelhouse",
    "scripts/14_docker.sh export-selected-image",
    "scripts/14_docker.sh volume-export-quiesced",
    "scripts/15_portainer.sh export-staged-lts-image",
    "scripts/15_portainer.sh volume-export-quiesced",
    "scripts/16_postgresql.sh restore-disposable --execute",
    "scripts/17_libvirt.sh qemu-img repair or VM disk payload copy",
    "scripts/18_runbooks.sh retire-old-placeholders --execute",
]

BACKUP_PAYLOAD_NOTES = {
    "actual_backup_writer": "Row 07 Borgmatic, triggered later through Row 08 by scripts/19_backup_execute.py.",
    "vault_repository": "/mnt/wantless_recovery/06_borg/repository",
    "configured_source_directories": ["/home/wantless", "/etc", "/opt", "/usr/local"],
    "current_recovery_runtime_excludes": ["state/dry_runs", "state/local_test", "state/tmp",
                                          "archive"],
    "archive_dir_note": (
        "Top-level recovery/archive is excluded by current Row 07 policy and is intended for "
        "manual moved/pruned output history by scripts/19_state_prune.py."
    ),
}


@dataclass(frozen=True)
class StepSpec:
    phase: str
    row: str
    label: str
    argv: list[str]
    required: bool = True
    expect_report: bool = True
    fail_on_report_warning: bool = False
    notes: str = ""
    report_command: str | None = None


@dataclass
class StepResult:
    phase: str
    row: str
    label: str
    argv: list[str]
    required: bool
    returncode: int | None = None
    ok: bool = False
    report_ok: bool | None = None
    report_path: str | None = None
    stdout_path: str | None = None
    stderr_path: str | None = None
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    notes: str = ""


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def iso_now() -> str:
    return datetime.now().astimezone().isoformat()


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def slug(value: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return text.strip("_") or "item"


def ensure_user_context() -> None:
    if os.geteuid() == 0:
        raise SystemExit(
            "STOP: run this as the logged-in user, not root. "
            "Row 13 desktop/session capture depends on the user session. "
            "Root/system backup execution belongs to scripts/19_backup_execute.py."
        )


def make_run_dir() -> Path:
    run_dir = OUTPUT_ROOT / utc_stamp()
    (run_dir / "commands").mkdir(parents=True, exist_ok=True)
    GENERATED_ROOT.mkdir(parents=True, exist_ok=True)
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n",
        encoding="utf-8",
    )


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if isinstance(payload, dict):
        return payload
    return None


def command_from_argv(argv: list[str]) -> str:
    if len(argv) >= 2:
        return argv[1]
    return "unknown"


def parse_report_paths(text: str) -> list[Path]:
    paths: list[Path] = []
    for match in re.finditer(r"(?:^|\n)report:\s+([^\r\n]+)", text):
        raw = match.group(1).strip()
        if not raw:
            continue
        path = Path(raw)
        if not path.is_absolute():
            path = PROJECT_ROOT / path
        paths.append(path)
    return paths


def discover_latest_report(row: str, command: str, *,
                           min_mtime: float | None = None) -> Path | None:
    root = PROJECT_ROOT / "state" / "dry_runs" / row
    if not root.exists():
        return None

    candidates: list[Path] = []
    candidates.extend(root.glob(f"*/{command}/*_report.json"))
    candidates.extend(root.glob(f"*/{command}/*report.json"))
    candidates.extend(root.glob(f"*/{command}/*.json"))
    candidates.extend(root.glob("*/error/*_report.json"))
    candidates.extend(root.glob("*/error/*report.json"))

    existing = [p for p in candidates if p.is_file()]

    if min_mtime is not None:
        existing = [p for p in existing if p.stat().st_mtime >= min_mtime]

    if not existing:
        return None

    return max(existing, key=lambda p: p.stat().st_mtime)

def report_status(report_path: Path | None) -> tuple[bool | None, list[str], list[str]]:
    if not report_path or not report_path.exists():
        return None, ["expected row report was not found"], []

    payload = load_json(report_path)
    if payload is None:
        return None, [f"row report is not valid JSON: {rel(report_path)}"], []

    failures = [str(item) for item in (payload.get("failures") or [])]
    warnings = [str(item) for item in (payload.get("warnings") or [])]
    ok = payload.get("ok")

    if ok is not True:
        if not failures:
            failures.append(f"row report ok is not true: {rel(report_path)}")
        return False, failures, warnings

    if failures:
        return False, failures, warnings

    return True, [], warnings


def run_step(index: int, spec: StepSpec, run_dir: Path, *, fail_on_warnings: bool) -> StepResult:
    label_slug = slug(f"{index:03d}_{spec.row}_{spec.label}")
    stdout_path = run_dir / "commands" / f"{label_slug}.stdout.txt"
    stderr_path = run_dir / "commands" / f"{label_slug}.stderr.txt"

    result = StepResult(
        phase=spec.phase,
        row=spec.row,
        label=spec.label,
        argv=spec.argv,
        required=spec.required,
        stdout_path=rel(stdout_path),
        stderr_path=rel(stderr_path),
        notes=spec.notes,
    )

    script_path = PROJECT_ROOT / spec.argv[0]
    if not script_path.exists():
        result.returncode = 127
        result.failures.append(f"missing script: {spec.argv[0]}")
        return result

    if not os.access(script_path, os.X_OK):
        result.returncode = 126
        result.failures.append(f"script is not executable: {spec.argv[0]}")
        return result

    # Prevent stale prior reports from being accepted if a row command returns
    # without printing a fresh report path or writing a fresh report.
    report_mtime_floor = datetime.now(timezone.utc).timestamp() - 1.0

    proc = subprocess.run(
        spec.argv,
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
    )

    result.returncode = proc.returncode
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)

    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    report_paths = [p for p in parse_report_paths(combined) if p.exists()]
    report_lookup_command = spec.report_command or command_from_argv(spec.argv)
    report_path = report_paths[-1] if report_paths else discover_latest_report(
        spec.row,
        report_lookup_command,
        min_mtime=report_mtime_floor,
    )

    if report_path:
        result.report_path = rel(report_path)

    if proc.returncode != 0:
        result.failures.append(f"command returned {proc.returncode}")

    if spec.expect_report:
        report_ok, report_failures, report_warnings = report_status(report_path)
        result.report_ok = report_ok
        result.failures.extend(report_failures)
        result.warnings.extend(report_warnings)
    else:
        result.report_ok = None

    if fail_on_warnings or spec.fail_on_report_warning:
        if result.warnings:
            result.failures.append("warnings were treated as failures for this run")

    result.ok = not result.failures
    return result


def print_step_result(result: StepResult) -> None:
    status = "PASS" if result.ok else "FAIL"
    print(f"[{result.phase}] {result.row} {result.label}: {status}")
    if result.report_path:
        print(f"  report: {result.report_path}")
    for failure in result.failures:
        print(f"  failure: {failure}")
    for warning in result.warnings[:5]:
        print(f"  warning: {warning}")
    if len(result.warnings) > 5:
        print(f"  warning: ... {len(result.warnings) - 5} more warnings in report")


def latest_files(root: Path, *, max_items: int = 200) -> list[dict[str, Any]]:
    if not root.exists():
        return []

    files = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    out: list[dict[str, Any]] = []
    for path in files[:max_items]:
        stat = path.stat()
        out.append(
            {
                "path": rel(path),
                "size_bytes": stat.st_size,
                "mtime": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(),
            }
        )
    return out


def latest_report_paths_by_row() -> dict[str, list[str]]:
    root = PROJECT_ROOT / "state" / "dry_runs"
    out: dict[str, list[str]] = {}
    if not root.exists():
        return out

    for row_dir in sorted(p for p in root.iterdir() if p.is_dir()):
        reports = sorted(
            [p for p in row_dir.glob("*/*/*_report.json") if p.is_file()],
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        out[row_dir.name] = [rel(p) for p in reports[:25]]
    return out


def complete_postgresql_dump_bundle(path: Path) -> tuple[bool, list[str]]:
    if not path.is_dir():
        return False, ["not a directory"]

    missing: list[str] = []

    if not ((path / "postgresql_dump_manifest.json").exists() or any(path.glob("*manifest*.json"))):
        missing.append("*manifest*.json")

    if not any(path.glob("*.dump")):
        missing.append("*.dump")

    if not any(path.glob("*.globals.sql")):
        missing.append("*.globals.sql")

    if not (any(path.glob("*.pg_restore_list.txt")) or any(path.glob("*restore*list*"))):
        missing.append("*restore*list*")

    return not missing, missing


def latest_database_dump_bundle() -> dict[str, Any] | None:
    root = PROJECT_ROOT / "state" / "exports" / "16_postgresql" / "dumps"
    if not root.exists():
        return None

    bundles = sorted(
        [p for p in root.iterdir() if p.is_dir()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if not bundles:
        return None

    incomplete: list[dict[str, Any]] = []

    for bundle in bundles:
        complete, missing = complete_postgresql_dump_bundle(bundle)
        if complete:
            return {
                "path": rel(bundle),
                "complete": True,
                "missing": [],
                "mtime": datetime.fromtimestamp(bundle.stat().st_mtime).astimezone().isoformat(),
                "files": latest_files(bundle, max_items=50),
                "incomplete_newer_or_checked_bundles": incomplete,
            }

        incomplete.append(
            {
                "path": rel(bundle),
                "complete": False,
                "missing": missing,
                "mtime": datetime.fromtimestamp(bundle.stat().st_mtime).astimezone().isoformat(),
            }
        )

    latest = bundles[0]
    complete, missing = complete_postgresql_dump_bundle(latest)
    return {
        "path": rel(latest),
        "complete": False,
        "missing": missing,
        "mtime": datetime.fromtimestamp(latest.stat().st_mtime).astimezone().isoformat(),
        "files": latest_files(latest, max_items=50),
        "incomplete_newer_or_checked_bundles": incomplete,
    }


def emergency_packet_valid(path: Path) -> bool:
    required = {
        "README_EMERGENCY_PACKET.txt",
        "configs/03_cryptsetup.yaml",
        "header_backup.img",
    }

    try:
        with tarfile.open(path, "r:*") as tf:
            names = set(tf.getnames())
    except Exception:
        return False

    return required.issubset(names)


def latest_valid_emergency_packet() -> dict[str, Any] | None:
    root = PROJECT_ROOT / "state" / "secrets" / "cryptsetup" / "emergency_packets"
    if not root.exists():
        return None

    packets = sorted(root.glob("*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True)
    invalid: list[str] = []

    for packet in packets:
        if emergency_packet_valid(packet):
            return {
                "path": rel(packet),
                "valid": True,
                "mtime": datetime.fromtimestamp(packet.stat().st_mtime).astimezone().isoformat(),
                "invalid_newer_packets": invalid,
            }
        invalid.append(rel(packet))

    return {
        "path": rel(packets[0]) if packets else None,
        "valid": False,
        "invalid_newer_packets": invalid,
    }


def latest_luks_header_backups() -> list[dict[str, Any]]:
    root = PROJECT_ROOT / "state" / "secrets" / "cryptsetup" / "header_backups"
    if not root.exists():
        return []

    files = sorted(
        [p for p in root.glob("*") if p.is_file() and not p.is_symlink()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )

    out: list[dict[str, Any]] = []
    for path in files[:10]:
        stat = path.stat()
        out.append(
            {
                "path": rel(path),
                "size_bytes": stat.st_size,
                "mtime": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(),
            }
        )
    return out


def latest_borg_key_exports() -> list[dict[str, Any]]:
    root = PROJECT_ROOT / "state" / "secrets" / "06_borg" / "key_exports"
    if not root.exists():
        return []

    files = [p for p in root.rglob("*") if p.is_file() and not p.is_symlink()]
    files = [
        p
        for p in files
        if p.name.endswith(".borg-key")
           or p.name.endswith(".paper-key.txt")
           or p.name.endswith(".txt")
    ]
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)

    out: list[dict[str, Any]] = []
    for path in files[:10]:
        stat = path.stat()
        out.append(
            {
                "path": rel(path),
                "size_bytes": stat.st_size,
                "mtime": datetime.fromtimestamp(stat.st_mtime).astimezone().isoformat(),
            }
        )
    return out


def generated_artifacts_snapshot(max_items: int) -> dict[str, list[dict[str, Any]]]:
    generated = PROJECT_ROOT / "state" / "generated"
    roots = [
        "07_borgmatic",
        "10_packages",
        "11_flatpak",
        "12_pipx",
        "13_desktop",
        "14_docker",
        "15_portainer",
        "16_postgresql",
        "17_libvirt",
        "18_runbooks",
        "prebackup",
    ]

    out: dict[str, list[dict[str, Any]]] = {}
    for name in roots:
        out[name] = latest_files(generated / name, max_items=max_items)
    return out


def recovery_use_map() -> dict[str, str]:
    return {
        "01_smartmontools": "Media and source/backup drive health admissibility.",
        "02_rescuezilla": "Whole-disk image readiness, ISO proof, boot/source layout facts.",
        "03_cryptsetup": "Vault identity and wrong-disk guard. Destructive/setup actions are not run here.",
        "04_integrity": "Hash and restore-admissibility gate over current recovery artifacts.",
        "05_rsync": "Dry-run-only staging/cold-copy transport previews. No file copy, delete, restore, or VM disk copy is run here.",
        "06_borg": "Borg version/key/archive recovery context. Real archive interaction is deferred to backup execution.",
        "07_borgmatic": "Config generation/validation only here. Real dry-run/backup stays in backup execution.",
        "08_systemd": "Mount/unit visibility checks only here. Manual-backup stays in backup execution.",
        "09_journalctl": "Current recovery/system failure evidence.",
        "10_packages": "Native OS package reinstall data and scripts.",
        "11_flatpak": "Flatpak app/runtime/remote/override reinstall data and scripts.",
        "12_pipx": "pipx CLI reinstall data and scripts.",
        "13_desktop": "Cinnamon/X11/user-session settings and restore preview data.",
        "14_docker": "Docker/Compose workload reconstruction metadata.",
        "15_portainer": "Portainer pinned-image and recreate/restore metadata.",
        "16_postgresql": "Logical PostgreSQL dump, globals, restore-list, row-count, and schema recovery evidence.",
        "17_libvirt": "Future VM/libvirt host-side recovery metadata and no-live-disk guard.",
        "18_runbooks": "Source/runbook validation only here. Final proof belongs to 19_backup_execute.py.",
        "19_prebackup_refresh": "This wrapper: health gates + current restore-ingredient refresh + latest manifest.",
    }


def build_manifest(
        *,
        run_dir: Path,
        steps: list[StepResult],
        health_phase_ok: bool,
        data_phase_ok: bool,
        max_generated_artifacts: int,
) -> dict[str, Any]:
    failed_steps = [s for s in steps if not s.ok]
    data_steps = [s for s in steps if s.phase == "data"]
    data_failed_steps = [s for s in data_steps if not s.ok]

    refresh_complete = bool(data_steps) and data_phase_ok and not data_failed_steps
    backup_ready = health_phase_ok and refresh_complete and not failed_steps

    latest_report_per_command = {
        f"{s.row}:{s.label}": s.report_path
        for s in steps
        if s.report_path
    }

    return {
        "schema": "recovery.prebackup.latest_artifacts_manifest.v1",
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "source_run_dir": rel(run_dir),

        # ok means this manifest is usable by 19_backup_execute.py as a complete
        # prebackup refresh. Health-only runs may pass health but are not backup-ready.
        "ok": backup_ready,
        "backup_ready": backup_ready,
        "refresh_complete": refresh_complete,
        "health_phase_ok": health_phase_ok,
        "data_phase_ok": data_phase_ok,
        "data_step_count": len(data_steps),

        "backup_payload_notes": BACKUP_PAYLOAD_NOTES,
        "commands_run": [
            {
                "phase": s.phase,
                "row": s.row,
                "label": s.label,
                "argv": s.argv,
                "ok": s.ok,
                "report_ok": s.report_ok,
                "report_path": s.report_path,
                "required": s.required,
                "notes": s.notes,
            }
            for s in steps
        ],
        "latest_report_per_command": latest_report_per_command,
        "latest_reports_by_row": latest_report_paths_by_row(),
        "latest_generated_artifacts": generated_artifacts_snapshot(max_generated_artifacts),
        "latest_database_dump_bundle": latest_database_dump_bundle(),
        "latest_valid_emergency_packet": latest_valid_emergency_packet(),
        "latest_luks_header_backups": latest_luks_header_backups(),
        "latest_borg_key_exports": latest_borg_key_exports(),
        "recovery_use_map": recovery_use_map(),
        "deferred_to_19_backup_execute": DEFERRED_TO_BACKUP_EXECUTE,
        "deferred_setup_or_restore_actions": DEFERRED_SETUP_OR_RESTORE,
        "failures": [
            {
                "phase": s.phase,
                "row": s.row,
                "label": s.label,
                "failures": s.failures,
                "report_path": s.report_path,
            }
            for s in failed_steps
        ],
    }

def manifest_markdown(manifest: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# Latest prebackup artifacts manifest")
    lines.append("")
    lines.append(f"- generated_at: `{manifest.get('generated_at')}`")
    lines.append(f"- host: `{manifest.get('host')}`")
    lines.append(f"- ok: `{manifest.get('ok')}`")
    lines.append(f"- health_phase_ok: `{manifest.get('health_phase_ok')}`")
    lines.append(f"- data_phase_ok: `{manifest.get('data_phase_ok')}`")
    lines.append(f"- source_run_dir: `{manifest.get('source_run_dir')}`")
    lines.append("")

    notes = manifest.get("backup_payload_notes", {})
    lines.append("## Backup payload notes")
    lines.append("")
    lines.append(f"- actual_backup_writer: `{notes.get('actual_backup_writer')}`")
    lines.append(f"- vault_repository: `{notes.get('vault_repository')}`")
    lines.append(
        "- configured_source_directories: "
        + ", ".join(f"`{item}`" for item in notes.get("configured_source_directories", []))
    )
    lines.append(
        "- current_recovery_runtime_excludes: "
        + ", ".join(f"`{item}`" for item in notes.get("current_recovery_runtime_excludes", []))
    )
    lines.append(f"- archive_dir_note: {notes.get('archive_dir_note')}")
    lines.append("")

    lines.append("## Commands run")
    lines.append("")
    lines.append("| Phase | Row | Command | OK | Report |")
    lines.append("|---|---|---|---:|---|")
    for item in manifest.get("commands_run", []):
        argv = " ".join(item.get("argv", []))
        lines.append(
            f"| {item.get('phase')} | {item.get('row')} | `{argv}` | "
            f"{item.get('ok')} | `{item.get('report_path') or ''}` |"
        )
    lines.append("")

    dump = manifest.get("latest_database_dump_bundle")
    lines.append("## Latest database dump bundle")
    lines.append("")
    if dump:
        lines.append(f"- path: `{dump.get('path')}`")
        lines.append(f"- complete: `{dump.get('complete')}`")
        lines.append(f"- mtime: `{dump.get('mtime')}`")
        if dump.get("missing"):
            lines.append("- missing:")
            for item in dump.get("missing", []):
                lines.append(f"  - `{item}`")
    else:
        lines.append("- none found")
    lines.append("")

    packet = manifest.get("latest_valid_emergency_packet")
    lines.append("## Latest valid emergency packet")
    lines.append("")
    if packet:
        lines.append(f"- path: `{packet.get('path')}`")
        lines.append(f"- valid: `{packet.get('valid')}`")
        if packet.get("invalid_newer_packets"):
            lines.append("- invalid newer packets:")
            for path in packet.get("invalid_newer_packets", []):
                lines.append(f"  - `{path}`")
    else:
        lines.append("- none found")
    lines.append("")

    lines.append("## Latest Borg key exports")
    lines.append("")
    for item in manifest.get("latest_borg_key_exports", []):
        lines.append(f"- `{item.get('path')}`")
    if not manifest.get("latest_borg_key_exports"):
        lines.append("- none found")
    lines.append("")

    lines.append("## Deferred to 19_backup_execute")
    lines.append("")
    for item in manifest.get("deferred_to_19_backup_execute", []):
        lines.append(f"- `{item}`")
    lines.append("")

    lines.append("## Recovery use map")
    lines.append("")
    for row, purpose in manifest.get("recovery_use_map", {}).items():
        lines.append(f"- `{row}`: {purpose}")
    lines.append("")

    failures = manifest.get("failures") or []
    if failures:
        lines.append("## Failures")
        lines.append("")
        for item in failures:
            lines.append(f"- `{item.get('row')} {item.get('label')}`")
            for failure in item.get("failures", []):
                lines.append(f"  - {failure}")
        lines.append("")

    return "\n".join(lines) + "\n"


def build_health_steps(target_device: str) -> list[StepSpec]:
    return [
        StepSpec(
            "health",
            "18_runbooks",
            "assert-required-artifacts",
            ["scripts/18_runbooks.sh", "assert-required-artifacts", "--level", "source"],
            notes="Source authority must be structurally complete before any refresh.",
        ),
        StepSpec(
            "health",
            "18_runbooks",
            "check-completeness",
            ["scripts/18_runbooks.sh", "check-completeness"],
        ),
        StepSpec(
            "health",
            "18_runbooks",
            "validate-stop-conditions",
            ["scripts/18_runbooks.sh", "validate-stop-conditions"],
        ),
        StepSpec(
            "health",
            "18_runbooks",
            "validate-checklist",
            ["scripts/18_runbooks.sh", "validate-checklist"],
        ),
        StepSpec(
            "health",
            "01_smartmontools",
            "capture-source",
            ["scripts/01_smartmontools.sh", "capture-source"],
        ),
        StepSpec(
            "health",
            "01_smartmontools",
            "capture-backup-hdd",
            ["scripts/01_smartmontools.sh", "capture-backup-hdd"],
        ),
        StepSpec(
            "health",
            "01_smartmontools",
            "gate-full",
            ["scripts/01_smartmontools.sh", "gate", "full"],
            notes="Full media gate because the backup HDD is now configured and in use.",
            report_command="gate-full",
        ),
        StepSpec(
            "health",
            "02_rescuezilla",
            "verify-iso",
            ["scripts/02_rescuezilla.sh", "verify-iso"],
            notes="ISO proof is a health/admissibility gate before capture refresh.",
        ),
        StepSpec(
            "health",
            "03_cryptsetup",
            "assert-not-root",
            ["scripts/03_cryptsetup.sh", "assert-not-root", "--target-device", target_device],
            notes="Wrong-disk guard only; safe while vault is mounted.",
        ),
        StepSpec(
            "health",
            "03_cryptsetup",
            "assert-not-rescuezilla-usb",
            ["scripts/03_cryptsetup.sh", "assert-not-rescuezilla-usb", "--target-device",
             target_device],
            notes="Wrong-media guard only; safe while vault is mounted.",
        ),
        StepSpec(
            "health",
            "03_cryptsetup",
            "assert-not-restore-target",
            ["scripts/03_cryptsetup.sh", "assert-not-restore-target", "--target-device",
             target_device],
            notes="Restore-target guard only; safe while vault is mounted.",
        ),
        StepSpec(
            "health",
            "03_cryptsetup",
            "export-metadata",
            ["scripts/03_cryptsetup.sh", "export-metadata", "--target-device", target_device],
            notes="Mounted-vault metadata refresh; no format/open/close action.",
        ),
        StepSpec(
            "health",
            "04_integrity",
            "verify-restore-gate-local-only",
            ["scripts/04_integrity.sh", "verify-restore-gate", "--local-only"],
            notes="Local-only integrity gate before data refresh.",
        ),
        StepSpec(
            "health",
            "06_borg",
            "assert-version",
            ["scripts/06_borg.sh", "assert-version"],
        ),
        StepSpec(
            "health",
            "08_systemd",
            "show-units",
            ["scripts/08_systemd.sh", "show-units"],
        ),
        StepSpec(
            "health",
            "08_systemd",
            "show-timers",
            ["scripts/08_systemd.sh", "show-timers"],
        ),
        StepSpec(
            "health",
            "08_systemd",
            "assert-mount-condition",
            ["scripts/08_systemd.sh", "assert-mount-condition"],
            notes=(
                "Mountpoint gate only; this does not prove root-owned Borg repository readability. "
                "Repository read/list proof is deferred to scripts/19_backup_execute.py."
            ),
        ),
        StepSpec(
            "health",
            "07_borgmatic",
            "assert-version",
            ["scripts/07_borgmatic.sh", "assert-version"],
            notes="Borgmatic/Borg version gate only.",
        ),
        StepSpec(
            "health",
            "07_borgmatic",
            "generate-reference-local-test",
            ["scripts/07_borgmatic.sh", "generate-reference", "--profile", "local-test"],
            notes="Generate local-test reference config for user-context validation.",
        ),
        StepSpec(
            "health",
            "07_borgmatic",
            "validate-local-test",
            ["scripts/07_borgmatic.sh", "validate", "--profile", "local-test"],
            notes="Validate borgmatic mechanics without requiring production Borg passphrase.",
        ),
        StepSpec(
            "health",
            "07_borgmatic",
            "generate-reference-vault-primary",
            ["scripts/07_borgmatic.sh", "generate-reference", "--profile", "vault-primary"],
            notes="Generate production reference config only; production validation runs later via 19_backup_execute.py with root env.",
        ),
    ]


def build_data_steps() -> list[StepSpec]:
    return [
        # Row 02
        StepSpec("data", "02_rescuezilla", "capture-source-layout",
                 ["scripts/02_rescuezilla.sh", "capture-source-layout"]),
        StepSpec("data", "02_rescuezilla", "capture-uefi",
                 ["scripts/02_rescuezilla.sh", "capture-uefi"]),

        # Row 09
        StepSpec("data", "09_journalctl", "capture-recovery-units",
                 ["scripts/09_journalctl.sh", "capture-recovery-units"]),
        StepSpec("data", "09_journalctl", "capture-boot-warnings",
                 ["scripts/09_journalctl.sh", "capture-boot-warnings"]),
        StepSpec("data", "09_journalctl", "capture-kernel-storage-warnings",
                 ["scripts/09_journalctl.sh", "capture-kernel-storage-warnings"]),
        StepSpec("data", "09_journalctl", "capture-docker-libvirt-errors",
                 ["scripts/09_journalctl.sh", "capture-docker-libvirt-errors"]),
        StepSpec("data", "09_journalctl", "capture-timer-history",
                 ["scripts/09_journalctl.sh", "capture-timer-history"]),
        StepSpec("data", "09_journalctl", "list-boots", ["scripts/09_journalctl.sh", "list-boots"]),
        StepSpec("data", "09_journalctl", "capture-previous-boot",
                 ["scripts/09_journalctl.sh", "capture-previous-boot"]),
        StepSpec("data", "09_journalctl", "capture-failure-context",
                 ["scripts/09_journalctl.sh", "capture-failure-context"]),

        # Row 10
        StepSpec("data", "10_packages", "capture-os", ["scripts/10_packages.sh", "capture-os"]),
        StepSpec("data", "10_packages", "capture-sources",
                 ["scripts/10_packages.sh", "capture-sources"]),
        StepSpec("data", "10_packages", "capture-keyrings",
                 ["scripts/10_packages.sh", "capture-keyrings"]),
        StepSpec("data", "10_packages", "capture-preferences",
                 ["scripts/10_packages.sh", "capture-preferences"]),
        StepSpec("data", "10_packages", "capture-policy",
                 ["scripts/10_packages.sh", "capture-policy"]),
        StepSpec("data", "10_packages", "capture-dpkg", ["scripts/10_packages.sh", "capture-dpkg"]),
        StepSpec("data", "10_packages", "capture-manual-auto-holds",
                 ["scripts/10_packages.sh", "capture-manual-auto-holds"]),
        StepSpec("data", "10_packages", "capture-selections",
                 ["scripts/10_packages.sh", "capture-selections"]),
        StepSpec("data", "10_packages", "capture-critical",
                 ["scripts/10_packages.sh", "capture-critical"]),
        StepSpec("data", "10_packages", "build-local-deb-manifest",
                 ["scripts/10_packages.sh", "build-local-deb-manifest"]),
        StepSpec("data", "10_packages", "verify-critical-debs",
                 ["scripts/10_packages.sh", "verify-critical-debs"]),
        StepSpec("data", "10_packages", "restore-plan", ["scripts/10_packages.sh", "restore-plan"]),
        StepSpec("data", "10_packages", "generate-reinstall-script",
                 ["scripts/10_packages.sh", "generate-reinstall-script"]),

        # Row 11
        StepSpec("data", "11_flatpak", "capture-scopes",
                 ["scripts/11_flatpak.sh", "capture-scopes"]),
        StepSpec("data", "11_flatpak", "capture-remotes",
                 ["scripts/11_flatpak.sh", "capture-remotes"]),
        StepSpec("data", "11_flatpak", "capture-apps", ["scripts/11_flatpak.sh", "capture-apps"]),
        StepSpec("data", "11_flatpak", "capture-runtimes",
                 ["scripts/11_flatpak.sh", "capture-runtimes"]),
        StepSpec("data", "11_flatpak", "capture-overrides",
                 ["scripts/11_flatpak.sh", "capture-overrides"]),
        StepSpec("data", "11_flatpak", "capture-app-data-manifest",
                 ["scripts/11_flatpak.sh", "capture-app-data-manifest"]),
        StepSpec("data", "11_flatpak", "offline-export-plan",
                 ["scripts/11_flatpak.sh", "offline-export-plan"]),
        StepSpec("data", "11_flatpak", "verify-offline-artifacts",
                 ["scripts/11_flatpak.sh", "verify-offline-artifacts"]),
        StepSpec("data", "11_flatpak", "restore-plan", ["scripts/11_flatpak.sh", "restore-plan"]),
        StepSpec("data", "11_flatpak", "generate-reinstall-script",
                 ["scripts/11_flatpak.sh", "generate-reinstall-script"]),

        # Row 12
        StepSpec("data", "12_pipx", "capture-environment",
                 ["scripts/12_pipx.sh", "capture-environment"]),
        StepSpec("data", "12_pipx", "capture-list-json",
                 ["scripts/12_pipx.sh", "capture-list-json"]),
        StepSpec("data", "12_pipx", "capture-interpreter",
                 ["scripts/12_pipx.sh", "capture-interpreter"]),
        StepSpec("data", "12_pipx", "capture-entrypoints",
                 ["scripts/12_pipx.sh", "capture-entrypoints"]),
        StepSpec("data", "12_pipx", "capture-injected", ["scripts/12_pipx.sh", "capture-injected"]),
        StepSpec("data", "12_pipx", "generate-reinstall-input",
                 ["scripts/12_pipx.sh", "generate-reinstall-input"]),
        StepSpec("data", "12_pipx", "restore-plan", ["scripts/12_pipx.sh", "restore-plan"]),
        StepSpec("data", "12_pipx", "generate-reinstall-script",
                 ["scripts/12_pipx.sh", "generate-reinstall-script"]),
        StepSpec(
            "data",
            "12_pipx",
            "verify-wheelhouse",
            ["scripts/12_pipx.sh", "verify-wheelhouse"],
            notes="Verification only; build-critical-wheelhouse is intentionally not run.",
        ),

        # Row 13
        StepSpec(
            "data",
            "13_desktop",
            "capture-session",
            ["scripts/13_desktop.sh", "capture-session"],
            notes="Must run in logged-in user session.",
        ),

        # Row 14
        StepSpec("data", "14_docker", "capture-info", ["scripts/14_docker.sh", "capture-info"]),
        StepSpec("data", "14_docker", "capture-daemon-config",
                 ["scripts/14_docker.sh", "capture-daemon-config"]),
        StepSpec("data", "14_docker", "capture-systemd-overrides",
                 ["scripts/14_docker.sh", "capture-systemd-overrides"]),
        StepSpec("data", "14_docker", "capture-contexts",
                 ["scripts/14_docker.sh", "capture-contexts"]),
        StepSpec("data", "14_docker", "capture-containers",
                 ["scripts/14_docker.sh", "capture-containers"]),
        StepSpec("data", "14_docker", "capture-images", ["scripts/14_docker.sh", "capture-images"]),
        StepSpec("data", "14_docker", "capture-image-digests",
                 ["scripts/14_docker.sh", "capture-image-digests"]),
        StepSpec("data", "14_docker", "capture-networks",
                 ["scripts/14_docker.sh", "capture-networks"]),
        StepSpec("data", "14_docker", "capture-volumes",
                 ["scripts/14_docker.sh", "capture-volumes"]),
        StepSpec("data", "14_docker", "capture-bind-mounts",
                 ["scripts/14_docker.sh", "capture-bind-mounts"]),
        StepSpec("data", "14_docker", "capture-compose-sources",
                 ["scripts/14_docker.sh", "capture-compose-sources"]),
        StepSpec("data", "14_docker", "capture-compose-env",
                 ["scripts/14_docker.sh", "capture-compose-env"]),
        StepSpec("data", "14_docker", "capture-gpu-runtime-contracts",
                 ["scripts/14_docker.sh", "capture-gpu-runtime-contracts"]),
        StepSpec("data", "14_docker", "generate-compose-restore-plan",
                 ["scripts/14_docker.sh", "generate-compose-restore-plan"]),

        # Row 15
        StepSpec("data", "15_portainer", "capture-container",
                 ["scripts/15_portainer.sh", "capture-container"]),
        StepSpec("data", "15_portainer", "capture-image",
                 ["scripts/15_portainer.sh", "capture-image"]),
        StepSpec("data", "15_portainer", "capture-image-digest",
                 ["scripts/15_portainer.sh", "capture-image-digest"]),
        StepSpec("data", "15_portainer", "capture-volume",
                 ["scripts/15_portainer.sh", "capture-volume"]),
        StepSpec("data", "15_portainer", "capture-ports",
                 ["scripts/15_portainer.sh", "capture-ports"]),
        StepSpec("data", "15_portainer", "capture-mounts",
                 ["scripts/15_portainer.sh", "capture-mounts"]),
        StepSpec("data", "15_portainer", "capture-networks",
                 ["scripts/15_portainer.sh", "capture-networks"]),
        StepSpec("data", "15_portainer", "gate-latest-not-authority",
                 ["scripts/15_portainer.sh", "gate-latest-not-authority"]),
        StepSpec("data", "15_portainer", "validate-restore-prereqs",
                 ["scripts/15_portainer.sh", "validate-restore-prereqs"]),
        StepSpec("data", "15_portainer", "generate-restore-plan",
                 ["scripts/15_portainer.sh", "generate-restore-plan"]),
        StepSpec("data", "15_portainer", "generate-recreate-command",
                 ["scripts/15_portainer.sh", "generate-recreate-command"]),

        # Row 16
        StepSpec("data", "16_postgresql", "discover-active-server",
                 ["scripts/16_postgresql.sh", "discover-active-server"]),
        StepSpec("data", "16_postgresql", "assert-major-match",
                 ["scripts/16_postgresql.sh", "assert-major-match"]),
        StepSpec("data", "16_postgresql", "list-databases",
                 ["scripts/16_postgresql.sh", "list-databases"]),
        StepSpec("data", "16_postgresql", "capture-server",
                 ["scripts/16_postgresql.sh", "capture-server"]),
        StepSpec("data", "16_postgresql", "capture-extensions",
                 ["scripts/16_postgresql.sh", "capture-extensions"]),
        StepSpec("data", "16_postgresql", "capture-schema-inventory",
                 ["scripts/16_postgresql.sh", "capture-schema-inventory"]),
        StepSpec("data", "16_postgresql", "dump-globals",
                 ["scripts/16_postgresql.sh", "dump-globals"]),
        StepSpec("data", "16_postgresql", "dump-all-required",
                 ["scripts/16_postgresql.sh", "dump-all-required"]),
        StepSpec("data", "16_postgresql", "verify-restore-list",
                 ["scripts/16_postgresql.sh", "verify-restore-list"]),
        StepSpec("data", "16_postgresql", "row-count-sanity",
                 ["scripts/16_postgresql.sh", "row-count-sanity"]),
        StepSpec("data", "16_postgresql", "gate", ["scripts/16_postgresql.sh", "gate"]),
        StepSpec("data", "16_postgresql", "restore-plan",
                 ["scripts/16_postgresql.sh", "restore-plan"]),

        # Row 17
        StepSpec("data", "17_libvirt", "discover-system",
                 ["scripts/17_libvirt.sh", "discover-system"]),
        StepSpec("data", "17_libvirt", "capture-inventory",
                 ["scripts/17_libvirt.sh", "capture-inventory"]),
        StepSpec("data", "17_libvirt", "capture-domain-xml",
                 ["scripts/17_libvirt.sh", "capture-domain-xml"]),
        StepSpec("data", "17_libvirt", "capture-network-xml",
                 ["scripts/17_libvirt.sh", "capture-network-xml"]),
        StepSpec("data", "17_libvirt", "capture-pool-xml",
                 ["scripts/17_libvirt.sh", "capture-pool-xml"]),
        StepSpec("data", "17_libvirt", "capture-secret-refs",
                 ["scripts/17_libvirt.sh", "capture-secret-refs"]),
        StepSpec("data", "17_libvirt", "capture-qemu-img-info",
                 ["scripts/17_libvirt.sh", "capture-qemu-img-info"]),
        StepSpec(
            "data",
            "17_libvirt",
            "run-qemu-img-check",
            ["scripts/17_libvirt.sh", "run-qemu-img-check"],
            notes="Read-only qemu-img check only; Row 17 policy forbids repair.",
        ),
        StepSpec("data", "17_libvirt", "capture-nvram", ["scripts/17_libvirt.sh", "capture-nvram"]),
        StepSpec("data", "17_libvirt", "capture-swtpm", ["scripts/17_libvirt.sh", "capture-swtpm"]),
        StepSpec("data", "17_libvirt", "verify-no-live-disk-copy",
                 ["scripts/17_libvirt.sh", "verify-no-live-disk-copy"]),
        StepSpec("data", "17_libvirt", "generate-restore-plan",
                 ["scripts/17_libvirt.sh", "generate-restore-plan"]),
        StepSpec("data", "17_libvirt", "define-domain-plan",
                 ["scripts/17_libvirt.sh", "define-domain-plan"]),
        StepSpec("data", "17_libvirt", "vm-smoke-plan", ["scripts/17_libvirt.sh", "vm-smoke-plan"]),
        StepSpec("data", "17_libvirt", "gate", ["scripts/17_libvirt.sh", "gate"]),

        # Row 05
        StepSpec(
            "data",
            "05_rsync",
            "dry-run-manifest-tree-staging",
            ["scripts/05_rsync.sh", "dry-run", "--profile", "manifest-tree-staging"],
            notes="Row 05 manifest-tree staging dry-run only; no file copy, delete, restore, or HDD write.",
        ),
        StepSpec(
            "data",
            "05_rsync",
            "dry-run-large-artifact-staging",
            ["scripts/05_rsync.sh", "dry-run", "--profile", "large-artifact-staging"],
            notes="Row 05 large-artifact staging dry-run only; no file copy, delete, restore, or HDD write.",
        ),

        # Row 04 after current artifacts exist.
        StepSpec(
            "data",
            "04_integrity",
            "verify-restore-gate",
            ["scripts/04_integrity.sh", "verify-restore-gate"],
            notes="Runs after capture/export rows so current artifacts are included.",
        ),
    ]


def run_health_phase(
        specs: list[StepSpec],
        run_dir: Path,
        *,
        fail_on_warnings: bool,
        start_index: int,
) -> tuple[bool, list[StepResult]]:
    print("\n===== HEALTH =====")
    results: list[StepResult] = []

    for offset, spec in enumerate(specs):
        index = start_index + offset
        result = run_step(index, spec, run_dir, fail_on_warnings=fail_on_warnings)
        print_step_result(result)
        results.append(result)

    ok = all(result.ok or not result.required for result in results)
    print("\nHEALTH: PASS" if ok else "\nHEALTH: FAIL")
    return ok, results


def run_data_phase(
        specs: list[StepSpec],
        run_dir: Path,
        *,
        fail_on_warnings: bool,
        start_index: int,
) -> tuple[bool, list[StepResult]]:
    print("\n===== DATA REFRESH =====")
    results: list[StepResult] = []

    for offset, spec in enumerate(specs):
        index = start_index + offset
        result = run_step(index, spec, run_dir, fail_on_warnings=fail_on_warnings)
        print_step_result(result)
        results.append(result)

        if not result.ok and spec.required:
            print("\nDATA REFRESH: FAIL")
            return False, results

    print("\nDATA REFRESH: PASS")
    return True, results


def write_outputs(
        *,
        run_dir: Path,
        report: dict[str, Any],
        manifest: dict[str, Any],
) -> None:
    report_path = run_dir / "prebackup_refresh_report.json"
    manifest_json = GENERATED_ROOT / "latest_artifacts_manifest.json"
    manifest_md = GENERATED_ROOT / "latest_artifacts_manifest.md"

    report["latest_artifacts_manifest_json"] = rel(manifest_json)
    report["latest_artifacts_manifest_md"] = rel(manifest_md)

    write_json(report_path, report)
    write_json(manifest_json, manifest)
    write_text(manifest_md, manifest_markdown(manifest))

    print(f"\nreport: {rel(report_path)}")
    print(f"latest manifest json: {rel(manifest_json)}")
    print(f"latest manifest md: {rel(manifest_md)}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=f"scripts/{SCRIPT_NAME}",
        description="Run prebackup health gates, refresh local restore ingredients, and write latest manifest.",
    )
    parser.add_argument(
        "--target-device",
        default=DEFAULT_TARGET_DEVICE,
        help="Stable backup HDD target device used for Row 03 gate.",
    )
    parser.add_argument(
        "--health-only",
        action="store_true",
        help="Run health gates only and still write a report/manifest.",
    )
    parser.add_argument(
        "--fail-on-warnings",
        action="store_true",
        help="Treat row warnings as failures. Default is false.",
    )
    parser.add_argument(
        "--max-generated-artifacts",
        type=int,
        default=200,
        help="Maximum generated artifact files to list per generated root in latest manifest.",
    )
    parser.add_argument(
        "--print-plan",
        action="store_true",
        help="Print planned commands and exit without running them.",
    )
    return parser


def print_plan(health: list[StepSpec], data: list[StepSpec]) -> None:
    print("===== HEALTH PLAN =====")
    for spec in health:
        print(f"{spec.row:18} {spec.label:42} {' '.join(spec.argv)}")

    print("\n===== DATA REFRESH PLAN =====")
    for spec in data:
        print(f"{spec.row:18} {spec.label:42} {' '.join(spec.argv)}")

    print("\n===== DEFERRED TO 19_BACKUP_EXECUTE =====")
    for item in DEFERRED_TO_BACKUP_EXECUTE:
        print(item)

    print("\n===== DEFERRED SETUP / RESTORE / EXPORT ACTIONS =====")
    for item in DEFERRED_SETUP_OR_RESTORE:
        print(item)


def result_to_dict(step: StepResult) -> dict[str, Any]:
    return {
        "phase": step.phase,
        "row": step.row,
        "label": step.label,
        "argv": step.argv,
        "required": step.required,
        "returncode": step.returncode,
        "ok": step.ok,
        "report_ok": step.report_ok,
        "report_path": step.report_path,
        "stdout_path": step.stdout_path,
        "stderr_path": step.stderr_path,
        "failures": step.failures,
        "warnings": step.warnings,
        "notes": step.notes,
    }


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)

    health_specs = build_health_steps(args.target_device)
    data_specs = build_data_steps()

    if args.print_plan:
        print_plan(health_specs, data_specs)
        return 0

    ensure_user_context()
    run_dir = make_run_dir()

    report: dict[str, Any] = {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "prebackup_refresh",
            "script": SCRIPT_NAME,
        },
        "command": "prebackup-refresh",
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": False,
        "health_phase_ok": False,
        "data_phase_ok": False,
        "health_only": bool(args.health_only),
        "fail_on_warnings": bool(args.fail_on_warnings),
        "target_device": args.target_device,
        "backup_payload_notes": BACKUP_PAYLOAD_NOTES,
        "failures": [],
        "warnings": [],
        "steps": [],
        "deferred_to_19_backup_execute": DEFERRED_TO_BACKUP_EXECUTE,
        "deferred_setup_or_restore_actions": DEFERRED_SETUP_OR_RESTORE,
    }

    all_results: list[StepResult] = []

    try:
        health_ok, health_results = run_health_phase(
            health_specs,
            run_dir,
            fail_on_warnings=args.fail_on_warnings,
            start_index=1,
        )
        all_results.extend(health_results)
        report["health_phase_ok"] = health_ok

        if not health_ok:
            data_ok = False
            report["failures"].append("health phase failed; data refresh did not run")
        elif args.health_only:
            data_ok = True
            report["warnings"].append("health-only mode requested; data refresh did not run")
        else:
            data_ok, data_results = run_data_phase(
                data_specs,
                run_dir,
                fail_on_warnings=args.fail_on_warnings,
                start_index=1 + len(health_specs),
            )
            all_results.extend(data_results)

        report["data_phase_ok"] = data_ok
        report["steps"] = [result_to_dict(step) for step in all_results]

        failed = [step for step in all_results if not step.ok]
        for step in failed:
            report["failures"].append(f"{step.phase}:{step.row}:{step.label} failed")

        report["ok"] = health_ok and data_ok and not failed

        manifest = build_manifest(
            run_dir=run_dir,
            steps=all_results,
            health_phase_ok=health_ok,
            data_phase_ok=data_ok,
            max_generated_artifacts=args.max_generated_artifacts,
        )
        write_outputs(run_dir=run_dir, report=report, manifest=manifest)

        if report["ok"]:
            if args.health_only:
                print("\nPREBACKUP_HEALTH: PASS")
                print("NEXT: run scripts/19_prebackup_refresh.py without --health-only")
            else:
                print("\nPREBACKUP_REFRESH: PASS")
                print("NEXT: optional scripts/19_state_prune.py --mode report --keep 2")
                print("NEXT: scripts/19_backup_execute.py --mode dry-run")
            return 0

        print("\nPREBACKUP_REFRESH: FAIL")
        print("STOP: do not run backup execution until the failed row is corrected.")
        return 2

    except KeyboardInterrupt:
        report["failures"].append("interrupted by user")
        report["ok"] = False
        report["steps"] = [result_to_dict(step) for step in all_results]

        manifest = build_manifest(
            run_dir=run_dir,
            steps=all_results,
            health_phase_ok=bool(report.get("health_phase_ok")),
            data_phase_ok=bool(report.get("data_phase_ok")),
            max_generated_artifacts=args.max_generated_artifacts,
        )
        write_outputs(run_dir=run_dir, report=report, manifest=manifest)

        print("\nPREBACKUP_REFRESH: INTERRUPTED")
        return 130

    except Exception as exc:
        report["failures"].append(str(exc))
        report["ok"] = False
        report["steps"] = [result_to_dict(step) for step in all_results]

        manifest = build_manifest(
            run_dir=run_dir,
            steps=all_results,
            health_phase_ok=bool(report.get("health_phase_ok")),
            data_phase_ok=bool(report.get("data_phase_ok")),
            max_generated_artifacts=args.max_generated_artifacts,
        )
        write_outputs(run_dir=run_dir, report=report, manifest=manifest)

        print("\nPREBACKUP_REFRESH: FAIL")
        print(f"failure: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))