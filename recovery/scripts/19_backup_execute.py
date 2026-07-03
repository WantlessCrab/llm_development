#!/usr/bin/env python3
"""
Row 19 workflow utility: backup execute.

Purpose:
  1. Require a current successful scripts/19_prebackup_refresh.py manifest.
  2. Re-check the active backup boundary without duplicating row authority.
  3. Run pre-action proof so current restore maps are available before backup.
  4. Use Row 08 as the only activation path for Borgmatic backup work.
  5. Run dry-run by default.
  6. In execute mode, run a required pre-execute dry-run first.
  7. In execute mode, write a backup intent manifest before the real archive.
  8. In execute mode, run the real Row 08 / Row 07 Borgmatic backup.
  9. Capture post-action Borg/Borgmatic, journal, runbook, and integrity evidence.
 10. Write stable latest backup execution manifests.

This script does not replace Row 02, Row 03, Row 06, Row 07, Row 08,
Row 16, Row 18, or any restore row. It is a workflow wrapper over the
intended row contracts.

Important authority boundaries:
  - Row 02 Rescuezilla: bare-metal baseline image authority.
  - Row 03 Cryptsetup: encrypted vault setup/identity/header authority.
  - Row 06 Borg: repository/archive/key mechanics.
  - Row 07 Borgmatic: backup policy, retention, check, dry-run/backup command semantics.
  - Row 08 systemd: deterministic backup activation boundary.
  - Row 16 PostgreSQL: logical dump authority.
  - Row 18 runbooks: human proof/checklist/runbook authority.

Outputs:
  state/dry_runs/19_backup_execute/<timestamp>/backup_execute_report.json
  state/generated/backup/backup_intent_manifest.json
  state/generated/backup/backup_intent_manifest.md
  state/generated/backup/latest_backup_execution.json
  state/generated/backup/latest_backup_execution.md

Safety:
  - Dry-run mode is default.
  - Execute mode requires:
      --mode execute
      --execute
      --confirm-token BACKUP_EXECUTE:vault-primary
  - This wrapper should be run as the logged-in user, not root, so wrapper
    reports stay user-owned. Root backup work is invoked through sudo -n
    by default. Run `sudo -v` first.
  - No pruning, timer enablement, LUKS setup, repo creation, key export,
    image export, volume export, disposable restore, VM disk copy, or restore
    action is run here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import socket
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCRIPT_NAME = "19_backup_execute.py"
SCHEMA_NAME = "recovery.backup_execute.v1"

PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = PROJECT_ROOT / "state" / "dry_runs" / "19_backup_execute"
GENERATED_ROOT = PROJECT_ROOT / "state" / "generated" / "backup"

PREBACKUP_MANIFEST_PATH = (
        PROJECT_ROOT / "state" / "generated" / "prebackup" / "latest_artifacts_manifest.json"
)
PREBACKUP_MANIFEST_MD_PATH = (
        PROJECT_ROOT / "state" / "generated" / "prebackup" / "latest_artifacts_manifest.md"
)

ROOT_ENV_FILE = Path("/etc/wantless-recovery/recovery.env")

DEFAULT_PROFILE = "vault-primary"
DEFAULT_CONFIRM_TOKEN = "BACKUP_EXECUTE:vault-primary"
DEFAULT_MAX_PREBACKUP_AGE_HOURS = 24.0

EXPECTED_VAULT_MOUNT = "/mnt/wantless_recovery"
EXPECTED_REPO = "/mnt/wantless_recovery/06_borg/repository"

FORBIDDEN_ACTIONS = [
    "scripts/03_cryptsetup.sh prepare-luks2-vault",
    "scripts/03_cryptsetup.sh backup-header",
    "scripts/03_cryptsetup.sh build-emergency-packet",
    "scripts/06_borg.sh export-key --profile vault-primary --execute",
    "scripts/07_borgmatic.sh repo-create-guarded --profile vault-primary --execute",
    "scripts/07_borgmatic.sh prune-compact --profile vault-primary --execute",
    "scripts/11_flatpak.sh offline-export execution",
    "scripts/12_pipx.sh build-critical-wheelhouse",
    "scripts/14_docker.sh export-selected-image",
    "scripts/14_docker.sh volume-export-quiesced",
    "scripts/15_portainer.sh export-staged-lts-image",
    "scripts/15_portainer.sh volume-export-quiesced",
    "scripts/16_postgresql.sh restore-disposable --execute",
    "scripts/17_libvirt.sh qemu-img repair",
    "scripts/18_runbooks.sh retire-old-placeholders --execute",
]

BACKUP_PAYLOAD_CONTRACT = {
    "actual_backup_writer": "Row 07 Borgmatic",
    "activation_boundary": "Row 08 manual-backup --unit-context system",
    "profile": DEFAULT_PROFILE,
    "vault_mount": EXPECTED_VAULT_MOUNT,
    "repository": EXPECTED_REPO,
    "configured_source_directories": ["/home/wantless", "/etc", "/opt", "/usr/local"],
    "configured_recovery_runtime_excludes": [
        "state/dry_runs",
        "state/local_test",
        "state/tmp",
        "archive",
    ],
    "timer_enabled_here": False,
    "forbidden_in_this_wrapper": FORBIDDEN_ACTIONS,
}


@dataclass(frozen=True)
class StepSpec:
    phase: str
    row: str
    label: str
    argv: list[str]
    required: bool = True
    expect_report: bool = True
    root_env: bool = False
    sudo: bool = False
    report_command: str | None = None
    notes: str = ""


@dataclass
class StepResult:
    phase: str
    row: str
    label: str
    argv: list[str]
    required: bool
    expect_report: bool
    root_env: bool = False
    sudo: bool = False
    effective_argv: list[str] = field(default_factory=list)
    started_at: str | None = None
    completed_at: str | None = None
    duration_seconds: float | None = None
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


def parse_iso_datetime(value: str) -> datetime | None:
    if not value:
        return None
    try:
        normalized = value.replace("Z", "+00:00")
        dt = datetime.fromisoformat(normalized)
    except Exception:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=datetime.now().astimezone().tzinfo)
    return dt


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def resolve_project_path(value: str | None) -> Path | None:
    if not value:
        return None
    path = Path(value)
    if path.is_absolute():
        return path
    return PROJECT_ROOT / path


def slug(value: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return text.strip("_") or "item"


def ensure_user_context() -> None:
    if os.geteuid() == 0:
        raise SystemExit(
            "STOP: run this wrapper as the logged-in user, not root. "
            "Root backup work is invoked through sudo and Row 08."
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


def sha256_file(path: Path) -> str | None:
    if not path.exists() or not path.is_file():
        return None

    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_from_argv(argv: list[str]) -> str:
    if len(argv) >= 2 and argv[0].startswith("scripts/"):
        return argv[1]
    if argv:
        return Path(argv[0]).name
    return "unknown"


def parse_report_paths(text: str) -> list[Path]:
    paths: list[Path] = []
    for line in text.splitlines():
        match = re.search(r"\breport:\s+(.+)$", line.strip())
        if not match:
            continue
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
        return None, [f"row report is not valid JSON or is not readable: {rel(report_path)}"], []

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


def root_env_loader_argv(
        argv: list[str],
        *,
        sudo_noninteractive: bool,
) -> tuple[list[str], list[str]]:
    payload = "\n".join(
        [
            "set -euo pipefail",
            f"ENV_FILE={shlex.quote(str(ROOT_ENV_FILE))}",
            'test -f "$ENV_FILE"',
            'test -r "$ENV_FILE"',
            "set -a",
            '. "$ENV_FILE"',
            "set +a",
            f"cd {shlex.quote(str(PROJECT_ROOT))}",
            'exec "$@"',
        ]
    )

    prefix = ["sudo"]
    if sudo_noninteractive:
        prefix.append("-n")

    final_argv = prefix + ["bash", "-c", payload, "root-env-command"] + argv
    effective_argv = prefix + ["bash", "-c", "<root-env-loader>", "root-env-command"] + argv
    return final_argv, effective_argv


def sudo_argv(argv: list[str], *, sudo_noninteractive: bool) -> tuple[list[str], list[str]]:
    prefix = ["sudo"]
    if sudo_noninteractive:
        prefix.append("-n")
    return prefix + argv, prefix + argv


def build_effective_argv(
        spec: StepSpec,
        *,
        sudo_noninteractive: bool,
) -> tuple[list[str], list[str]]:
    if spec.root_env:
        return root_env_loader_argv(spec.argv, sudo_noninteractive=sudo_noninteractive)
    if spec.sudo:
        return sudo_argv(spec.argv, sudo_noninteractive=sudo_noninteractive)
    return spec.argv, spec.argv


def root_env_contract_script() -> str:
    project_root = str(PROJECT_ROOT)

    return "\n".join(
        [
            "set -euo pipefail",
            f"ENV_FILE={shlex.quote(str(ROOT_ENV_FILE))}",
            'test -f "$ENV_FILE"',
            'test -r "$ENV_FILE"',
            "set -a",
            '. "$ENV_FILE"',
            "set +a",
            f'test "${{RECOVERY_PROJECT_ROOT:-}}" = {shlex.quote(project_root)}',
            f'test "${{RECOVERY_PROFILE:-}}" = {shlex.quote(DEFAULT_PROFILE)}',
            f'test "${{RECOVERY_VAULT_MOUNT:-}}" = {shlex.quote(EXPECTED_VAULT_MOUNT)}',
            'if [[ -z "${BORG_PASSPHRASE:-}" && -z "${BORG_PASSCOMMAND:-}" ]]; then exit 97; fi',
            "printf 'root env contract: ok\\n'",
        ]
    )


def run_step(
        index: int,
        spec: StepSpec,
        run_dir: Path,
        *,
        sudo_noninteractive: bool,
        fail_on_warnings: bool,
) -> StepResult:
    label_slug = slug(f"{index:03d}_{spec.phase}_{spec.row}_{spec.label}")
    stdout_path = run_dir / "commands" / f"{label_slug}.stdout.txt"
    stderr_path = run_dir / "commands" / f"{label_slug}.stderr.txt"

    result = StepResult(
        phase=spec.phase,
        row=spec.row,
        label=spec.label,
        argv=spec.argv,
        required=spec.required,
        expect_report=spec.expect_report,
        root_env=spec.root_env,
        sudo=spec.sudo,
        stdout_path=rel(stdout_path),
        stderr_path=rel(stderr_path),
        notes=spec.notes,
    )

    if spec.argv and spec.argv[0].startswith("scripts/"):
        script_path = PROJECT_ROOT / spec.argv[0]
        if not script_path.exists():
            result.returncode = 127
            result.failures.append(f"missing script: {spec.argv[0]}")
            return result
        if not os.access(script_path, os.X_OK):
            result.returncode = 126
            result.failures.append(f"script is not executable: {spec.argv[0]}")
            return result

    final_argv, effective_argv = build_effective_argv(
        spec,
        sudo_noninteractive=sudo_noninteractive,
    )
    result.effective_argv = effective_argv

    started = datetime.now(timezone.utc)
    result.started_at = started.astimezone().isoformat()
    report_mtime_floor = started.timestamp() - 1.0

    proc = subprocess.run(
        final_argv,
        cwd=PROJECT_ROOT,
        text=True,
        capture_output=True,
    )

    completed = datetime.now(timezone.utc)
    result.completed_at = completed.astimezone().isoformat()
    result.duration_seconds = round((completed - started).total_seconds(), 3)
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
        if "sudo:" in (proc.stderr or "").lower():
            result.failures.append("sudo failed. Run `sudo -v`, then rerun this script.")

    if spec.expect_report:
        report_ok, report_failures, report_warnings = report_status(report_path)
        result.report_ok = report_ok
        result.failures.extend(report_failures)
        result.warnings.extend(report_warnings)
    else:
        result.report_ok = None

    if fail_on_warnings and result.warnings:
        result.failures.append("warnings were treated as failures for this run")

    result.ok = not result.failures
    return result


def print_step_result(result: StepResult) -> None:
    status = "PASS" if result.ok else "FAIL"
    req = "required" if result.required else "optional"
    root_suffix = " root-env" if result.root_env else " sudo" if result.sudo else ""
    print(f"[{result.phase}]{root_suffix} {result.row} {result.label}: {status} ({req})")
    if result.report_path:
        print(f"  report: {result.report_path}")
    if result.duration_seconds is not None:
        print(f"  duration_seconds: {result.duration_seconds}")
    for failure in result.failures:
        print(f"  failure: {failure}")
    for warning in result.warnings[:5]:
        print(f"  warning: {warning}")
    if len(result.warnings) > 5:
        print(f"  warning: ... {len(result.warnings) - 5} more warnings in report")


def result_to_dict(result: StepResult) -> dict[str, Any]:
    return {
        "phase": result.phase,
        "row": result.row,
        "label": result.label,
        "argv": result.argv,
        "effective_argv": result.effective_argv,
        "required": result.required,
        "expect_report": result.expect_report,
        "root_env": result.root_env,
        "sudo": result.sudo,
        "started_at": result.started_at,
        "completed_at": result.completed_at,
        "duration_seconds": result.duration_seconds,
        "returncode": result.returncode,
        "ok": result.ok,
        "report_ok": result.report_ok,
        "report_path": result.report_path,
        "stdout_path": result.stdout_path,
        "stderr_path": result.stderr_path,
        "failures": result.failures,
        "warnings": result.warnings,
        "notes": result.notes,
    }


def run_phase(
        title: str,
        specs: list[StepSpec],
        run_dir: Path,
        *,
        start_index: int,
        sudo_noninteractive: bool,
        fail_on_warnings: bool,
        stop_on_required_failure: bool,
) -> tuple[bool, list[StepResult]]:
    print(f"\n===== {title} =====")
    results: list[StepResult] = []

    for offset, spec in enumerate(specs):
        result = run_step(
            start_index + offset,
            spec,
            run_dir,
            sudo_noninteractive=sudo_noninteractive,
            fail_on_warnings=fail_on_warnings,
        )
        print_step_result(result)
        results.append(result)

        if stop_on_required_failure and spec.required and not result.ok:
            print(f"\n{title}: STOP after required failure")
            break

    ok = all(result.ok or not result.required for result in results)
    print(f"\n{title}: {'PASS' if ok else 'FAIL'}")
    return ok, results


def validate_prebackup_manifest(*, max_age_hours: float, allow_stale: bool) -> dict[str, Any]:
    status: dict[str, Any] = {
        "path": rel(PREBACKUP_MANIFEST_PATH),
        "md_path": rel(PREBACKUP_MANIFEST_MD_PATH),
        "exists": PREBACKUP_MANIFEST_PATH.exists(),
        "ok": False,
        "failures": [],
        "warnings": [],
        "generated_at": None,
        "age_hours": None,
        "backup_ready": None,
        "refresh_complete": None,
        "health_phase_ok": None,
        "data_phase_ok": None,
        "latest_database_dump_bundle": None,
        "latest_valid_emergency_packet": None,
        "latest_luks_header_count": 0,
        "latest_borg_key_export_count": 0,
        "source_run_dir": None,
        "source_run_report": None,
    }

    if not PREBACKUP_MANIFEST_PATH.exists():
        status["failures"].append("latest prebackup manifest is missing")
        return status

    manifest = load_json(PREBACKUP_MANIFEST_PATH)
    if manifest is None:
        status["failures"].append("latest prebackup manifest is not valid JSON")
        return status

    status["schema"] = manifest.get("schema")
    status["generated_at"] = manifest.get("generated_at")
    status["backup_ready"] = manifest.get("backup_ready")
    status["refresh_complete"] = manifest.get("refresh_complete")
    status["health_phase_ok"] = manifest.get("health_phase_ok")
    status["data_phase_ok"] = manifest.get("data_phase_ok")
    status["manifest_ok"] = manifest.get("ok")
    status["data_step_count"] = manifest.get("data_step_count")
    status["source_run_dir"] = manifest.get("source_run_dir")
    status["latest_database_dump_bundle"] = manifest.get("latest_database_dump_bundle")
    status["latest_valid_emergency_packet"] = manifest.get("latest_valid_emergency_packet")
    status["manifest_sha256"] = sha256_file(PREBACKUP_MANIFEST_PATH)

    if manifest.get("ok") is not True:
        status["failures"].append("latest prebackup manifest ok is not true")
    if manifest.get("backup_ready") is not True:
        status["failures"].append("latest prebackup manifest backup_ready is not true")
    if manifest.get("refresh_complete") is not True:
        status["failures"].append("latest prebackup manifest refresh_complete is not true")
    if manifest.get("health_phase_ok") is not True:
        status["failures"].append("latest prebackup manifest health_phase_ok is not true")
    if manifest.get("data_phase_ok") is not True:
        status["failures"].append("latest prebackup manifest data_phase_ok is not true")

    try:
        data_step_count = int(manifest.get("data_step_count") or 0)
    except Exception:
        data_step_count = 0
    if data_step_count <= 0:
        status["failures"].append("latest prebackup manifest has no data steps")

    if manifest.get("host") != socket.gethostname():
        status["failures"].append(
            f"latest prebackup manifest host {manifest.get('host')!r} "
            f"does not match current host {socket.gethostname()!r}"
        )

    manifest_project_root = manifest.get("project_root")
    if manifest_project_root and Path(str(manifest_project_root)).resolve() != PROJECT_ROOT:
        status["failures"].append(
            f"latest prebackup manifest project_root {manifest_project_root!r} "
            f"does not match {str(PROJECT_ROOT)!r}"
        )

    generated_at = manifest.get("generated_at")
    if generated_at:
        dt = parse_iso_datetime(str(generated_at))
        if dt is None:
            status["failures"].append("latest prebackup manifest generated_at is not parseable")
        else:
            age_hours = (
                                datetime.now(timezone.utc) - dt.astimezone(timezone.utc)
                        ).total_seconds() / 3600.0
            status["age_hours"] = round(age_hours, 3)
            if age_hours > max_age_hours:
                message = (
                    f"latest prebackup manifest is stale: age_hours={age_hours:.2f}, "
                    f"max_age_hours={max_age_hours:.2f}"
                )
                if allow_stale:
                    status["warnings"].append(message)
                else:
                    status["failures"].append(message)
    else:
        status["failures"].append("latest prebackup manifest has no generated_at")

    source_run_dir = manifest.get("source_run_dir")
    if source_run_dir:
        source_report = PROJECT_ROOT / str(source_run_dir) / "prebackup_refresh_report.json"
        status["source_run_report"] = rel(source_report)
        if not source_report.exists():
            status["failures"].append("prebackup source run report is missing")
        else:
            source_payload = load_json(source_report)
            if source_payload is None:
                status["failures"].append("prebackup source run report is not readable JSON")
            elif source_payload.get("ok") is not True:
                status["failures"].append("prebackup source run report ok is not true")
    else:
        status["failures"].append("latest prebackup manifest has no source_run_dir")

    db_bundle = manifest.get("latest_database_dump_bundle")
    if not isinstance(db_bundle, dict):
        status["failures"].append("latest prebackup manifest has no latest_database_dump_bundle")
    else:
        if db_bundle.get("complete") is not True:
            status["failures"].append("latest prebackup database dump bundle is not complete")
        if db_bundle.get("path"):
            dump_path = resolve_project_path(str(db_bundle["path"]))
            if not dump_path or not dump_path.exists() or not dump_path.is_dir():
                status["failures"].append(
                    f"latest prebackup database dump path does not exist: {db_bundle['path']}"
                )
        else:
            status["failures"].append("latest prebackup database dump bundle has no path")

    emergency_packet = manifest.get("latest_valid_emergency_packet")
    if not isinstance(emergency_packet, dict) or emergency_packet.get("valid") is not True:
        status["failures"].append("latest_valid_emergency_packet is missing or invalid")
    else:
        packet_path = resolve_project_path(str(emergency_packet.get("path") or ""))
        if not packet_path or not packet_path.exists() or not packet_path.is_file():
            status["failures"].append("latest_valid_emergency_packet path is missing on disk")

    luks_headers = manifest.get("latest_luks_header_backups") or []
    if not isinstance(luks_headers, list) or not luks_headers:
        status["failures"].append("latest_luks_header_backups is empty")
    else:
        status["latest_luks_header_count"] = len(luks_headers)

    borg_keys = manifest.get("latest_borg_key_exports") or []
    if not isinstance(borg_keys, list) or not borg_keys:
        status["failures"].append("latest_borg_key_exports is empty")
    else:
        status["latest_borg_key_export_count"] = len(borg_keys)

    commands_run = manifest.get("commands_run") or []
    if not isinstance(commands_run, list) or not commands_run:
        status["failures"].append("latest prebackup manifest commands_run is empty")
    else:
        status["command_count"] = len(commands_run)

    status["ok"] = not status["failures"]
    return status


def required_failed(results: list[StepResult]) -> list[StepResult]:
    return [result for result in results if result.required and not result.ok]


def optional_failed(results: list[StepResult]) -> list[StepResult]:
    return [result for result in results if not result.required and not result.ok]


def step_ok(results: list[StepResult], row: str, label_contains: str) -> bool:
    return any(
        result.row == row and label_contains in result.label and result.ok
        for result in results
    )


def rescuezilla_image_proven(results: list[StepResult]) -> bool:
    list_ok = step_ok(results, "02_rescuezilla", "list-images")
    validate_ok = step_ok(results, "02_rescuezilla", "validate-image-manifest")
    return list_ok and validate_ok


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


def latest_files(root: Path, *, max_items: int = 50) -> list[dict[str, Any]]:
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


def latest_generated_snapshot() -> dict[str, list[dict[str, Any]]]:
    generated = PROJECT_ROOT / "state" / "generated"
    roots = [
        "backup",
        "prebackup",
        "07_borgmatic",
        "13_desktop",
        "14_docker",
        "15_portainer",
        "16_postgresql",
        "17_libvirt",
        "18_runbooks",
    ]
    return {root: latest_files(generated / root, max_items=50) for root in roots}


def maybe_load_report(path_value: str | None) -> dict[str, Any] | None:
    path = resolve_project_path(path_value)
    if not path:
        return None
    return load_json(path)


def summarize_archive_reports(results: list[StepResult]) -> dict[str, Any]:
    summary: dict[str, Any] = {
        "repo_info_reports": [],
        "list_archive_reports": [],
        "archive_inventory_reports": [],
    }

    for result in results:
        if result.row != "06_borg" or not result.report_path:
            continue

        payload = maybe_load_report(result.report_path)
        item: dict[str, Any] = {
            "label": result.label,
            "report_path": result.report_path,
            "ok": result.ok,
        }

        if payload:
            for key in (
                    "repository",
                    "repository_path",
                    "archive",
                    "archive_name",
                    "latest_archive",
                    "newest_archive",
            ):
                if key in payload:
                    item[key] = payload.get(key)

            archive_inventory = payload.get("archive_inventory")
            if isinstance(archive_inventory, dict):
                item["archive_inventory_keys"] = sorted(archive_inventory.keys())
                for count_key in ("archive_count", "count", "total_archives"):
                    if count_key in archive_inventory:
                        item["archive_count"] = archive_inventory.get(count_key)
                for name_key in ("latest_archive", "newest_archive", "archive"):
                    if name_key in archive_inventory:
                        item["latest_archive"] = archive_inventory.get(name_key)

            repository_info = payload.get("repository_info")
            if isinstance(repository_info, dict):
                item["repository_info_keys"] = sorted(repository_info.keys())

        if "repo-info" in result.label:
            summary["repo_info_reports"].append(item)
        elif "list-archives" in result.label:
            summary["list_archive_reports"].append(item)
        elif "archive-inventory" in result.label:
            summary["archive_inventory_reports"].append(item)

    return summary


def build_preflight_steps(*, require_rescuezilla_image: bool) -> list[StepSpec]:
    return [
        StepSpec(
            "preflight",
            "19_backup_execute",
            "root-env-contract",
            ["bash", "-c", root_env_contract_script()],
            sudo=True,
            expect_report=False,
            notes="Check root-only recovery.env contract without printing secret values.",
        ),
        StepSpec(
            "preflight",
            "19_backup_execute",
            "vault-repository-path-exists",
            ["/usr/bin/test", "-d", EXPECTED_REPO],
            sudo=True,
            expect_report=False,
            notes="Prove root can see the root-owned Borg repository path.",
        ),
        StepSpec(
            "preflight",
            "08_systemd",
            "assert-mount-condition",
            ["scripts/08_systemd.sh", "assert-mount-condition"],
            notes="Prove expected mounted vault and repository parent condition.",
        ),
        StepSpec(
            "preflight",
            "07_borgmatic",
            "validate-vault-primary-root-env",
            ["scripts/07_borgmatic.sh", "validate", "--profile", DEFAULT_PROFILE],
            root_env=True,
            report_command="validate",
            notes="Production Borgmatic validation under root recovery.env.",
        ),
        StepSpec(
            "preflight",
            "06_borg",
            "repo-info-pre",
            ["scripts/06_borg.sh", "repo-info", "--profile", DEFAULT_PROFILE],
            root_env=True,
            report_command="repo-info",
            notes="Read-only repository identity proof before backup action.",
        ),
        StepSpec(
            "preflight",
            "06_borg",
            "list-archives-pre",
            ["scripts/06_borg.sh", "list-archives", "--profile", DEFAULT_PROFILE],
            root_env=True,
            required=False,
            report_command="list-archives",
            notes="Pre-action archive list. Optional before first archive.",
        ),
        StepSpec(
            "preflight",
            "02_rescuezilla",
            "list-images",
            ["scripts/02_rescuezilla.sh", "list-images"],
            required=require_rescuezilla_image,
            notes=(
                "Advisory by default. Required only when --require-rescuezilla-image "
                "is set for blank-machine package completeness."
            ),
        ),
        StepSpec(
            "preflight",
            "02_rescuezilla",
            "validate-image-manifest",
            ["scripts/02_rescuezilla.sh", "validate-image-manifest"],
            required=require_rescuezilla_image,
            notes=(
                "Advisory by default. This wrapper never creates a Rescuezilla image."
            ),
        ),
    ]


def build_pre_action_proof_steps() -> list[StepSpec]:
    return [
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "assert-required-artifacts-source",
            ["scripts/18_runbooks.sh", "assert-required-artifacts", "--level", "source"],
            report_command="assert-required-artifacts",
        ),
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "render-index",
            ["scripts/18_runbooks.sh", "render-index"],
        ),
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "generate-proof-bundle-index",
            ["scripts/18_runbooks.sh", "generate-proof-bundle-index"],
        ),
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "check-completeness",
            ["scripts/18_runbooks.sh", "check-completeness"],
        ),
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "validate-stop-conditions",
            ["scripts/18_runbooks.sh", "validate-stop-conditions"],
        ),
        StepSpec(
            "pre-action-proof",
            "18_runbooks",
            "validate-checklist",
            ["scripts/18_runbooks.sh", "validate-checklist"],
        ),
        StepSpec(
            "pre-action-proof",
            "04_integrity",
            "verify-restore-gate-pre-action",
            ["scripts/04_integrity.sh", "verify-restore-gate"],
            report_command="verify-restore-gate",
            notes="Runs before backup so current proof artifacts can be included in execute-mode archive.",
        ),
    ]


def build_dry_run_step(phase: str) -> StepSpec:
    return StepSpec(
        phase,
        "08_systemd",
        "manual-backup-dry-run-system",
        ["scripts/08_systemd.sh", "manual-backup", "--unit-context", "system"],
        root_env=True,
        report_command="manual-backup",
        notes="Row 08 activation boundary. This invokes Row 07 dry-run, not backup execution.",
    )


def build_execute_step() -> StepSpec:
    return StepSpec(
        "execute",
        "08_systemd",
        "manual-backup-execute-system",
        ["scripts/08_systemd.sh", "manual-backup", "--unit-context", "system", "--execute"],
        root_env=True,
        report_command="manual-backup",
        notes=(
            "Real backup execution through Row 08. Row 08 config invokes "
            "Row 07 backup --profile vault-primary --execute with Row 07's owning token."
        ),
    )


def build_post_action_steps(*, mode: str) -> list[StepSpec]:
    archive_required = mode == "execute"

    return [
        StepSpec(
            "post-action",
            "07_borgmatic",
            "check-vault-primary-post",
            ["scripts/07_borgmatic.sh", "check", "--profile", DEFAULT_PROFILE],
            root_env=True,
            report_command="check",
            notes="Repository/archive consistency check through Row 07.",
        ),
        StepSpec(
            "post-action",
            "06_borg",
            "repo-info-post",
            ["scripts/06_borg.sh", "repo-info", "--profile", DEFAULT_PROFILE],
            root_env=True,
            report_command="repo-info",
            notes="Borg repository identity/read proof through Row 06.",
        ),
        StepSpec(
            "post-action",
            "06_borg",
            "list-archives-post",
            ["scripts/06_borg.sh", "list-archives", "--profile", DEFAULT_PROFILE],
            root_env=True,
            required=archive_required,
            report_command="list-archives",
            notes="Required after execute, advisory after dry-run.",
        ),
        StepSpec(
            "post-action",
            "06_borg",
            "capture-archive-inventory-post",
            ["scripts/06_borg.sh", "capture-archive-inventory", "--profile", DEFAULT_PROFILE],
            root_env=True,
            required=archive_required,
            report_command="capture-archive-inventory",
            notes="Required after execute, advisory after dry-run.",
        ),
        StepSpec(
            "post-action",
            "09_journalctl",
            "capture-recovery-units",
            ["scripts/09_journalctl.sh", "capture-recovery-units"],
        ),
        StepSpec(
            "post-action",
            "09_journalctl",
            "capture-timer-history",
            ["scripts/09_journalctl.sh", "capture-timer-history"],
        ),
        StepSpec(
            "post-action",
            "09_journalctl",
            "capture-failure-context",
            ["scripts/09_journalctl.sh", "capture-failure-context"],
        ),
    ]


def build_post_archive_evidence_steps() -> list[StepSpec]:
    return [
        StepSpec(
            "post-archive-evidence",
            "18_runbooks",
            "generate-proof-bundle-index-post",
            ["scripts/18_runbooks.sh", "generate-proof-bundle-index"],
            notes=(
                "Post-action evidence. In execute mode this is written after the archive "
                "and is not inside the just-created archive."
            ),
        ),
        StepSpec(
            "post-archive-evidence",
            "18_runbooks",
            "check-completeness-post",
            ["scripts/18_runbooks.sh", "check-completeness"],
        ),
        StepSpec(
            "post-archive-evidence",
            "18_runbooks",
            "validate-stop-conditions-post",
            ["scripts/18_runbooks.sh", "validate-stop-conditions"],
        ),
        StepSpec(
            "post-archive-evidence",
            "18_runbooks",
            "validate-checklist-post",
            ["scripts/18_runbooks.sh", "validate-checklist"],
        ),
        StepSpec(
            "post-archive-evidence",
            "04_integrity",
            "verify-restore-gate-post",
            ["scripts/04_integrity.sh", "verify-restore-gate"],
            report_command="verify-restore-gate",
            notes=(
                "Post-action integrity evidence. In execute mode this is written after "
                "the archive and is not inside the just-created archive."
            ),
        ),
    ]


def build_failure_evidence_steps() -> list[StepSpec]:
    return [
        StepSpec(
            "failure-evidence",
            "09_journalctl",
            "capture-recovery-units",
            ["scripts/09_journalctl.sh", "capture-recovery-units"],
            required=False,
        ),
        StepSpec(
            "failure-evidence",
            "09_journalctl",
            "capture-timer-history",
            ["scripts/09_journalctl.sh", "capture-timer-history"],
            required=False,
        ),
        StepSpec(
            "failure-evidence",
            "09_journalctl",
            "capture-failure-context",
            ["scripts/09_journalctl.sh", "capture-failure-context"],
            required=False,
        ),
    ]


def phase_ok(results: list[StepResult], phase: str) -> bool:
    phase_results = [result for result in results if result.phase == phase]
    return bool(phase_results) and not required_failed(phase_results)


def compute_status(
        *,
        mode: str,
        prebackup_status: dict[str, Any],
        results: list[StepResult],
        actual_backup_executed: bool,
) -> dict[str, Any]:
    prebackup_ok = bool(prebackup_status.get("ok"))
    preflight_ok = phase_ok(results, "preflight")
    pre_action_proof_ok = phase_ok(results, "pre-action-proof")
    pre_execute_dry_run_results = [r for r in results if r.phase == "pre-execute-dry-run"]
    dry_run_action_results = [r for r in results if r.phase == "dry-run-action"]
    execute_results = [r for r in results if r.phase == "execute"]

    if mode == "execute":
        dry_run_ok = bool(pre_execute_dry_run_results) and not required_failed(
            pre_execute_dry_run_results)
        action_ok = bool(execute_results) and not required_failed(execute_results)
    else:
        dry_run_ok = bool(dry_run_action_results) and not required_failed(dry_run_action_results)
        action_ok = dry_run_ok

    post_action_evidence_ok = phase_ok(results, "post-action")
    post_archive_evidence_ok = phase_ok(results, "post-archive-evidence")

    archive_inventory_ok = step_ok(results, "06_borg", "capture-archive-inventory-post")
    archive_list_ok = step_ok(results, "06_borg", "list-archives-post")
    borg_transaction_complete = bool(
        mode == "execute"
        and actual_backup_executed
        and action_ok
        and archive_inventory_ok
        and archive_list_ok
        and post_action_evidence_ok
    )

    db_proven = False
    dump = prebackup_status.get("latest_database_dump_bundle")
    if isinstance(dump, dict):
        db_proven = dump.get("complete") is True and bool(dump.get("path"))

    luks_proven = bool(
        prebackup_status.get("latest_valid_emergency_packet", {}).get("valid")
        and int(prebackup_status.get("latest_luks_header_count") or 0) > 0
    )
    borg_key_proven = int(prebackup_status.get("latest_borg_key_export_count") or 0) > 0
    rescuezilla_proven = rescuezilla_image_proven(results)

    blank_machine_complete = bool(
        rescuezilla_proven
        and borg_transaction_complete
        and db_proven
        and luks_proven
        and borg_key_proven
    )

    required_failures = required_failed(results)

    return {
        "prebackup_ok": prebackup_ok,
        "preflight_ok": preflight_ok,
        "pre_action_proof_ok": pre_action_proof_ok,
        "dry_run_ok": dry_run_ok,
        "action_ok": action_ok,
        "post_action_evidence_ok": post_action_evidence_ok,
        "post_archive_evidence_ok": post_archive_evidence_ok,
        "backup_executed": bool(actual_backup_executed),
        "borg_transaction_complete": borg_transaction_complete,
        "rescuezilla_image_proven": rescuezilla_proven,
        "database_logical_dump_proven": db_proven,
        "luks_recovery_material_proven": luks_proven,
        "borg_key_export_proven": borg_key_proven,
        "blank_machine_recovery_package_complete": blank_machine_complete,
        "post_archive_evidence_in_current_archive": False if mode == "execute" else None,
        "archive_inventory_ok": archive_inventory_ok,
        "archive_list_ok": archive_list_ok,
        "required_failure_count": len(required_failures),
        "ok": bool(
            prebackup_ok
            and preflight_ok
            and pre_action_proof_ok
            and action_ok
            and post_action_evidence_ok
            and post_archive_evidence_ok
            and not required_failures
        ),
    }


def build_execution_manifest(
        *,
        run_dir: Path,
        mode: str,
        stage: str,
        prebackup_status: dict[str, Any],
        results: list[StepResult],
        actual_backup_executed: bool,
) -> dict[str, Any]:
    status = compute_status(
        mode=mode,
        prebackup_status=prebackup_status,
        results=results,
        actual_backup_executed=actual_backup_executed,
    )
    failed = [result for result in results if not result.ok]
    warnings = [
        {
            "phase": result.phase,
            "row": result.row,
            "label": result.label,
            "warnings": result.warnings,
            "report_path": result.report_path,
        }
        for result in results
        if result.warnings
    ]

    manifest = {
        "schema": "recovery.backup_execution_manifest.v1",
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "mode": mode,
        "stage": stage,
        "ok": status["ok"],
        **status,
        "timer_enabled_here": False,
        "backup_payload_contract": BACKUP_PAYLOAD_CONTRACT,
        "prebackup_manifest": prebackup_status,
        "reports": [
            {
                "phase": result.phase,
                "row": result.row,
                "label": result.label,
                "ok": result.ok,
                "required": result.required,
                "report_path": result.report_path,
                "root_env": result.root_env,
                "sudo": result.sudo,
                "notes": result.notes,
            }
            for result in results
        ],
        "archive_summary": summarize_archive_reports(results),
        "failures": [
            {
                "phase": result.phase,
                "row": result.row,
                "label": result.label,
                "failures": result.failures,
                "report_path": result.report_path,
            }
            for result in failed
        ],
        "warnings": warnings,
        "restore_note": (
            "Use Rescuezilla USB for baseline bare-metal restore when a Row 02 "
            "image is available, then open the Row 03 vault and use the Row 06/07 "
            "Borg repository for post-image filesystem deltas. PostgreSQL recovery "
            "authority remains the Row 16 logical dump bundle referenced by the "
            "prebackup manifest."
        ),
    }
    return manifest


def execution_manifest_md(manifest: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# Backup execution manifest")
    lines.append("")
    for key in [
        "generated_at",
        "host",
        "mode",
        "stage",
        "ok",
        "prebackup_ok",
        "preflight_ok",
        "pre_action_proof_ok",
        "dry_run_ok",
        "action_ok",
        "post_action_evidence_ok",
        "post_archive_evidence_ok",
        "backup_executed",
        "borg_transaction_complete",
        "rescuezilla_image_proven",
        "database_logical_dump_proven",
        "luks_recovery_material_proven",
        "borg_key_export_proven",
        "blank_machine_recovery_package_complete",
        "post_archive_evidence_in_current_archive",
    ]:
        lines.append(f"- {key}: `{manifest.get(key)}`")
    lines.append("")

    contract = manifest.get("backup_payload_contract", {})
    lines.append("## Backup payload contract")
    lines.append("")
    lines.append(f"- actual_backup_writer: `{contract.get('actual_backup_writer')}`")
    lines.append(f"- activation_boundary: `{contract.get('activation_boundary')}`")
    lines.append(f"- repository: `{contract.get('repository')}`")
    lines.append(f"- vault_mount: `{contract.get('vault_mount')}`")
    lines.append(
        "- configured_source_directories: "
        + ", ".join(f"`{item}`" for item in contract.get("configured_source_directories", []))
    )
    lines.append(
        "- configured_recovery_runtime_excludes: "
        + ", ".join(
            f"`{item}`" for item in contract.get("configured_recovery_runtime_excludes", [])
        )
    )
    lines.append("")

    pre = manifest.get("prebackup_manifest", {})
    lines.append("## Prebackup manifest")
    lines.append("")
    lines.append(f"- ok: `{pre.get('ok')}`")
    lines.append(f"- generated_at: `{pre.get('generated_at')}`")
    lines.append(f"- age_hours: `{pre.get('age_hours')}`")
    lines.append(f"- path: `{pre.get('path')}`")
    lines.append(f"- manifest_sha256: `{pre.get('manifest_sha256')}`")
    lines.append(f"- source_run_dir: `{pre.get('source_run_dir')}`")
    lines.append(f"- source_run_report: `{pre.get('source_run_report')}`")
    lines.append(f"- data_step_count: `{pre.get('data_step_count')}`")
    lines.append(f"- command_count: `{pre.get('command_count')}`")
    dump = pre.get("latest_database_dump_bundle")
    if isinstance(dump, dict):
        lines.append(f"- latest_database_dump_bundle: `{dump.get('path')}`")
        lines.append(f"- latest_database_dump_complete: `{dump.get('complete')}`")
    packet = pre.get("latest_valid_emergency_packet")
    if isinstance(packet, dict):
        lines.append(f"- latest_valid_emergency_packet: `{packet.get('path')}`")
    lines.append(f"- latest_luks_header_count: `{pre.get('latest_luks_header_count')}`")
    lines.append(f"- latest_borg_key_export_count: `{pre.get('latest_borg_key_export_count')}`")
    lines.append("")

    lines.append("## Reports")
    lines.append("")
    lines.append("| Phase | Row | Label | Required | OK | Report |")
    lines.append("|---|---|---|---:|---:|---|")
    for item in manifest.get("reports", []):
        lines.append(
            f"| {item.get('phase')} | {item.get('row')} | `{item.get('label')}` | "
            f"{item.get('required')} | {item.get('ok')} | `{item.get('report_path') or ''}` |"
        )
    lines.append("")

    archive_summary = manifest.get("archive_summary", {})
    lines.append("## Archive summary")
    lines.append("")
    for key in ("repo_info_reports", "list_archive_reports", "archive_inventory_reports"):
        values = archive_summary.get(key) or []
        lines.append(f"### {key}")
        if not values:
            lines.append("- none")
            continue
        for value in values:
            bits = [f"`{value.get('report_path')}`"]
            if "archive_count" in value:
                bits.append(f"archive_count={value.get('archive_count')}")
            if "latest_archive" in value:
                bits.append(f"latest_archive={value.get('latest_archive')}")
            lines.append("- " + " | ".join(bits))
    lines.append("")

    failures = manifest.get("failures") or []
    if failures:
        lines.append("## Failures")
        lines.append("")
        for item in failures:
            lines.append(f"- `{item.get('phase')}:{item.get('row')}:{item.get('label')}`")
            for failure in item.get("failures", []):
                lines.append(f"  - {failure}")
        lines.append("")

    warnings = manifest.get("warnings") or []
    if warnings:
        lines.append("## Warnings")
        lines.append("")
        for item in warnings:
            lines.append(f"- `{item.get('phase')}:{item.get('row')}:{item.get('label')}`")
            for warning in item.get("warnings", []):
                lines.append(f"  - {warning}")
        lines.append("")

    return "\n".join(lines) + "\n"


def write_execution_manifest(
        *,
        run_dir: Path,
        report: dict[str, Any],
        manifest: dict[str, Any],
        stable_name: str,
) -> tuple[Path, Path]:
    json_path = GENERATED_ROOT / f"{stable_name}.json"
    md_path = GENERATED_ROOT / f"{stable_name}.md"

    write_json(json_path, manifest)
    write_text(md_path, execution_manifest_md(manifest))

    write_json(run_dir / f"{stable_name}.json", manifest)
    write_text(run_dir / f"{stable_name}.md", execution_manifest_md(manifest))

    report.setdefault("outputs", [])
    report["outputs"].extend(
        [
            {"kind": "json", "label": stable_name, "path": rel(json_path)},
            {"kind": "markdown", "label": stable_name, "path": rel(md_path)},
        ]
    )
    return json_path, md_path


def write_report(run_dir: Path, report: dict[str, Any]) -> Path:
    path = run_dir / "backup_execute_report.json"
    report["report_path"] = rel(path)
    write_json(path, report)
    return path


def build_report_base(run_dir: Path, args: argparse.Namespace) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {"name": "backup_execute", "script": SCRIPT_NAME},
        "command": "backup-execute",
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "mode": args.mode,
        "ok": False,
        "actual_backup_executed": False,
        "timer_enabled_here": False,
        "fail_on_warnings": bool(args.fail_on_warnings),
        "allow_stale_prebackup": bool(args.allow_stale_prebackup),
        "max_prebackup_age_hours": args.max_prebackup_age_hours,
        "require_rescuezilla_image": bool(args.require_rescuezilla_image),
        "backup_payload_contract": BACKUP_PAYLOAD_CONTRACT,
        "prebackup_validation": None,
        "steps": [],
        "failures": [],
        "warnings": [],
        "outputs": [],
    }


def add_results(report: dict[str, Any], results: list[StepResult]) -> None:
    report.setdefault("steps", []).extend(result_to_dict(step) for step in results)
    for step in results:
        if not step.ok:
            report.setdefault("failures", []).append(f"{step.phase}:{step.row}:{step.label} failed")
        if step.warnings:
            report.setdefault("warnings", []).append(
                {
                    "phase": step.phase,
                    "row": step.row,
                    "label": step.label,
                    "warnings": step.warnings,
                    "report_path": step.report_path,
                }
            )


def update_report_status(
        report: dict[str, Any],
        *,
        prebackup_status: dict[str, Any],
        results: list[StepResult],
        actual_backup_executed: bool,
) -> None:
    status = compute_status(
        mode=str(report["mode"]),
        prebackup_status=prebackup_status,
        results=results,
        actual_backup_executed=actual_backup_executed,
    )
    report.update(status)
    report["actual_backup_executed"] = actual_backup_executed
    report["ok"] = status["ok"]


def fail_with_manifest(
        *,
        run_dir: Path,
        report: dict[str, Any],
        mode: str,
        stage: str,
        prebackup_status: dict[str, Any],
        results: list[StepResult],
        actual_backup_executed: bool,
        message: str,
) -> int:
    report.setdefault("failures", []).append(message)
    update_report_status(
        report,
        prebackup_status=prebackup_status,
        results=results,
        actual_backup_executed=actual_backup_executed,
    )
    manifest = build_execution_manifest(
        run_dir=run_dir,
        mode=mode,
        stage=stage,
        prebackup_status=prebackup_status,
        results=results,
        actual_backup_executed=actual_backup_executed,
    )
    write_execution_manifest(
        run_dir=run_dir,
        report=report,
        manifest=manifest,
        stable_name="latest_backup_execution",
    )
    report_path = write_report(run_dir, report)
    print("\nBACKUP_EXECUTE: FAIL")
    print(f"failure: {message}")
    print(f"report: {rel(report_path)}")
    return 2


def print_plan(args: argparse.Namespace) -> None:
    print("===== 19_BACKUP_EXECUTE PLAN =====")
    print(f"mode={args.mode}")
    print(f"requires prebackup manifest: {rel(PREBACKUP_MANIFEST_PATH)}")
    print(f"requires root env: {ROOT_ENV_FILE}")
    print(f"requires vault: {EXPECTED_VAULT_MOUNT}")
    print(f"requires repo: {EXPECTED_REPO}")
    print(f"require_rescuezilla_image={args.require_rescuezilla_image}")

    phases: list[tuple[str, list[StepSpec]]] = [
        ("PREFLIGHT",
         build_preflight_steps(require_rescuezilla_image=args.require_rescuezilla_image)),
        ("PRE-ACTION PROOF", build_pre_action_proof_steps()),
    ]

    if args.mode == "execute":
        phases.append(("PRE-EXECUTE DRY-RUN", [build_dry_run_step("pre-execute-dry-run")]))
        phases.append(("INTENT MANIFEST", []))
        phases.append(("EXECUTE", [build_execute_step()]))
    else:
        phases.append(("DRY-RUN ACTION", [build_dry_run_step("dry-run-action")]))

    phases.extend(
        [
            ("POST-ACTION", build_post_action_steps(mode=args.mode)),
            ("POST-ARCHIVE EVIDENCE", build_post_archive_evidence_steps()),
        ]
    )

    for title, steps in phases:
        print(f"\n===== {title} =====")
        if not steps:
            print("write state/generated/backup/backup_intent_manifest.{json,md}")
            continue
        for spec in steps:
            root = " [root-env]" if spec.root_env else " [sudo]" if spec.sudo else ""
            req = "required" if spec.required else "optional"
            print(f"{spec.row:18} {spec.label:42} {req:9} {' '.join(spec.argv)}{root}")

    print("\n===== FORBIDDEN ACTIONS =====")
    for item in FORBIDDEN_ACTIONS:
        print(item)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=f"scripts/{SCRIPT_NAME}",
        description="Run guarded Borg backup transaction proof through Row 08/Row 07.",
    )
    parser.add_argument(
        "--mode",
        choices=["dry-run", "execute"],
        default="dry-run",
        help="dry-run proves the backup path without writing an archive. execute runs the real backup.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Required with --mode execute.",
    )
    parser.add_argument(
        "--confirm-token",
        default="",
        help=f"Required for --mode execute. Expected: {DEFAULT_CONFIRM_TOKEN}",
    )
    parser.add_argument(
        "--max-prebackup-age-hours",
        type=float,
        default=DEFAULT_MAX_PREBACKUP_AGE_HOURS,
        help="Maximum accepted age of latest prebackup manifest unless --allow-stale-prebackup is set.",
    )
    parser.add_argument(
        "--allow-stale-prebackup",
        action="store_true",
        help="Warn instead of failing when the latest prebackup manifest is older than max age.",
    )
    parser.add_argument(
        "--require-rescuezilla-image",
        action="store_true",
        help=(
            "Require Row 02 image list/manifest validation before backup action. "
            "Use only when asserting blank-machine package completeness."
        ),
    )
    parser.add_argument(
        "--allow-sudo-prompt",
        action="store_true",
        help="Allow sudo to prompt. Default is non-interactive sudo -n.",
    )
    parser.add_argument(
        "--fail-on-warnings",
        action="store_true",
        help="Treat row warnings as failures. Default is false.",
    )
    parser.add_argument(
        "--print-plan",
        action="store_true",
        help="Print planned commands and exit without running them.",
    )
    return parser


def validate_args(args: argparse.Namespace) -> list[str]:
    failures: list[str] = []

    if args.mode == "execute":
        if not args.execute:
            failures.append("--mode execute requires --execute")
        if args.confirm_token != DEFAULT_CONFIRM_TOKEN:
            failures.append(f"--mode execute requires --confirm-token {DEFAULT_CONFIRM_TOKEN}")
    else:
        if args.execute:
            failures.append("--execute is only valid with --mode execute")
        if args.confirm_token:
            failures.append("--confirm-token is only valid with --mode execute")

    if args.max_prebackup_age_hours <= 0:
        failures.append("--max-prebackup-age-hours must be positive")

    return failures


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)

    if args.print_plan:
        print_plan(args)
        arg_failures = validate_args(args)
        if arg_failures:
            print("\n===== PLAN ARGUMENT WARNINGS =====")
            for failure in arg_failures:
                print(f"failure: {failure}")
            return 2
        return 0

    ensure_user_context()
    run_dir = make_run_dir()
    report = build_report_base(run_dir, args)
    all_results: list[StepResult] = []
    actual_backup_executed = False
    sudo_noninteractive = not args.allow_sudo_prompt

    print("===== 19 BACKUP EXECUTE =====")
    print(f"mode={args.mode}")
    print(f"run_dir={rel(run_dir)}")
    print("No pruning. No timer enablement. No LUKS setup. No repo creation. No restore actions.")

    arg_failures = validate_args(args)
    if arg_failures:
        prebackup_status = {"ok": False, "failures": arg_failures, "warnings": []}
        for failure in arg_failures:
            report.setdefault("failures", []).append(failure)
        return fail_with_manifest(
            run_dir=run_dir,
            report=report,
            mode=args.mode,
            stage="argument-failure",
            prebackup_status=prebackup_status,
            results=[],
            actual_backup_executed=False,
            message="argument validation failed",
        )

    try:
        prebackup_status = validate_prebackup_manifest(
            max_age_hours=args.max_prebackup_age_hours,
            allow_stale=args.allow_stale_prebackup,
        )
        report["prebackup_validation"] = prebackup_status

        if not prebackup_status.get("ok"):
            for item in prebackup_status.get("failures", []):
                report.setdefault("failures", []).append(f"prebackup manifest: {item}")
            return fail_with_manifest(
                run_dir=run_dir,
                report=report,
                mode=args.mode,
                stage="prebackup-manifest-failed",
                prebackup_status=prebackup_status,
                results=[],
                actual_backup_executed=False,
                message="latest prebackup manifest is not backup-ready",
            )

        print("\nPREBACKUP MANIFEST: PASS")
        print(f"  manifest: {prebackup_status.get('path')}")
        print(f"  source_run_dir: {prebackup_status.get('source_run_dir')}")
        print(
            "  latest_database_dump_bundle: "
            f"{(prebackup_status.get('latest_database_dump_bundle') or {}).get('path')}"
        )
        for warning in prebackup_status.get("warnings", []):
            print(f"  warning: {warning}")

        start_index = 1

        for phase_name, specs in [
            (
                    "PREFLIGHT",
                    build_preflight_steps(require_rescuezilla_image=args.require_rescuezilla_image),
            ),
            ("PRE-ACTION PROOF", build_pre_action_proof_steps()),
        ]:
            phase_ok_value, results = run_phase(
                phase_name,
                specs,
                run_dir,
                start_index=start_index,
                sudo_noninteractive=sudo_noninteractive,
                fail_on_warnings=args.fail_on_warnings,
                stop_on_required_failure=True,
            )
            start_index += len(results)
            all_results.extend(results)
            add_results(report, results)
            if not phase_ok_value:
                return fail_with_manifest(
                    run_dir=run_dir,
                    report=report,
                    mode=args.mode,
                    stage=f"failed-{slug(phase_name.lower())}",
                    prebackup_status=prebackup_status,
                    results=all_results,
                    actual_backup_executed=actual_backup_executed,
                    message=f"{phase_name} failed",
                )

        if args.mode == "execute":
            phase_ok_value, results = run_phase(
                "PRE-EXECUTE DRY-RUN",
                [build_dry_run_step("pre-execute-dry-run")],
                run_dir,
                start_index=start_index,
                sudo_noninteractive=sudo_noninteractive,
                fail_on_warnings=args.fail_on_warnings,
                stop_on_required_failure=True,
            )
            start_index += len(results)
            all_results.extend(results)
            add_results(report, results)
            if not phase_ok_value:
                return fail_with_manifest(
                    run_dir=run_dir,
                    report=report,
                    mode=args.mode,
                    stage="failed-pre-execute-dry-run",
                    prebackup_status=prebackup_status,
                    results=all_results,
                    actual_backup_executed=actual_backup_executed,
                    message="pre-execute dry-run failed",
                )

            intent_manifest = build_execution_manifest(
                run_dir=run_dir,
                mode=args.mode,
                stage="pre-execute-intent",
                prebackup_status=prebackup_status,
                results=all_results,
                actual_backup_executed=False,
            )
            intent_json, intent_md = write_execution_manifest(
                run_dir=run_dir,
                report=report,
                manifest=intent_manifest,
                stable_name="backup_intent_manifest",
            )
            print("\nPRE-EXECUTE INTENT MANIFEST: PASS")
            print(f"  intent_json: {rel(intent_json)}")
            print(f"  intent_md: {rel(intent_md)}")
            print("  This intent manifest should be inside the archive about to be created.")

            phase_ok_value, results = run_phase(
                "EXECUTE",
                [build_execute_step()],
                run_dir,
                start_index=start_index,
                sudo_noninteractive=sudo_noninteractive,
                fail_on_warnings=args.fail_on_warnings,
                stop_on_required_failure=True,
            )
            start_index += len(results)
            all_results.extend(results)
            add_results(report, results)
            actual_backup_executed = phase_ok_value

            if not phase_ok_value:
                failure_evidence_ok, failure_results = run_phase(
                    "FAILURE EVIDENCE",
                    build_failure_evidence_steps(),
                    run_dir,
                    start_index=start_index,
                    sudo_noninteractive=sudo_noninteractive,
                    fail_on_warnings=False,
                    stop_on_required_failure=False,
                )
                _ = failure_evidence_ok
                start_index += len(failure_results)
                all_results.extend(failure_results)
                add_results(report, failure_results)
                return fail_with_manifest(
                    run_dir=run_dir,
                    report=report,
                    mode=args.mode,
                    stage="failed-execute",
                    prebackup_status=prebackup_status,
                    results=all_results,
                    actual_backup_executed=False,
                    message="execute backup action failed",
                )

        else:
            phase_ok_value, results = run_phase(
                "DRY-RUN ACTION",
                [build_dry_run_step("dry-run-action")],
                run_dir,
                start_index=start_index,
                sudo_noninteractive=sudo_noninteractive,
                fail_on_warnings=args.fail_on_warnings,
                stop_on_required_failure=True,
            )
            start_index += len(results)
            all_results.extend(results)
            add_results(report, results)

            if not phase_ok_value:
                return fail_with_manifest(
                    run_dir=run_dir,
                    report=report,
                    mode=args.mode,
                    stage="failed-dry-run-action",
                    prebackup_status=prebackup_status,
                    results=all_results,
                    actual_backup_executed=False,
                    message="dry-run backup action failed",
                )

        for phase_name, specs in [
            ("POST-ACTION", build_post_action_steps(mode=args.mode)),
            ("POST-ARCHIVE EVIDENCE", build_post_archive_evidence_steps()),
        ]:
            phase_ok_value, results = run_phase(
                phase_name,
                specs,
                run_dir,
                start_index=start_index,
                sudo_noninteractive=sudo_noninteractive,
                fail_on_warnings=args.fail_on_warnings,
                stop_on_required_failure=True,
            )
            start_index += len(results)
            all_results.extend(results)
            add_results(report, results)
            if not phase_ok_value:
                return fail_with_manifest(
                    run_dir=run_dir,
                    report=report,
                    mode=args.mode,
                    stage=f"failed-{slug(phase_name.lower())}",
                    prebackup_status=prebackup_status,
                    results=all_results,
                    actual_backup_executed=actual_backup_executed,
                    message=f"{phase_name} failed",
                )

        update_report_status(
            report,
            prebackup_status=prebackup_status,
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )

        final_stage = "execute-pass" if args.mode == "execute" else "dry-run-pass"
        final_manifest = build_execution_manifest(
            run_dir=run_dir,
            mode=args.mode,
            stage=final_stage,
            prebackup_status=prebackup_status,
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )
        final_json, final_md = write_execution_manifest(
            run_dir=run_dir,
            report=report,
            manifest=final_manifest,
            stable_name="latest_backup_execution",
        )
        report_path = write_report(run_dir, report)

        if report.get("ok") is True:
            if args.mode == "execute":
                print("\nBACKUP_EXECUTE: PASS")
                print(f"BACKUP_EXECUTED: {report.get('backup_executed')}")
                print(f"BORG_TRANSACTION_COMPLETE: {report.get('borg_transaction_complete')}")
                print(
                    "BLANK_MACHINE_RECOVERY_PACKAGE_COMPLETE: "
                    f"{report.get('blank_machine_recovery_package_complete')}"
                )
                print(
                    "POST_ARCHIVE_EVIDENCE_IN_CURRENT_ARCHIVE: "
                    f"{report.get('post_archive_evidence_in_current_archive')}"
                )
                print(f"latest execution manifest json: {rel(final_json)}")
                print(f"latest execution manifest md: {rel(final_md)}")
                print(f"report: {rel(report_path)}")
                if not report.get("blank_machine_recovery_package_complete"):
                    print(
                        "NOTE: Borg transaction passed, but full blank-machine package "
                        "is not complete until Rescuezilla image proof is also true."
                    )
            else:
                print("\nBACKUP_EXECUTE_DRY_RUN: PASS")
                print("BACKUP_EXECUTED: False")
                print(f"DRY_RUN_OK: {report.get('dry_run_ok')}")
                print(f"latest execution manifest json: {rel(final_json)}")
                print(f"latest execution manifest md: {rel(final_md)}")
                print(f"report: {rel(report_path)}")
                print(
                    "NEXT: scripts/19_backup_execute.py --mode execute "
                    "--execute --confirm-token BACKUP_EXECUTE:vault-primary"
                )
            return 0

        print("\nBACKUP_EXECUTE: FAIL")
        print("STOP: report status is not ok; review required failures.")
        print(f"report: {rel(report_path)}")
        return 2

    except KeyboardInterrupt:
        report.setdefault("failures", []).append("interrupted by user")
        update_report_status(
            report,
            prebackup_status=report.get("prebackup_validation") or {},
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )
        manifest = build_execution_manifest(
            run_dir=run_dir,
            mode=args.mode,
            stage="interrupted",
            prebackup_status=report.get("prebackup_validation") or {},
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )
        write_execution_manifest(
            run_dir=run_dir,
            report=report,
            manifest=manifest,
            stable_name="latest_backup_execution",
        )
        report_path = write_report(run_dir, report)
        print("\nBACKUP_EXECUTE: INTERRUPTED")
        print(f"report: {rel(report_path)}")
        return 130

    except Exception as exc:
        report.setdefault("failures", []).append(str(exc))
        update_report_status(
            report,
            prebackup_status=report.get("prebackup_validation") or {},
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )
        manifest = build_execution_manifest(
            run_dir=run_dir,
            mode=args.mode,
            stage="exception",
            prebackup_status=report.get("prebackup_validation") or {},
            results=all_results,
            actual_backup_executed=actual_backup_executed,
        )
        write_execution_manifest(
            run_dir=run_dir,
            report=report,
            manifest=manifest,
            stable_name="latest_backup_execution",
        )
        report_path = write_report(run_dir, report)
        print("\nBACKUP_EXECUTE: FAIL")
        print(f"failure: {exc}")
        print(f"report: {rel(report_path)}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))