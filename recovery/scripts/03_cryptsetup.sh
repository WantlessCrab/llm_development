#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PY'
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "03_cryptsetup.sh"
SCHEMA_NAME = "recovery.cryptsetup.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "cryptsetup",
        "verified_cryptsetup_version": "2.7.0",
        "verified_gnome_disks_version": "46.0",
        "layer": "03_encrypted_backup_vault",
    },
    "project": {
        "output_root": "state/dry_runs/03_cryptsetup",
        "local_test_root": "state/local_test/03_cryptsetup",
    },
    "commands": {
        "cryptsetup": "/usr/sbin/cryptsetup",
        "lsblk": "/usr/bin/lsblk",
        "blkid": "/usr/sbin/blkid",
        "findmnt": "/usr/bin/findmnt",
        "mount": "/usr/bin/mount",
        "umount": "/usr/bin/umount",
        "losetup": "/usr/sbin/losetup",
        "truncate": "/usr/bin/truncate",
        "mkfs_ext4": "/usr/sbin/mkfs.ext4",
        "sha256sum": "/usr/bin/sha256sum",
        "tar": "/usr/bin/tar",
    },
    "safety": {
        "confirmation_prefix": "FORMAT_LUKS2",
        "secret_directory_mode": "0700",
        "secret_file_mode": "0600",
    },
    "vault": {
        "mapper_name": "wantless_recovery_vault",
        "mountpoint": "/mnt/wantless_recovery",
        "luks_label": "wantless-recovery-luks",
        "filesystem_label": "wantless-recovery",
        "filesystem_type": "ext4",
        "allow_whole_disk_luks": True,
        "require_target_unmounted": True,
        "require_no_children_mounted": True,
        "require_luks2": True,
        "cryptsetup_format_args": "--type luks2 --pbkdf argon2id --cipher aes-xts-plain64 --key-size 512 --hash sha512",
        "filesystem_mkfs_args": "-F -m 0",
    },
    "backup_hdd": {
        "expected_model_regex": "IronWolf|ST24000|Seagate",
        "min_capacity_bytes": 23000000000000,
        "allowed_transports": "usb;sata;scsi;sat",
        "require_non_root": True,
        "require_not_rescuezilla_usb": True,
        "require_not_restore_target": True,
    },
    "rescuezilla_usb_guard": {
        "max_size_bytes": 256000000000,
        "suspicious_fstype_regex": "iso9660|udf",
        "suspicious_label_regex": "rescuezilla|clonezilla|ubuntu|ventoy|live",
    },
    "restore_target_guard": {
        "protected_paths": "",
        "protected_model_regex": "",
    },
    "header_backup": {
        "directory": "state/secrets/cryptsetup/header_backups",
        "filename_template": "luks_header_{device_slug}_{uuid}_{timestamp}.img",
        "checksum_template": "{header_filename}.sha256",
    },
    "metadata": {
        "directory": "state/dry_runs/03_cryptsetup/metadata",
    },
    "emergency_packet": {
        "directory": "state/secrets/cryptsetup/emergency_packets",
        "filename_template": "cryptsetup_emergency_packet_{timestamp}.tar.gz",
        "include_header_backup": True,
        "include_metadata": True,
        "include_config_snapshot": True,
        "include_readme": True,
    },
    "local_test": {
        "image_path": "state/local_test/03_cryptsetup/test_vault.img",
        "key_file": "state/local_test/03_cryptsetup/test_vault.key",
        "size_bytes": 268435456,
        "mapper_name": "wantless_recovery_test_vault",
        "mountpoint": "state/local_test/03_cryptsetup/mount",
        "luks_label": "wantless-test-luks",
        "filesystem_label": "wantless-test-vault",
    },
}


def print_usage() -> None:
    print(
        f"""Usage:
  scripts/{SCRIPT_NAME} discover-target [--target-device PATH]
  scripts/{SCRIPT_NAME} assert-not-root --target-device PATH
  scripts/{SCRIPT_NAME} assert-not-rescuezilla-usb --target-device PATH
  scripts/{SCRIPT_NAME} assert-not-restore-target --target-device PATH
  scripts/{SCRIPT_NAME} assert-backup-hdd [--target-device PATH]
  scripts/{SCRIPT_NAME} prepare-luks2-vault --target-device PATH --confirm-token FORMAT_LUKS2:PATH
  scripts/{SCRIPT_NAME} open --target-device PATH [--key-file PATH]
  scripts/{SCRIPT_NAME} close
  scripts/{SCRIPT_NAME} export-metadata --target-device PATH
  scripts/{SCRIPT_NAME} backup-header --target-device PATH
  scripts/{SCRIPT_NAME} verify-header --header-file PATH
  scripts/{SCRIPT_NAME} build-emergency-packet [--header-file PATH] [--metadata-file PATH]
  scripts/{SCRIPT_NAME} verify-emergency-packet --packet PATH
  scripts/{SCRIPT_NAME} smoke-open-close --target-device PATH
  scripts/{SCRIPT_NAME} gate [--target-device PATH]

Local loopback test mode:
  scripts/{SCRIPT_NAME} prepare-test-vault --i-understand-local-loopback-test
  scripts/{SCRIPT_NAME} open-test-vault
  scripts/{SCRIPT_NAME} close-test-vault
  scripts/{SCRIPT_NAME} destroy-test-vault --i-understand-destroy-local-test-vault

Critical safety:
  prepare-luks2-vault is destructive and requires an explicit target plus exact confirmation token.
  Local test mode operates only under state/local_test/03_cryptsetup by default.
""",
        end="",
    )


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
            raise SystemExit(f"{path}: list-item YAML is unsupported. Use scalar/semicolon strings.")
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
    path = PROJECT_ROOT / "configs" / "03_cryptsetup.yaml"
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


def cmd_path(name: str) -> str:
    value = str(cfg_get(f"commands.{name}", name))
    if "/" in value:
        return value
    return shutil.which(value) or value


CRYPTSETUP = cmd_path("cryptsetup")
LSBLK = cmd_path("lsblk")
BLKID = cmd_path("blkid")
FINDMNT = cmd_path("findmnt")
MOUNT = cmd_path("mount")
UMOUNT = cmd_path("umount")
LOSETUP = cmd_path("losetup")
TRUNCATE = cmd_path("truncate")
MKFS_EXT4 = cmd_path("mkfs_ext4")
SHA256SUM = cmd_path("sha256sum")


