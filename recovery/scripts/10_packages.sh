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
import subprocess
import sys
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "10_packages.sh"
SCHEMA_NAME = "recovery.packages.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "packages",
        "verified_apt_version": "2.8.3",
        "verified_dpkg_version": "1.22.6ubuntu6.6",
        "layer": "10_native_os_package_driver_reinstall",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/10_packages",
        "generated_root": "state/generated/10_packages",
    },
    "commands": {
        "apt": "/usr/local/bin/apt",
        "apt_fallback": "/usr/bin/apt",
        "apt_get": "/usr/bin/apt-get",
        "apt_config": "/usr/bin/apt-config",
        "apt_cache": "/usr/bin/apt-cache",
        "apt_mark": "/usr/bin/apt-mark",
        "dpkg": "/usr/bin/dpkg",
        "dpkg_query": "/usr/bin/dpkg-query",
        "dpkg_deb": "/usr/bin/dpkg-deb",
        "dpkg_divert": "/usr/bin/dpkg-divert",
        "dpkg_statoverride": "/usr/bin/dpkg-statoverride",
        "uname": "/usr/bin/uname",
        "hostnamectl": "/usr/bin/hostnamectl",
        "lsb_release": "/usr/bin/lsb_release",
        "sha256sum": "/usr/bin/sha256sum",
        "gpg": "/usr/bin/gpg",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "packages_report.json",
        "reinstall_script_name": "reinstall_native_packages.review.sh",
        "restore_plan_name": "native_package_restore_plan.md",
        "no_execute": True,
        "generated_script_requires_token": True,
        "generated_script_token": "I_UNDERSTAND_THIS_REINSTALLS_NATIVE_PACKAGES",
        "generated_script_mode": "0600",
        "include_apt_lists": False,
        "include_sources_file_contents": True,
        "include_keyring_file_hashes": True,
        "include_keyring_file_copies": True,
        "include_apt_auth_file_copies": False,
        "keyring_copy_mode": "0644",
        "max_file_copy_bytes": 52428800,
        "capture_apt_update_simulation": False,
        "package_install_chunk_size": 80,
    },
    "paths": {
        "os_release": "/etc/os-release",
        "apt_sources": "/etc/apt/sources.list;/etc/apt/sources.list.d",
        "apt_keyrings": "/etc/apt/trusted.gpg;/etc/apt/trusted.gpg.d;/etc/apt/keyrings;/usr/share/keyrings",
        "apt_preferences": "/etc/apt/preferences;/etc/apt/preferences.d",
        "apt_conf": "/etc/apt/apt.conf;/etc/apt/apt.conf.d",
        "apt_auth": "/etc/apt/auth.conf;/etc/apt/auth.conf.d",
        "package_state_files": "/var/lib/dpkg/status;/var/lib/dpkg/available;/var/lib/apt/extended_states",
        "local_deb_dirs": "/var/cache/apt/archives;/var/cache/apt/archives/partial;state/local_debs",
    },
    "critical": {
        "required_packages": "apt;dpkg;systemd;coreutils;ca-certificates;cryptsetup;smartmontools;rsync;flatpak;pipx;dconf-cli",
        "optional_packages": "docker-ce;docker-ce-cli;containerd.io;docker-compose-plugin;libvirt-daemon-system;libvirt-clients;qemu-kvm;qemu-utils;virt-manager;ovmf;swtpm;swtpm-tools;ubuntu-drivers-common;dkms;linux-firmware;firmware-sof-signed;mesa-vulkan-drivers;mesa-utils;vulkan-tools;pipewire;wireplumber;alsa-utils;network-manager;gnome-disk-utility;gsmartcontrol;dconf-editor;b3sum;python3;python3-venv;python3-pip;efibootmgr;mokutil;grub-efi-amd64;shim-signed;initramfs-tools",
        "installed_package_regex": r"(?i)^(linux-|linux$|linux-image|linux-headers|linux-modules|linux-firmware|firmware|amd|amdgpu|mesa|vulkan|xserver|xorg|wayland|pipewire|wireplumber|alsa|pulseaudio|bluez|network-manager|dkms|docker|containerd|libvirt|qemu|virt|ovmf|swtpm|cryptsetup|lvm2|mdadm|smartmontools|flatpak|pipx|systemd|grub|shim|mokutil|efibootmgr|initramfs|ubuntu-drivers)",
        "policy_packages_extra": "linux-generic;linux-image-generic;ubuntu-drivers-common;build-essential;dkms;linux-firmware;mesa-vulkan-drivers;mesa-utils;vulkan-tools;docker-ce;libvirt-daemon-system;qemu-kvm;cryptsetup;smartmontools;flatpak;pipx;dconf-cli;dconf-editor;b3sum;gnome-disk-utility;gsmartcontrol",
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
    path = PROJECT_ROOT / "configs" / "10_packages.yaml"
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
    if Path(value).exists() or shutil.which(value):
        return value
    if name == "apt":
        fallback = str(cfg_get("commands.apt_fallback", "/usr/bin/apt"))
        if Path(fallback).exists() or shutil.which(fallback):
            return fallback
    return value if "/" in value else (shutil.which(value) or value)


APT = cmd_path("apt")
APT_GET = cmd_path("apt_get")
APT_CONFIG = cmd_path("apt_config")
APT_CACHE = cmd_path("apt_cache")
APT_MARK = cmd_path("apt_mark")
DPKG = cmd_path("dpkg")
DPKG_QUERY = cmd_path("dpkg_query")
DPKG_DEB = cmd_path("dpkg_deb")
DPKG_DIVERT = cmd_path("dpkg_divert")
DPKG_STATOVERRIDE = cmd_path("dpkg_statoverride")
UNAME = cmd_path("uname")
HOSTNAMECTL = cmd_path("hostnamectl")
LSB_RELEASE = cmd_path("lsb_release")
SHA256SUM = cmd_path("sha256sum")
GPG = cmd_path("gpg")


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
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/10_packages")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "10_packages.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "10_packages.config.snapshot.yaml")
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
            "name": "packages",
            "script": SCRIPT_NAME,
            "apt_path": APT,
            "dpkg_path": DPKG,
            "apt_version": None,
            "dpkg_version": None,
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
        "outputs": [],
    }


