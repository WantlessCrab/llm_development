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
SCRIPT_NAME = "08_systemd.sh"
SCHEMA_NAME = "recovery.systemd.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {"name": "systemd", "verified_systemd_version": "255.4-1ubuntu8.15", "layer": "08_local_deterministic_activation"},
    "project": {"root": str(PROJECT_ROOT), "output_root": "state/dry_runs/08_systemd", "local_test_root": "state/local_test/08_systemd"},
    "commands": {"systemctl": "/usr/bin/systemctl", "systemd_analyze": "/usr/bin/systemd-analyze", "install": "/usr/bin/install", "rm": "/usr/bin/rm"},
    "policy": {
        "system_unit_source_dir": "systemd/system", "user_unit_source_dir": "systemd/user",
        "system_unit_target_dir": "/etc/systemd/system", "user_unit_target_dir": "/home/wantless/.config/systemd/user",
        "system_env_dir": "/etc/wantless-recovery", "system_env_file": "/etc/wantless-recovery/recovery.env",
        "install_system_confirmation": "INSTALL_SYSTEMD_SYSTEM:/etc/systemd/system", "uninstall_system_confirmation": "UNINSTALL_SYSTEMD_SYSTEM:/etc/systemd/system",
        "install_user_confirmation": "INSTALL_SYSTEMD_USER:/home/wantless/.config/systemd/user", "uninstall_user_confirmation": "UNINSTALL_SYSTEMD_USER:/home/wantless/.config/systemd/user",
        "copy_config_snapshot_into_run": True, "report_name": "systemd_report.json", "backup_timer_enable_default": False,
        "backup_timer_unit": "wantless-recovery-backup.timer", "backup_service_unit": "wantless-recovery-backup.service",
        "preflight_service_unit": "wantless-recovery-preflight.service", "verify_service_unit": "wantless-recovery-verify.service",
        "desktop_capture_user_unit": "wantless-desktop-capture.service",
    },
    "mounts": {"recovery_vault": {"path": "/mnt/wantless_recovery", "required_for_backup": True, "required_for_verify": False, "expected_repo_path": "/mnt/wantless_recovery/06_borg/repository"}},
    "manual_verify": {"require_mount": False, "commands": "scripts/01_smartmontools.sh capture-source; scripts/02_rescuezilla.sh verify-iso; scripts/04_integrity.sh verify-restore-gate --local-only; scripts/06_borg.sh assert-version; scripts/07_borgmatic.sh validate --profile local-test", "local_test_commands": "scripts/01_smartmontools.sh capture-source; scripts/02_rescuezilla.sh verify-iso; scripts/04_integrity.sh verify-restore-gate --local-only; scripts/06_borg.sh assert-version; scripts/07_borgmatic.sh validate --profile local-test"},
    "manual_backup": {"require_mount": True, "local_test_commands": "scripts/07_borgmatic.sh backup --profile local-test --execute", "dry_run_commands": "scripts/07_borgmatic.sh dry-run --profile vault-primary", "execute_commands": "scripts/07_borgmatic.sh backup --profile vault-primary --execute --confirm-token BORGMATIC_BACKUP:vault-primary"},
    "manual_desktop_capture": {
        "description": "User-session activation for Row 13 desktop/session capture.",
        "commands": "scripts/13_desktop.sh capture-session",
        "allow_missing_command": False,
    },
    "units": {"system": "wantless-recovery-preflight.service;wantless-recovery-backup.service;wantless-recovery-backup.timer;wantless-recovery-verify.service", "user": "wantless-desktop-capture.service"},
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
    path = PROJECT_ROOT / "configs" / "08_systemd.yaml"
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