def now_stamp() -> str:
    return datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")


def iso_now() -> str:
    return datetime.now().astimezone().isoformat()


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def resolve_path(value: str | Path) -> Path:
    p = Path(str(value)).expanduser()
    if not p.is_absolute():
        p = PROJECT_ROOT / p
    return p.resolve()


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/03_cryptsetup")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def build_argv(argv: list[str], *, sudo: bool = False) -> tuple[list[str], str | None]:
    final_argv = argv[:]
    if sudo and os.geteuid() != 0:
        if shutil.which("sudo"):
            final_argv = ["sudo"] + final_argv
        else:
            return argv, "sudo is required but not available"
    return final_argv, None


def run_cmd(argv: list[str], *, sudo: bool = False, input_text: str | None = None) -> dict[str, Any]:
    final_argv, error = build_argv(argv, sudo=sudo)
    if error:
        return {"argv": argv, "returncode": 127, "stdout": "", "stderr": error}
    proc = subprocess.run(final_argv, text=True, input=input_text, capture_output=True)
    return {"argv": final_argv, "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}


def run_interactive_cmd(argv: list[str], *, sudo: bool = False) -> dict[str, Any]:
    final_argv, error = build_argv(argv, sudo=sudo)
    if error:
        return {"argv": argv, "returncode": 127, "stdout": "", "stderr": error}

    try:
        with open("/dev/tty", "rb", buffering=0) as tty_in, \
             open("/dev/tty", "wb", buffering=0) as tty_out:
            proc = subprocess.run(
                final_argv,
                stdin=tty_in,
                stdout=tty_out,
                stderr=tty_out,
            )
    except OSError as exc:
        return {
            "argv": final_argv,
            "returncode": 127,
            "stdout": "",
            "stderr": f"interactive command requires a controlling TTY: {exc}",
        }

    return {
        "argv": final_argv,
        "returncode": proc.returncode,
        "stdout": "",
        "stderr": "interactive command; stdin/stdout/stderr attached to /dev/tty",
    }


def scrub_command(result: dict[str, Any], stdout_path: str | None = None) -> dict[str, Any]:
    payload = {"argv": [str(x) for x in result.get("argv", [])], "returncode": int(result.get("returncode", 0)), "stderr": result.get("stderr", "")}
    if stdout_path:
        payload["stdout_path"] = stdout_path
    return payload


def parse_json_stdout(result: dict[str, Any]) -> dict[str, Any] | None:
    try:
        return json.loads(result.get("stdout") or "")
    except json.JSONDecodeError:
        return None


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {"name": "cryptsetup", "script": SCRIPT_NAME},
        "command": command,
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": True,
        "failures": [],
        "warnings": [],
    }


def split_semicolon(value: str | None) -> list[str]:
    return [part.strip() for part in str(value or "").split(";") if part.strip()]


def canonical_device_path(value: str | Path | None) -> str | None:
    if value in (None, ""):
        return None
    text = str(value)
    if not text.startswith("/dev/"):
        return text
    try:
        return str(Path(text).resolve())
    except OSError:
        return text


def get_lsblk(target: str | None = None) -> dict[str, Any]:
    argv = [LSBLK, "-J", "-b", "-O", "-e7"]
    if target:
        argv.append(str(target))
    result = run_cmd(argv)
    parsed = parse_json_stdout(result)
    if parsed is None:
        return {"blockdevices": [], "_command_error": result}
    parsed["_command"] = result
    return parsed


