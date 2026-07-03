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
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "02_rescuezilla.sh"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {"name": "rescuezilla", "verified_rescuezilla_version": "2.6.2", "release_family": "Resolute"},
    "project": {"output_root": "state/dry_runs/02_rescuezilla"},
    "iso": {
        "path": "downloads/rescuezilla-2.6.2-64bit.resolute.iso",
        "expected_sha256": "20dfdad31d3da56b8dd3978159721f19071916f65e123003a850fdecec85ae3f",
        "expected_filename": "rescuezilla-2.6.2-64bit.resolute.iso",
    },
    "source": {
        "disk": "/dev/nvme0n1",
        "efi_partition": "/dev/nvme0n1p1",
        "root_partition": "/dev/nvme0n1p2",
        "expected_boot_mode": "uefi",
        "minimum_restore_target_bytes": 1900000000000,
        "minimum_restore_target_policy": "max(actual_source_disk_bytes, configured_floor)",
        "require_configured_root_matches_active": True,
        "require_configured_efi_matches_active": True,
    },
    "image_inventory": {
        "search_roots": "state/dry_runs/02_rescuezilla/images;/mnt/wantless_recovery/01_rescuezilla_images",
        "manifest_name": "rescuezilla_image_manifest.json",
        "write_manifest_to_image_dir": False,
    },
    "commands": {
        "sha256sum": "/usr/bin/sha256sum",
        "lsblk": "/usr/bin/lsblk",
        "blkid": "/usr/sbin/blkid",
        "sfdisk": "/usr/sbin/sfdisk",
        "findmnt": "/usr/bin/findmnt",
        "efibootmgr": "/usr/bin/efibootmgr",
        "mokutil": "/usr/bin/mokutil",
        "du": "/usr/bin/du",
        "file": "/usr/bin/file",
    },
}


def print_usage() -> None:
    print(
        f"""Usage:
  scripts/{SCRIPT_NAME} verify-iso
  scripts/{SCRIPT_NAME} list-usb-candidates
  scripts/{SCRIPT_NAME} capture-source-layout
  scripts/{SCRIPT_NAME} capture-uefi
  scripts/{SCRIPT_NAME} write-image-manifest --image-path PATH [--label LABEL] [--manifest-output PATH]
  scripts/{SCRIPT_NAME} list-images
  scripts/{SCRIPT_NAME} validate-image-manifest --manifest PATH
  scripts/{SCRIPT_NAME} assert-target-size --target-device PATH [--manifest PATH]

Safety:
  This script is read-only for disks and USB devices. It does not write an ISO, image, restore, partition, format, mount, or encrypt.
""",
        end="",
    )


def strip_comment(line: str) -> str:
    in_single = False
    in_double = False
    out = []
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
    path = PROJECT_ROOT / "configs" / "02_rescuezilla.yaml"
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


SHA256SUM = cmd_path("sha256sum")
LSBLK = cmd_path("lsblk")
BLKID = cmd_path("blkid")
SFDISK = cmd_path("sfdisk")
FINDMNT = cmd_path("findmnt")
EFIBOOTMGR = cmd_path("efibootmgr")
MOKUTIL = cmd_path("mokutil")
DU = cmd_path("du")
FILE = cmd_path("file")


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


def resolve_project_path(value: str) -> Path:
    p = Path(str(value)).expanduser()
    if not p.is_absolute():
        p = PROJECT_ROOT / p
    return p.resolve()


def make_run_dir(command: str, explicit: str | None = None) -> Path:
    if explicit:
        run_dir = resolve_project_path(explicit)
    else:
        root = resolve_project_path(str(cfg_get("project.output_root", "state/dry_runs/02_rescuezilla")))
        run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def run_cmd(argv: list[str], *, sudo: bool = False) -> dict[str, Any]:
    final_argv = argv[:]
    if sudo and os.geteuid() != 0:
        if shutil.which("sudo"):
            final_argv = ["sudo"] + final_argv
        else:
            return {"argv": argv, "returncode": 127, "stdout": "", "stderr": "sudo is required but not available"}
    proc = subprocess.run(final_argv, text=True, capture_output=True)
    return {"argv": final_argv, "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr}


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
        "schema": "recovery.rescuezilla.v1",
        "tool": {"name": "rescuezilla", "script": SCRIPT_NAME},
        "command": command,
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": True,
        "failures": [],
        "warnings": [],
    }


