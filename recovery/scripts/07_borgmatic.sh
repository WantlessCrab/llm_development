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
SCRIPT_NAME = "07_borgmatic.sh"
SCHEMA_NAME = "recovery.borgmatic.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "borgmatic",
        "verified_borgmatic_version": "2.1.6",
        "verified_borg_version": "1.4.4",
        "layer": "07_borg_policy_retention_check_hook_orchestration",
    },
    "project": {
        "output_root": "state/dry_runs/07_borgmatic",
        "local_test_root": "state/local_test/07_borgmatic",
        "generated_config_root": "state/generated/07_borgmatic",
    },
    "commands": {
        "borgmatic": "/usr/local/bin/borgmatic-2.1.6",
        "borg": "/usr/local/bin/borg-1.4.4",
    },
    "policy": {
        "required_borgmatic_version": "borgmatic 2.1.6",
        "required_borg_version": "borg 1.4.4",
        "reject_borg_major_regex": r"^borg 2\.",
        "default_actions": False,
        "compression": "zstd,6",
        "archive_name_format": "{hostname}-wantless-{now:%Y%m%dT%H%M%S}",
        "local_test_archive_name_format": "{hostname}-borgmatic-local-test-{now:%Y%m%dT%H%M%S}",
        "match_archives": "sh:{hostname}-wantless-*",
        "local_test_match_archives": "sh:{hostname}-borgmatic-local-test-*",
        "lock_wait": 20,
        "umask": 77,
        "keep_daily": 14,
        "keep_weekly": 8,
        "keep_monthly": 12,
        "keep_yearly": 2,
        "check_repository_frequency": "always",
        "check_archives_frequency": "4 weeks",
        "check_extract_frequency": "4 weeks",
        "require_execute_for_repo_create": True,
        "require_execute_for_backup": True,
        "require_execute_for_prune_compact": True,
        "repo_create_confirmation_prefix": "BORGMATIC_REPO_CREATE",
        "backup_confirmation_prefix": "BORGMATIC_BACKUP",
        "retention_confirmation_prefix": "BORGMATIC_RETENTION",
        "require_mounted_vault_for_real_profile": True,
        "vault_mountpoint": "/mnt/wantless_recovery",
        "copy_config_snapshot_into_run": True,
        "report_name": "borgmatic_report.json",
        "stdout_name": "borgmatic.stdout.txt",
        "stderr_name": "borgmatic.stderr.txt",
    },
    "profiles": {
        "local-test": {
            "description": "Local borgmatic proof profile. Safe to create and write under project state.",
            "repository": "state/local_test/07_borgmatic/repository",
            "repository_label": "local-test",
            "source_directories": "state/local_test/07_borgmatic/source",
            "config_path": "state/generated/07_borgmatic/local-test.yaml",
            "encryption": "repokey-blake2",
            "passphrase_source": "local_test_config",
            "local_test_passphrase": "LOCAL_TEST_ONLY_BORGMATIC_NOT_FOR_REAL_BACKUPS",
            "archive_name_format_override": "{hostname}-borgmatic-local-test-{now:%Y%m%dT%H%M%S}",
            "match_archives_override": "sh:{hostname}-borgmatic-local-test-*",
            "allow_repo_create": True,
            "allow_backup_execute": True,
            "allow_prune_compact_execute": True,
            "repository_must_be_under_project": True,
            "source_must_be_under_project": True,
            "generate_local_test_payload": True,
            "required": True,
        },
        "vault-primary": {
            "description": "Future production borgmatic profile for the opened Row 03 LUKS vault.",
            "repository": "/mnt/wantless_recovery/06_borg/repository",
            "repository_label": "vault-primary",
            "source_directories": "/home/wantless;/etc;/opt;/usr/local",
            "config_path": "state/generated/07_borgmatic/vault-primary.yaml",
            "encryption": "repokey-blake2",
            "passphrase_source": "environment",
            "passphrase_env": "BORG_PASSPHRASE",
            "archive_name_format_override": "{hostname}-wantless-{now:%Y%m%dT%H%M%S}",
            "match_archives_override": "sh:{hostname}-wantless-*",
            "allow_repo_create": True,
            "allow_backup_execute": True,
            "allow_prune_compact_execute": True,
            "repository_must_be_under_project": False,
            "source_must_be_under_project": False,
            "require_mounted_vault": True,
            "mounted_vault_path": "/mnt/wantless_recovery",
            "required": False,
        },
    },
    "source_policy": {
        "global_exclude_patterns": "/proc;/sys;/dev;/run;/tmp;/mnt;/media;/lost+found;**/.cache;**/Cache;**/GPUCache;**/Code Cache;**/.Trash;**/node_modules;**/__pycache__;**/.pytest_cache;**/.mypy_cache;**/.ruff_cache;**/.venv;**/venv;**/*.pyc;**/.DS_Store",
        "recovery_runtime_excludes": "state/dry_runs;state/local_test;state/tmp",
        "full_payload_note": "Final production payload semantics belong to Row 06 Borg and Row 07 borgmatic execution policy. Specialized logical/inventory artifacts remain owned by their rows.",
    },
    "hook_policy": {
        "include_command_hooks": False,
        "note": "Hooks are generated only when explicitly enabled after owning rows exist. Row 07 owns hook order; owning rows own hook payload semantics.",
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
    path = PROJECT_ROOT / "configs" / "07_borgmatic.yaml"
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


BORGMATIC = cmd_path("borgmatic")
BORG = cmd_path("borg")


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


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/07_borgmatic")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)):
        config_path = PROJECT_ROOT / "configs" / "07_borgmatic.yaml"
        if config_path.exists():
            shutil.copy2(config_path, run_dir / "07_borgmatic.config.snapshot.yaml")
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
            "name": "borgmatic",
            "script": SCRIPT_NAME,
            "borgmatic_path": BORGMATIC,
            "borg_path": BORG,
            "borgmatic_version": None,
            "borg_version": None,
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
    report_path = run_dir / str(cfg_get("policy.report_name", "borgmatic_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], report: dict[str, Any], *, env: dict[str, str] | None = None, cwd: Path | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, cwd=str(cwd) if cwd else None, env=env)
    result = {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    report.setdefault("commands", []).append({"argv": result["argv"], "returncode": result["returncode"], "stderr": result["stderr"]})
    return result


def command_to_report_files(report: dict[str, Any], result: dict[str, Any], run_dir: Path, name: str) -> None:
    stdout_path = run_dir / f"{name}.stdout.txt"
    stderr_path = run_dir / f"{name}.stderr.txt"
    write_text(stdout_path, result.get("stdout", ""))
    write_text(stderr_path, result.get("stderr", ""))
    if report.get("commands"):
        report["commands"][-1]["stdout_path"] = rel(stdout_path)
        report["commands"][-1]["stderr_path"] = rel(stderr_path)


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    report["failures"].append(f"required tool missing for {label}: {path}")
    return False


def semantic_version_tuple(text: str) -> tuple[int, int, int] | None:
    matches = re.findall(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)", text.strip())
    if not matches:
        return None
    major, minor, patch = matches[-1]
    return int(major), int(minor), int(patch)


def semantic_version_text(text: str) -> str | None:
    parsed = semantic_version_tuple(text)
    if not parsed:
        return None
    return ".".join(str(item) for item in parsed)


def assert_versions_into(report: dict[str, Any], run_dir: Path) -> None:
    if require_tool(BORGMATIC, report, "borgmatic"):
        result = run_cmd([BORGMATIC, "--version"], report)
        command_to_report_files(report, result, run_dir, "borgmatic_version")
        version = (result["stdout"].strip() or result["stderr"].strip()).strip()
        report["tool"]["borgmatic_version"] = version
        if result["returncode"] != 0:
            report["failures"].append("borgmatic --version failed")

        expected = str(cfg_get("policy.required_borgmatic_version", "borgmatic 2.1.6"))
        expected_semver = semantic_version_text(expected)
        actual_semver = semantic_version_text(version)

        if not expected_semver:
            report["failures"].append(f"could not parse required borgmatic version from: {expected!r}")
        elif not actual_semver:
            report["failures"].append(f"could not parse borgmatic version from: {version!r}")
        elif actual_semver != expected_semver:
            report["failures"].append(f"expected borgmatic {expected_semver}, got {version}")

    if require_tool(BORG, report, "borg"):
        result = run_cmd([BORG, "--version"], report)
        command_to_report_files(report, result, run_dir, "borg_version")
        version = (result["stdout"].strip() or result["stderr"].strip()).strip()
        report["tool"]["borg_version"] = version
        if result["returncode"] != 0:
            report["failures"].append("borg --version failed")

        expected = str(cfg_get("policy.required_borg_version", "borg 1.4.4"))
        expected_semver = semantic_version_text(expected)
        actual_tuple = semantic_version_tuple(version)
        actual_semver = ".".join(str(item) for item in actual_tuple) if actual_tuple else None

        reject_regex = str(cfg_get("policy.reject_borg_major_regex", r"^borg 2\."))
        if re.search(reject_regex, version) or (actual_tuple is not None and actual_tuple[0] >= 2):
            report["failures"].append(f"Borg 2.x is blocked for production vaults: {version}")

        if not expected_semver:
            report["failures"].append(f"could not parse required Borg version from: {expected!r}")
        elif not actual_semver:
            report["failures"].append(f"could not parse Borg version from: {version!r}")
        elif actual_semver != expected_semver:
            report["failures"].append(f"expected borg {expected_semver}, got {version}")

def profile_alias(value: str) -> str:
    aliases = {
        "local_test": "local-test",
        "local": "local-test",
        "vault_primary": "vault-primary",
        "recovery_vault": "vault-primary",
        "recovery-vault": "vault-primary",
    }
    return aliases.get(value, value)


def profile_config(name: str) -> dict[str, Any]:
    resolved = profile_alias(name)
    profiles = cfg_get("profiles", {})
    if not isinstance(profiles, dict) or resolved not in profiles:
        raise SystemExit(f"unknown borgmatic profile: {name}")
    cfg = deepcopy(profiles[resolved])
    cfg["_profile"] = resolved
    return cfg


def profile_repo(profile: dict[str, Any]) -> Path:
    return resolve_path(str(profile.get("repository")))


def profile_config_path(profile: dict[str, Any]) -> Path:
    return resolve_path(str(profile.get("config_path")))


def profile_sources(profile: dict[str, Any]) -> list[Path]:
    return [resolve_path(item) for item in split_semicolon(profile.get("source_directories"))]


def repo_create_token(repo: Path) -> str:
    return f"{cfg_get('policy.repo_create_confirmation_prefix', 'BORGMATIC_REPO_CREATE')}:{repo.resolve()}"


def backup_token(profile: dict[str, Any]) -> str:
    return f"{cfg_get('policy.backup_confirmation_prefix', 'BORGMATIC_BACKUP')}:{profile['_profile']}"


def retention_token(profile: dict[str, Any]) -> str:
    return f"{cfg_get('policy.retention_confirmation_prefix', 'BORGMATIC_RETENTION')}:{profile['_profile']}"


def vault_mountpoint(profile: dict[str, Any]) -> Path:
    return resolve_path(str(profile.get("mounted_vault_path") or cfg_get("policy.vault_mountpoint", "/mnt/wantless_recovery")))


def require_mounted_vault(profile: dict[str, Any], report: dict[str, Any]) -> None:
    if profile["_profile"] == "local-test":
        return
    if not boolish(profile.get("require_mounted_vault", False)) and not boolish(cfg_get("policy.require_mounted_vault_for_real_profile", True)):
        return
    mountpoint = vault_mountpoint(profile)
    repo = profile_repo(profile)
    if not mountpoint.exists():
        report["failures"].append(f"vault mountpoint does not exist: {mountpoint}")
        return
    if not os.path.ismount(mountpoint):
        report["failures"].append(f"vault mountpoint is not mounted: {mountpoint}")
    if not is_under(repo, mountpoint):
        report["failures"].append(f"repository is not under mounted vault path: repo={repo} mount={mountpoint}")


def require_profile_credentials(profile: dict[str, Any], report: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    if str(profile.get("passphrase_source")) == "local_test_config":
        env["BORG_PASSPHRASE"] = str(profile.get("local_test_passphrase"))
    elif str(profile.get("passphrase_source")) == "environment":
        env_name = str(profile.get("passphrase_env", "BORG_PASSPHRASE"))
        if not env.get(env_name) and not env.get("BORG_PASSCOMMAND"):
            report["failures"].append(f"profile {profile['_profile']} requires {env_name} or BORG_PASSCOMMAND in environment")
        elif env_name != "BORG_PASSPHRASE" and env.get(env_name):
            env["BORG_PASSPHRASE"] = env[env_name]
    else:
        report["failures"].append(f"unsupported passphrase_source for profile {profile['_profile']}: {profile.get('passphrase_source')}")
    env["BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK"] = "no"
    env["BORG_RELOCATED_REPO_ACCESS_IS_OK"] = "no"
    return env


def validate_profile_paths(profile: dict[str, Any], report: dict[str, Any]) -> None:
    repo = profile_repo(profile)
    if boolish(profile.get("repository_must_be_under_project", False)) and not is_under(repo, PROJECT_ROOT):
        report["failures"].append(f"repository must be under project root for profile {profile['_profile']}: {repo}")
    for source in profile_sources(profile):
        if boolish(profile.get("source_must_be_under_project", False)) and not is_under(source, PROJECT_ROOT):
            report["failures"].append(f"source must be under project root for profile {profile['_profile']}: {source}")


def ensure_local_test_payload(profile: dict[str, Any]) -> None:
    if not boolish(profile.get("generate_local_test_payload", False)):
        return
    root = profile_sources(profile)[0]
    nested = root / "nested"
    nested.mkdir(parents=True, exist_ok=True)
    (root / "alpha.txt").write_text("borgmatic row 07 local proof alpha\n", encoding="utf-8")
    (nested / "beta with spaces.txt").write_text("borgmatic row 07 local proof beta\n", encoding="utf-8")
    (root / "payload.bin").write_bytes(bytes((i * 23) % 256 for i in range(8192)))
    (root / "README.local_test.txt").write_text(
        "Generated by Row 07 borgmatic local proof. Safe to recreate.\n",
        encoding="utf-8",
    )


def yaml_quote(value: Any) -> str:
    text = str(value)
    escaped = text.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def yaml_list(items: list[Any], indent: int = 0) -> str:
    pad = " " * indent
    return "\n".join(f"{pad}- {yaml_quote(item)}" for item in items)


def generated_config_text(profile: dict[str, Any]) -> str:
    repo = profile_repo(profile)
    sources = profile_sources(profile)
    excludes = split_semicolon(cfg_get("source_policy.global_exclude_patterns", ""))
    excludes += split_semicolon(cfg_get("source_policy.recovery_runtime_excludes", ""))
    archive_name = str(profile.get("archive_name_format_override") or cfg_get("policy.archive_name_format"))
    match_archives = str(profile.get("match_archives_override") or cfg_get("policy.match_archives"))
    checks_repository_frequency = str(cfg_get("policy.check_repository_frequency", "always"))
    checks_archives_frequency = str(cfg_get("policy.check_archives_frequency", "4 weeks"))
    checks_extract_frequency = str(cfg_get("policy.check_extract_frequency", "4 weeks"))

    lines: list[str] = []
    lines.append("# Generated by recovery Row 07 borgmatic. Do not hand-edit; edit configs/07_borgmatic.yaml.")
    lines.append("source_directories:")
    lines.append(yaml_list([str(p) for p in sources], 4))
    lines.append("source_directories_must_exist: true")
    lines.append("repositories:")
    lines.append(f"    - path: {yaml_quote(repo)}")
    lines.append(f"      label: {yaml_quote(profile.get('repository_label', profile['_profile']))}")
    lines.append(f"      encryption: {yaml_quote(profile.get('encryption', 'repokey-blake2'))}")
    lines.append("      make_parent_directories: true")
    lines.append(f"working_directory: {yaml_quote(PROJECT_ROOT)}")
    lines.append("one_file_system: false")
    lines.append("numeric_ids: true")
    lines.append("atime: false")
    lines.append(f"local_path: {yaml_quote(BORG)}")
    lines.append(f"compression: {yaml_quote(cfg_get('policy.compression', 'zstd,6'))}")
    lines.append(f"archive_name_format: {yaml_quote(archive_name)}")
    lines.append(f"match_archives: {yaml_quote(match_archives)}")
    lines.append(f"lock_wait: {cfg_get('policy.lock_wait', 20)}")
    umask_value = cfg_get("policy.umask", 77)
    try:
        umask_int = int(umask_value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"policy.umask must be an integer-like value, got {umask_value!r}") from exc
    lines.append(f"umask: {umask_int}")
    lines.append(f"default_actions: {'true' if boolish(cfg_get('policy.default_actions', False)) else 'false'}")
    if str(profile.get("passphrase_source")) == "local_test_config":
        lines.append(f"encryption_passphrase: {yaml_quote(profile.get('local_test_passphrase'))}")
    lines.append("exclude_patterns:")
    lines.append(yaml_list(excludes, 4))
    lines.append("keep_daily: " + str(cfg_get("policy.keep_daily", 14)))
    lines.append("keep_weekly: " + str(cfg_get("policy.keep_weekly", 8)))
    lines.append("keep_monthly: " + str(cfg_get("policy.keep_monthly", 12)))
    lines.append("keep_yearly: " + str(cfg_get("policy.keep_yearly", 2)))
    lines.append("checks:")
    lines.append("    - name: repository")
    if checks_repository_frequency != "always":
        lines.append(f"      frequency: {yaml_quote(checks_repository_frequency)}")
    lines.append("    - name: archives")
    lines.append(f"      frequency: {yaml_quote(checks_archives_frequency)}")
    lines.append("    - name: extract")
    lines.append(f"      frequency: {yaml_quote(checks_extract_frequency)}")
    if boolish(cfg_get("hook_policy.include_command_hooks", False)):
        lines.append("commands:")
        lines.append("    - before: action")
        lines.append("      when: [create]")
        lines.append("      run:")
        lines.append("          - " + yaml_quote(str(PROJECT_ROOT / "scripts" / "04_integrity.sh") + " verify-restore-gate --local-only"))
    return "\n".join(lines) + "\n"


def write_generated_config(profile: dict[str, Any], report: dict[str, Any]) -> Path:
    ensure_local_test_payload(profile)
    config_path = profile_config_path(profile)
    config_path.parent.mkdir(parents=True, exist_ok=True)
    text = generated_config_text(profile)
    config_path.write_text(text, encoding="utf-8")
    report["generated_config"] = {
        "path": str(config_path),
        "relative_path": rel(config_path),
        "repository": str(profile_repo(profile)),
        "source_directories": [str(p) for p in profile_sources(profile)],
    }
    return config_path


def borgmatic_argv(config_path: Path, actions: list[str], *, dry_run: bool = False, extra: list[str] | None = None) -> list[str]:
    argv = [BORGMATIC, "--config", str(config_path), "--no-color"]
    if dry_run:
        argv.append("-n")
    argv.extend(actions)
    if extra:
        argv.extend(extra)
    return argv


def cmd_assert_version(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-version")
    report = report_base("assert-version", run_dir)
    report["mode"] = "assert"
    assert_versions_into(report, run_dir)
    return finalize_report(report, run_dir)


def cmd_generate_reference(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-reference")
    report = report_base("generate-reference", run_dir)
    report["mode"] = "summary"
    profile = profile_config(args.profile)
    report["profile"] = profile["_profile"]
    validate_profile_paths(profile, report)
    write_generated_config(profile, report)
    report["config_path"] = report["generated_config"]["path"]
    report["repository"] = str(profile_repo(profile))
    report["hook_plan"] = {
        "include_command_hooks": boolish(cfg_get("hook_policy.include_command_hooks", False)),
        "note": str(cfg_get("hook_policy.note", "")),
    }
    report["retention"] = {
        "keep_daily": cfg_get("policy.keep_daily"),
        "keep_weekly": cfg_get("policy.keep_weekly"),
        "keep_monthly": cfg_get("policy.keep_monthly"),
        "keep_yearly": cfg_get("policy.keep_yearly"),
    }
    return finalize_report(report, run_dir)


def run_borgmatic_action(report: dict[str, Any], run_dir: Path, profile: dict[str, Any], actions: list[str], *, dry_run: bool = False, extra: list[str] | None = None, name: str = "borgmatic") -> dict[str, Any] | None:
    config_path = write_generated_config(profile, report)
    env = require_profile_credentials(profile, report)
    if report["failures"]:
        return None
    argv = borgmatic_argv(config_path, actions, dry_run=dry_run, extra=extra)
    result = run_cmd(argv, report, env=env, cwd=PROJECT_ROOT)
    command_to_report_files(report, result, run_dir, name)
    return result


def cmd_validate(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("validate")
    report = report_base("validate", run_dir)
    report["mode"] = "assert"
    profile = profile_config(args.profile)
    report["profile"] = profile["_profile"]
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    result = run_borgmatic_action(report, run_dir, profile, ["config", "validate"], name="borgmatic_config_validate")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic config validate failed")
    return finalize_report(report, run_dir)


def cmd_show_config(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("show-config")
    report = report_base("show-config", run_dir)
    report["mode"] = "summary"
    profile = profile_config(args.profile)
    report["profile"] = profile["_profile"]
    assert_versions_into(report, run_dir)
    result = run_borgmatic_action(report, run_dir, profile, ["config", "validate", "--show"], name="borgmatic_config_show")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic config validate --show failed")
    return finalize_report(report, run_dir)


def cmd_repo_create_guarded(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("repo-create-guarded")
    report = report_base("repo-create-guarded", run_dir)
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "execute" if args.execute else "dry-run"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if not boolish(profile.get("allow_repo_create", False)):
        report["failures"].append(f"profile does not allow repo-create: {profile['_profile']}")
    if profile["_profile"] != "local-test":
        require_mounted_vault(profile, report)
    if boolish(cfg_get("policy.require_execute_for_repo_create", True)) and not args.execute:
        report["warnings"].append("repo-create-guarded did not run because --execute was not supplied")
        write_generated_config(profile, report)
        return finalize_report(report, run_dir)
    if profile["_profile"] != "local-test":
        expected = repo_create_token(repo)
        if args.confirm_token != expected:
            report["failures"].append(f"repo-create-guarded --execute requires --confirm-token {expected}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    repo.parent.mkdir(parents=True, exist_ok=True)
    result = run_borgmatic_action(report, run_dir, profile, ["repo-create"], extra=["--repository", str(repo)], name="borgmatic_repo_create")
    if result and result["returncode"] != 0:
        text = (result["stdout"] + result["stderr"]).lower()
        if "already" in text:
            report["warnings"].append("repository already exists")
        else:
            report["failures"].append("borgmatic repo-create failed")
    return finalize_report(report, run_dir)


def cmd_dry_run(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("dry-run")
    report = report_base("dry-run", run_dir)
    profile = profile_config(args.profile)
    report.update({"profile": profile["_profile"], "mode": "dry-run"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if profile["_profile"] != "local-test":
        require_mounted_vault(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_borgmatic_action(report, run_dir, profile, ["create"], dry_run=True, extra=["--stats"], name="borgmatic_create_dry_run")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic create dry-run failed")
    return finalize_report(report, run_dir)


def cmd_backup(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("backup")
    report = report_base("backup", run_dir)
    profile = profile_config(args.profile)
    report.update({"profile": profile["_profile"], "mode": "execute" if args.execute else "dry-run"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if not boolish(profile.get("allow_backup_execute", False)):
        report["failures"].append(f"profile does not allow backup execution: {profile['_profile']}")
    if profile["_profile"] != "local-test":
        require_mounted_vault(profile, report)
    if boolish(cfg_get("policy.require_execute_for_backup", True)) and not args.execute:
        report["warnings"].append("backup did not execute because --execute was not supplied; running dry-run instead")
        result = run_borgmatic_action(report, run_dir, profile, ["create"], dry_run=True, extra=["--stats"], name="borgmatic_create_dry_run")
        if result and result["returncode"] != 0:
            report["failures"].append("borgmatic create dry-run failed")
        return finalize_report(report, run_dir)
    if profile["_profile"] != "local-test":
        expected = backup_token(profile)
        if args.confirm_token != expected:
            report["failures"].append(f"backup --execute requires --confirm-token {expected}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_borgmatic_action(report, run_dir, profile, ["create"], extra=["--stats", "--list"], name="borgmatic_create")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic create failed")
    return finalize_report(report, run_dir)


def cmd_check(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("check")
    report = report_base("check", run_dir)
    profile = profile_config(args.profile)
    report.update({"profile": profile["_profile"], "mode": "assert"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if profile["_profile"] != "local-test":
        require_mounted_vault(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_borgmatic_action(report, run_dir, profile, ["check"], name="borgmatic_check")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic check failed")
    return finalize_report(report, run_dir)


def cmd_prune_compact(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("prune-compact")
    report = report_base("prune-compact", run_dir)
    profile = profile_config(args.profile)
    report.update({"profile": profile["_profile"], "mode": "execute" if args.execute else "dry-run"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if not boolish(profile.get("allow_prune_compact_execute", False)):
        report["failures"].append(f"profile does not allow prune/compact execution: {profile['_profile']}")
    if profile["_profile"] != "local-test":
        require_mounted_vault(profile, report)
    if boolish(cfg_get("policy.require_execute_for_prune_compact", True)) and not args.execute:
        report["warnings"].append("prune-compact did not execute because --execute was not supplied; running dry-run instead")
        result = run_borgmatic_action(report, run_dir, profile, ["prune", "compact"], dry_run=True, name="borgmatic_prune_compact_dry_run")
        if result and result["returncode"] != 0:
            report["failures"].append("borgmatic prune/compact dry-run failed")
        return finalize_report(report, run_dir)
    if profile["_profile"] != "local-test":
        expected = retention_token(profile)
        if args.confirm_token != expected:
            report["failures"].append(f"prune-compact --execute requires --confirm-token {expected}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_borgmatic_action(report, run_dir, profile, ["prune", "compact"], name="borgmatic_prune_compact")
    if result and result["returncode"] != 0:
        report["failures"].append("borgmatic prune/compact failed")
    return finalize_report(report, run_dir)


def cmd_verify_cycle(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-cycle")
    report = report_base("verify-cycle", run_dir)
    profile = profile_config("local-test")
    report.update({"profile": "local-test", "mode": "execute"})
    assert_versions_into(report, run_dir)
    validate_profile_paths(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)

    validate_result = run_borgmatic_action(report, run_dir, profile, ["config", "validate"], name="cycle_config_validate")
    if validate_result and validate_result["returncode"] != 0:
        report["failures"].append("cycle config validation failed")
        return finalize_report(report, run_dir)

    repo = profile_repo(profile)
    repo.parent.mkdir(parents=True, exist_ok=True)
    repo_result = run_borgmatic_action(report, run_dir, profile, ["repo-create"], extra=["--repository", str(repo)], name="cycle_repo_create")
    if repo_result and repo_result["returncode"] != 0:
        text = (repo_result["stdout"] + repo_result["stderr"]).lower()
        if "already" in text:
            report["warnings"].append("cycle repo-create reported repository already exists")
        else:
            report["failures"].append("cycle repo-create failed")
            return finalize_report(report, run_dir)

    dry_result = run_borgmatic_action(report, run_dir, profile, ["create"], dry_run=True, extra=["--stats"], name="cycle_create_dry_run")
    if dry_result and dry_result["returncode"] != 0:
        report["failures"].append("cycle create dry-run failed")
        return finalize_report(report, run_dir)

    create_result = run_borgmatic_action(report, run_dir, profile, ["create"], extra=["--stats", "--list"], name="cycle_create")
    if create_result and create_result["returncode"] != 0:
        report["failures"].append("cycle create failed")
        return finalize_report(report, run_dir)

    check_result = run_borgmatic_action(report, run_dir, profile, ["check"], name="cycle_check")
    if check_result and check_result["returncode"] != 0:
        report["failures"].append("cycle check failed")

    retention_result = run_borgmatic_action(report, run_dir, profile, ["prune", "compact"], dry_run=True, name="cycle_prune_compact_dry_run")
    if retention_result and retention_result["returncode"] != 0:
        report["failures"].append("cycle prune/compact dry-run failed")

    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_profile(p: argparse.ArgumentParser) -> None:
        p.add_argument("--profile", default="local-test")

    p = sub.add_parser("assert-version")
    p.set_defaults(func=cmd_assert_version)

    p = sub.add_parser("generate-reference")
    add_profile(p)
    p.set_defaults(func=cmd_generate_reference)

    p = sub.add_parser("validate")
    add_profile(p)
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("dry-run")
    add_profile(p)
    p.set_defaults(func=cmd_dry_run)

    p = sub.add_parser("repo-create-guarded")
    add_profile(p)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_repo_create_guarded)

    p = sub.add_parser("backup")
    add_profile(p)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_backup)

    p = sub.add_parser("check")
    add_profile(p)
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("prune-compact")
    add_profile(p)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_prune_compact)

    p = sub.add_parser("verify-cycle")
    p.set_defaults(func=cmd_verify_cycle)

    p = sub.add_parser("show-config")
    add_profile(p)
    p.set_defaults(func=cmd_show_config)

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