def flatten_blockdevices(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for node in nodes:
        out.append(node)
        children = node.get("children") or []
        if isinstance(children, list):
            out.extend(flatten_blockdevices(children))
    return out


def has_mount(node: dict[str, Any], mountpoint: str) -> bool:
    if node.get("mountpoint") == mountpoint:
        return True
    mounts = node.get("mountpoints")
    return isinstance(mounts, list) and mountpoint in mounts


def root_disk_from_lsblk(payload: dict[str, Any]) -> str | None:
    def walk(nodes: list[dict[str, Any]], disk_path: str | None = None) -> str | None:
        for node in nodes:
            node_type = str(node.get("type") or "")
            node_path = str(node.get("path") or "")
            current_disk = node_path if node_type == "disk" and node_path else disk_path
            if has_mount(node, "/"):
                return current_disk
            child = walk(node.get("children") or [], current_disk)
            if child:
                return child
        return None
    return walk(payload.get("blockdevices", []) or [])


def blockdevice_by_path(payload: dict[str, Any], wanted: str) -> dict[str, Any] | None:
    wanted_canon = canonical_device_path(wanted)
    for node in flatten_blockdevices(payload.get("blockdevices", []) or []):
        path = str(node.get("path") or "")
        if path == wanted or canonical_device_path(path) == wanted_canon:
            return node
    return None


def parent_disk_for_path(payload: dict[str, Any], wanted: str) -> str | None:
    wanted_canon = canonical_device_path(wanted)
    parent: str | None = None

    def walk(nodes: list[dict[str, Any]], current_disk: str | None = None) -> None:
        nonlocal parent
        for node in nodes:
            path = str(node.get("path") or "")
            node_type = str(node.get("type") or "")
            next_disk = path if node_type == "disk" and path else current_disk
            if path == wanted or canonical_device_path(path) == wanted_canon:
                parent = next_disk
                return
            walk(node.get("children") or [], next_disk)

    walk(payload.get("blockdevices", []) or [])
    return parent


def target_info(target: str) -> dict[str, Any]:
    payload = get_lsblk()
    node = blockdevice_by_path(payload, target)
    parent_disk = parent_disk_for_path(payload, target)
    children = []
    if node and isinstance(node.get("children"), list):
        children = node["children"]
    return {
        "requested": target,
        "canonical": canonical_device_path(target),
        "exists": Path(target).exists() or node is not None,
        "node": node,
        "parent_disk": parent_disk,
        "root_disk": root_disk_from_lsblk(payload),
        "children": children,
        "lsblk": payload,
    }


def is_root_or_child(target: str) -> bool:
    info = target_info(target)
    root_disk = canonical_device_path(info.get("root_disk"))
    target_canon = canonical_device_path(target)
    parent_canon = canonical_device_path(info.get("parent_disk"))
    return target_canon == root_disk or parent_canon == root_disk


def mounted_paths_for_node(node: dict[str, Any]) -> list[str]:
    mounts: list[str] = []
    mountpoint = node.get("mountpoint")
    if mountpoint:
        mounts.append(str(mountpoint))
    mountpoints = node.get("mountpoints")
    if isinstance(mountpoints, list):
        mounts.extend(str(x) for x in mountpoints if x)
    for child in node.get("children") or []:
        mounts.extend(mounted_paths_for_node(child))
    return sorted(set(mounts))


def evaluate_backup_hdd(target: str) -> tuple[list[str], list[str], dict[str, Any]]:
    failures: list[str] = []
    warnings: list[str] = []
    info = target_info(target)
    node = info.get("node") or {}
    if not info["exists"]:
        failures.append(f"Target device does not exist or is not visible in lsblk: {target}")
        return failures, warnings, info

    if is_root_or_child(target):
        failures.append(f"Target is the current root/source disk or a child of it: {target}")

    if str(node.get("type") or "") not in {"disk", "part"}:
        failures.append(f"Target must be a disk or partition, got type {node.get('type')!r}")

    size = int(node.get("size") or 0)
    min_size = int(cfg_get("backup_hdd.min_capacity_bytes", 23000000000000))
    if size < min_size:
        failures.append(f"Target size {size} is below backup HDD minimum {min_size}")

    model = str(node.get("model") or "")
    expected_model = str(cfg_get("backup_hdd.expected_model_regex", "") or "")
    if expected_model and not re.search(expected_model, model, re.IGNORECASE):
        failures.append(f"Target model {model!r} does not match expected {expected_model!r}")

    allowed = {x.lower() for x in split_semicolon(str(cfg_get("backup_hdd.allowed_transports", "")))}
    transport = str(node.get("tran") or "").lower()
    if allowed and transport and transport not in allowed:
        failures.append(f"Target transport {transport!r} is not in allowed transports {sorted(allowed)}")
    elif allowed and not transport:
        warnings.append("Target transport was not reported by lsblk")

    if bool(cfg_get("vault.require_target_unmounted", True)):
        mounts = mounted_paths_for_node(node)
        if mounts:
            failures.append(f"Target or children are mounted: {mounts}")

    return failures, warnings, info


def discover_target_candidate() -> dict[str, Any] | None:
    payload = get_lsblk()
    root_disk = canonical_device_path(root_disk_from_lsblk(payload))
    expected = str(cfg_get("backup_hdd.expected_model_regex", "") or "")
    min_size = int(cfg_get("backup_hdd.min_capacity_bytes", 23000000000000))
    candidates = []
    for node in flatten_blockdevices(payload.get("blockdevices", []) or []):
        if str(node.get("type") or "") != "disk":
            continue
        path = str(node.get("path") or "")
        if not path or canonical_device_path(path) == root_disk:
            continue
        size = int(node.get("size") or 0)
        model = str(node.get("model") or "")
        model_ok = bool(re.search(expected, model, re.IGNORECASE)) if expected else True
        size_ok = size >= min_size
        if model_ok or size_ok:
            candidates.append({"path": path, "size": size, "model": model, "node": node, "model_ok": model_ok, "size_ok": size_ok})
    candidates.sort(key=lambda item: (item["model_ok"], item["size_ok"], item["size"]), reverse=True)
    return candidates[0] if candidates else None


def luks_uuid(target: str) -> str | None:
    result = run_cmd([BLKID, "-s", "UUID", "-o", "value", str(target)], sudo=True)
    if result["returncode"] == 0:
        value = result["stdout"].strip()
        return value or None
    return None


def is_luks(target: str) -> bool:
    result = run_cmd([CRYPTSETUP, "isLuks", str(target)], sudo=True)
    return result["returncode"] == 0


def mapper_path(mapper_name: str) -> Path:
    return Path("/dev/mapper") / mapper_name


def ensure_mountpoint(path: Path) -> dict[str, Any]:
    try:
        path.mkdir(parents=True, exist_ok=True)
        return {"argv": ["python-mkdir", str(path)], "returncode": 0, "stdout": "", "stderr": ""}
    except PermissionError:
        return run_cmd(["/usr/bin/install", "-d", "-m", "0755", str(path)], sudo=True)


def require_confirmation(flag_present: bool, message: str) -> None:
    if not flag_present:
        raise SystemExit(message)


def octal_mode_from_config(path: str, default: int) -> int:
    raw = str(cfg_get(path, "") or "")
    try:
        return int(raw, 8)
    except ValueError:
        return default


def chmod_private(path: Path, *, directory: bool = False) -> None:
    mode = octal_mode_from_config("safety.secret_directory_mode" if directory else "safety.secret_file_mode", 0o700 if directory else 0o600)
    try:
        os.chmod(path, mode)
    except PermissionError:
        run_cmd(["/usr/bin/chmod", oct(mode)[2:], str(path)], sudo=True)


def ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    chmod_private(path, directory=True)


def cmd_discover_target(opts: dict[str, str]) -> int:
    run_dir = make_run_dir("discover-target")
    report = report_base("discover-target", run_dir)
    target = opts.get("target_device")
    if target:
        failures, warnings, info = evaluate_backup_hdd(target)
        report["target"] = info
        report["failures"] = failures
        report["warnings"] = warnings
    else:
        candidate = discover_target_candidate()
        report["target"] = candidate
        if candidate is None:
            report["warnings"].append("No backup HDD candidate found. Attach IronWolf/NexStar target or pass --target-device.")
    report["ok"] = not report["failures"]
    write_json(run_dir / "discover_target_report.json", report)
    print(f"discover-target report: {rel(run_dir / 'discover_target_report.json')}")
    return 0 if report["ok"] else 2


def not_root_findings(target: str) -> tuple[list[str], list[str], dict[str, Any]]:
    failures: list[str] = []
    warnings: list[str] = []
    info = target_info(target)

    if not info.get("exists"):
        failures.append(f"Target device is not visible: {target}")
        return failures, warnings, info

    if is_root_or_child(target):
        failures.append(f"Target is current root/source disk or child: {target}")

    return failures, warnings, info


def rescuezilla_usb_findings(target: str) -> tuple[list[str], list[str], dict[str, Any]]:
    failures: list[str] = []
    warnings: list[str] = []
    info = target_info(target)
    node = info.get("node") or {}

    if not info.get("exists"):
        failures.append(f"Target device is not visible: {target}")
        return failures, warnings, info

    size = int(node.get("size") or 0)
    transport = str(node.get("tran") or "").lower()
    max_size = int(cfg_get("rescuezilla_usb_guard.max_size_bytes", 256000000000))
    suspicious_fstype = str(cfg_get("rescuezilla_usb_guard.suspicious_fstype_regex", "") or "")
    suspicious_label = str(cfg_get("rescuezilla_usb_guard.suspicious_label_regex", "") or "")
    labels: list[str] = []
    fstypes: list[str] = []

    for child in [node] + list(node.get("children") or []):
        if child.get("label"):
            labels.append(str(child.get("label")))
        if child.get("fstype"):
            fstypes.append(str(child.get("fstype")))

    if transport == "usb" and size <= max_size:
        if any(re.search(suspicious_label, label, re.IGNORECASE) for label in labels if suspicious_label):
            failures.append(f"Target resembles Rescuezilla/live USB by label: {labels}")
        if any(re.search(suspicious_fstype, fstype, re.IGNORECASE) for fstype in fstypes if suspicious_fstype):
            failures.append(f"Target resembles ISO/live USB by filesystem type: {fstypes}")
        if not labels and not fstypes:
            warnings.append("USB target is small enough to be boot media, but label/fstype evidence is absent")

    return failures, warnings, info


def restore_target_findings(target: str) -> tuple[list[str], list[str], dict[str, Any]]:
    failures: list[str] = []
    warnings: list[str] = []
    info = target_info(target)
    node = info.get("node") or {}

    if not info.get("exists"):
        failures.append(f"Target device is not visible: {target}")
        return failures, warnings, info

    protected_paths = [canonical_device_path(x) for x in split_semicolon(str(cfg_get("restore_target_guard.protected_paths", "")))]
    target_canon = canonical_device_path(target)
    if target_canon in protected_paths:
        failures.append(f"Target is configured as protected restore target: {target}")

    protected_model = str(cfg_get("restore_target_guard.protected_model_regex", "") or "")
    model = str(node.get("model") or "")
    if protected_model and re.search(protected_model, model, re.IGNORECASE):
        failures.append(f"Target model matches protected restore-target regex: {model!r}")

    return failures, warnings, info


def cmd_assert_not_root(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("assert-not-root")
    report = report_base("assert-not-root", run_dir)
    failures, warnings, info = not_root_findings(target)
    report["target"] = info
    report["failures"] = failures
    report["warnings"] = warnings
    report["ok"] = not report["failures"]
    write_json(run_dir / "assert_not_root_report.json", report)
    print(f"assert-not-root report: {rel(run_dir / 'assert_not_root_report.json')}")
    return 0 if report["ok"] else 2


def cmd_assert_not_rescuezilla_usb(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("assert-not-rescuezilla-usb")
    report = report_base("assert-not-rescuezilla-usb", run_dir)
    failures, warnings, info = rescuezilla_usb_findings(target)
    report["target"] = info
    report["failures"] = failures
    report["warnings"] = warnings
    report["ok"] = not report["failures"]
    write_json(run_dir / "assert_not_rescuezilla_usb_report.json", report)
    print(f"assert-not-rescuezilla-usb report: {rel(run_dir / 'assert_not_rescuezilla_usb_report.json')}")
    return 0 if report["ok"] else 2


def cmd_assert_not_restore_target(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("assert-not-restore-target")
    report = report_base("assert-not-restore-target", run_dir)
    failures, warnings, info = restore_target_findings(target)
    report["target"] = info
    report["failures"] = failures
    report["warnings"] = warnings
    report["ok"] = not report["failures"]
    write_json(run_dir / "assert_not_restore_target_report.json", report)
    print(f"assert-not-restore-target report: {rel(run_dir / 'assert_not_restore_target_report.json')}")
    return 0 if report["ok"] else 2


def cmd_assert_backup_hdd(opts: dict[str, str]) -> int:
    target = target_or_discovered(opts)
    run_dir = make_run_dir("assert-backup-hdd")
    report = report_base("assert-backup-hdd", run_dir)
    failures, warnings, info = evaluate_backup_hdd(target)
    report["target"] = info
    report["failures"] = failures
    report["warnings"] = warnings
    if is_luks(target):
        report["warnings"].append("Target is already a LUKS device")
    report["ok"] = not report["failures"]
    write_json(run_dir / "assert_backup_hdd_report.json", report)
    print(f"assert-backup-hdd report: {rel(run_dir / 'assert_backup_hdd_report.json')}")
    return 0 if report["ok"] else 2


def run_all_safety_guards(target: str) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []

    for guard in (evaluate_backup_hdd, not_root_findings, rescuezilla_usb_findings, restore_target_findings):
        f, w, _ = guard(target)
        failures.extend(f)
        warnings.extend(w)

    return sorted(set(failures)), sorted(set(warnings))


def require_target(opts: dict[str, str]) -> str:
    target = opts.get("target_device")
    if not target:
        raise SystemExit("--target-device PATH is required")
    return target


def target_or_discovered(opts: dict[str, str]) -> str:
    if opts.get("target_device"):
        return str(opts["target_device"])
    candidate = discover_target_candidate()
    if not candidate:
        raise SystemExit("No backup HDD target discovered. Attach IronWolf/NexStar or pass --target-device.")
    return str(candidate["path"])


def confirm_token_for_target(target: str) -> str:
    return f"{cfg_get('safety.confirmation_prefix', 'FORMAT_LUKS2')}:{target}"


def cmd_prepare_luks2_vault(opts: dict[str, str]) -> int:
    target = require_target(opts)
    expected_token = confirm_token_for_target(target)
    if opts.get("confirm_token") != expected_token:
        raise SystemExit(f"prepare-luks2-vault requires --confirm-token {expected_token}")
    run_dir = make_run_dir("prepare-luks2-vault")
    report = report_base("prepare-luks2-vault", run_dir)

    failures, warnings = run_all_safety_guards(target)
    report["failures"].extend(failures)
    report["warnings"].extend(warnings)

    if is_luks(target):
        report["failures"].append(f"Target is already LUKS: {target}")

    if report["failures"]:
        report["ok"] = False
        write_json(run_dir / "prepare_luks2_vault_report.json", report)
        print(f"prepare-luks2-vault report: {rel(run_dir / 'prepare_luks2_vault_report.json')}")
        return 2

    format_args = [arg for arg in str(cfg_get("vault.cryptsetup_format_args", "")).split() if arg]
    if cfg_get("vault.luks_label"):
        format_args += ["--label", str(cfg_get("vault.luks_label"))]

    print("cryptsetup will prompt for passphrase. This is the intended secure path.", file=sys.stderr)
    fmt = run_interactive_cmd([CRYPTSETUP, "luksFormat", *format_args, str(target)], sudo=True)
    report.setdefault("commands", {})["luks_format"] = scrub_command(fmt)
    if fmt["returncode"] != 0:
        report["failures"].append("cryptsetup luksFormat failed")
    else:
        # Open temporarily, create filesystem, then close. This makes the vault usable for later rows.
        mapper = str(cfg_get("vault.mapper_name"))
        opn = run_interactive_cmd([CRYPTSETUP, "open", str(target), mapper], sudo=True)
        report["commands"]["open_after_format"] = scrub_command(opn)
        if opn["returncode"] != 0:
            report["failures"].append("cryptsetup open after format failed")
        else:
            fs_label = str(cfg_get("vault.filesystem_label"))
            mkfs_args = [arg for arg in str(cfg_get("vault.filesystem_mkfs_args", "")).split() if arg]
            mkfs = run_cmd([MKFS_EXT4, *mkfs_args, "-L", fs_label, str(mapper_path(mapper))], sudo=True)
            report["commands"]["mkfs_ext4"] = scrub_command(mkfs)
            if mkfs["returncode"] != 0:
                report["failures"].append("mkfs.ext4 failed on opened LUKS mapper")
            cls = run_cmd([CRYPTSETUP, "close", mapper], sudo=True)
            report["commands"]["close_after_mkfs"] = scrub_command(cls)
            if cls["returncode"] != 0:
                report["warnings"].append("cryptsetup close after mkfs returned nonzero; manual inspection may be needed")

    report["vault"] = {"target_device": target, "mapper_name": str(cfg_get("vault.mapper_name")), "mountpoint": str(cfg_get("vault.mountpoint"))}
    report["ok"] = not report["failures"]
    write_json(run_dir / "prepare_luks2_vault_report.json", report)
    print(f"prepare-luks2-vault report: {rel(run_dir / 'prepare_luks2_vault_report.json')}")
    return 0 if report["ok"] else 2


def cmd_open(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("open")
    report = report_base("open", run_dir)
    mapper = str(cfg_get("vault.mapper_name"))
    mountpoint = resolve_path(str(cfg_get("vault.mountpoint")))
    key_file = opts.get("key_file")

    if not is_luks(target):
        report["failures"].append(f"Target is not a LUKS device: {target}")
    else:
        if not mapper_path(mapper).exists():
            open_argv = [CRYPTSETUP, "open"]
            if key_file:
                open_argv.extend(["--key-file", str(resolve_path(key_file)), str(target), mapper])
                opn = run_cmd(open_argv, sudo=True)
            else:
                open_argv.extend([str(target), mapper])
                opn = run_interactive_cmd(open_argv, sudo=True)
            report.setdefault("commands", {})["cryptsetup_open"] = scrub_command(opn)
            if opn["returncode"] != 0:
                report["failures"].append("cryptsetup open failed")
        mkdir_result = ensure_mountpoint(mountpoint)
        report.setdefault("commands", {})["ensure_mountpoint"] = scrub_command(mkdir_result)
        if mkdir_result["returncode"] != 0:
            report["failures"].append(f"could not create mountpoint: {mountpoint}")
        if mapper_path(mapper).exists() and not report["failures"]:
            mnt = run_cmd([MOUNT, str(mapper_path(mapper)), str(mountpoint)], sudo=True)
            report.setdefault("commands", {})["mount"] = scrub_command(mnt)
            if mnt["returncode"] != 0 and "already mounted" not in mnt["stderr"].lower():
                report["failures"].append("mount of opened vault failed")

    report["vault"] = {"target_device": target, "mapper_name": mapper, "mapper_path": str(mapper_path(mapper)), "mountpoint": str(mountpoint)}
    report["ok"] = not report["failures"]
    write_json(run_dir / "open_report.json", report)
    print(f"open report: {rel(run_dir / 'open_report.json')}")
    return 0 if report["ok"] else 2


def cmd_close(opts: dict[str, str]) -> int:
    run_dir = make_run_dir("close")
    report = report_base("close", run_dir)
    mapper = str(cfg_get("vault.mapper_name"))
    mountpoint = resolve_path(str(cfg_get("vault.mountpoint")))

    if mountpoint.exists():
        umnt = run_cmd([UMOUNT, str(mountpoint)], sudo=True)
        report.setdefault("commands", {})["umount"] = scrub_command(umnt)
        if umnt["returncode"] != 0 and "not mounted" not in umnt["stderr"].lower():
            report["warnings"].append("umount returned nonzero; attempting cryptsetup close anyway")

    if mapper_path(mapper).exists():
        cls = run_cmd([CRYPTSETUP, "close", mapper], sudo=True)
        report.setdefault("commands", {})["cryptsetup_close"] = scrub_command(cls)
        if cls["returncode"] != 0:
            report["failures"].append("cryptsetup close failed")
    else:
        report["warnings"].append(f"Mapper was not open: {mapper}")

    report["ok"] = not report["failures"]
    write_json(run_dir / "close_report.json", report)
    print(f"close report: {rel(run_dir / 'close_report.json')}")
    return 0 if report["ok"] else 2


def metadata_payload(target: str) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    commands: dict[str, dict[str, Any]] = {}
    payload = {"target_device": target, "canonical_target": canonical_device_path(target), "luks_uuid": luks_uuid(target)}
    luksdump = run_cmd([CRYPTSETUP, "luksDump", str(target)], sudo=True)
    commands["luks_dump"] = scrub_command(luksdump)
    payload["luks_dump_text"] = luksdump["stdout"]
    blkid = run_cmd([BLKID, str(target)], sudo=True)
    commands["blkid_target"] = scrub_command(blkid)
    payload["blkid_text"] = blkid["stdout"]
    info = target_info(target)
    payload["target_info"] = {k: v for k, v in info.items() if k != "lsblk"}
    return payload, commands


def cmd_export_metadata(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("export-metadata")
    report = report_base("export-metadata", run_dir)
    if not is_luks(target):
        report["failures"].append(f"Target is not LUKS: {target}")
    else:
        metadata, commands = metadata_payload(target)
        metadata_path = run_dir / "cryptsetup_metadata.json"
        write_json(metadata_path, metadata)
        report["metadata"] = {"path": rel(metadata_path), "payload": metadata}
        report["commands"] = commands
    report["ok"] = not report["failures"]
    write_json(run_dir / "export_metadata_report.json", report)
    print(f"export-metadata report: {rel(run_dir / 'export_metadata_report.json')}")
    return 0 if report["ok"] else 2


def sha256_path(path: Path) -> str | None:
    result = run_cmd([SHA256SUM, str(path)], sudo=True)
    if result["returncode"] != 0:
        return None
    return result["stdout"].split()[0]


def header_filename(target: str) -> str:
    uuid = luks_uuid(target) or "unknown_uuid"
    slug = re.sub(r"[^A-Za-z0-9_.-]+", "_", target.strip("/"))
    template = str(cfg_get("header_backup.filename_template"))
    return template.format(device_slug=slug, uuid=uuid, timestamp=now_stamp())


def cmd_backup_header(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("backup-header")
    report = report_base("backup-header", run_dir)

    if not is_luks(target):
        report["failures"].append(f"Target is not LUKS: {target}")
    else:
        directory = resolve_path(str(cfg_get("header_backup.directory")))
        ensure_private_dir(directory)
        header_path = directory / header_filename(target)
        result = run_cmd([CRYPTSETUP, "luksHeaderBackup", str(target), "--header-backup-file", str(header_path)], sudo=True)
        report.setdefault("commands", {})["luks_header_backup"] = scrub_command(result)
        if result["returncode"] != 0:
            report["failures"].append("cryptsetup luksHeaderBackup failed")
        else:
            chmod_private(header_path)
            checksum = sha256_path(header_path)
            checksum_path = header_path.with_name(header_path.name + ".sha256")
            if checksum:
                write_text(checksum_path, f"{checksum}  {header_path.name}\n")
                chmod_private(checksum_path)
            report["header_backup"] = {"path": str(header_path), "relative_path": rel(header_path), "size_bytes": header_path.stat().st_size, "sha256": checksum, "checksum_path": str(checksum_path)}

    report["ok"] = not report["failures"]
    write_json(run_dir / "backup_header_report.json", report)
    print(f"backup-header report: {rel(run_dir / 'backup_header_report.json')}")
    return 0 if report["ok"] else 2


def cmd_verify_header(opts: dict[str, str]) -> int:
    header_arg = opts.get("header_file")
    if not header_arg:
        raise SystemExit("verify-header requires --header-file PATH")
    header = resolve_path(header_arg)
    run_dir = make_run_dir("verify-header")
    report = report_base("verify-header", run_dir)

    if not header.exists():
        report["failures"].append(f"Header backup file does not exist: {header}")
    else:
        dump = run_cmd([CRYPTSETUP, "luksDump", str(header)], sudo=True)
        dump_path = run_dir / "header_luks_dump.txt"
        write_text(dump_path, dump["stdout"] + dump["stderr"])
        report.setdefault("commands", {})["luks_dump_header"] = scrub_command(dump, rel(dump_path))
        if dump["returncode"] != 0:
            report["failures"].append("cryptsetup could not parse the header backup with luksDump")
        checksum = sha256_path(header)
        report["header_backup"] = {"path": str(header), "relative_path": rel(header), "size_bytes": header.stat().st_size, "sha256": checksum, "luks_dump_path": rel(dump_path)}

    report["ok"] = not report["failures"]
    write_json(run_dir / "verify_header_report.json", report)
    print(f"verify-header report: {rel(run_dir / 'verify_header_report.json')}")
    return 0 if report["ok"] else 2


def cmd_build_emergency_packet(opts: dict[str, str]) -> int:
    run_dir = make_run_dir("build-emergency-packet")
    report = report_base("build-emergency-packet", run_dir)
    directory = resolve_path(str(cfg_get("emergency_packet.directory")))
    ensure_private_dir(directory)
    packet_name = str(cfg_get("emergency_packet.filename_template")).format(timestamp=now_stamp())
    packet_path = directory / packet_name

    readme = run_dir / "README_EMERGENCY_PACKET.txt"
    write_text(readme, (
        "Cryptsetup emergency packet for wantless recovery vault.\n"
        "Contains no passphrase.\n"
        "Protect this packet because LUKS header backups are operationally sensitive.\n"
        "Recovery requires both a valid passphrase and the correct header/metadata context.\n"
    ))

    config_path = PROJECT_ROOT / "configs" / "03_cryptsetup.yaml"
    manifest = {"created_at": utc_now(), "packet_path": str(packet_path), "members": []}

    with tarfile.open(packet_path, "w:gz") as tar:
        for source, arcname in ((readme, "README_EMERGENCY_PACKET.txt"), (config_path, "configs/03_cryptsetup.yaml")):
            if source.exists():
                tar.add(source, arcname=arcname)
                manifest["members"].append(arcname)
        for opt_key, arcname in (("header_file", "header_backup.img"), ("metadata_file", "cryptsetup_metadata.json")):
            value = opts.get(opt_key)
            if value:
                source = resolve_path(value)
                if source.exists():
                    tar.add(source, arcname=arcname)
                    manifest["members"].append(arcname)
                else:
                    report["warnings"].append(f"Requested {opt_key} does not exist: {source}")

    chmod_private(packet_path)
    checksum = sha256_path(packet_path)
    checksum_path = packet_path.with_name(packet_path.name + ".sha256")
    if checksum:
        write_text(checksum_path, f"{checksum}  {packet_path.name}\n")
        chmod_private(checksum_path)

    report["emergency_packet"] = {"path": str(packet_path), "relative_path": rel(packet_path), "sha256": checksum, "checksum_path": str(checksum_path), "manifest": manifest}
    report["ok"] = not report["failures"]
    write_json(run_dir / "build_emergency_packet_report.json", report)
    print(f"build-emergency-packet report: {rel(run_dir / 'build_emergency_packet_report.json')}")
    return 0 if report["ok"] else 2


def cmd_verify_emergency_packet(opts: dict[str, str]) -> int:
    packet_arg = opts.get("packet")
    if not packet_arg:
        raise SystemExit("verify-emergency-packet requires --packet PATH")
    packet = resolve_path(packet_arg)
    run_dir = make_run_dir("verify-emergency-packet")
    report = report_base("verify-emergency-packet", run_dir)
    if not packet.exists():
        report["failures"].append(f"Emergency packet not found: {packet}")
    else:
        members = []
        try:
            with tarfile.open(packet, "r:gz") as tar:
                members = tar.getnames()
        except Exception as exc:
            report["failures"].append(f"Emergency packet is not a valid tar.gz: {exc}")
        checksum = sha256_path(packet)
        report["emergency_packet"] = {"path": str(packet), "relative_path": rel(packet), "sha256": checksum, "members": members}
        if "README_EMERGENCY_PACKET.txt" not in members:
            report["failures"].append("Emergency packet missing README_EMERGENCY_PACKET.txt")
    report["ok"] = not report["failures"]
    write_json(run_dir / "verify_emergency_packet_report.json", report)
    print(f"verify-emergency-packet report: {rel(run_dir / 'verify_emergency_packet_report.json')}")
    return 0 if report["ok"] else 2


def cmd_smoke_open_close(opts: dict[str, str]) -> int:
    target = require_target(opts)
    run_dir = make_run_dir("smoke-open-close")
    report = report_base("smoke-open-close", run_dir)
    mapper = str(cfg_get("vault.mapper_name"))

    if not is_luks(target):
        report["failures"].append(f"Target is not LUKS: {target}")
    else:
        opn = run_interactive_cmd([CRYPTSETUP, "open", "--test-passphrase", str(target)], sudo=True)
        report.setdefault("commands", {})["test_passphrase"] = scrub_command(opn)
        if opn["returncode"] != 0:
            report["failures"].append("cryptsetup open --test-passphrase failed")
        report["vault"] = {"target_device": target, "mapper_name": mapper}
    report["ok"] = not report["failures"]
    write_json(run_dir / "smoke_open_close_report.json", report)
    print(f"smoke-open-close report: {rel(run_dir / 'smoke_open_close_report.json')}")
    return 0 if report["ok"] else 2


def test_cfg() -> dict[str, Any]:
    return deepcopy(CFG.get("local_test", DEFAULT_CONFIG["local_test"]))


def write_test_key(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_bytes(os.urandom(64))
    chmod_private(path)


def cmd_prepare_test_vault(opts: dict[str, str]) -> int:
    require_confirmation(opts.get("confirm_test") == "yes", "prepare-test-vault requires --i-understand-local-loopback-test")
    run_dir = make_run_dir("prepare-test-vault")
    report = report_base("prepare-test-vault", run_dir)
    tc = test_cfg()
    image = resolve_path(str(tc["image_path"]))
    key_file = resolve_path(str(tc["key_file"]))
    mapper = str(tc["mapper_name"])
    image.parent.mkdir(parents=True, exist_ok=True)
    write_test_key(key_file)

    if image.exists():
        report["failures"].append(f"Local test image already exists; destroy or remove first: {image}")
    else:
        trunc = run_cmd([TRUNCATE, "-s", str(int(tc["size_bytes"])), str(image)])
        report.setdefault("commands", {})["truncate"] = scrub_command(trunc)
        if trunc["returncode"] != 0:
            report["failures"].append("truncate failed for local test image")

    if not report["failures"]:
        fmt_args = [arg for arg in str(cfg_get("vault.cryptsetup_format_args")).split() if arg]
        fmt_args += ["--label", str(tc["luks_label"])]
        fmt = run_cmd([CRYPTSETUP, "luksFormat", "--batch-mode", "--key-file", str(key_file), *fmt_args, str(image)], sudo=True)
        report["commands"]["luks_format_test"] = scrub_command(fmt)
        if fmt["returncode"] != 0:
            report["failures"].append("cryptsetup luksFormat failed for local test image")
        else:
            opn = run_cmd([CRYPTSETUP, "open", "--key-file", str(key_file), str(image), mapper], sudo=True)
            report["commands"]["open_test"] = scrub_command(opn)
            if opn["returncode"] != 0:
                report["failures"].append("cryptsetup open failed for local test image")
            else:
                mkfs_args = [arg for arg in str(cfg_get("vault.filesystem_mkfs_args")).split() if arg]
                mkfs = run_cmd([MKFS_EXT4, *mkfs_args, "-L", str(tc["filesystem_label"]), str(mapper_path(mapper))], sudo=True)
                report["commands"]["mkfs_ext4_test"] = scrub_command(mkfs)
                if mkfs["returncode"] != 0:
                    report["failures"].append("mkfs.ext4 failed for local test mapper")
                cls = run_cmd([CRYPTSETUP, "close", mapper], sudo=True)
                report["commands"]["close_test"] = scrub_command(cls)
                if cls["returncode"] != 0:
                    report["warnings"].append("cryptsetup close returned nonzero for local test mapper")

    report["local_test"] = {"image_path": str(image), "key_file": str(key_file), "mapper_name": mapper, "mountpoint": str(resolve_path(str(tc["mountpoint"])))}
    report["ok"] = not report["failures"]
    write_json(run_dir / "prepare_test_vault_report.json", report)
    print(f"prepare-test-vault report: {rel(run_dir / 'prepare_test_vault_report.json')}")
    return 0 if report["ok"] else 2


def cmd_open_test_vault(opts: dict[str, str]) -> int:
    tc = test_cfg()
    old_mount = CFG["vault"].get("mountpoint")
    old_mapper = CFG["vault"].get("mapper_name")
    old_label = CFG["vault"].get("filesystem_label")
    CFG["vault"]["mountpoint"] = tc["mountpoint"]
    CFG["vault"]["mapper_name"] = tc["mapper_name"]
    CFG["vault"]["filesystem_label"] = tc["filesystem_label"]
    try:
        return cmd_open({"target_device": str(resolve_path(str(tc["image_path"]))), "key_file": str(resolve_path(str(tc["key_file"])))})
    finally:
        CFG["vault"]["mountpoint"] = old_mount
        CFG["vault"]["mapper_name"] = old_mapper
        CFG["vault"]["filesystem_label"] = old_label


def cmd_close_test_vault(opts: dict[str, str]) -> int:
    tc = test_cfg()
    old_mount = CFG["vault"].get("mountpoint")
    old_mapper = CFG["vault"].get("mapper_name")
    CFG["vault"]["mountpoint"] = tc["mountpoint"]
    CFG["vault"]["mapper_name"] = tc["mapper_name"]
    try:
        return cmd_close({})
    finally:
        CFG["vault"]["mountpoint"] = old_mount
        CFG["vault"]["mapper_name"] = old_mapper


def cmd_destroy_test_vault(opts: dict[str, str]) -> int:
    require_confirmation(opts.get("confirm_destroy_test") == "yes", "destroy-test-vault requires --i-understand-destroy-local-test-vault")
    run_dir = make_run_dir("destroy-test-vault")
    report = report_base("destroy-test-vault", run_dir)
    tc = test_cfg()
    image = resolve_path(str(tc["image_path"]))
    key_file = resolve_path(str(tc["key_file"]))
    mapper = str(tc["mapper_name"])
    mountpoint = resolve_path(str(tc["mountpoint"]))

    if mountpoint.exists():
        umnt = run_cmd([UMOUNT, str(mountpoint)], sudo=True)
        report.setdefault("commands", {})["umount_test"] = scrub_command(umnt)
    if mapper_path(mapper).exists():
        close = run_cmd([CRYPTSETUP, "close", mapper], sudo=True)
        report.setdefault("commands", {})["close_test"] = scrub_command(close)
        if close["returncode"] != 0:
            report["failures"].append("could not close local test mapper")
    if not report["failures"]:
        for candidate in (image, key_file):
            if candidate.exists():
                candidate.unlink()
    report["local_test"] = {"image_path": str(image), "key_file": str(key_file), "removed": not image.exists() and not key_file.exists()}
    report["ok"] = not report["failures"]
    write_json(run_dir / "destroy_test_vault_report.json", report)
    print(f"destroy-test-vault report: {rel(run_dir / 'destroy_test_vault_report.json')}")
    return 0 if report["ok"] else 2


def cmd_gate(opts: dict[str, str]) -> int:
    run_dir = make_run_dir("gate")
    report = report_base("gate", run_dir)
    target = opts.get("target_device")
    if not target:
        candidate = discover_target_candidate()
        if candidate:
            target = str(candidate["path"])
        else:
            report["warnings"].append("No backup HDD target discovered; gate cannot fully pass until IronWolf/NexStar is attached")
    if target:
        failures, warnings = run_all_safety_guards(target)
        report["target"] = target_info(target)
        report["failures"].extend(failures)
        report["warnings"].extend(warnings)
        if not is_luks(target):
            report["warnings"].append("Target is not yet LUKS; this is expected before prepare-luks2-vault")
    report["ok"] = not report["failures"]
    write_json(run_dir / "gate_report.json", report)
    print(f"gate report: {rel(run_dir / 'gate_report.json')}")
    return 0 if report["ok"] else 2


def parse_args(argv: list[str]) -> tuple[str, dict[str, str]]:
    if not argv or argv[0] in {"help", "-h", "--help"}:
        print_usage()
        raise SystemExit(0)
    command = argv[0]
    opts: dict[str, str] = {}
    i = 1
    while i < len(argv):
        token = argv[i]
        if token == "--target-device":
            i += 1
            if i >= len(argv):
                raise SystemExit("--target-device requires a value")
            opts["target_device"] = argv[i]
        elif token == "--header-file":
            i += 1
            if i >= len(argv):
                raise SystemExit("--header-file requires a value")
            opts["header_file"] = argv[i]
        elif token == "--metadata-file":
            i += 1
            if i >= len(argv):
                raise SystemExit("--metadata-file requires a value")
            opts["metadata_file"] = argv[i]
        elif token == "--packet":
            i += 1
            if i >= len(argv):
                raise SystemExit("--packet requires a value")
            opts["packet"] = argv[i]
        elif token == "--confirm-token":
            i += 1
            if i >= len(argv):
                raise SystemExit("--confirm-token requires a value")
            opts["confirm_token"] = argv[i]
        elif token == "--key-file":
            i += 1
            if i >= len(argv):
                raise SystemExit("--key-file requires a value")
            opts["key_file"] = argv[i]
        elif token == "--i-understand-local-loopback-test":
            opts["confirm_test"] = "yes"
        elif token == "--i-understand-destroy-local-test-vault":
            opts["confirm_destroy_test"] = "yes"
        else:
            raise SystemExit(f"Unknown option: {token}")
        i += 1
    return command, opts


def main() -> int:
    command, opts = parse_args(ARGS)
    if command == "discover-target":
        return cmd_discover_target(opts)
    if command == "assert-not-root":
        return cmd_assert_not_root(opts)
    if command == "assert-not-rescuezilla-usb":
        return cmd_assert_not_rescuezilla_usb(opts)
    if command == "assert-not-restore-target":
        return cmd_assert_not_restore_target(opts)
    if command == "assert-backup-hdd":
        return cmd_assert_backup_hdd(opts)
    if command == "prepare-luks2-vault":
        return cmd_prepare_luks2_vault(opts)
    if command == "open":
        return cmd_open(opts)
    if command == "close":
        return cmd_close(opts)
    if command == "export-metadata":
        return cmd_export_metadata(opts)
    if command == "backup-header":
        return cmd_backup_header(opts)
    if command == "verify-header":
        return cmd_verify_header(opts)
    if command == "build-emergency-packet":
        return cmd_build_emergency_packet(opts)
    if command == "verify-emergency-packet":
        return cmd_verify_emergency_packet(opts)
    if command == "smoke-open-close":
        return cmd_smoke_open_close(opts)
    if command == "gate":
        return cmd_gate(opts)
    if command == "prepare-test-vault":
        return cmd_prepare_test_vault(opts)
    if command == "open-test-vault":
        return cmd_open_test_vault(opts)
    if command == "close-test-vault":
        return cmd_close_test_vault(opts)
    if command == "destroy-test-vault":
        return cmd_destroy_test_vault(opts)

    print_usage()
    raise SystemExit(f"Unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
PY