def split_paths(value: str) -> list[Path]:
    return [resolve_project_path(part.strip()) for part in str(value or "").split(";") if part.strip()]


def file_size(path: Path) -> int | None:
    try:
        return path.stat().st_size
    except OSError:
        return None


def directory_size(path: Path) -> int:
    result = run_cmd([DU, "-sb", str(path)])
    if result["returncode"] == 0 and result["stdout"].strip():
        try:
            return int(result["stdout"].split()[0])
        except (ValueError, IndexError):
            pass
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            try:
                total += item.stat().st_size
            except OSError:
                pass
    return total


def get_lsblk() -> dict[str, Any]:
    result = run_cmd([LSBLK, "-J", "-b", "-O", "-e7"])
    parsed = parse_json_stdout(result)
    return parsed if parsed is not None else {"blockdevices": [], "_command_error": result}


def flatten_blockdevices(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out = []
    for node in nodes:
        out.append(node)
        children = node.get("children") or []
        if isinstance(children, list):
            out.extend(flatten_blockdevices(children))
    return out


def has_root_mount(node: dict[str, Any]) -> bool:
    if node.get("mountpoint") == "/":
        return True
    mounts = node.get("mountpoints")
    return isinstance(mounts, list) and "/" in mounts


def root_disk_from_lsblk(lsblk_payload: dict[str, Any]) -> str | None:
    def walk(nodes: list[dict[str, Any]], disk_path: str | None = None) -> str | None:
        for node in nodes:
            node_type = str(node.get("type") or "")
            node_path = str(node.get("path") or "")
            current_disk = node_path if node_type == "disk" and node_path else disk_path
            if has_root_mount(node):
                return current_disk
            child = walk(node.get("children") or [], current_disk)
            if child:
                return child
        return None
    return walk(lsblk_payload.get("blockdevices", []) or [])


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


def device_paths_match(configured: str | None, active: str | None) -> bool:
    if configured in (None, "") or active in (None, ""):
        return False
    configured_text = str(configured)
    active_text = str(active)
    if configured_text.startswith("/dev/") and active_text.startswith("/dev/"):
        return canonical_device_path(configured_text) == canonical_device_path(active_text)
    return configured_text == active_text


def blockdevice_by_path(lsblk_payload: dict[str, Any], wanted_path: str) -> dict[str, Any] | None:
    for node in flatten_blockdevices(lsblk_payload.get("blockdevices", []) or []):
        if str(node.get("path") or "") == wanted_path:
            return node
    return None


def disk_size_from_lsblk(lsblk_payload: dict[str, Any], disk_path: str) -> int | None:
    node = blockdevice_by_path(lsblk_payload, disk_path)
    if not node:
        return None
    try:
        return int(node.get("size"))
    except (TypeError, ValueError):
        return None


def minimum_restore_target_bytes(lsblk_payload: dict[str, Any] | None = None) -> tuple[int, int | None]:
    configured_floor = int(cfg_get("source.minimum_restore_target_bytes", 1900000000000))
    payload = lsblk_payload if isinstance(lsblk_payload, dict) else get_lsblk()
    source_disk = str(cfg_get("source.disk"))
    actual_source_size = disk_size_from_lsblk(payload, source_disk)
    if actual_source_size is None:
        return configured_floor, None
    return max(configured_floor, actual_source_size), actual_source_size


def cmd_verify_iso(run_dir_arg: str | None) -> int:
    run_dir = make_run_dir("verify-iso", run_dir_arg)
    report = report_base("verify-iso", run_dir)
    iso_path = resolve_project_path(str(cfg_get("iso.path")))
    expected_sha = str(cfg_get("iso.expected_sha256", "") or "").strip().lower()

    iso_report = {"path": str(iso_path), "relative_path": rel(iso_path), "exists": iso_path.exists(), "sha256": None, "expected_sha256": expected_sha or None, "size_bytes": None}

    if not iso_path.exists():
        report["failures"].append(f"Rescuezilla ISO not found: {iso_path}")
    else:
        iso_report["size_bytes"] = file_size(iso_path)
        sha_result = run_cmd([SHA256SUM, str(iso_path)])
        sha_path = run_dir / "rescuezilla_iso.sha256"
        write_text(sha_path, sha_result["stdout"] + sha_result["stderr"])
        report.setdefault("commands", {})["sha256sum_iso"] = scrub_command(sha_result, rel(sha_path))
        if sha_result["returncode"] != 0:
            report["failures"].append(f"sha256sum failed for ISO: {iso_path}")
        else:
            actual = sha_result["stdout"].split()[0].strip().lower()
            iso_report["sha256"] = actual
            if expected_sha and actual != expected_sha:
                report["failures"].append(f"ISO SHA256 mismatch: expected {expected_sha}, got {actual}")

        file_result = run_cmd([FILE, str(iso_path)])
        file_path = run_dir / "file_rescuezilla_iso.txt"
        write_text(file_path, file_result["stdout"] + file_result["stderr"])
        report.setdefault("commands", {})["file_iso"] = scrub_command(file_result, rel(file_path))

    report["iso"] = iso_report
    report["ok"] = not report["failures"]
    write_json(run_dir / "verify_iso_report.json", report)
    print(f"verify-iso report: {rel(run_dir / 'verify_iso_report.json')}")
    return 0 if report["ok"] else 2


def cmd_list_usb_candidates(run_dir_arg: str | None) -> int:
    run_dir = make_run_dir("list-usb-candidates", run_dir_arg)
    report = report_base("list-usb-candidates", run_dir)
    lsblk_payload = get_lsblk()
    lsblk_path = run_dir / "lsblk.json"
    write_json(lsblk_path, lsblk_payload)

    root_disk = root_disk_from_lsblk(lsblk_payload)
    candidates = []
    for dev in flatten_blockdevices(lsblk_payload.get("blockdevices", []) or []):
        if dev.get("type") != "disk":
            continue
        path = dev.get("path")
        if not path or path == root_disk:
            continue
        tran = str(dev.get("tran") or "").lower()
        rm = str(dev.get("rm") or "")
        hotplug = str(dev.get("hotplug") or "")
        if tran == "usb" or rm == "1" or hotplug == "1":
            candidates.append(dev)

    byid_result = run_cmd(["find", "/dev/disk/by-id", "-maxdepth", "1", "-type", "l", "-printf", "%f -> %l\\n"])
    byid_path = run_dir / "disk_by_id.txt"
    write_text(byid_path, byid_result["stdout"] + byid_result["stderr"])

    report["commands"] = {
        "lsblk": {"argv": [LSBLK, "-J", "-b", "-O", "-e7"], "returncode": 0, "stdout_path": rel(lsblk_path), "stderr": ""},
        "disk_by_id": scrub_command(byid_result, rel(byid_path)),
    }
    report["root_disk"] = root_disk
    report["usb_candidates"] = candidates
    if not candidates:
        report["warnings"].append("No USB/removable disk candidates found. This is acceptable before creating/testing Rescuezilla USB media.")
    report["ok"] = True
    write_json(run_dir / "usb_candidates_report.json", report)
    print(f"list-usb-candidates report: {rel(run_dir / 'usb_candidates_report.json')}")
    return 0


def capture_command_to_file(argv: list[str], path: Path, *, sudo: bool = False) -> dict[str, Any]:
    result = run_cmd(argv, sudo=sudo)
    write_text(path, result["stdout"] + result["stderr"])
    return scrub_command(result, rel(path))


def findmnt_source(path: str) -> str | None:
    result = run_cmd([FINDMNT, "-n", "-o", "SOURCE", path])
    if result["returncode"] != 0:
        return None
    lines = [line.strip() for line in result["stdout"].splitlines() if line.strip()]
    return lines[0] if lines else None


def cmd_capture_source_layout(run_dir_arg: str | None) -> int:
    run_dir = make_run_dir("capture-source-layout", run_dir_arg)
    report = report_base("capture-source-layout", run_dir)

    source_disk = str(cfg_get("source.disk"))
    efi_partition = str(cfg_get("source.efi_partition"))
    root_partition = str(cfg_get("source.root_partition"))
    active_root_source = findmnt_source("/")
    active_efi_source = findmnt_source("/boot/efi")

    lsblk_payload = get_lsblk()
    lsblk_path = run_dir / "lsblk.json"
    write_json(lsblk_path, lsblk_payload)

    findmnt_result = run_cmd([FINDMNT, "--json", "--real"])
    findmnt_path = run_dir / "findmnt.json"
    parsed_findmnt = parse_json_stdout(findmnt_result)
    if parsed_findmnt is not None:
        write_json(findmnt_path, parsed_findmnt)
    else:
        write_text(findmnt_path, findmnt_result["stdout"] + findmnt_result["stderr"])

    commands = {
        "lsblk": {"argv": [LSBLK, "-J", "-b", "-O", "-e7"], "returncode": 0, "stdout_path": rel(lsblk_path), "stderr": ""},
        "findmnt": scrub_command(findmnt_result, rel(findmnt_path)),
        "blkid": capture_command_to_file([BLKID], run_dir / "blkid.txt", sudo=True),
        "sfdisk_dump": capture_command_to_file([SFDISK, "-d", source_disk], run_dir / "sfdisk_dump.txt", sudo=True),
        "sfdisk_json": capture_command_to_file([SFDISK, "-J", source_disk], run_dir / "sfdisk.json", sudo=True),
    }

    root_disk = root_disk_from_lsblk(lsblk_payload)
    if root_disk != source_disk:
        report["warnings"].append(f"Configured source disk {source_disk} differs from detected root disk {root_disk}")

    paths = {str(dev.get("path")) for dev in flatten_blockdevices(lsblk_payload.get("blockdevices", []) or [])}
    for required_path in (source_disk, efi_partition, root_partition):
        if required_path not in paths:
            report["failures"].append(f"Expected source layout path not visible in lsblk: {required_path}")

    if bool(cfg_get("source.require_configured_root_matches_active", True)) and not device_paths_match(root_partition, active_root_source):
        report["failures"].append(
            f"Configured root partition {root_partition} does not match active findmnt / source {active_root_source}"
        )

    if bool(cfg_get("source.require_configured_efi_matches_active", True)) and not device_paths_match(efi_partition, active_efi_source):
        report["failures"].append(
            f"Configured EFI partition {efi_partition} does not match active findmnt /boot/efi source {active_efi_source}"
        )

    report["commands"] = commands
    minimum_target_bytes, actual_source_size = minimum_restore_target_bytes(lsblk_payload)

    report["source_layout"] = {
        "configured_source_disk": source_disk,
        "configured_efi_partition": efi_partition,
        "configured_root_partition": root_partition,
        "active_root_source": active_root_source,
        "active_root_source_canonical": canonical_device_path(active_root_source),
        "active_efi_source": active_efi_source,
        "active_efi_source_canonical": canonical_device_path(active_efi_source),
        "configured_root_partition_canonical": canonical_device_path(root_partition),
        "configured_efi_partition_canonical": canonical_device_path(efi_partition),
        "detected_root_disk": root_disk,
        "source_disk_size_bytes": actual_source_size,
        "configured_minimum_restore_target_bytes": int(cfg_get("source.minimum_restore_target_bytes")),
        "minimum_restore_target_bytes": minimum_target_bytes,
        "minimum_restore_target_policy": str(cfg_get("source.minimum_restore_target_policy", "max(actual_source_disk_bytes, configured_floor)")),
        "files": {
            "lsblk": rel(lsblk_path),
            "findmnt": rel(findmnt_path),
            "blkid": rel(run_dir / "blkid.txt"),
            "sfdisk_dump": rel(run_dir / "sfdisk_dump.txt"),
            "sfdisk_json": rel(run_dir / "sfdisk.json"),
        },
    }
    report["ok"] = not report["failures"]
    write_json(run_dir / "source_layout_report.json", report)
    print(f"capture-source-layout report: {rel(run_dir / 'source_layout_report.json')}")
    return 0 if report["ok"] else 2


def cmd_capture_uefi(run_dir_arg: str | None) -> int:
    run_dir = make_run_dir("capture-uefi", run_dir_arg)
    report = report_base("capture-uefi", run_dir)

    is_uefi = Path("/sys/firmware/efi").exists()
    commands = {
        "efibootmgr": capture_command_to_file([EFIBOOTMGR, "-v"], run_dir / "efibootmgr_v.txt", sudo=True),
        "mokutil_sb_state": capture_command_to_file([MOKUTIL, "--sb-state"], run_dir / "mokutil_sb_state.txt"),
    }

    if str(cfg_get("source.expected_boot_mode", "uefi")).lower() == "uefi" and not is_uefi:
        report["failures"].append("Expected UEFI boot mode, but /sys/firmware/efi is not present")

    report["commands"] = commands
    report["uefi"] = {
        "sys_firmware_efi_present": is_uefi,
        "expected_boot_mode": str(cfg_get("source.expected_boot_mode", "uefi")),
        "files": {
            "efibootmgr": rel(run_dir / "efibootmgr_v.txt"),
            "mokutil_sb_state": rel(run_dir / "mokutil_sb_state.txt"),
        },
    }
    report["ok"] = not report["failures"]
    write_json(run_dir / "uefi_report.json", report)
    print(f"capture-uefi report: {rel(run_dir / 'uefi_report.json')}")
    return 0 if report["ok"] else 2


def image_candidate(path: Path) -> dict[str, Any]:
    exists = path.exists()
    is_dir = path.is_dir()
    is_file = path.is_file()
    size = directory_size(path) if is_dir else file_size(path)
    manifest_name = str(cfg_get("image_inventory.manifest_name", "rescuezilla_image_manifest.json"))
    manifest_path = path / manifest_name if is_dir else path.with_suffix(path.suffix + ".manifest.json")
    return {
        "path": str(path),
        "relative_path": rel(path),
        "exists": exists,
        "kind": "directory" if is_dir else ("file" if is_file else "missing"),
        "size_bytes": size,
        "manifest_path": str(manifest_path),
        "manifest_exists": manifest_path.exists(),
    }


def cmd_list_images(run_dir_arg: str | None) -> int:
    run_dir = make_run_dir("list-images", run_dir_arg)
    report = report_base("list-images", run_dir)

    roots = split_paths(str(cfg_get("image_inventory.search_roots", "")))
    candidates = []
    for root in roots:
        if not root.exists():
            report["warnings"].append(f"Image search root does not exist yet: {root}")
            continue
        if root.is_file():
            candidates.append(image_candidate(root))
            continue
        for child in sorted(root.iterdir()):
            if child.is_dir() or child.is_file():
                candidates.append(image_candidate(child))

    report["image_candidates"] = candidates
    report["search_roots"] = [str(p) for p in roots]
    report["ok"] = True
    write_json(run_dir / "image_list_report.json", report)
    print(f"list-images report: {rel(run_dir / 'image_list_report.json')}")
    return 0


def build_image_manifest(image_path: Path, label: str | None) -> dict[str, Any]:
    if not image_path.exists():
        raise SystemExit(f"Image path does not exist: {image_path}")

    source_disk = str(cfg_get("source.disk"))
    efi_partition = str(cfg_get("source.efi_partition"))
    root_partition = str(cfg_get("source.root_partition"))
    lsblk_payload = get_lsblk()
    minimum_target_bytes, actual_source_size = minimum_restore_target_bytes(lsblk_payload)

    files = []
    if image_path.is_dir():
        for item in sorted(image_path.rglob("*")):
            if item.is_file():
                try:
                    st = item.stat()
                    files.append({
                        "path": str(item),
                        "relative_to_image": str(item.relative_to(image_path)),
                        "size_bytes": st.st_size,
                        "mtime_ns": st.st_mtime_ns,
                    })
                except OSError:
                    pass
    else:
        st = image_path.stat()
        files.append({
            "path": str(image_path),
            "relative_to_image": image_path.name,
            "size_bytes": st.st_size,
            "mtime_ns": st.st_mtime_ns,
        })

    return {
        "schema": "recovery.rescuezilla.image_manifest.v1",
        "created_at": utc_now(),
        "label": label or image_path.name,
        "image_path": str(image_path),
        "relative_image_path": rel(image_path),
        "kind": "directory" if image_path.is_dir() else "file",
        "size_bytes": directory_size(image_path) if image_path.is_dir() else file_size(image_path),
        "minimum_target_bytes": minimum_target_bytes,
        "source_disk_size_bytes": actual_source_size,
        "source": {
            "source_disk": source_disk,
            "efi_partition": efi_partition,
            "root_partition": root_partition,
            "expected_boot_mode": str(cfg_get("source.expected_boot_mode", "uefi")),
        },
        "integrity": {
            "owned_by": "04_integrity",
            "sha256_manifest_path": None,
            "b3sum_manifest_path": None,
        },
        "files": files,
    }


def cmd_write_image_manifest(run_dir_arg: str | None, opts: dict[str, str]) -> int:
    image_arg = opts.get("image_path")
    if not image_arg:
        raise SystemExit("write-image-manifest requires --image-path PATH")

    run_dir = make_run_dir("write-image-manifest", run_dir_arg)
    report = report_base("write-image-manifest", run_dir)
    image_path = resolve_project_path(image_arg)
    label = opts.get("label")

    try:
        manifest = build_image_manifest(image_path, label)
    except SystemExit as exc:
        report["failures"].append(str(exc))
        report["ok"] = False
        write_json(run_dir / "write_image_manifest_report.json", report)
        print(f"write-image-manifest report: {rel(run_dir / 'write_image_manifest_report.json')}")
        return 2

    manifest_output = opts.get("manifest_output")
    manifest_name = str(cfg_get("image_inventory.manifest_name", "rescuezilla_image_manifest.json"))
    write_to_image_dir = bool(cfg_get("image_inventory.write_manifest_to_image_dir", False))

    if manifest_output:
        manifest_path = resolve_project_path(manifest_output)
    elif write_to_image_dir and image_path.is_dir():
        manifest_path = image_path / manifest_name
    elif write_to_image_dir:
        manifest_path = image_path.with_suffix(image_path.suffix + ".manifest.json")
    else:
        manifest_path = run_dir / manifest_name

    write_json(manifest_path, manifest)
    report["image_manifest"] = manifest
    report["manifest_path"] = str(manifest_path)
    report["manifest_relative_path"] = rel(manifest_path)
    report["manifest_write_policy"] = {
        "explicit_manifest_output": bool(manifest_output),
        "write_manifest_to_image_dir": write_to_image_dir,
        "defaulted_to_run_dir": not manifest_output and not write_to_image_dir,
    }
    report["ok"] = True
    write_json(run_dir / "write_image_manifest_report.json", report)
    print(f"image manifest written: {rel(manifest_path)}")
    print(f"write-image-manifest report: {rel(run_dir / 'write_image_manifest_report.json')}")
    return 0


def load_json_file(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def cmd_validate_image_manifest(run_dir_arg: str | None, opts: dict[str, str]) -> int:
    manifest_arg = opts.get("manifest")
    if not manifest_arg:
        raise SystemExit("validate-image-manifest requires --manifest PATH")

    run_dir = make_run_dir("validate-image-manifest", run_dir_arg)
    report = report_base("validate-image-manifest", run_dir)
    manifest_path = resolve_project_path(manifest_arg)

    if not manifest_path.exists():
        report["failures"].append(f"Manifest not found: {manifest_path}")
        report["ok"] = False
        write_json(run_dir / "validate_image_manifest_report.json", report)
        print(f"validate-image-manifest report: {rel(run_dir / 'validate_image_manifest_report.json')}")
        return 2

    try:
        manifest = load_json_file(manifest_path)
    except Exception as exc:
        report["failures"].append(f"Could not parse manifest JSON: {exc}")
        report["ok"] = False
        write_json(run_dir / "validate_image_manifest_report.json", report)
        print(f"validate-image-manifest report: {rel(run_dir / 'validate_image_manifest_report.json')}")
        return 2

    required = ["schema", "image_path", "created_at", "minimum_target_bytes", "source"]
    for key in required:
        if key not in manifest:
            report["failures"].append(f"Manifest missing required key: {key}")

    if manifest.get("schema") != "recovery.rescuezilla.image_manifest.v1":
        report["failures"].append(f"Unexpected manifest schema: {manifest.get('schema')!r}")

    image_path = Path(str(manifest.get("image_path", "")))
    if not image_path.exists():
        report["warnings"].append(f"Image path recorded in manifest does not currently exist: {image_path}")
    else:
        current_size = directory_size(image_path) if image_path.is_dir() else file_size(image_path)
        manifest_size = manifest.get("size_bytes")
        if manifest_size is not None and current_size != manifest_size:
            report["warnings"].append(f"Image size differs from manifest: manifest={manifest_size}, current={current_size}")

    report["image_manifest"] = manifest
    report["manifest_path"] = str(manifest_path)
    report["ok"] = not report["failures"]
    write_json(run_dir / "validate_image_manifest_report.json", report)
    print(f"validate-image-manifest report: {rel(run_dir / 'validate_image_manifest_report.json')}")
    return 0 if report["ok"] else 2


def target_device_report(target: Path) -> dict[str, Any]:
    result = run_cmd([LSBLK, "-J", "-b", "-O", str(target)])
    parsed = parse_json_stdout(result)
    dev = parsed["blockdevices"][0] if parsed and parsed.get("blockdevices") else {}
    return {"path": str(target), "exists": target.exists(), "lsblk": dev, "command": scrub_command(result)}


def cmd_assert_target_size(run_dir_arg: str | None, opts: dict[str, str]) -> int:
    target_arg = opts.get("target_device")
    if not target_arg:
        raise SystemExit("assert-target-size requires --target-device PATH")

    run_dir = make_run_dir("assert-target-size", run_dir_arg)
    report = report_base("assert-target-size", run_dir)
    target = Path(target_arg)

    lsblk_payload = get_lsblk()
    required_bytes, actual_source_size = minimum_restore_target_bytes(lsblk_payload)
    manifest_path = None

    if opts.get("manifest"):
        manifest_path = resolve_project_path(opts["manifest"])
        if not manifest_path.exists():
            report["failures"].append(f"Manifest not found: {manifest_path}")
        else:
            try:
                manifest = load_json_file(manifest_path)
                manifest_required_bytes = int(manifest.get("minimum_target_bytes", required_bytes))
                required_bytes = max(required_bytes, manifest_required_bytes)
                report["image_manifest"] = manifest
                report["manifest_minimum_target_bytes"] = manifest_required_bytes
            except Exception as exc:
                report["failures"].append(f"Could not parse manifest: {exc}")

    root_disk = root_disk_from_lsblk(lsblk_payload)
    configured_source_disk = str(cfg_get("source.disk"))
    target_canonical = canonical_device_path(target)
    root_canonical = canonical_device_path(root_disk)
    configured_source_canonical = canonical_device_path(configured_source_disk)
    target_report = target_device_report(target)
    target_lsblk = target_report.get("lsblk", {})
    target_size = target_lsblk.get("size")
    target_type = str(target_lsblk.get("type") or "")

    if target_canonical in {root_canonical, configured_source_canonical}:
        report["failures"].append(
            f"Refusing restore target because it is the current root/source disk: {target} -> {target_canonical}"
        )

    if target_type and target_type != "disk":
        report["failures"].append(f"Restore target must be a whole disk, not type {target_type!r}: {target}")

    if not target_report["exists"]:
        report["failures"].append(f"Target device does not exist: {target}")

    try:
        target_size_int = int(target_size)
    except (TypeError, ValueError):
        target_size_int = None

    if target_size_int is None:
        report["failures"].append(f"Could not determine target size for {target}")
    elif target_size_int < required_bytes:
        report["failures"].append(f"Target size {target_size_int} is below required minimum {required_bytes}")

    report["target_size"] = {
        "target_device": str(target),
        "target_canonical_path": target_canonical,
        "target_size_bytes": target_size_int,
        "required_bytes": required_bytes,
        "actual_source_disk_size_bytes": actual_source_size,
        "target_type": target_type,
        "root_disk": root_disk,
        "root_disk_canonical_path": root_canonical,
        "configured_source_disk": configured_source_disk,
        "configured_source_disk_canonical_path": configured_source_canonical,
        "manifest_path": str(manifest_path) if manifest_path else None,
        "target": target_report,
    }
    report["ok"] = not report["failures"]
    write_json(run_dir / "assert_target_size_report.json", report)
    print(f"assert-target-size report: {rel(run_dir / 'assert_target_size_report.json')}")
    return 0 if report["ok"] else 2


def parse_args(argv: list[str]) -> tuple[str, str | None, dict[str, str]]:
    if not argv or argv[0] in {"help", "-h", "--help"}:
        print_usage()
        raise SystemExit(0)

    command = argv[0]
    run_dir = None
    opts: dict[str, str] = {}
    i = 1
    while i < len(argv):
        token = argv[i]
        if token == "--run-dir":
            i += 1
            if i >= len(argv):
                raise SystemExit("--run-dir requires a value")
            run_dir = argv[i]
        elif token == "--image-path":
            i += 1
            if i >= len(argv):
                raise SystemExit("--image-path requires a value")
            opts["image_path"] = argv[i]
        elif token == "--manifest":
            i += 1
            if i >= len(argv):
                raise SystemExit("--manifest requires a value")
            opts["manifest"] = argv[i]
        elif token == "--manifest-output":
            i += 1
            if i >= len(argv):
                raise SystemExit("--manifest-output requires a value")
            opts["manifest_output"] = argv[i]
        elif token == "--target-device":
            i += 1
            if i >= len(argv):
                raise SystemExit("--target-device requires a value")
            opts["target_device"] = argv[i]
        elif token == "--label":
            i += 1
            if i >= len(argv):
                raise SystemExit("--label requires a value")
            opts["label"] = argv[i]
        else:
            raise SystemExit(f"Unknown option: {token}")
        i += 1
    return command, run_dir, opts


def main() -> int:
    command, run_dir, opts = parse_args(ARGS)

    if command == "verify-iso":
        return cmd_verify_iso(run_dir)
    if command == "list-usb-candidates":
        return cmd_list_usb_candidates(run_dir)
    if command == "capture-source-layout":
        return cmd_capture_source_layout(run_dir)
    if command == "capture-uefi":
        return cmd_capture_uefi(run_dir)
    if command == "write-image-manifest":
        return cmd_write_image_manifest(run_dir, opts)
    if command == "list-images":
        return cmd_list_images(run_dir)
    if command == "validate-image-manifest":
        return cmd_validate_image_manifest(run_dir, opts)
    if command == "assert-target-size":
        return cmd_assert_target_size(run_dir, opts)

    print_usage()
    raise SystemExit(f"Unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
PY