def finalize_report(report: dict[str, Any], run_dir: Path) -> int:
    report["ok"] = not report.get("failures")
    report_path = run_dir / str(cfg_get("policy.report_name", "packages_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False, env: dict[str, str] | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, env=env)
    result = {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}
    run_dir = resolve_path(report["run_dir"])
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    report["commands"].append({"argv": argv[:], "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr})
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(argv)} :: {proc.stderr.strip()}")
    return result


def require_tool(path: str, report: dict[str, Any], label: str) -> bool:
    if Path(path).exists() or shutil.which(path):
        return True
    report["failures"].append(f"{label} not found: {path}")
    return False


def capture_versions(report: dict[str, Any]) -> None:
    if require_tool(APT, report, "apt"):
        result = run_cmd([APT, "--version"], report, label="apt_version")
        report["tool"]["apt_version"] = result["stdout"].splitlines()[0] if result["stdout"].splitlines() else result["stderr"].strip()
    if require_tool(DPKG, report, "dpkg"):
        result = run_cmd([DPKG, "--version"], report, label="dpkg_version")
        first = result["stdout"].splitlines()[0] if result["stdout"].splitlines() else result["stderr"].strip()
        report["tool"]["dpkg_version"] = first


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report.setdefault("outputs", []).append(entry)


def sha256_file(path: Path) -> tuple[str | None, str | None]:
    if not path.exists() or not path.is_file():
        return None, None
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        return h.hexdigest(), None
    except (OSError, PermissionError) as exc:
        return None, str(exc)


def file_record(path: Path, base: Path | None = None) -> dict[str, Any]:
    record = {
        "path": str(path),
        "exists": path.exists(),
        "type": "missing",
    }
    if path.exists():
        record["type"] = "dir" if path.is_dir() else "file" if path.is_file() else "other"
        try:
            stat = path.stat()
            record["size_bytes"] = stat.st_size
            record["mode"] = oct(stat.st_mode & 0o777)
            record["mtime"] = datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat()
        except OSError as exc:
            record["stat_error"] = str(exc)
        if path.is_file():
            digest, error = sha256_file(path)
            if digest:
                record["sha256"] = digest
            if error:
                record["sha256_error"] = error
        if base:
            try:
                record["relative_path"] = str(path.relative_to(base))
            except ValueError:
                record["relative_path"] = rel(path)
    return record


def iter_existing_files(paths_value: Any, *, recursive: bool = True) -> tuple[list[Path], list[str]]:
    files: list[Path] = []
    missing: list[str] = []
    for item in split_semicolon(paths_value):
        path = resolve_path(item)
        if not path.exists():
            missing.append(str(path))
            continue
        if path.is_file():
            files.append(path)
        elif path.is_dir() and recursive:
            for child in sorted(path.rglob("*")):
                if child.is_file():
                    files.append(child)
    return files, missing


def copy_file_to_tree(src: Path, root_label: str, dest_root: Path, *, mode: int | None = None) -> tuple[Path | None, str | None]:
    try:
        max_bytes = int(cfg_get("policy.max_file_copy_bytes", 52428800))
        size = src.stat().st_size
        if size > max_bytes:
            return None, f"file larger than max_file_copy_bytes:{max_bytes}"
        if src.is_absolute():
            rel_part = str(src).lstrip("/")
        else:
            rel_part = str(src)
        dest = dest_root / root_label / rel_part
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dest)
        if mode is not None:
            dest.chmod(mode)
        return dest, None
    except (OSError, PermissionError) as exc:
        return None, str(exc)


def installed_packages(report: dict[str, Any] | None = None) -> list[dict[str, str]]:
    argv = [DPKG_QUERY, "-W", "-f=${binary:Package}\t${Version}\t${Architecture}\t${db:Status-Abbrev}\t${binary:Summary}\n"]
    proc = subprocess.run(argv, text=True, capture_output=True)
    if report is not None:
        run_dir = resolve_path(report["run_dir"])
        write_text(run_dir / "installed_packages_raw.tsv", proc.stdout)
    packages = []
    for line in proc.stdout.splitlines():
        parts = line.split("\t", 4)
        if len(parts) < 5:
            continue
        packages.append({"package": parts[0], "version": parts[1], "architecture": parts[2], "status_abbrev": parts[3], "summary": parts[4]})
    return packages


def package_names_installed() -> set[str]:
    return {pkg["package"].split(":")[0] for pkg in installed_packages() if pkg.get("status_abbrev", "").startswith("ii")}


def cmd_capture_os(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-os")
    report = report_base("capture-os", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    os_data: dict[str, Any] = {}

    os_release = resolve_path(str(cfg_get("paths.os_release", "/etc/os-release")))
    if os_release.exists():
        text = os_release.read_text(encoding="utf-8", errors="replace")
        write_text(run_dir / "os-release.txt", text)
        for line in text.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                os_data[key] = value.strip().strip('"')
        output_file(report, run_dir / "os-release.txt", "text", "os-release")

    for label, argv in [
        ("hostnamectl", [HOSTNAMECTL]),
        ("uname_all", [UNAME, "-a"]),
        ("uname_kernel_release", [UNAME, "-r"]),
        ("dpkg_architecture", [DPKG, "--print-architecture"]),
        ("dpkg_foreign_architectures", [DPKG, "--print-foreign-architectures"]),
        ("lsb_release", [LSB_RELEASE, "-a"]),
    ]:
        if Path(argv[0]).exists() or shutil.which(argv[0]):
            result = run_cmd(argv, report, label=label)
            if result["returncode"] != 0 and label != "lsb_release":
                report["warnings"].append(f"{label} returned nonzero: {result['stderr'].strip()}")

    report["os"] = os_data
    return finalize_report(report, run_dir)


def cmd_capture_sources(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-sources")
    report = report_base("capture-sources", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    files, missing = iter_existing_files(cfg_get("paths.apt_sources", ""))
    source_root = run_dir / "apt_sources_copy"
    manifest = {"files": [], "missing_paths": missing}
    for src in files:
        dest, copy_error = (copy_file_to_tree(src, "apt", source_root) if boolish(cfg_get("policy.include_sources_file_contents", True)) else (None, None))
        rec = file_record(src)
        if dest:
            rec["copied_to"] = rel(dest)
        if copy_error:
            rec["copy_error"] = copy_error
        manifest["files"].append(rec)
    write_json(run_dir / "apt_sources_manifest.json", manifest)
    output_file(report, run_dir / "apt_sources_manifest.json", "json", "apt_sources_manifest", {"file_count": len(files), "missing_count": len(missing)})
    if missing:
        report["warnings"].append(f"missing apt source paths: {missing}")
    return finalize_report(report, run_dir)


def cmd_capture_keyrings(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-keyrings")
    report = report_base("capture-keyrings", run_dir)
    report["mode"] = "capture"
    files, missing = iter_existing_files(cfg_get("paths.apt_keyrings", ""))
    key_root = run_dir / "apt_keyrings_copy"
    manifest = {"files": [], "missing_paths": missing}
    for src in files:
        rec = file_record(src)
        if boolish(cfg_get("policy.include_keyring_file_copies", True)):
            mode = int(str(cfg_get("policy.keyring_copy_mode", "0644")), 8)
            dest, copy_error = copy_file_to_tree(src, "keyrings", key_root, mode=mode)
            if dest:
                rec["copied_to"] = rel(dest)
            if copy_error:
                rec["copy_error"] = copy_error
        if (Path(GPG).exists() or shutil.which(GPG)) and src.is_file() and "sha256_error" not in rec:
            gpg_result = run_cmd([GPG, "--show-keys", "--with-fingerprint", str(src)], report, label=f"gpg_show_keys_{src.name}")
            rec["gpg_fingerprint_attempt_returncode"] = gpg_result["returncode"]
        manifest["files"].append(rec)
    write_json(run_dir / "apt_keyrings_manifest.json", manifest)
    output_file(report, run_dir / "apt_keyrings_manifest.json", "json", "apt_keyrings_manifest", {"file_count": len(files), "missing_count": len(missing)})
    if missing:
        report["warnings"].append(f"missing apt keyring paths: {missing}")
    return finalize_report(report, run_dir)


def cmd_capture_preferences(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-preferences")
    report = report_base("capture-preferences", run_dir)
    report["mode"] = "capture"

    non_auth_paths = ";".join([str(cfg_get("paths.apt_preferences", "")), str(cfg_get("paths.apt_conf", ""))])
    auth_paths = str(cfg_get("paths.apt_auth", ""))
    files, missing = iter_existing_files(non_auth_paths)
    auth_files, auth_missing = iter_existing_files(auth_paths)
    dest_root = run_dir / "apt_preferences_conf_copy"
    manifest = {"files": [], "auth_files": [], "missing_paths": missing, "missing_auth_paths": auth_missing}

    for src in files:
        dest, copy_error = copy_file_to_tree(src, "apt", dest_root)
        rec = file_record(src)
        if dest:
            rec["copied_to"] = rel(dest)
        if copy_error:
            rec["copy_error"] = copy_error
        manifest["files"].append(rec)

    copy_auth = boolish(cfg_get("policy.include_apt_auth_file_copies", False))
    for src in auth_files:
        rec = file_record(src)
        rec["sensitive_note"] = "APT auth file may contain credentials; content copy disabled by default"
        if copy_auth:
            dest, copy_error = copy_file_to_tree(src, "apt_auth_sensitive", dest_root, mode=0o600)
            if dest:
                rec["copied_to"] = rel(dest)
                rec["sensitive_copy"] = True
            if copy_error:
                rec["copy_error"] = copy_error
        else:
            rec["copy_skipped"] = "include_apt_auth_file_copies is false"
        manifest["auth_files"].append(rec)

    write_json(run_dir / "apt_preferences_conf_manifest.json", manifest)
    output_file(report, run_dir / "apt_preferences_conf_manifest.json", "json", "apt_preferences_conf_manifest", {"file_count": len(files), "auth_file_count": len(auth_files), "missing_count": len(missing) + len(auth_missing)})
    if missing:
        report["warnings"].append(f"missing apt preference/conf paths: {missing}")
    if auth_missing:
        report["warnings"].append(f"missing apt auth paths: {auth_missing}")
    if auth_files and not copy_auth:
        report["warnings"].append("APT auth files were identified but not copied by default; Borg/encrypted file backup owns secret file payload recovery")
    return finalize_report(report, run_dir)

def cmd_capture_policy(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-policy")
    report = report_base("capture-policy", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    for label, argv in [
        ("apt_cache_policy_all", [APT_CACHE, "policy"]),
        ("apt_config_dump", [APT_CONFIG, "dump"]),
    ]:
        if Path(argv[0]).exists() or shutil.which(argv[0]):
            result = run_cmd(argv, report, label=label)
            if result["returncode"] != 0:
                report["warnings"].append(f"{label} returned nonzero: {result['stderr'].strip()}")
    policy_packages = sorted(set(split_semicolon(cfg_get("critical.required_packages", "")) + split_semicolon(cfg_get("critical.optional_packages", "")) + split_semicolon(cfg_get("critical.policy_packages_extra", ""))))
    if policy_packages:
        result = run_cmd([APT_CACHE, "policy", *policy_packages], report, label="apt_cache_policy_critical")
        if result["returncode"] != 0:
            report["warnings"].append("apt-cache policy for critical package list returned nonzero")
    return finalize_report(report, run_dir)


def cmd_capture_dpkg(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-dpkg")
    report = report_base("capture-dpkg", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    packages = installed_packages(report)
    write_json(run_dir / "dpkg_installed_packages.json", {"packages": packages, "count": len(packages)})
    output_file(report, run_dir / "dpkg_installed_packages.json", "json", "dpkg_installed_packages", {"package_count": len(packages)})

    for label, argv in [
        ("dpkg_list", [DPKG, "-l"]),
        ("dpkg_audit", [DPKG, "--audit"]),
        ("dpkg_get_selections", [DPKG, "--get-selections"]),
    ]:
        result = run_cmd(argv, report, label=label)
        if result["returncode"] != 0 and label == "dpkg_audit":
            report["warnings"].append(f"{label} returned nonzero: {result['stderr'].strip()}")

    if Path(DPKG_DIVERT).exists() or shutil.which(DPKG_DIVERT):
        run_cmd([DPKG_DIVERT, "--list"], report, label="dpkg_divert_list")
    else:
        report["warnings"].append(f"dpkg-divert command not found: {DPKG_DIVERT}")
    if Path(DPKG_STATOVERRIDE).exists() or shutil.which(DPKG_STATOVERRIDE):
        run_cmd([DPKG_STATOVERRIDE, "--list"], report, label="dpkg_statoverride_list")
    else:
        report["warnings"].append(f"dpkg-statoverride command not found: {DPKG_STATOVERRIDE}")

    files, missing = iter_existing_files(cfg_get("paths.package_state_files", ""), recursive=False)
    state_root = run_dir / "package_state_files_copy"
    state_manifest = {"files": [], "missing_paths": missing}
    for src in files:
        dest, copy_error = copy_file_to_tree(src, "package_state", state_root, mode=0o600)
        rec = file_record(src)
        if dest:
            rec["copied_to"] = rel(dest)
        if copy_error:
            rec["copy_error"] = copy_error
        state_manifest["files"].append(rec)
    write_json(run_dir / "package_state_files_manifest.json", state_manifest)
    output_file(report, run_dir / "package_state_files_manifest.json", "json", "package_state_files_manifest", {"file_count": len(files), "missing_count": len(missing)})
    if missing:
        report["warnings"].append(f"missing package state paths: {missing}")
    return finalize_report(report, run_dir)

def cmd_capture_manual_auto_holds(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-manual-auto-holds")
    report = report_base("capture-manual-auto-holds", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    data = {}
    for label, argv in [
        ("manual", [APT_MARK, "showmanual"]),
        ("auto", [APT_MARK, "showauto"]),
        ("holds", [APT_MARK, "showhold"]),
    ]:
        result = run_cmd(argv, report, label=f"apt_mark_{label}")
        values = sorted([line.strip() for line in result["stdout"].splitlines() if line.strip()])
        data[label] = values
        write_text(run_dir / f"apt_mark_{label}.txt", "\n".join(values) + ("\n" if values else ""))
    write_json(run_dir / "apt_mark_manual_auto_holds.json", data)
    output_file(report, run_dir / "apt_mark_manual_auto_holds.json", "json", "apt_mark_manual_auto_holds", {k + "_count": len(v) for k, v in data.items()})
    return finalize_report(report, run_dir)


def cmd_capture_selections(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-selections")
    report = report_base("capture-selections", run_dir)
    report["mode"] = "capture"
    result = run_cmd([DPKG, "--get-selections"], report, label="dpkg_get_selections", check=True)
    selections_path = run_dir / "dpkg_selections.txt"
    write_text(selections_path, result["stdout"])
    output_file(report, selections_path, "text", "dpkg_selections", {"line_count": len(result["stdout"].splitlines())})
    return finalize_report(report, run_dir)


def critical_package_names() -> tuple[list[str], list[str]]:
    return split_semicolon(cfg_get("critical.required_packages", "")), split_semicolon(cfg_get("critical.optional_packages", ""))


def discover_critical_installed(packages: list[dict[str, str]]) -> list[dict[str, str]]:
    regex = re.compile(str(cfg_get("critical.installed_package_regex", "")))
    selected = []
    for pkg in packages:
        name = pkg["package"].split(":")[0]
        if regex.search(name):
            selected.append(pkg)
    return selected


def cmd_capture_critical(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-critical")
    report = report_base("capture-critical", run_dir)
    report["mode"] = "capture"
    capture_versions(report)
    packages = installed_packages()
    required, optional = critical_package_names()
    installed = package_names_installed()
    discovered = discover_critical_installed(packages)
    critical = {
        "required_packages": required,
        "optional_packages": optional,
        "required_present": sorted([p for p in required if p in installed]),
        "required_missing": sorted([p for p in required if p not in installed]),
        "optional_present": sorted([p for p in optional if p in installed]),
        "optional_missing": sorted([p for p in optional if p not in installed]),
        "discovered_kernel_driver_firmware_packages": discovered,
    }
    write_json(run_dir / "critical_packages.json", critical)
    output_file(report, run_dir / "critical_packages.json", "json", "critical_packages", {"discovered_count": len(discovered), "required_missing_count": len(critical["required_missing"])})
    if critical["required_missing"]:
        report["failures"].append(f"required critical packages are missing: {critical['required_missing']}")
    if critical["optional_missing"]:
        report["warnings"].append(f"optional critical packages not installed: {critical['optional_missing']}")
    names = sorted({pkg["package"].split(":")[0] for pkg in discovered} | set(required) | set(optional))
    if names:
        run_cmd([APT_CACHE, "policy", *names], report, label="apt_cache_policy_discovered_critical")
    return finalize_report(report, run_dir)


def deb_metadata(path: Path) -> dict[str, Any]:
    rec = file_record(path)
    if Path(DPKG_DEB).exists() or shutil.which(DPKG_DEB):
        for field in ("Package", "Version", "Architecture"):
            proc = subprocess.run([DPKG_DEB, "-f", str(path), field], text=True, capture_output=True)
            if proc.returncode == 0:
                rec[field.lower()] = proc.stdout.strip()
    return rec


def cmd_build_local_deb_manifest(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("build-local-deb-manifest")
    report = report_base("build-local-deb-manifest", run_dir)
    report["mode"] = "capture"
    files = []
    missing = []
    for item in split_semicolon(cfg_get("paths.local_deb_dirs", "")):
        root = resolve_path(item)
        if not root.exists():
            missing.append(str(root))
            continue
        for deb in sorted(root.rglob("*.deb")):
            if deb.is_file():
                files.append(deb)
    manifest = {"deb_files": [deb_metadata(p) for p in files], "missing_paths": missing, "count": len(files)}
    write_json(run_dir / "local_deb_manifest.json", manifest)
    output_file(report, run_dir / "local_deb_manifest.json", "json", "local_deb_manifest", {"deb_count": len(files), "missing_count": len(missing)})
    if not files:
        report["warnings"].append("no local .deb files found in configured local_deb_dirs")
    return finalize_report(report, run_dir)


def local_deb_index() -> dict[str, list[dict[str, Any]]]:
    index: dict[str, list[dict[str, Any]]] = {}
    for item in split_semicolon(cfg_get("paths.local_deb_dirs", "")):
        root = resolve_path(item)
        if not root.exists():
            continue
        for deb in sorted(root.rglob("*.deb")):
            if not deb.is_file():
                continue
            rec = deb_metadata(deb)
            name = str(rec.get("package", "") or "")
            if name:
                index.setdefault(name, []).append(rec)
    return index


def cmd_verify_critical_debs(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-critical-debs")
    report = report_base("verify-critical-debs", run_dir)
    report["mode"] = "verify"
    capture_versions(report)
    required, optional = critical_package_names()
    installed = package_names_installed()
    deb_index = local_deb_index()
    result = {"required": {}, "optional": {}, "local_deb_index_package_count": len(deb_index)}
    for group_name, names in [("required", required), ("optional", optional)]:
        for name in names:
            policy = run_cmd([APT_CACHE, "policy", name], report, label=f"apt_policy_{name}")
            installed_here = name in installed
            has_candidate = bool(re.search(r"Candidate:\s+(?!\\(none\\))\S+", policy["stdout"]))
            local_debs = deb_index.get(name, [])
            result[group_name][name] = {
                "installed": installed_here,
                "apt_policy_candidate_available": has_candidate,
                "local_deb_files_present": bool(local_debs),
                "local_deb_file_count": len(local_debs),
                "policy_returncode": policy["returncode"],
            }
            if group_name == "required" and not installed_here:
                report["failures"].append(f"required package is not installed: {name}")
            elif group_name == "optional" and not installed_here:
                report["warnings"].append(f"optional package is not installed: {name}")
            if installed_here and not has_candidate:
                report["warnings"].append(f"installed package has no apt-cache candidate in current sources: {name}")
            if installed_here and not local_debs:
                report["warnings"].append(f"installed critical package has no local .deb coverage in configured dirs: {name}")
    write_json(run_dir / "critical_deb_verification.json", result)
    output_file(report, run_dir / "critical_deb_verification.json", "json", "critical_deb_verification")
    return finalize_report(report, run_dir)

def current_manifest_bundle(run_dir: Path, report: dict[str, Any]) -> dict[str, Any]:
    # Fresh read-only captures used by restore-plan and reinstall-script.
    packages = installed_packages()
    manual = subprocess.run([APT_MARK, "showmanual"], text=True, capture_output=True).stdout.splitlines() if Path(APT_MARK).exists() else []
    auto = subprocess.run([APT_MARK, "showauto"], text=True, capture_output=True).stdout.splitlines() if Path(APT_MARK).exists() else []
    holds = subprocess.run([APT_MARK, "showhold"], text=True, capture_output=True).stdout.splitlines() if Path(APT_MARK).exists() else []
    arch = subprocess.run([DPKG, "--print-architecture"], text=True, capture_output=True).stdout.strip() if Path(DPKG).exists() else ""
    foreign = subprocess.run([DPKG, "--print-foreign-architectures"], text=True, capture_output=True).stdout.splitlines() if Path(DPKG).exists() else []
    required, optional = critical_package_names()
    discovered = discover_critical_installed(packages)
    bundle = {
        "generated_at": iso_now(),
        "architecture": arch,
        "foreign_architectures": [x.strip() for x in foreign if x.strip()],
        "manual_packages": sorted([x.strip() for x in manual if x.strip()]),
        "auto_packages": sorted([x.strip() for x in auto if x.strip()]),
        "held_packages": sorted([x.strip() for x in holds if x.strip()]),
        "installed_package_count": len(packages),
        "critical_required": required,
        "critical_optional": optional,
        "driver_kernel_firmware_discovered": discovered,
    }
    write_json(run_dir / "restore_input_package_bundle.json", bundle)
    output_file(report, run_dir / "restore_input_package_bundle.json", "json", "restore_input_package_bundle")
    return bundle


def chunked(items: list[str], size: int) -> list[list[str]]:
    return [items[i:i+size] for i in range(0, len(items), size)]


def restore_plan_markdown(bundle: dict[str, Any]) -> str:
    manual = bundle["manual_packages"]
    holds = bundle["held_packages"]
    auto = bundle.get("auto_packages", [])
    foreign = bundle["foreign_architectures"]
    critical = sorted(set(bundle["critical_required"] + [p["package"].split(":")[0] for p in bundle["driver_kernel_firmware_discovered"]]))
    lines = [
        "# Native package restore plan",
        "",
        "## Authority",
        "",
        "This plan restores native apt/dpkg package-manager state. It does not restore Flatpak, pipx, Docker workloads, user files, databases, or desktop settings.",
        "",
        "## Source restoration order",
        "",
        "1. Restore `/etc/apt/sources.list`, `/etc/apt/sources.list.d`, keyrings, apt preferences, and apt config from captured Row 10 artifacts.",
        "2. Re-add foreign architectures before `apt update`.",
        "3. Run `sudo apt update`.",
        "4. Install critical native packages first.",
        "5. Install manual packages in chunks.",
        "6. Reapply captured auto-package markers after installation review.",
        "7. Reapply holds.",
        "8. Run `sudo apt -f install` and `sudo dpkg --audit`.",
        "9. Review driver/kernel/firmware packages against the captured critical package manifest.",
        "",
        "## Foreign architectures",
        "",
    ]
    lines.extend([f"- `{arch}`" for arch in foreign] or ["- none captured"])
    lines += ["", "## Critical packages", ""]
    lines.extend([f"- `{name}`" for name in critical[:200]] or ["- none captured"])
    lines += ["", "## Held packages", ""]
    lines.extend([f"- `{name}`" for name in holds] or ["- none captured"])
    lines += ["", "## Manual package count", "", f"`{len(manual)}` manual packages captured.", ""]
    lines += ["", "## Auto package count", "", f"`{len(auto)}` auto packages captured for marker restoration review.", ""]
    return "\n".join(lines) + "\n"


def cmd_restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-plan")
    report = report_base("restore-plan", run_dir)
    report["mode"] = "plan"
    bundle = current_manifest_bundle(run_dir, report)
    plan = restore_plan_markdown(bundle)
    plan_path = run_dir / str(cfg_get("policy.restore_plan_name", "native_package_restore_plan.md"))
    write_text(plan_path, plan)
    output_file(report, plan_path, "markdown", "native_package_restore_plan")
    report["restore_plan"] = {"path": rel(plan_path), "manual_package_count": len(bundle["manual_packages"])}
    return finalize_report(report, run_dir)


def reinstall_script_text(bundle: dict[str, Any]) -> str:
    manual = bundle["manual_packages"]
    holds = bundle["held_packages"]
    auto = bundle.get("auto_packages", [])
    foreign = bundle["foreign_architectures"]
    chunk_size = int(cfg_get("policy.package_install_chunk_size", 80))
    token = str(cfg_get("policy.generated_script_token", "I_UNDERSTAND_THIS_REINSTALLS_NATIVE_PACKAGES"))
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Generated by Row 10 packages. Review before running on a restored system.",
        "# This script restores apt/dpkg package-manager state only.",
        "",
        f'REQUIRED_CONFIRMATION="{token}"',
        'if [[ "${CONFIRM_NATIVE_PACKAGE_REINSTALL:-}" != "$REQUIRED_CONFIRMATION" ]]; then',
        '  echo "Refusing to run. Set CONFIRM_NATIVE_PACKAGE_REINSTALL=$REQUIRED_CONFIRMATION after review." >&2',
        "  exit 2",
        "fi",
        "",
        "sudo -v",
    ]
    for arch in foreign:
        lines.append("sudo dpkg --add-architecture " + shlex.quote(arch))
    lines += ["sudo apt update", ""]
    # Critical first.
    critical_names = sorted(set(bundle["critical_required"]))
    if critical_names:
        lines.append("# Critical required packages")
        for chunk in chunked(critical_names, chunk_size):
            lines.append("sudo apt install -y " + " ".join(shlex.quote(x) for x in chunk))
        lines.append("")
    lines.append("# Manual packages")
    for chunk in chunked(manual, chunk_size):
        lines.append("sudo apt install -y " + " ".join(shlex.quote(x) for x in chunk))
    if auto:
        lines += ["", "# Reapply captured auto-package markers after manual-package installation"]
        for chunk in chunked(auto, chunk_size):
            lines.append("sudo apt-mark auto " + " ".join(shlex.quote(x) for x in chunk))
    if holds:
        lines += ["", "# Reapply holds"]
        for name in holds:
            lines.append("sudo apt-mark hold " + shlex.quote(name))
    lines += ["", "sudo apt -f install -y", "sudo dpkg --audit", ""]
    return "\n".join(lines)


def cmd_generate_reinstall_script(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-reinstall-script")
    report = report_base("generate-reinstall-script", run_dir)
    report["mode"] = "plan"
    bundle = current_manifest_bundle(run_dir, report)
    script_text = reinstall_script_text(bundle)
    script_path = run_dir / str(cfg_get("policy.reinstall_script_name", "reinstall_native_packages.review.sh"))
    write_text(script_path, script_text)
    try:
        script_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    except OSError as exc:
        report["warnings"].append(f"could not chmod generated reinstall script: {exc}")
    output_file(
        report,
        script_path,
        "shell",
        "native_package_reinstall_script",
        {
            "manual_package_count": len(bundle["manual_packages"]),
            "mode": oct(script_path.stat().st_mode & 0o777) if script_path.exists() else None,
        },
    )
    report["restore_plan"] = {"script": rel(script_path), "execute_guard": "CONFIRM_NATIVE_PACKAGE_REINSTALL"}
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=f"scripts/{SCRIPT_NAME}")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("capture-os"); p.set_defaults(func=cmd_capture_os)
    p = sub.add_parser("capture-sources"); p.set_defaults(func=cmd_capture_sources)
    p = sub.add_parser("capture-keyrings"); p.set_defaults(func=cmd_capture_keyrings)
    p = sub.add_parser("capture-preferences"); p.set_defaults(func=cmd_capture_preferences)
    p = sub.add_parser("capture-policy"); p.set_defaults(func=cmd_capture_policy)
    p = sub.add_parser("capture-dpkg"); p.set_defaults(func=cmd_capture_dpkg)
    p = sub.add_parser("capture-manual-auto-holds"); p.set_defaults(func=cmd_capture_manual_auto_holds)
    p = sub.add_parser("capture-selections"); p.set_defaults(func=cmd_capture_selections)
    p = sub.add_parser("capture-critical"); p.set_defaults(func=cmd_capture_critical)
    p = sub.add_parser("build-local-deb-manifest"); p.set_defaults(func=cmd_build_local_deb_manifest)
    p = sub.add_parser("verify-critical-debs"); p.set_defaults(func=cmd_verify_critical_debs)
    p = sub.add_parser("restore-plan"); p.set_defaults(func=cmd_restore_plan)
    p = sub.add_parser("generate-reinstall-script"); p.set_defaults(func=cmd_generate_reinstall_script)
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