SYSTEMCTL = cmd_path("systemctl")
SYSTEMD_ANALYZE = cmd_path("systemd_analyze")
INSTALL = cmd_path("install")
RM = cmd_path("rm")


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
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/08_systemd")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "08_systemd.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "08_systemd.config.snapshot.yaml")
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
        "tool": {"name": "systemd", "script": SCRIPT_NAME, "systemctl_path": SYSTEMCTL, "systemd_version": None},
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
    report_path = run_dir / str(cfg_get("policy.report_name", "systemd_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], report: dict[str, Any], *, sudo: bool = False, label: str = "command", check: bool = False) -> dict[str, Any]:
    final_argv = argv[:]
    if sudo and os.geteuid() != 0:
        sudo_path = shutil.which("sudo")
        if not sudo_path:
            result = {"argv": argv, "returncode": 127, "stdout": "", "stderr": "sudo is required but unavailable"}
            report["commands"].append(result)
            if check:
                report["failures"].append(result["stderr"])
            return result
        final_argv = [sudo_path] + final_argv
    proc = subprocess.run(final_argv, text=True, capture_output=True)
    result = {"argv": final_argv, "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    run_dir = resolve_path(report["run_dir"])
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    report["commands"].append({"argv": final_argv, "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr})
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(final_argv)} :: {proc.stderr.strip()}")
    return result


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    report["failures"].append(f"{label} not found: {path}")
    return False


def capture_systemd_version(report: dict[str, Any]) -> None:
    if require_tool(SYSTEMCTL, report, "systemctl"):
        result = run_cmd([SYSTEMCTL, "--version"], report, label="systemctl_version")
        first = result["stdout"].splitlines()[0] if result["stdout"].splitlines() else result["stderr"].strip()
        report["tool"]["systemd_version"] = first


def unit_names(scope: str) -> list[str]:
    return split_semicolon(cfg_get(f"units.{scope}", ""))


def system_source_dir() -> Path:
    return resolve_path(str(cfg_get("policy.system_unit_source_dir", "systemd/system")))


def user_source_dir() -> Path:
    return resolve_path(str(cfg_get("policy.user_unit_source_dir", "systemd/user")))


def system_target_dir() -> Path:
    return Path(str(cfg_get("policy.system_unit_target_dir", "/etc/systemd/system"))).expanduser().resolve()


def user_target_dir() -> Path:
    return Path(str(cfg_get("policy.user_unit_target_dir", str(Path.home() / ".config/systemd/user")))).expanduser().resolve()


def validate_units(scope: str, report: dict[str, Any]) -> None:
    source_dir = system_source_dir() if scope == "system" else user_source_dir()
    units = unit_names(scope)
    if not units:
        report["warnings"].append(f"no {scope} units configured")
        return
    if not source_dir.exists():
        report["failures"].append(f"source unit directory missing: {source_dir}")
        return
    for unit in units:
        source = source_dir / unit
        if not source.exists():
            report["failures"].append(f"source unit missing: {source}")
            continue
        if Path(SYSTEMD_ANALYZE).exists() or shutil.which(SYSTEMD_ANALYZE):
            verify = run_cmd([SYSTEMD_ANALYZE, "verify", str(source)], report, label=f"systemd_analyze_verify_{unit}")
            if verify["returncode"] != 0:
                report["failures"].append(f"systemd-analyze verify failed for {source}: {verify['stderr'].strip()}")
        else:
            report["warnings"].append(f"systemd-analyze not available; skipped unit verification for {source}")
        report.setdefault("units", []).append({"scope": scope, "name": unit, "source": str(source)})


def install_file(source: Path, target: Path, report: dict[str, Any], *, sudo: bool) -> None:
    if target.exists():
        current = target.read_bytes() if os.access(target, os.R_OK) and not sudo else None
        source_bytes = source.read_bytes()
        if current == source_bytes:
            report["warnings"].append(f"active unit already matches source: {target}")
            return
        backup = target.with_name(target.name + f".pre-row08-{now_stamp()}.bak")
        run_cmd(["/usr/bin/cp", "-a", str(target), str(backup)], report, sudo=sudo, label=f"backup_{target.name}")
    run_cmd([INSTALL, "-m", "0644", str(source), str(target)], report, sudo=sudo, label=f"install_{target.name}", check=True)


def write_system_env(report: dict[str, Any], *, sudo: bool) -> None:
    env_dir = Path(str(cfg_get("policy.system_env_dir", "/etc/wantless-recovery"))).resolve()
    env_file = Path(str(cfg_get("policy.system_env_file", "/etc/wantless-recovery/recovery.env"))).resolve()
    tmp = resolve_path("state/local_test/08_systemd/recovery.env.generated")

    run_cmd([INSTALL, "-d", "-m", "0700", str(env_dir)], report, sudo=sudo, label="install_env_dir", check=True)

    sudo_env_exists = run_cmd(
        ["/usr/bin/test", "-e", str(env_file)],
        report,
        sudo=sudo,
        label="check_existing_env_file",
        check=False,
    )

    if sudo_env_exists["returncode"] == 0:
        report["warnings"].append(f"preserved existing system environment file: {env_file}")
        run_cmd(["/usr/bin/chown", "root:root", str(env_dir), str(env_file)], report, sudo=sudo, label="preserve_env_owner", check=True)
        run_cmd(["/usr/bin/chmod", "0700", str(env_dir)], report, sudo=sudo, label="preserve_env_dir_mode", check=True)
        run_cmd(["/usr/bin/chmod", "0600", str(env_file)], report, sudo=sudo, label="preserve_env_file_mode", check=True)
        return

    if sudo_env_exists["returncode"] != 1:
        report["failures"].append(f"could not determine whether system environment file exists: {env_file}")
        return

    text = "\n".join([
        "# Generated by recovery Row 08 systemd installer.",
        "# Non-secret template. Add BORG_PASSPHRASE before enabling production backup.",
        f"RECOVERY_PROJECT_ROOT={PROJECT_ROOT}",
        "RECOVERY_PROFILE=vault-primary",
        "RECOVERY_VAULT_MOUNT=/mnt/wantless_recovery",
        "",
    ])
    write_text(tmp, text)
    run_cmd([INSTALL, "-m", "0600", str(tmp), str(env_file)], report, sudo=sudo, label="install_env_file_template", check=True)


def cmd_install_system(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("install-system")
    report = report_base("install-system", run_dir)
    report.update({"manager": "system", "mode": "execute" if args.execute else "dry-run"})
    capture_systemd_version(report)
    validate_units("system", report)
    expected = str(cfg_get("policy.install_system_confirmation"))
    if not args.execute:
        report["warnings"].append("install-system did not install because --execute was not supplied")
        return finalize_report(report, run_dir)
    if args.confirm_token != expected:
        report["failures"].append(f"install-system requires --confirm-token {expected}")
        return finalize_report(report, run_dir)
    if report["failures"]:
        return finalize_report(report, run_dir)
    target_dir = system_target_dir()
    run_cmd([INSTALL, "-d", "-m", "0755", str(target_dir)], report, sudo=True, label="install_system_unit_dir", check=True)
    for unit in unit_names("system"):
        install_file(system_source_dir() / unit, target_dir / unit, report, sudo=True)
    write_system_env(report, sudo=True)
    run_cmd([SYSTEMCTL, "daemon-reload"], report, sudo=True, label="system_daemon_reload", check=True)
    if args.enable_timer:
        timer = str(cfg_get("policy.backup_timer_unit", "wantless-recovery-backup.timer"))
        run_cmd([SYSTEMCTL, "enable", "--now", timer], report, sudo=True, label="enable_backup_timer", check=True)
    else:
        report["warnings"].append("backup timer installed but not enabled; pass --enable-timer to enable")
    return finalize_report(report, run_dir)


def cmd_uninstall_system(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("uninstall-system")
    report = report_base("uninstall-system", run_dir)
    report.update({"manager": "system", "mode": "execute" if args.execute else "dry-run"})
    expected = str(cfg_get("policy.uninstall_system_confirmation"))
    if not args.execute:
        report["warnings"].append("uninstall-system did not uninstall because --execute was not supplied")
        return finalize_report(report, run_dir)
    if args.confirm_token != expected:
        report["failures"].append(f"uninstall-system requires --confirm-token {expected}")
        return finalize_report(report, run_dir)
    for unit in unit_names("system"):
        run_cmd([SYSTEMCTL, "disable", "--now", unit], report, sudo=True, label=f"disable_{unit}")
        run_cmd([RM, "-f", str(system_target_dir() / unit)], report, sudo=True, label=f"remove_{unit}", check=True)
    run_cmd([SYSTEMCTL, "daemon-reload"], report, sudo=True, label="system_daemon_reload", check=True)
    return finalize_report(report, run_dir)


def cmd_install_user(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("install-user")
    report = report_base("install-user", run_dir)
    report.update({"manager": "user", "mode": "execute" if args.execute else "dry-run"})
    capture_systemd_version(report)
    validate_units("user", report)
    expected = str(cfg_get("policy.install_user_confirmation"))
    if not args.execute:
        report["warnings"].append("install-user did not install because --execute was not supplied")
        return finalize_report(report, run_dir)
    if args.confirm_token != expected:
        report["failures"].append(f"install-user requires --confirm-token {expected}")
        return finalize_report(report, run_dir)
    if report["failures"]:
        return finalize_report(report, run_dir)
    target_dir = user_target_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    for unit in unit_names("user"):
        install_file(user_source_dir() / unit, target_dir / unit, report, sudo=False)
    run_cmd([SYSTEMCTL, "--user", "daemon-reload"], report, label="user_daemon_reload", check=True)
    if args.enable_user_unit:
        unit = str(cfg_get("policy.desktop_capture_user_unit", "wantless-desktop-capture.service"))
        run_cmd([SYSTEMCTL, "--user", "enable", unit], report, label="enable_user_unit", check=True)
    return finalize_report(report, run_dir)


def cmd_uninstall_user(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("uninstall-user")
    report = report_base("uninstall-user", run_dir)
    report.update({"manager": "user", "mode": "execute" if args.execute else "dry-run"})
    expected = str(cfg_get("policy.uninstall_user_confirmation"))
    if not args.execute:
        report["warnings"].append("uninstall-user did not uninstall because --execute was not supplied")
        return finalize_report(report, run_dir)
    if args.confirm_token != expected:
        report["failures"].append(f"uninstall-user requires --confirm-token {expected}")
        return finalize_report(report, run_dir)
    for unit in unit_names("user"):
        run_cmd([SYSTEMCTL, "--user", "disable", "--now", unit], report, label=f"disable_user_{unit}")
        target = user_target_dir() / unit
        if target.exists():
            target.unlink()
    run_cmd([SYSTEMCTL, "--user", "daemon-reload"], report, label="user_daemon_reload", check=True)
    return finalize_report(report, run_dir)


def cmd_show_units(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("show-units")
    report = report_base("show-units", run_dir)
    report.update({"mode": "summary"})
    capture_systemd_version(report)
    for unit in unit_names("system"):
        run_cmd([SYSTEMCTL, "--no-pager", "--full", "status", unit], report, sudo=True, label=f"system_status_{unit}")
        run_cmd([SYSTEMCTL, "cat", unit], report, sudo=True, label=f"system_cat_{unit}")
    for unit in unit_names("user"):
        run_cmd([SYSTEMCTL, "--user", "--no-pager", "--full", "status", unit], report, label=f"user_status_{unit}")
        run_cmd([SYSTEMCTL, "--user", "cat", unit], report, label=f"user_cat_{unit}")
    return finalize_report(report, run_dir)


def cmd_show_timers(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("show-timers")
    report = report_base("show-timers", run_dir)
    report.update({"mode": "summary", "manager": "system"})
    run_cmd([SYSTEMCTL, "list-timers", "--all", "--no-pager"], report, sudo=True, label="system_list_timers")
    unit = str(cfg_get("policy.backup_timer_unit", "wantless-recovery-backup.timer"))
    run_cmd([SYSTEMCTL, "--no-pager", "--full", "status", unit], report, sudo=True, label="backup_timer_status")
    return finalize_report(report, run_dir)


def assert_mount(report: dict[str, Any], *, required: bool) -> bool:
    mount = resolve_path(str(cfg_get("mounts.recovery_vault.path", "/mnt/wantless_recovery")))
    repo = resolve_path(str(cfg_get("mounts.recovery_vault.expected_repo_path", "/mnt/wantless_recovery/06_borg/repository")))
    info = {"path": str(mount), "exists": mount.exists(), "is_mount": mount.is_mount(), "expected_repo_path": str(repo), "repo_parent_exists": repo.parent.exists()}
    report.setdefault("mounts", {})["recovery_vault"] = info
    if required:
        if not mount.exists():
            report["failures"].append(f"required recovery vault mountpoint does not exist: {mount}")
        elif not mount.is_mount():
            report["failures"].append(f"required recovery vault is not mounted: {mount}")
        try:
            repo.relative_to(mount)
        except ValueError:
            report["failures"].append(f"expected repository path is not under mountpoint: {repo}")
    return not report.get("failures")


def cmd_assert_mount_condition(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-mount-condition")
    report = report_base("assert-mount-condition", run_dir)
    report.update({"mode": "assert"})
    assert_mount(report, required=True)
    return finalize_report(report, run_dir)


def sequence_command_exists(argv0: str) -> tuple[bool, str]:
    candidate = Path(argv0).expanduser()
    if candidate.is_absolute():
        path = candidate
    elif "/" in argv0:
        path = PROJECT_ROOT / candidate
    else:
        resolved = shutil.which(argv0)
        if not resolved:
            return False, f"configured command not found on PATH: {argv0}"
        return True, resolved

    if not path.exists():
        return False, f"configured command does not exist: {argv0}"
    if not os.access(path, os.X_OK):
        return False, f"configured command is not executable: {argv0}"
    return True, str(path)


def run_sequence(command_text: str, report: dict[str, Any], *, label_prefix: str) -> None:
    import shlex

    commands = split_semicolon(command_text)
    if not commands:
        report["failures"].append(f"{label_prefix}: no commands configured")
        return

    for index, raw in enumerate(commands, start=1):
        try:
            argv = shlex.split(raw)
        except ValueError as exc:
            report["failures"].append(f"{label_prefix}: command parse failed at item {index}: {exc}")
            break
        if not argv:
            continue
        exists, resolved_or_error = sequence_command_exists(argv[0])
        if not exists:
            report["failures"].append(f"{label_prefix}: {resolved_or_error}")
            break
        argv[0] = resolved_or_error
        run_cmd(argv, report, label=f"{label_prefix}_{index}_{Path(argv[0]).name}", check=True)
        if report.get("failures"):
            break


def cmd_manual_verify(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("manual-verify")
    report = report_base("manual-verify", run_dir)
    report.update({
        "mode": "local-test" if args.local_test else "assert",
        "activation": {"unit_context": args.unit_context, "scope": args.scope},
    })
    if boolish(cfg_get("manual_verify.require_mount", False)) and not args.local_test:
        assert_mount(report, required=True)
    if not report["failures"]:
        key = "manual_verify.local_test_commands" if args.local_test else "manual_verify.commands"
        run_sequence(str(cfg_get(key, cfg_get("manual_verify.commands", ""))), report, label_prefix="manual_verify")
    return finalize_report(report, run_dir)


def cmd_manual_backup(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("manual-backup")
    report = report_base("manual-backup", run_dir)
    report.update({
        "mode": "local-test" if args.local_test else ("execute" if args.execute else "dry-run"),
        "activation": {"unit_context": args.unit_context},
    })
    if args.local_test:
        run_sequence(str(cfg_get("manual_backup.local_test_commands", "")), report, label_prefix="manual_backup_local_test")
        return finalize_report(report, run_dir)
    require_mount = boolish(cfg_get("manual_backup.require_mount", True))
    assert_mount(report, required=require_mount)
    if report["failures"]:
        return finalize_report(report, run_dir)
    key = "manual_backup.execute_commands" if args.execute else "manual_backup.dry_run_commands"
    run_sequence(str(cfg_get(key, "")), report, label_prefix="manual_backup")
    return finalize_report(report, run_dir)


def cmd_manual_desktop_capture(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("manual-desktop-capture")
    report = report_base("manual-desktop-capture", run_dir)
    report.update({
        "manager": "user",
        "mode": "capture",
        "activation": {"unit_context": args.unit_context},
    })
    session = {
        key: os.environ.get(key)
        for key in [
            "DISPLAY",
            "XAUTHORITY",
            "XDG_SESSION_TYPE",
            "XDG_CURRENT_DESKTOP",
            "DBUS_SESSION_BUS_ADDRESS",
            "WAYLAND_DISPLAY",
            "DESKTOP_SESSION",
        ]
    }
    report["activation"]["session_environment"] = session

    commands = str(cfg_get("manual_desktop_capture.commands", "") or "").strip()
    allow_missing = boolish(cfg_get("manual_desktop_capture.allow_missing_command", False))
    if not commands:
        if allow_missing:
            report["warnings"].append("manual_desktop_capture.commands is empty")
        else:
            report["failures"].append("manual_desktop_capture.commands is empty")
        return finalize_report(report, run_dir)

    run_sequence(commands, report, label_prefix="manual_desktop_capture")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_execute(p: argparse.ArgumentParser) -> None:
        p.add_argument("--execute", action="store_true")
        p.add_argument("--confirm-token", default=None)

    p = sub.add_parser("install-system"); add_execute(p); p.add_argument("--enable-timer", action="store_true"); p.set_defaults(func=cmd_install_system)
    p = sub.add_parser("uninstall-system"); add_execute(p); p.set_defaults(func=cmd_uninstall_system)
    p = sub.add_parser("install-user"); add_execute(p); p.add_argument("--enable-user-unit", action="store_true"); p.set_defaults(func=cmd_install_user)
    p = sub.add_parser("uninstall-user"); add_execute(p); p.set_defaults(func=cmd_uninstall_user)
    p = sub.add_parser("show-units"); p.set_defaults(func=cmd_show_units)
    p = sub.add_parser("show-timers"); p.set_defaults(func=cmd_show_timers)
    p = sub.add_parser("assert-mount-condition"); p.set_defaults(func=cmd_assert_mount_condition)
    p = sub.add_parser("manual-backup"); p.add_argument("--execute", action="store_true"); p.add_argument("--local-test", action="store_true"); p.add_argument("--unit-context", default="manual"); p.set_defaults(func=cmd_manual_backup)
    p = sub.add_parser("manual-verify"); p.add_argument("--local-test", action="store_true"); p.add_argument("--unit-context", default="manual"); p.add_argument("--scope", default="manual"); p.set_defaults(func=cmd_manual_verify)
    p = sub.add_parser("manual-desktop-capture"); p.add_argument("--unit-context", default="manual"); p.set_defaults(func=cmd_manual_desktop_capture)
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