#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PY'
from __future__ import annotations

import argparse
import hashlib
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
SCRIPT_NAME = "06_borg.sh"
SCHEMA_NAME = "recovery.borg.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {"name": "borg", "verified_borg_version": "1.4.4", "borg_path": "/usr/local/bin/borg-1.4.4", "layer": "06_versioned_filesystem_payload_post_image_delta"},
    "project": {"output_root": "state/dry_runs/06_borg", "local_test_root": "state/local_test/06_borg", "secret_root": "state/secrets/06_borg"},
    "policy": {
        "expected_major": 1, "expected_minor": 4, "expected_patch": 4, "hard_block_major_above": 1,
        "require_execute_for_init": True, "require_execute_for_restore": True, "require_execute_for_mount": True,
        "production_init_confirmation_prefix": "BORG_INIT", "production_key_export_confirmation_prefix": "BORG_KEY_EXPORT",
        "restore_confirmation_prefix": "BORG_RESTORE", "mount_confirmation_prefix": "BORG_MOUNT",
        "copy_config_snapshot_into_run": True, "report_name": "borg_report.json", "archive_inventory_name": "archive_inventory.json",
        "key_export_mode": "0600", "secret_dir_mode": "0700", "local_test_archive_name": "local-test-proof",
        "local_test_passphrase": "LOCAL_TEST_ONLY_NOT_A_REAL_SECRET",
        "borg_unknown_unencrypted_repo_access_is_ok": "no", "borg_relocated_repo_access_is_ok": "no",
    },
    "repository_profiles": {
        "local-test": {
            "repository": "state/local_test/06_borg/repository", "payload_root": "state/local_test/06_borg/payload",
            "restore_root": "state/local_test/06_borg/restore", "key_export_dir": "state/local_test/06_borg/key_exports",
            "encryption": "repokey-blake2", "compression": "lz4", "passphrase_source": "local_test_config",
            "allow_init": True, "allow_create_test_archive": True, "allow_restore_execute": True, "allow_mount_execute": True,
            "require_init_token": False, "require_key_export_token": False, "repository_must_be_under_project": True, "restore_must_be_under_project": True,
        },
        "vault-primary": {
            "repository": "/mnt/wantless_recovery/06_borg/repository", "payload_root": "/", "restore_root": "state/restore_previews/06_borg",
            "key_export_dir": "state/secrets/06_borg/key_exports/vault-primary", "encryption": "repokey-blake2", "compression": "lz4",
            "passphrase_source": "environment", "passphrase_env": "BORG_PASSPHRASE",
            "allow_init": True, "allow_create_test_archive": False, "allow_restore_execute": True, "allow_mount_execute": True,
            "require_init_token": True, "require_key_export_token": True, "repository_must_be_under_project": False,
            "require_mountpoint": True, "mountpoint": "/mnt/wantless_recovery", "restore_must_be_under_project": False,
        },
    },
    "exclude_policy": {"default_excludes": "**/.cache/**;**/__pycache__/**;**/.git/**;**/.venv/**;**/venv/**;**/*.pyc;**/.DS_Store"},
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
    path = PROJECT_ROOT / "configs" / "06_borg.yaml"
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


def boolish(value: Any) -> bool:
    return value if isinstance(value, bool) else str(value).strip().lower() in {"1", "true", "yes", "on"}


def borg_path() -> str:
    configured = str(cfg_get("tool.borg_path", "/usr/local/bin/borg-1.4.4"))
    return configured if "/" in configured else (shutil.which(configured) or configured)


BORG = borg_path()


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


def is_under(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def project_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/06_borg")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "06_borg.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "06_borg.config.snapshot.yaml")
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {"schema": SCHEMA_NAME, "tool": {"name": "borg", "script": SCRIPT_NAME, "borg_path": BORG, "version": None}, "command": command, "generated_at": iso_now(), "host": socket.gethostname(), "project_root": str(PROJECT_ROOT), "run_dir": rel(run_dir), "ok": True, "failures": [], "warnings": [], "commands": []}


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_path = run_dir / str(cfg_get("policy.report_name", "borg_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def normalize_profile_name(name: str) -> str:
    aliases = {
        "local_test": "local-test",
        "vault_primary": "vault-primary",
        "recovery_vault": "vault-primary",
    }
    return aliases.get(name, name)


def profile_config(name: str) -> dict[str, Any]:
    requested_name = name
    name = normalize_profile_name(name)
    profiles = cfg_get("repository_profiles", {})
    if not isinstance(profiles, dict) or name not in profiles:
        raise SystemExit(f"unknown Borg repository profile: {requested_name}")
    cfg = deepcopy(profiles[name])
    cfg["_profile"] = name
    cfg["_requested_profile"] = requested_name
    return cfg


def profile_repo(profile: dict[str, Any]) -> Path:
    return resolve_path(str(profile.get("repository", "")))


def borg_env(profile: dict[str, Any], report: dict[str, Any]) -> dict[str, str]:
    env = os.environ.copy()
    source = str(profile.get("passphrase_source", "environment"))
    if source == "local_test_config":
        env["BORG_PASSPHRASE"] = str(cfg_get("policy.local_test_passphrase", "LOCAL_TEST_ONLY_NOT_A_REAL_SECRET"))
    elif source == "environment":
        env_name = str(profile.get("passphrase_env", "BORG_PASSPHRASE"))
        if not env.get(env_name):
            report["failures"].append(f"required Borg passphrase environment variable is not set: {env_name}")
        elif env_name != "BORG_PASSPHRASE":
            env["BORG_PASSPHRASE"] = env[env_name]
    else:
        report["failures"].append(f"unsupported passphrase_source: {source}")
    env["BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK"] = str(cfg_get("policy.borg_unknown_unencrypted_repo_access_is_ok", "no"))
    env["BORG_RELOCATED_REPO_ACCESS_IS_OK"] = str(cfg_get("policy.borg_relocated_repo_access_is_ok", "no"))
    return env


def run_cmd(argv: list[str], report: dict[str, Any], *, env: dict[str, str] | None = None, cwd: Path | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, env=env, cwd=str(cwd) if cwd else None)
    result = {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    report.setdefault("commands", []).append({"argv": result["argv"], "returncode": result["returncode"], "stderr": result["stderr"]})
    return result


def require_borg(report: dict[str, Any]) -> bool:
    if Path(BORG).exists() or shutil.which(BORG):
        return True
    report["failures"].append(f"Borg binary not found: {BORG}")
    return False


def parse_borg_version(text: str) -> tuple[int, int, int] | None:
    matches = re.findall(r"(?<!\d)(\d+)\.(\d+)\.(\d+)(?!\d)", text.strip())
    if not matches:
        return None
    major, minor, patch = matches[-1]
    return int(major), int(minor), int(patch)

def assert_version_into(report: dict[str, Any]) -> None:
    if not require_borg(report):
        return
    result = run_cmd([BORG, "--version"], report)
    version_text = result["stdout"].strip() or result["stderr"].strip()
    report["tool"]["version"] = version_text
    if result["returncode"] != 0:
        report["failures"].append(f"borg --version failed: {result['stderr'].strip()}")
        return
    parsed = parse_borg_version(version_text)
    if not parsed:
        report["failures"].append(f"could not parse Borg version from: {version_text!r}")
        return
    major, minor, patch = parsed
    report["borg"] = {"version_text": version_text, "major": major, "minor": minor, "patch": patch}
    if major > int(cfg_get("policy.hard_block_major_above", 1)):
        report["failures"].append(f"Borg {version_text} is blocked; production vault requires Borg 1.4.x")
    if major != int(cfg_get("policy.expected_major", 1)) or minor != int(cfg_get("policy.expected_minor", 4)) or patch != int(cfg_get("policy.expected_patch", 4)):
        report["failures"].append(f"unexpected Borg version: {version_text}; expected borg 1.4.4")


def init_token(repo: Path) -> str:
    return f"{cfg_get('policy.production_init_confirmation_prefix', 'BORG_INIT')}:{repo.resolve()}"


def key_export_token(repo: Path) -> str:
    return f"{cfg_get('policy.production_key_export_confirmation_prefix', 'BORG_KEY_EXPORT')}:{repo.resolve()}"


def restore_token(destination: Path) -> str:
    return f"{cfg_get('policy.restore_confirmation_prefix', 'BORG_RESTORE')}:{destination.resolve()}"


def mount_token(mountpoint: Path) -> str:
    return f"{cfg_get('policy.mount_confirmation_prefix', 'BORG_MOUNT')}:{mountpoint.resolve()}"


def validate_repository_path(profile: dict[str, Any], repo: Path, report: dict[str, Any]) -> None:
    if boolish(profile.get("repository_must_be_under_project", False)) and not is_under(repo, PROJECT_ROOT):
        report["failures"].append(f"repository must be under project root for profile {profile['_profile']}: {repo}")
    if repo == Path("/") or str(repo) in {"/home", "/home/wantless", "/mnt", "/media"}:
        report["failures"].append(f"refusing unsafe repository path: {repo}")
    if boolish(profile.get("require_mountpoint", False)):
        mountpoint = resolve_path(str(profile.get("mountpoint", "")))
        if not mountpoint.exists():
            report["failures"].append(f"required Borg vault mountpoint does not exist: {mountpoint}")
        elif not mountpoint.is_mount():
            report["failures"].append(f"required Borg vault mountpoint is not mounted: {mountpoint}")
        if not is_under(repo, mountpoint):
            report["failures"].append(f"Borg repository path must be under required mountpoint {mountpoint}: {repo}")


def ensure_local_test_payload(profile: dict[str, Any]) -> Path:
    payload = resolve_path(str(profile.get("payload_root")))
    nested = payload / "projects" / "demo"
    nested.mkdir(parents=True, exist_ok=True)
    (payload / "README.local_test.txt").write_text("Borg Row 06 local-test payload. Safe to recreate.\n", encoding="utf-8")
    (nested / "alpha.txt").write_text("alpha filesystem payload proof\n", encoding="utf-8")
    (nested / "beta with spaces.txt").write_text("beta filesystem payload proof\n", encoding="utf-8")
    (payload / "deterministic.bin").write_bytes(bytes((i * 13) % 256 for i in range(4096)))
    return payload


def local_payload_archive_path(profile: dict[str, Any]) -> str:
    return project_relative(resolve_path(str(profile.get("payload_root"))))


def local_payload_proof_archive_path(profile: dict[str, Any]) -> str:
    return f"{local_payload_archive_path(profile)}/projects/demo/alpha.txt"


def sha256_file(path: Path) -> str | None:
    if not path.exists() or not path.is_file():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_exists(repo: Path) -> bool:
    return (repo / "config").exists() and (repo / "data").exists()


def borg_json_command(argv: list[str], profile: dict[str, Any], report: dict[str, Any]) -> dict[str, Any] | None:
    env = borg_env(profile, report)
    if report["failures"]:
        return None
    result = run_cmd(argv, report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"Borg command failed: {' '.join(argv)} :: {result['stderr'].strip()}")
        return None
    try:
        return json.loads(result["stdout"])
    except json.JSONDecodeError as exc:
        report["failures"].append(f"could not parse Borg JSON output: {exc}")
        return None


def archive_names(profile: dict[str, Any], repo: Path, report: dict[str, Any]) -> list[str]:
    payload = borg_json_command([BORG, "list", "--json", str(repo)], profile, report)
    if not payload:
        return []
    names = []
    for item in payload.get("archives", []) if isinstance(payload, dict) else []:
        value = item.get("name") or item.get("archive")
        if value:
            names.append(str(value))
    return names


def latest_archive(profile: dict[str, Any], repo: Path, report: dict[str, Any]) -> str | None:
    names = archive_names(profile, repo, report)
    return names[-1] if names else None


def create_local_test_archive(profile: dict[str, Any], repo: Path, report: dict[str, Any]) -> str | None:
    if not boolish(profile.get("allow_create_test_archive", False)):
        report["failures"].append("selected profile does not allow local test archive creation")
        return None
    ensure_local_test_payload(profile)
    archive = f"{cfg_get('policy.local_test_archive_name', 'local-test-proof')}-{now_stamp()}"
    env = borg_env(profile, report)
    if report["failures"]:
        return None
    result = run_cmd([BORG, "create", "--stats", f"--compression={profile.get('compression', 'lz4')}", f"{repo}::{archive}", local_payload_archive_path(profile)], report, env=env, cwd=PROJECT_ROOT)
    if result["returncode"] != 0:
        report["failures"].append(f"borg create local-test archive failed: {result['stderr'].strip()}")
        return None
    return archive


def verify_key_export_against_repo(profile: dict[str, Any], repo: Path, key_file: Path, run_dir: Path, report: dict[str, Any]) -> None:
    if not key_file.exists() or not key_file.is_file():
        report["failures"].append(f"key export file does not exist: {key_file}")
        return
    mode = key_file.stat().st_mode & 0o777
    report["key_export"] = {"path": str(key_file), "relative_path": rel(key_file), "size_bytes": key_file.stat().st_size, "mode": oct(mode), "sha256": sha256_file(key_file)}
    if key_file.stat().st_size <= 0:
        report["failures"].append("key export file is empty")
    if mode & 0o077:
        report["failures"].append(f"key export file permissions are too open: {oct(mode)}")
    fresh_path = run_dir / "fresh_current_key_export.borg-key"
    env = borg_env(profile, report)
    if report["failures"]:
        return
    result = run_cmd([BORG, "key", "export", str(repo), str(fresh_path)], report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"fresh borg key export failed during verification: {result['stderr'].strip()}")
        return
    os.chmod(fresh_path, int(str(cfg_get("policy.key_export_mode", "0600")), 8))
    fresh_hash = sha256_file(fresh_path)
    report["key_export"]["fresh_sha256"] = fresh_hash
    report["key_export"]["matches_current_repo_export"] = report["key_export"].get("sha256") == fresh_hash
    if report["key_export"].get("sha256") != fresh_hash:
        report["failures"].append("key export does not match a fresh current export from the repository")


def cmd_assert_version(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-version")
    report = report_base("assert-version", run_dir)
    report["mode"] = "assert"
    assert_version_into(report)
    return finalize_report(report, run_dir)


def cmd_init_repo(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("init-repo")
    report = report_base("init-repo", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "execute" if args.execute else "dry-run"})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not boolish(profile.get("allow_init", False)):
        report["failures"].append(f"profile does not allow repository initialization: {profile['_profile']}")
    if boolish(cfg_get("policy.require_execute_for_init", True)) and not args.execute:
        report["warnings"].append("init-repo did not run because --execute was not supplied")
        return finalize_report(report, run_dir)
    if boolish(profile.get("require_init_token", False)) and args.confirm_token != init_token(repo):
        report["failures"].append(f"production init requires --confirm-token {init_token(repo)}")
    if repo.exists() and repo_exists(repo):
        report["warnings"].append(f"Borg repository already appears initialized: {repo}")
        return finalize_report(report, run_dir)
    if report["failures"]:
        return finalize_report(report, run_dir)
    repo.parent.mkdir(parents=True, exist_ok=True)
    env = borg_env(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_cmd([BORG, "init", f"--encryption={profile.get('encryption', 'repokey-blake2')}", str(repo)], report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"borg init failed: {result['stderr'].strip()}")
    return finalize_report(report, run_dir)


def cmd_export_key(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("export-key")
    report = report_base("export-key", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "execute" if args.execute else "dry-run"})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
    if not args.execute:
        report["warnings"].append("export-key did not run because --execute was not supplied")
        return finalize_report(report, run_dir)
    if boolish(profile.get("require_key_export_token", False)) and args.confirm_token != key_export_token(repo):
        report["failures"].append(f"production key export requires --confirm-token {key_export_token(repo)}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    key_dir = resolve_path(str(profile.get("key_export_dir")))
    key_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(key_dir, int(str(cfg_get("policy.secret_dir_mode", "0700")), 8))
    key_path = key_dir / f"{profile['_profile']}-{now_stamp()}.borg-key"
    env = borg_env(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_cmd([BORG, "key", "export", str(repo), str(key_path)], report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"borg key export failed: {result['stderr'].strip()}")
    else:
        os.chmod(key_path, int(str(cfg_get("policy.key_export_mode", "0600")), 8))
        report["key_export"] = {"path": str(key_path), "relative_path": rel(key_path), "size_bytes": key_path.stat().st_size, "mode": oct(key_path.stat().st_mode & 0o777)}
    return finalize_report(report, run_dir)


def cmd_verify_key_export(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("verify-key-export")
    report = report_base("verify-key-export", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "assert"})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
        return finalize_report(report, run_dir)
    verify_key_export_against_repo(profile, repo, resolve_path(args.key_file), run_dir, report)
    return finalize_report(report, run_dir)


def cmd_repo_info(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("repo-info")
    report = report_base("repo-info", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo)})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
        return finalize_report(report, run_dir)
    payload = borg_json_command([BORG, "info", "--json", str(repo)], profile, report)
    if payload is not None:
        report["repository_info"] = payload
        write_json(run_dir / "repo_info.json", payload)
    return finalize_report(report, run_dir)


def cmd_check(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("check")
    report = report_base("check", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo)})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
        return finalize_report(report, run_dir)
    argv = [BORG, "check"]
    if args.repository_only:
        argv.append("--repository-only")
    if args.archives_only:
        argv.append("--archives-only")
    argv.append(str(repo))
    env = borg_env(profile, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    result = run_cmd(argv, report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"borg check failed: {result['stderr'].strip()}")
    return finalize_report(report, run_dir)


def cmd_list_archives(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("list-archives")
    report = report_base("list-archives", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo)})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
        return finalize_report(report, run_dir)
    payload = borg_json_command([BORG, "list", "--json", str(repo)], profile, report)
    if payload is not None:
        report["archive_inventory"] = payload
        write_json(run_dir / "archives.json", payload)
    return finalize_report(report, run_dir)


def cmd_capture_archive_inventory(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    run_dir = make_run_dir("capture-archive-inventory")
    report = report_base("capture-archive-inventory", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo)})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
        return finalize_report(report, run_dir)
    inventory = {"repository": str(repo), "archives": []}
    for name in archive_names(profile, repo, report):
        info = borg_json_command([BORG, "info", "--json", f"{repo}::{name}"], profile, report)
        if info is not None:
            inventory["archives"].append(info)
    report["archive_inventory"] = inventory
    write_json(run_dir / str(cfg_get("policy.archive_inventory_name", "archive_inventory.json")), inventory)
    return finalize_report(report, run_dir)


def cmd_mount_readonly(args: argparse.Namespace) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    mountpoint = resolve_path(args.mountpoint)
    run_dir = make_run_dir("mount-readonly")
    report = report_base("mount-readonly", run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "execute" if args.execute else "dry-run", "mount": {"mountpoint": str(mountpoint), "archive": args.archive}})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
    if boolish(cfg_get("policy.require_execute_for_mount", True)) and not args.execute:
        report["warnings"].append("mount-readonly did not run because --execute was not supplied")
        return finalize_report(report, run_dir)
    if not boolish(profile.get("allow_mount_execute", False)):
        report["failures"].append(f"profile does not allow mount execution: {profile['_profile']}")
    if args.confirm_token != mount_token(mountpoint):
        report["failures"].append(f"mount-readonly --execute requires --confirm-token {mount_token(mountpoint)}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    mountpoint.mkdir(parents=True, exist_ok=True)
    target = f"{repo}::{args.archive}" if args.archive else str(repo)
    env = borg_env(profile, report)
    result = run_cmd([BORG, "mount", "-o", "ro", target, str(mountpoint)], report, env=env)
    if result["returncode"] != 0:
        report["failures"].append(f"borg mount failed: {result['stderr'].strip()}")
    return finalize_report(report, run_dir)


def extraction_archive(profile: dict[str, Any], repo: Path, explicit: str | None, report: dict[str, Any]) -> str | None:
    if explicit:
        return explicit
    names = archive_names(profile, repo, report)
    if not names:
        report["failures"].append("no archive available; pass --archive or create one first")
        return None
    return names[-1]


def run_extract(profile: dict[str, Any], repo: Path, archive: str, destination: Path, paths: list[str], report: dict[str, Any], *, dry_run: bool) -> None:
    env = borg_env(profile, report)
    if report["failures"]:
        return
    if not dry_run:
        destination.mkdir(parents=True, exist_ok=True)
    argv = [BORG, "extract", "--list"]
    if dry_run:
        argv.append("--dry-run")
    argv.append(f"{repo}::{archive}")
    argv.extend(paths)
    result = run_cmd(argv, report, env=env, cwd=destination if not dry_run else None)
    if result["returncode"] != 0:
        report["failures"].append(f"borg extract failed: {result['stderr'].strip()}")
    report["restore"] = {"archive": archive, "destination": str(destination), "paths": paths, "dry_run": dry_run}


def cmd_extract_or_restore(args: argparse.Namespace, command: str, *, force_dry_run: bool) -> int:
    profile = profile_config(args.profile)
    repo = profile_repo(profile)
    destination = resolve_path(args.destination or str(profile.get("restore_root", "state/restore_previews/06_borg")))
    run_dir = make_run_dir(command)
    report = report_base(command, run_dir)
    report.update({"profile": profile["_profile"], "repository": str(repo), "mode": "dry-run" if (force_dry_run or not args.execute) else "execute"})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if not repo_exists(repo):
        report["failures"].append(f"Borg repository is not initialized: {repo}")
    archive = extraction_archive(profile, repo, args.archive, report)
    if not archive:
        return finalize_report(report, run_dir)
    paths = args.paths or []
    if command == "extract-test-file" and not paths and profile["_profile"] == "local-test":
        paths = [local_payload_proof_archive_path(profile)]
    dry_run = force_dry_run or not args.execute
    if not dry_run:
        if not boolish(profile.get("allow_restore_execute", False)):
            report["failures"].append(f"profile does not allow restore execution: {profile['_profile']}")
        if boolish(profile.get("restore_must_be_under_project", False)) and not is_under(destination, PROJECT_ROOT):
            report["failures"].append(f"restore destination must be under project root for profile {profile['_profile']}: {destination}")
        if command == "restore-selected" and args.confirm_token != restore_token(destination):
            report["failures"].append(f"restore-selected --execute requires --confirm-token {restore_token(destination)}")
    if report["failures"]:
        return finalize_report(report, run_dir)
    run_extract(profile, repo, archive, destination, paths, report, dry_run=dry_run)
    if command == "extract-test-file" and not dry_run and paths:
        expected = destination / paths[0]
        if not expected.exists():
            report["failures"].append(f"extract-test-file did not produce expected file: {expected}")
    return finalize_report(report, run_dir)


def cmd_gate(args: argparse.Namespace) -> int:
    profile = profile_config("local-test")
    repo = profile_repo(profile)
    run_dir = make_run_dir("gate")
    report = report_base("gate", run_dir)
    report.update({"profile": "local-test", "repository": str(repo), "mode": "execute"})
    assert_version_into(report)
    validate_repository_path(profile, repo, report)
    if report["failures"]:
        return finalize_report(report, run_dir)
    if not repo_exists(repo):
        repo.parent.mkdir(parents=True, exist_ok=True)
        env = borg_env(profile, report)
        result = run_cmd([BORG, "init", f"--encryption={profile.get('encryption', 'repokey-blake2')}", str(repo)], report, env=env)
        if result["returncode"] != 0:
            report["failures"].append(f"borg init failed: {result['stderr'].strip()}")
            return finalize_report(report, run_dir)
    archive = create_local_test_archive(profile, repo, report)
    if not archive:
        return finalize_report(report, run_dir)
    report["archive"] = archive
    info = borg_json_command([BORG, "info", "--json", str(repo)], profile, report)
    if info is not None:
        report["repository_info"] = info
        write_json(run_dir / "repo_info.json", info)
    listing = borg_json_command([BORG, "list", "--json", str(repo)], profile, report)
    if listing is not None:
        report["archive_inventory"] = listing
        write_json(run_dir / "archives.json", listing)
    env = borg_env(profile, report)
    if not report["failures"]:
        check_result = run_cmd([BORG, "check", str(repo)], report, env=env)
        if check_result["returncode"] != 0:
            report["failures"].append(f"borg check failed: {check_result['stderr'].strip()}")
    key_dir = resolve_path(str(profile.get("key_export_dir")))
    key_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(key_dir, int(str(cfg_get("policy.secret_dir_mode", "0700")), 8))
    key_path = key_dir / f"local-test-{now_stamp()}.borg-key"
    if not report["failures"]:
        key_result = run_cmd([BORG, "key", "export", str(repo), str(key_path)], report, env=env)
        if key_result["returncode"] != 0:
            report["failures"].append(f"borg key export failed: {key_result['stderr'].strip()}")
        else:
            os.chmod(key_path, int(str(cfg_get("policy.key_export_mode", "0600")), 8))
            verify_key_export_against_repo(profile, repo, key_path, run_dir, report)
    restore_root = resolve_path(str(profile.get("restore_root"))) / archive
    archive_payload = local_payload_archive_path(profile)
    proof_archive_path = local_payload_proof_archive_path(profile)
    if not report["failures"]:
        run_extract(profile, repo, archive, restore_root, [archive_payload], report, dry_run=True)
    if not report["failures"]:
        run_extract(profile, repo, archive, restore_root, [archive_payload], report, dry_run=False)
        expected_file = restore_root / proof_archive_path
        if not expected_file.exists():
            report["failures"].append(f"selected local extract did not produce expected proof file: {expected_file}")
        else:
            report["restore"]["proof_file_verified"] = str(expected_file)
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_profile(p: argparse.ArgumentParser) -> None:
        p.add_argument("--profile", default="local-test")

    p = sub.add_parser("assert-version")
    p.set_defaults(func=cmd_assert_version)

    p = sub.add_parser("init-repo")
    add_profile(p)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_init_repo)

    p = sub.add_parser("export-key")
    add_profile(p)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_export_key)

    p = sub.add_parser("verify-key-export")
    add_profile(p)
    p.add_argument("--key-file", required=True)
    p.set_defaults(func=cmd_verify_key_export)

    p = sub.add_parser("repo-info")
    add_profile(p)
    p.set_defaults(func=cmd_repo_info)

    p = sub.add_parser("check")
    add_profile(p)
    p.add_argument("--repository-only", action="store_true")
    p.add_argument("--archives-only", action="store_true")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("list-archives")
    add_profile(p)
    p.set_defaults(func=cmd_list_archives)

    p = sub.add_parser("mount-readonly")
    add_profile(p)
    p.add_argument("--archive", default=None)
    p.add_argument("--mountpoint", required=True)
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default=None)
    p.set_defaults(func=cmd_mount_readonly)

    def add_restore_args(p: argparse.ArgumentParser) -> None:
        add_profile(p)
        p.add_argument("--archive", default=None)
        p.add_argument("--destination", default=None)
        p.add_argument("--execute", action="store_true")
        p.add_argument("--confirm-token", default=None)
        p.add_argument("paths", nargs="*")

    p = sub.add_parser("extract-test-file")
    add_restore_args(p)
    p.set_defaults(func=lambda a: cmd_extract_or_restore(a, "extract-test-file", force_dry_run=False))

    p = sub.add_parser("restore-preview")
    add_restore_args(p)
    p.set_defaults(func=lambda a: cmd_extract_or_restore(a, "restore-preview", force_dry_run=True))

    p = sub.add_parser("restore-selected")
    add_restore_args(p)
    p.set_defaults(func=lambda a: cmd_extract_or_restore(a, "restore-selected", force_dry_run=False))

    p = sub.add_parser("capture-archive-inventory")
    add_profile(p)
    p.set_defaults(func=cmd_capture_archive_inventory)

    p = sub.add_parser("gate")
    p.set_defaults(func=cmd_gate)

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