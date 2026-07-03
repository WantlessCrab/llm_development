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
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "17_libvirt.sh"
SCHEMA_NAME = "recovery.libvirt.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "libvirt",
        "verified_virsh_version": "10.0.0",
        "verified_qemu_img_version": "8.2.2",
        "verified_virt_manager_version": "4.1.0",
        "verified_swtpm_version": "0.7.3",
        "verified_virt_viewer": "installed",
        "verified_virt_install": "installed",
        "verified_swtpm_setup": "installed",
        "layer": "17_future_windows_vm_host_side_recovery",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/17_libvirt",
        "generated_root": "state/generated/17_libvirt",
    },
    "commands": {
        "virsh": "/usr/bin/virsh",
        "qemu_img": "/usr/bin/qemu-img",
        "virt_manager": "/usr/bin/virt-manager",
        "virt_viewer": "/usr/bin/virt-viewer",
        "virt_install": "/usr/bin/virt-install",
        "swtpm": "/usr/bin/swtpm",
        "swtpm_setup": "/usr/bin/swtpm_setup",
        "systemctl": "/usr/bin/systemctl",
        "getent": "/usr/bin/getent",
        "id": "/usr/bin/id",
        "find": "/usr/bin/find",
    },
    "libvirt": {
        "uri": "qemu:///system",
        "expected_default_network": "default",
        "expected_default_bridge": "virbr0",
        "known_disk_roots": "/var/lib/libvirt/images;/home/wantless/PycharmProjects/automation/recovery/state/vm_cold_copies",
        "allowed_disk_extensions": ".qcow2;.raw;.img;.vmdk;.vdi",
        "ovmf_reference_roots": "/usr/share/OVMF;/usr/share/ovmf;/var/lib/libvirt/qemu/nvram",
        "nvram_roots": "/var/lib/libvirt/qemu/nvram;/etc/libvirt/qemu/nvram",
        "swtpm_roots": "/var/lib/libvirt/swtpm;/var/lib/swtpm",
        "virtio_iso_candidates": "/usr/share/virtio-win/virtio-win.iso;/var/lib/libvirt/images/virtio-win.iso;/home/wantless/Downloads/virtio-win.iso",
        "service_units": "libvirtd.service;libvirtd.socket;libvirtd-ro.socket;libvirtd-admin.socket;virtqemud.service;virtqemud.socket;virtlogd.service;virtlogd.socket;virtlockd.service;virtlockd.socket;libvirt-guests.service;qemu-kvm.service;run-qemu.mount;machines.target",
        "qemu_img_check_formats": "qcow2;qed;vdi;vmdk",
        "critical_groups": "libvirt;kvm;libvirt-qemu;swtpm",
        "critical_users": "swtpm;libvirt-qemu",
        "max_disk_scan_entries": 5000,
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "libvirt_report.json",
        "generated_restore_plan_name": "libvirt_vm_restore_plan.md",
        "generated_define_plan_name": "libvirt_define_domain_plan.md",
        "generated_smoke_plan_name": "libvirt_vm_smoke_plan.md",
        "generated_script_mode": "0600",
        "fail_if_virsh_missing": True,
        "fail_if_qemu_img_missing": True,
        "fail_if_system_uri_unavailable": True,
        "fail_if_qemu_img_check_nonzero": True,
        "fail_if_live_disk_copy": True,
        "require_inactive_domain_for_disk_check": True,
        "qemu_img_check_runs_readonly": True,
        "qemu_img_check_forbid_repair": True,
        "copy_domain_xml": True,
        "copy_network_xml": True,
        "copy_pool_xml": True,
        "secret_values_never_read": True,
        "capture_secret_xml_only": True,
        "nvram_payload_not_copied": True,
        "swtpm_payload_not_copied": True,
        "disk_payload_not_copied": True,
        "rsync_cold_copy_owner": "Row 05 rsync",
        "in_guest_windows_backup_owner": "out of Row 17 scope",
        "bitlocker_tpm_warning_required": True,
        "no_mutating_virsh_commands": True,
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
    path = PROJECT_ROOT / "configs" / "17_libvirt.yaml"
    return deep_merge(DEFAULT_CONFIG, parse_simple_yaml(path)) if path.exists() else deepcopy(DEFAULT_CONFIG)


CFG = load_config()


def cfg_get(path: str, default: Any = None) -> Any:
    cur: Any = CFG
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def boolish(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def split_semicolon(value: Any) -> list[str]:
    return [part.strip() for part in str(value or "").split(";") if part.strip()]


def cmd_path(name: str) -> str:
    value = str(cfg_get(f"commands.{name}", name))
    if Path(value).exists() or shutil.which(value):
        return value
    return value if "/" in value else (shutil.which(value) or value)


VIRSH = cmd_path("virsh")
QEMU_IMG = cmd_path("qemu_img")
VIRT_MANAGER = cmd_path("virt_manager")
VIRT_VIEWER = cmd_path("virt_viewer")
VIRT_INSTALL = cmd_path("virt_install")
SWTPM = cmd_path("swtpm")
SWTPM_SETUP = cmd_path("swtpm_setup")
SYSTEMCTL = cmd_path("systemctl")
GETENT = cmd_path("getent")
ID_CMD = cmd_path("id")


def uri() -> str:
    return str(cfg_get("libvirt.uri", "qemu:///system"))


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


def safe_name(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value).strip())
    return cleaned.strip("_") or "unnamed"


def shell_join(argv: list[str]) -> str:
    return " ".join(shlex.quote(str(part)) for part in argv)


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/17_libvirt")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "17_libvirt.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "17_libvirt.config.snapshot.yaml")
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def sha256_file(path: Path) -> str | None:
    try:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        return h.hexdigest()
    except OSError:
        return None


def file_record(path: Path, *, include_hash: bool = True, payload_copied: bool = False) -> dict[str, Any]:
    try:
        st = path.lstat()
    except OSError as exc:
        return {"path": str(path), "exists": False, "error": str(exc), "payload_copied": False}
    rec: dict[str, Any] = {
        "path": str(path),
        "exists": path.exists(),
        "is_file": path.is_file(),
        "is_dir": path.is_dir(),
        "is_symlink": path.is_symlink(),
        "mode": oct(stat.S_IMODE(st.st_mode)),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "size_bytes": st.st_size,
        "mtime_ns": st.st_mtime_ns,
        "payload_copied": payload_copied,
    }
    if path.is_symlink():
        try:
            rec["symlink_target"] = os.readlink(path)
            rec["target_resolved"] = str(path.resolve(strict=False))
            rec["target_exists"] = path.resolve(strict=False).exists()
        except OSError as exc:
            rec["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink():
        rec["sha256"] = sha256_file(path)
    return rec


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "libvirt",
            "script": SCRIPT_NAME,
            "virsh_path": VIRSH,
            "qemu_img_path": QEMU_IMG,
            "libvirt_uri": uri(),
            "virsh_version": None,
            "qemu_img_version": None,
            "virt_manager_version": None,
            "swtpm_version": None,
            "virt_viewer_version": None,
            "virt_install_version": None,
            "swtpm_setup_version": None,
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
    report_path = run_dir / str(cfg_get("policy.report_name", "libvirt_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True)
    safe = safe_name(label)
    run_dir = resolve_path(report["run_dir"])
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    record = {"argv": argv[:], "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr}
    report["commands"].append(record)
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {shell_join(argv)} :: {proc.stderr.strip()}")
    return {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "record": record}


def virsh(args: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    return run_cmd([VIRSH, "-c", uri(), *args], report, label=label, check=check)


def qemu_img(args: list[str], report: dict[str, Any], *, label: str, check: bool = False) -> dict[str, Any]:
    return run_cmd([QEMU_IMG, *args], report, label=label, check=check)


def parse_json_or_text(text: str) -> Any:
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


def parse_table(stdout: str) -> list[dict[str, str]]:
    lines = [line.rstrip() for line in stdout.splitlines() if line.strip()]
    if len(lines) < 2:
        return []
    data_lines = [line for line in lines if not re.fullmatch(r"[-+\s]+", line.strip())]
    if len(data_lines) <= 1:
        return []
    headers = re.split(r"\s{2,}", data_lines[0].strip())
    rows = []
    for line in data_lines[1:]:
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) == len(headers):
            rows.append({headers[i]: parts[i] for i in range(len(headers))})
        elif parts:
            rows.append({"raw": line})
    return rows


def set_versions(report: dict[str, Any]) -> None:
    if command_exists(VIRSH):
        result = run_cmd([VIRSH, "--version"], report, label="virsh_version")
        report["tool"]["virsh_version"] = result["stdout"].strip() or result["stderr"].strip()
    if command_exists(QEMU_IMG):
        result = run_cmd([QEMU_IMG, "--version"], report, label="qemu_img_version")
        report["tool"]["qemu_img_version"] = (result["stdout"] or result["stderr"]).splitlines()[0].strip() if (result["stdout"] or result["stderr"]) else None
    if command_exists(VIRT_MANAGER):
        result = run_cmd([VIRT_MANAGER, "--version"], report, label="virt_manager_version")
        report["tool"]["virt_manager_version"] = result["stdout"].strip() or result["stderr"].strip()
    if command_exists(SWTPM):
        result = run_cmd([SWTPM, "--version"], report, label="swtpm_version")
        report["tool"]["swtpm_version"] = (result["stdout"] or result["stderr"]).splitlines()[0].strip() if (result["stdout"] or result["stderr"]) else None
    if command_exists(VIRT_VIEWER):
        result = run_cmd([VIRT_VIEWER, "--version"], report, label="virt_viewer_version")
        report["tool"]["virt_viewer_version"] = (result["stdout"] or result["stderr"]).splitlines()[0].strip() if (result["stdout"] or result["stderr"]) else None
    if command_exists(VIRT_INSTALL):
        result = run_cmd([VIRT_INSTALL, "--version"], report, label="virt_install_version")
        report["tool"]["virt_install_version"] = (result["stdout"] or result["stderr"]).splitlines()[0].strip() if (result["stdout"] or result["stderr"]) else None
    if command_exists(SWTPM_SETUP):
        result = run_cmd([SWTPM_SETUP, "--version"], report, label="swtpm_setup_version")
        report["tool"]["swtpm_setup_version"] = (result["stdout"] or result["stderr"]).splitlines()[0].strip() if (result["stdout"] or result["stderr"]) else None


def preflight(report: dict[str, Any], *, require_uri: bool = True, require_qemu_img: bool = False) -> None:
    if not command_exists(VIRSH):
        msg = f"virsh command not found at configured path: {VIRSH}"
        if boolish(cfg_get("policy.fail_if_virsh_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    if require_qemu_img and not command_exists(QEMU_IMG):
        msg = f"qemu-img command not found at configured path: {QEMU_IMG}"
        if boolish(cfg_get("policy.fail_if_qemu_img_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
    set_versions(report)
    if require_uri and command_exists(VIRSH):
        result = virsh(["uri"], report, label="virsh_uri_probe")
        if result["returncode"] != 0 or result["stdout"].strip() != uri():
            msg = f"libvirt system URI unavailable or unexpected: expected {uri()} got {result['stdout'].strip()!r}"
            if boolish(cfg_get("policy.fail_if_system_uri_unavailable", True)):
                report["failures"].append(msg)
            else:
                report["warnings"].append(msg)


def service_state(report: dict[str, Any]) -> list[dict[str, Any]]:
    records = []
    for unit in split_semicolon(cfg_get("libvirt.service_units", "")):
        rec: dict[str, Any] = {"unit": unit}
        if command_exists(SYSTEMCTL):
            for label, args in {
                "is_enabled": ["is-enabled", unit],
                "is_active": ["is-active", unit],
                "show": ["show", unit, "-p", "Id", "-p", "LoadState", "-p", "ActiveState", "-p", "SubState", "-p", "FragmentPath", "-p", "UnitFileState"],
            }.items():
                result = run_cmd([SYSTEMCTL, *args], report, label=f"systemctl_{safe_name(unit)}_{label}")
                rec[label] = {"returncode": result["returncode"], "stdout": result["stdout"].strip(), "stderr": result["stderr"].strip()}
        records.append(rec)
    return records


def group_state(report: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {"id": None, "groups": [], "passwd": []}
    if command_exists(ID_CMD):
        result = run_cmd([ID_CMD], report, label="current_user_id")
        payload["id"] = result["stdout"].strip()
    if command_exists(GETENT):
        for group in split_semicolon(cfg_get("libvirt.critical_groups", "")):
            result = run_cmd([GETENT, "group", group], report, label=f"getent_group_{safe_name(group)}")
            payload["groups"].append({"group": group, "returncode": result["returncode"], "record": result["stdout"].strip()})
        for user in split_semicolon(cfg_get("libvirt.critical_users", "swtpm;libvirt-qemu")):
            result = run_cmd([GETENT, "passwd", user], report, label=f"getent_passwd_{safe_name(user)}")
            payload["passwd"].append({"user": user, "returncode": result["returncode"], "record": result["stdout"].strip()})
    return payload


def domain_names(report: dict[str, Any], *, include_inactive: bool = True) -> list[str]:
    args = ["list", "--name"]
    if include_inactive:
        args.append("--all")
    result = virsh(args, report, label="domain_names")
    if result["returncode"] != 0:
        report["warnings"].append("could not list libvirt domains")
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def network_names(report: dict[str, Any]) -> list[str]:
    result = virsh(["net-list", "--all", "--name"], report, label="network_names")
    if result["returncode"] != 0:
        report["warnings"].append("could not list libvirt networks")
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def pool_names(report: dict[str, Any]) -> list[str]:
    result = virsh(["pool-list", "--all", "--name"], report, label="pool_names")
    if result["returncode"] != 0:
        report["warnings"].append("could not list libvirt storage pools")
        return []
    return sorted(set(line.strip() for line in result["stdout"].splitlines() if line.strip()))


def parse_xml(text: str) -> ET.Element | None:
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        return None


def elem_text(root: ET.Element | None, path: str) -> str | None:
    if root is None:
        return None
    elem = root.find(path)
    return elem.text.strip() if elem is not None and elem.text else None


def domain_state(name: str, report: dict[str, Any]) -> str | None:
    result = virsh(["domstate", name], report, label=f"domstate_{safe_name(name)}")
    return result["stdout"].strip() if result["returncode"] == 0 else None


def domain_autostart(name: str, report: dict[str, Any]) -> str | None:
    result = virsh(["dominfo", name], report, label=f"dominfo_{safe_name(name)}")
    if result["returncode"] != 0:
        return None
    for line in result["stdout"].splitlines():
        if line.lower().startswith("autostart:"):
            return line.split(":", 1)[1].strip()
    return None


def summarize_domain_xml(xml_text: str, *, domain_name: str | None = None) -> dict[str, Any]:
    root = parse_xml(xml_text)
    if root is None:
        return {"domain": domain_name, "parse_error": True}
    devices = root.find("devices")
    disks = []
    nics = []
    graphics = []
    tpm = []
    hostdevs = []
    filesystems = []
    controllers = []
    redirs = []
    sounds = []
    videos = []
    inputs = []
    boot_orders = []
    if devices is not None:
        for disk in devices.findall("disk"):
            rec = {
                "type": disk.get("type"),
                "device": disk.get("device"),
                "driver": disk.find("driver").attrib if disk.find("driver") is not None else {},
                "source": {},
                "target": disk.find("target").attrib if disk.find("target") is not None else {},
                "readonly": disk.find("readonly") is not None,
                "shareable": disk.find("shareable") is not None,
                "boot_order": None,
            }
            source = disk.find("source")
            if source is not None:
                rec["source"] = dict(source.attrib)
            boot = disk.find("boot")
            if boot is not None and boot.get("order"):
                rec["boot_order"] = boot.get("order")
                boot_orders.append({"device": "disk", "target": rec["target"], "order": boot.get("order")})
            disks.append(rec)
        for iface in devices.findall("interface"):
            boot = iface.find("boot")
            rec = {
                "type": iface.get("type"),
                "mac": iface.find("mac").attrib if iface.find("mac") is not None else {},
                "source": iface.find("source").attrib if iface.find("source") is not None else {},
                "model": iface.find("model").attrib if iface.find("model") is not None else {},
                "boot_order": boot.get("order") if boot is not None else None,
            }
            if rec["boot_order"]:
                boot_orders.append({"device": "interface", "mac": rec["mac"], "order": rec["boot_order"]})
            nics.append(rec)
        for g in devices.findall("graphics"):
            graphics.append(dict(g.attrib))
        for item in devices.findall("tpm"):
            tpm.append({
                "model": item.get("model"),
                "backend": item.find("backend").attrib if item.find("backend") is not None else {},
            })
        for item in devices.findall("hostdev"):
            hostdevs.append(dict(item.attrib))
        for item in devices.findall("filesystem"):
            filesystems.append({"type": item.get("type"), "source": item.find("source").attrib if item.find("source") is not None else {}, "target": item.find("target").attrib if item.find("target") is not None else {}})
        for item in devices.findall("controller"):
            controllers.append(dict(item.attrib))
        for item in devices.findall("redirdev"):
            redirs.append(dict(item.attrib))
        for item in devices.findall("sound"):
            sounds.append(dict(item.attrib))
        for item in devices.findall("video"):
            model = item.find("model")
            videos.append(model.attrib if model is not None else dict(item.attrib))
        for item in devices.findall("input"):
            inputs.append(dict(item.attrib))
    loader = root.find("./os/loader")
    cpu = root.find("cpu")
    return {
        "name": elem_text(root, "name") or domain_name,
        "uuid": elem_text(root, "uuid"),
        "memory": root.find("memory").attrib | {"value": elem_text(root, "memory")} if root.find("memory") is not None else None,
        "current_memory": root.find("currentMemory").attrib | {"value": elem_text(root, "currentMemory")} if root.find("currentMemory") is not None else None,
        "vcpu": root.find("vcpu").attrib | {"value": elem_text(root, "vcpu")} if root.find("vcpu") is not None else None,
        "cpu": cpu.attrib | {"model": elem_text(cpu, "model")} if cpu is not None else None,
        "os": {
            "type": root.find("./os/type").attrib | {"value": elem_text(root, "./os/type")} if root.find("./os/type") is not None else None,
            "loader": loader.attrib | {"value": loader.text.strip() if loader is not None and loader.text else None} if loader is not None else None,
            "nvram": elem_text(root, "./os/nvram"),
            "firmware": root.find("./os").get("firmware") if root.find("./os") is not None else None,
            "bootmenu": root.find("./os/bootmenu").attrib if root.find("./os/bootmenu") is not None else None,
        },
        "features": [child.tag for child in root.findall("./features/*")],
        "clock": root.find("clock").attrib if root.find("clock") is not None else None,
        "disks": disks,
        "nics": nics,
        "graphics": graphics,
        "tpm": tpm,
        "hostdevs": hostdevs,
        "filesystems": filesystems,
        "controllers": controllers,
        "redirdevs": redirs,
        "sounds": sounds,
        "videos": videos,
        "inputs": inputs,
        "boot_orders": boot_orders,
        "bitlocker_tpm_warning": "Windows BitLocker recovery can be triggered by TPM, Secure Boot, firmware, machine type, disk identity, or boot-order changes. Keep recovery keys outside this row.",
    }


def dump_domain_xml(name: str, report: dict[str, Any], xml_dir: Path) -> dict[str, Any]:
    result = virsh(["dumpxml", "--inactive", name], report, label=f"dumpxml_inactive_{safe_name(name)}")
    if result["returncode"] != 0:
        result = virsh(["dumpxml", name], report, label=f"dumpxml_active_{safe_name(name)}")
    if result["returncode"] != 0:
        return {"domain": name, "returncode": result["returncode"], "error": result["stderr"].strip()}
    path = xml_dir / f"{safe_name(name)}.xml"
    write_text(path, result["stdout"])
    summary = summarize_domain_xml(result["stdout"], domain_name=name)
    return {"domain": name, "xml_path": rel(path), "returncode": result["returncode"], "summary": summary}


def disk_paths_from_domain_summary(summary: dict[str, Any]) -> list[dict[str, Any]]:
    out = []
    for disk in summary.get("disks", []) or []:
        source = disk.get("source", {}) or {}
        for key in ("file", "dev", "name", "volume"):
            if source.get(key):
                out.append({"domain": summary.get("name"), "path": source[key], "source_key": key, "disk": disk})
    return out


def domain_xml_records(report: dict[str, Any], run_dir: Path) -> list[dict[str, Any]]:
    xml_dir = run_dir / "domain_xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    records = []
    for name in domain_names(report):
        rec = dump_domain_xml(name, report, xml_dir)
        rec["state"] = domain_state(name, report)
        rec["autostart"] = domain_autostart(name, report)
        records.append(rec)
        if rec.get("xml_path"):
            output_file(report, resolve_path(rec["xml_path"]), "xml", f"domain_xml_{name}")
    return records


def discover_domain_disks(report: dict[str, Any], run_dir: Path | None = None) -> list[dict[str, Any]]:
    tmp_dir = run_dir or make_run_dir("tmp-domain-disks")
    records = domain_xml_records(report, tmp_dir)
    disks: list[dict[str, Any]] = []
    for rec in records:
        summary = rec.get("summary", {})
        disks.extend(disk_paths_from_domain_summary(summary))
    return disks


def scan_known_disk_roots(report: dict[str, Any]) -> list[dict[str, Any]]:
    allowed = tuple(split_semicolon(cfg_get("libvirt.allowed_disk_extensions", ".qcow2;.raw;.img;.vmdk;.vdi")))
    max_entries = int(cfg_get("libvirt.max_disk_scan_entries", 5000))
    records: list[dict[str, Any]] = []
    count = 0
    for raw_root in split_semicolon(cfg_get("libvirt.known_disk_roots", "")):
        root = Path(raw_root).expanduser()
        if not root.exists():
            records.append({"root": str(root), "exists": False})
            continue
        if not root.is_dir():
            records.append({"root": str(root), "exists": True, "is_dir": False})
            continue
        for dirpath, dirnames, filenames in os.walk(root, topdown=True, onerror=lambda exc: records.append({"root": str(root), "walk_error": str(exc)})):
            for filename in sorted(filenames):
                if count >= max_entries:
                    records.append({"root": str(root), "truncated": True, "max_entries": max_entries})
                    return records
                item = Path(dirpath) / filename
                if item.name.endswith(allowed):
                    records.append({"path": str(item), "root": str(root), "file": file_record(item, include_hash=False), "source": "known_disk_root_scan"})
                    count += 1
    return records


def normalize_disk_path(value: str) -> str:
    if not value:
        return value
    if value.startswith("/"):
        return str(Path(value).resolve())
    return value

def domain_state_blocks_disk_operations(state: str | None) -> bool:
    s = str(state or "").strip().lower()
    if not s:
        return False
    unsafe_tokens = (
        "running",
        "paused",
        "pmsuspended",
        "in shutdown",
        "blocked",
        "crashed",
    )
    return any(token in s for token in unsafe_tokens)



def running_domain_disk_users(report: dict[str, Any]) -> list[dict[str, Any]]:
    users = []
    for name in domain_names(report):
        state = domain_state(name, report) or ""
        if not domain_state_blocks_disk_operations(state):
            continue
        run_dir = make_run_dir(f"tmp-running-domain-{safe_name(name)}")
        rec = dump_domain_xml(name, report, run_dir / "domain_xml")
        for disk in disk_paths_from_domain_summary(rec.get("summary", {})):
            users.append({"domain": name, "state": state, "path": normalize_disk_path(disk.get("path", "")), "disk": disk})
    return users


def live_disk_conflicts(paths: list[str], report: dict[str, Any]) -> list[dict[str, Any]]:
    wanted = {normalize_disk_path(p) for p in paths if p}
    conflicts = []
    for user in running_domain_disk_users(report):
        if user.get("path") in wanted:
            conflicts.append(user)
    return conflicts


def qemu_img_info_for_path(path: Path, report: dict[str, Any]) -> dict[str, Any]:
    rec = {"path": str(path), "file": file_record(path, include_hash=False)}
    if not path.exists():
        rec["exists"] = False
        return rec
    result = qemu_img(["info", "--output=json", str(path)], report, label=f"qemu_img_info_{safe_name(str(path))}")
    rec["returncode"] = result["returncode"]
    rec["info"] = parse_json_or_text(result["stdout"]) if result["stdout"].strip() else {}
    if result["returncode"] != 0:
        rec["error"] = result["stderr"].strip()
        report["warnings"].append(f"qemu-img info failed for {path}")
    return rec


def get_disk_candidates(report: dict[str, Any], run_dir: Path, explicit_disk: str | None = None) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    if explicit_disk:
        candidates.append({"path": str(Path(explicit_disk).expanduser()), "source": "explicit"})
    for disk in discover_domain_disks(report, run_dir):
        p = disk.get("path")
        if p:
            candidates.append({"path": p, "source": "domain_xml", "domain": disk.get("domain"), "disk": disk.get("disk")})
    candidates.extend(scan_known_disk_roots(report))
    seen = set()
    unique = []
    for item in candidates:
        p = item.get("path")
        if not p:
            continue
        norm = normalize_disk_path(str(Path(str(p)).expanduser())) if str(p).startswith(("~", "/")) else str(p)
        if norm in seen:
            continue
        seen.add(norm)
        item["normalized_path"] = norm
        unique.append(item)
    return unique


def cmd_discover_system(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("discover-system")
    report = report_base("discover-system", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=False, require_qemu_img=True)
    facts: dict[str, Any] = {
        "command_paths": {
            "virsh": VIRSH,
            "qemu_img": QEMU_IMG,
            "virt_manager": VIRT_MANAGER,
            "virt_viewer": VIRT_VIEWER,
            "virt_install": VIRT_INSTALL,
            "swtpm": SWTPM,
            "swtpm_setup": SWTPM_SETUP,
        },
        "versions": report["tool"],
        "uri": None,
        "capabilities": None,
        "nodeinfo": None,
        "services": service_state(report),
        "groups": group_state(report),
        "reference_paths": {
            "ovmf": [file_record(Path(p).expanduser(), include_hash=False) for p in split_semicolon(cfg_get("libvirt.ovmf_reference_roots", ""))],
            "nvram": [file_record(Path(p).expanduser(), include_hash=False) for p in split_semicolon(cfg_get("libvirt.nvram_roots", ""))],
            "swtpm": [file_record(Path(p).expanduser(), include_hash=False) for p in split_semicolon(cfg_get("libvirt.swtpm_roots", ""))],
            "virtio_iso": [file_record(Path(p).expanduser(), include_hash=True) for p in split_semicolon(cfg_get("libvirt.virtio_iso_candidates", ""))],
        },
    }
    if command_exists(VIRSH):
        uri_result = virsh(["uri"], report, label="virsh_uri")
        facts["uri"] = uri_result["stdout"].strip()
        node = virsh(["nodeinfo"], report, label="virsh_nodeinfo")
        facts["nodeinfo"] = node["record"]["stdout_path"]
        caps = virsh(["capabilities"], report, label="virsh_capabilities")
        if caps["returncode"] == 0:
            caps_path = run_dir / "libvirt_capabilities.xml"
            write_text(caps_path, caps["stdout"])
            output_file(report, caps_path, "xml", "libvirt_capabilities")
            facts["capabilities"] = rel(caps_path)
        domcaps = virsh(["domcapabilities"], report, label="virsh_domcapabilities")
        if domcaps["returncode"] == 0:
            domcaps_path = run_dir / "libvirt_domcapabilities.xml"
            write_text(domcaps_path, domcaps["stdout"])
            output_file(report, domcaps_path, "xml", "libvirt_domcapabilities")
            facts["domcapabilities"] = rel(domcaps_path)
    path = run_dir / "libvirt_system_discovery.json"
    write_json(path, facts)
    report["libvirt"] = {"discovery": rel(path), "uri": facts["uri"]}
    output_file(report, path, "json", "libvirt_system_discovery")
    return finalize_report(report, run_dir)


def cmd_capture_inventory(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-inventory")
    report = report_base("capture-inventory", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    inventory: dict[str, Any] = {}
    for label, command in {
        "domains": ["list", "--all"],
        "domains_name": ["list", "--all", "--name"],
        "networks": ["net-list", "--all"],
        "networks_name": ["net-list", "--all", "--name"],
        "pools": ["pool-list", "--all"],
        "pools_name": ["pool-list", "--all", "--name"],
        "secrets": ["secret-list"],
        "interfaces": ["iface-list", "--all"],
    }.items():
        result = virsh(command, report, label=f"inventory_{label}")
        inventory[label] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"], "rows": parse_table(result["stdout"])}
    default_network = str(cfg_get("libvirt.expected_default_network", "default"))
    if default_network not in network_names(report):
        report["warnings"].append(f"expected default libvirt network not found: {default_network}")
    path = run_dir / "libvirt_inventory.json"
    write_json(path, inventory)
    report["inventory"] = {"manifest": rel(path), "domain_count": len(domain_names(report)), "network_count": len(network_names(report)), "pool_count": len(pool_names(report))}
    output_file(report, path, "json", "libvirt_inventory")
    return finalize_report(report, run_dir)


def cmd_capture_domain_xml(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-domain-xml")
    report = report_base("capture-domain-xml", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    records = []
    all_names = domain_names(report)
    if args.domain and args.domain not in all_names:
        report["failures"].append(f"requested domain not found: {args.domain}")
        names = []
    else:
        names = [args.domain] if args.domain else all_names
    xml_dir = run_dir / "domain_xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    for name in names:
        rec = dump_domain_xml(name, report, xml_dir)
        rec["state"] = domain_state(name, report)
        rec["autostart"] = domain_autostart(name, report)
        records.append(rec)
        if rec.get("xml_path"):
            output_file(report, resolve_path(rec["xml_path"]), "xml", f"domain_xml_{safe_name(name)}")
    if not records:
        report["warnings"].append("no libvirt domains found; Row 17 is ready for future VM capture but no VM exists yet")
    manifest_path = run_dir / "libvirt_domain_xml_manifest.json"
    write_json(manifest_path, {"domains": records})
    report["domains"] = {"manifest": rel(manifest_path), "count": len(records)}
    output_file(report, manifest_path, "json", "libvirt_domain_xml_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_network_xml(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-network-xml")
    report = report_base("capture-network-xml", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    records = []
    xml_dir = run_dir / "network_xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    for name in network_names(report):
        result = virsh(["net-dumpxml", name], report, label=f"net_dumpxml_{safe_name(name)}")
        rec = {"network": name, "returncode": result["returncode"]}
        if result["returncode"] == 0:
            path = xml_dir / f"{safe_name(name)}.xml"
            write_text(path, result["stdout"])
            rec["xml_path"] = rel(path)
            root = parse_xml(result["stdout"])
            rec["summary"] = {
                "name": elem_text(root, "name"),
                "uuid": elem_text(root, "uuid"),
                "bridge": root.find("bridge").attrib if root is not None and root.find("bridge") is not None else {},
                "forward": root.find("forward").attrib if root is not None and root.find("forward") is not None else {},
                "ips": [item.attrib for item in root.findall("ip")] if root is not None else [],
            }
            output_file(report, path, "xml", f"network_xml_{safe_name(name)}")
        records.append(rec)
    manifest_path = run_dir / "libvirt_network_xml_manifest.json"
    write_json(manifest_path, {"networks": records})
    report["networks"] = {"manifest": rel(manifest_path), "count": len(records)}
    output_file(report, manifest_path, "json", "libvirt_network_xml_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_pool_xml(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-pool-xml")
    report = report_base("capture-pool-xml", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    records = []
    xml_dir = run_dir / "pool_xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    for name in pool_names(report):
        result = virsh(["pool-dumpxml", name], report, label=f"pool_dumpxml_{safe_name(name)}")
        rec = {"pool": name, "returncode": result["returncode"]}
        if result["returncode"] == 0:
            path = xml_dir / f"{safe_name(name)}.xml"
            write_text(path, result["stdout"])
            rec["xml_path"] = rel(path)
            root = parse_xml(result["stdout"])
            rec["summary"] = {
                "name": elem_text(root, "name"),
                "uuid": elem_text(root, "uuid"),
                "type": root.get("type") if root is not None else None,
                "target_path": elem_text(root, "./target/path"),
            }
            output_file(report, path, "xml", f"pool_xml_{safe_name(name)}")
        vol = virsh(["vol-list", "--pool", name, "--details"], report, label=f"pool_vol_list_{safe_name(name)}")
        rec["vol_list_returncode"] = vol["returncode"]
        rec["vol_list_stdout_path"] = vol["record"]["stdout_path"]
        records.append(rec)
    manifest_path = run_dir / "libvirt_pool_xml_manifest.json"
    write_json(manifest_path, {"pools": records})
    report["pools"] = {"manifest": rel(manifest_path), "count": len(records)}
    output_file(report, manifest_path, "json", "libvirt_pool_xml_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_secret_refs(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-secret-refs")
    report = report_base("capture-secret-refs", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    result = virsh(["secret-list"], report, label="secret_list")
    records = {"secret_list_stdout": result["record"]["stdout_path"], "secrets": [], "secret_values_read": False}
    xml_dir = run_dir / "secret_xml"
    xml_dir.mkdir(parents=True, exist_ok=True)
    for row in parse_table(result["stdout"]):
        uuid_value = row.get("UUID") or row.get("uuid")
        if not uuid_value or uuid_value == "-":
            continue
        dump = virsh(["secret-dumpxml", uuid_value], report, label=f"secret_dumpxml_{safe_name(uuid_value)}")
        rec = {"uuid": uuid_value, "returncode": dump["returncode"]}
        if dump["returncode"] == 0:
            path = xml_dir / f"{safe_name(uuid_value)}.xml"
            write_text(path, dump["stdout"])
            rec["xml_path"] = rel(path)
            output_file(report, path, "xml", f"secret_xml_{safe_name(uuid_value)}")
        records["secrets"].append(rec)
    manifest_path = run_dir / "libvirt_secret_refs_manifest.json"
    write_json(manifest_path, records)
    report["secrets"] = {"manifest": rel(manifest_path), "secret_count": len(records["secrets"]), "secret_values_read": False}
    output_file(report, manifest_path, "json", "libvirt_secret_refs_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_qemu_img_info(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-qemu-img-info")
    report = report_base("capture-qemu-img-info", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True, require_qemu_img=True)
    candidates = get_disk_candidates(report, run_dir, explicit_disk=args.disk)
    if getattr(args, "domain", None):
        names = set(domain_names(report))
        if args.domain not in names:
            report["failures"].append(f"requested domain not found: {args.domain}")
        candidates = [item for item in candidates if item.get("domain") == args.domain or item.get("candidate", {}).get("domain") == args.domain]
    records = []
    for item in candidates:
        p = item.get("normalized_path") or item.get("path")
        if not p or not str(p).startswith("/"):
            records.append({"candidate": item, "qemu_img_info_skipped": "non-filesystem disk source"})
            continue
        rec = qemu_img_info_for_path(Path(str(p)).expanduser(), report)
        rec["candidate"] = item
        records.append(rec)
    manifest_path = run_dir / "qemu_img_info_manifest.json"
    write_json(manifest_path, {"records": records, "disk_payload_copied": False, "payload_owner": cfg_get("policy.rsync_cold_copy_owner")})
    report["qemu_img"] = {"info_manifest": rel(manifest_path), "record_count": len(records)}
    output_file(report, manifest_path, "json", "qemu_img_info_manifest")
    return finalize_report(report, run_dir)


def cmd_run_qemu_img_check(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("run-qemu-img-check")
    report = report_base("run-qemu-img-check", run_dir)
    report["mode"] = "verify"
    preflight(report, require_uri=True, require_qemu_img=True)
    candidates = get_disk_candidates(report, run_dir, explicit_disk=args.disk)
    if args.domain:
        names = set(domain_names(report))
        if args.domain not in names:
            report["failures"].append(f"requested domain not found: {args.domain}")
        candidates = [item for item in candidates if item.get("domain") == args.domain or item.get("candidate", {}).get("domain") == args.domain]
    records: list[dict[str, Any]] = []
    paths = [str(item.get("normalized_path") or item.get("path")) for item in candidates if item.get("normalized_path") or item.get("path")]
    conflicts = live_disk_conflicts(paths, report)
    if conflicts and boolish(cfg_get("policy.fail_if_live_disk_copy", True)):
        report["failures"].append(f"refusing qemu-img check/copy-adjacent operation for disks used by active domains: {conflicts}")
    if report["failures"]:
        manifest_path = run_dir / "qemu_img_check_manifest.json"
        write_json(manifest_path, {"records": records, "live_disk_conflicts": conflicts})
        output_file(report, manifest_path, "json", "qemu_img_check_manifest")
        return finalize_report(report, run_dir)
    allowed_formats = set(split_semicolon(cfg_get("libvirt.qemu_img_check_formats", "qcow2;qed;vdi;vmdk")))
    for item in candidates:
        p = item.get("normalized_path") or item.get("path")
        if not p or not str(p).startswith("/"):
            records.append({"candidate": item, "qemu_img_check_skipped": "non-filesystem disk source"})
            continue
        path = Path(str(p)).expanduser()
        if not path.exists():
            records.append({"path": str(path), "exists": False})
            continue
        info = qemu_img_info_for_path(path, report)
        image_format = str((info.get("info") or {}).get("format") or "")
        if image_format and image_format not in allowed_formats:
            records.append({
                "path": str(path),
                "candidate": item,
                "qemu_img_info": info,
                "qemu_img_check_skipped": f"format_not_in_policy:{image_format}",
                "allowed_formats": sorted(allowed_formats),
                "readonly_check": True,
                "repair_used": False,
            })
            continue
        args_list = ["check", "--output=json"]
        if image_format:
            args_list.extend(["-f", image_format])
        args_list.append(str(path))
        result = qemu_img(args_list, report, label=f"qemu_img_check_{safe_name(str(path))}")
        rec = {"path": str(path), "candidate": item, "returncode": result["returncode"], "stdout": parse_json_or_text(result["stdout"]) if result["stdout"].strip() else {}, "stderr": result["stderr"].strip(), "qemu_img_info": info, "format": image_format or None, "readonly_check": True, "repair_used": False}
        if result["returncode"] != 0 and boolish(cfg_get("policy.fail_if_qemu_img_check_nonzero", True)):
            report["failures"].append(f"qemu-img check returned nonzero for {path}: {result['returncode']}")
        records.append(rec)
    manifest_path = run_dir / "qemu_img_check_manifest.json"
    write_json(manifest_path, {"records": records, "live_disk_conflicts": conflicts})
    report["qemu_img"] = {"check_manifest": rel(manifest_path), "record_count": len(records), "live_conflict_count": len(conflicts)}
    output_file(report, manifest_path, "json", "qemu_img_check_manifest")
    return finalize_report(report, run_dir)


def cmd_capture_nvram(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-nvram")
    report = report_base("capture-nvram", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    domains = domain_xml_records(report, run_dir)
    records = []
    for rec in domains:
        summary = rec.get("summary", {})
        nvram = summary.get("os", {}).get("nvram") if isinstance(summary.get("os"), dict) else None
        loader = summary.get("os", {}).get("loader") if isinstance(summary.get("os"), dict) else None
        if nvram:
            records.append({"domain": summary.get("name"), "kind": "domain_nvram", "path": nvram, "file": file_record(Path(nvram).expanduser(), include_hash=True, payload_copied=False)})
        if isinstance(loader, dict) and loader.get("value"):
            records.append({"domain": summary.get("name"), "kind": "domain_loader", "path": loader.get("value"), "file": file_record(Path(loader.get("value")).expanduser(), include_hash=True, payload_copied=False), "loader_attrs": {k: v for k, v in loader.items() if k != "value"}})
    for root in split_semicolon(cfg_get("libvirt.nvram_roots", "")):
        records.append({"kind": "nvram_root", "path": root, "file": file_record(Path(root).expanduser(), include_hash=False, payload_copied=False)})
    manifest_path = run_dir / "libvirt_nvram_manifest.json"
    write_json(manifest_path, {"records": records, "payload_copied": False, "payload_owner": "Borg/rsync according to restore plan; Row 17 owns identity/path capture"})
    report["nvram"] = {"manifest": rel(manifest_path), "record_count": len(records)}
    output_file(report, manifest_path, "json", "libvirt_nvram_manifest")
    return finalize_report(report, run_dir)


def swtpm_candidate_path_records(summary: dict[str, Any], tpm: dict[str, Any]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    domain = summary.get("name")
    uuid_value = summary.get("uuid")
    backend = tpm.get("backend") if isinstance(tpm.get("backend"), dict) else {}

    for key in ("path", "dir", "file"):
        value = backend.get(key)
        if value:
            path = Path(str(value)).expanduser()
            records.append({
                "domain": domain,
                "uuid": uuid_value,
                "kind": f"domain_tpm_backend_{key}",
                "path": str(path),
                "file": file_record(path, include_hash=False, payload_copied=False),
            })

    roots = [Path(item).expanduser() for item in split_semicolon(cfg_get("libvirt.swtpm_roots", ""))]
    for root in roots:
        for identifier_kind, identifier in (("uuid", uuid_value), ("name", domain)):
            if not identifier:
                continue
            path = root / str(identifier)
            records.append({
                "domain": domain,
                "uuid": uuid_value,
                "kind": f"conventional_{identifier_kind}_path",
                "path": str(path),
                "file": file_record(path, include_hash=False, payload_copied=False),
            })
    return records


def cmd_capture_swtpm(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-swtpm")
    report = report_base("capture-swtpm", run_dir)
    report["mode"] = "capture"
    preflight(report, require_uri=True)
    domains = domain_xml_records(report, run_dir)
    records = []
    for rec in domains:
        summary = rec.get("summary", {})
        for tpm in summary.get("tpm", []) or []:
            records.append({
                "domain": summary.get("name"),
                "uuid": summary.get("uuid"),
                "kind": "domain_tpm_definition",
                "tpm": tpm,
                "candidate_paths": swtpm_candidate_path_records(summary, tpm),
                "bitlocker_warning": "Windows BitLocker recovery can be triggered by TPM/swtpm state or firmware changes.",
            })
    for root in split_semicolon(cfg_get("libvirt.swtpm_roots", "")):
        root_path = Path(root).expanduser()
        rec = {"kind": "swtpm_root", "path": root, "file": file_record(root_path, include_hash=False, payload_copied=False)}
        if root_path.exists() and root_path.is_dir():
            children = []
            try:
                for child in sorted(root_path.glob("*"))[:200]:
                    children.append(file_record(child, include_hash=False, payload_copied=False))
            except OSError as exc:
                rec["children_error"] = str(exc)
            rec["children"] = children
        records.append(rec)
    manifest_path = run_dir / "libvirt_swtpm_manifest.json"
    write_json(manifest_path, {"records": records, "payload_copied": False, "secret_boundary": "swtpm state path identity only; exact state bytes are payload artifacts captured by Borg/rsync policy"})
    report["swtpm"] = {"manifest": rel(manifest_path), "record_count": len(records)}
    output_file(report, manifest_path, "json", "libvirt_swtpm_manifest")
    return finalize_report(report, run_dir)


def cmd_verify_no_live_disk_copy(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("verify-no-live-disk-copy")
    report = report_base("verify-no-live-disk-copy", run_dir)
    report["mode"] = "verify"
    preflight(report, require_uri=True)
    paths = []
    if args.disk:
        paths.append(str(Path(args.disk).expanduser().resolve()))
    else:
        for item in get_disk_candidates(report, run_dir):
            p = item.get("normalized_path") or item.get("path")
            if p and str(p).startswith("/"):
                paths.append(str(Path(str(p)).expanduser().resolve()))
    conflicts = live_disk_conflicts(paths, report)
    if conflicts and boolish(cfg_get("policy.fail_if_live_disk_copy", True)):
        report["failures"].append(f"live-domain disk guard failed: {conflicts}")
    manifest_path = run_dir / "libvirt_no_live_disk_copy_guard.json"
    write_json(manifest_path, {"checked_paths": sorted(set(paths)), "conflicts": conflicts, "copy_owner": cfg_get("policy.rsync_cold_copy_owner"), "row17_performed_copy": False})
    report["qemu_img"] = {"live_disk_guard": rel(manifest_path), "conflict_count": len(conflicts)}
    output_file(report, manifest_path, "json", "libvirt_no_live_disk_copy_guard")
    return finalize_report(report, run_dir)


def cmd_generate_restore_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-restore-plan")
    report = report_base("generate-restore-plan", run_dir)
    report["mode"] = "plan"
    generated = resolve_path(str(cfg_get("project.generated_root", "state/generated/17_libvirt")))
    generated.mkdir(parents=True, exist_ok=True)
    plan_path = generated / str(cfg_get("policy.generated_restore_plan_name", "libvirt_vm_restore_plan.md"))
    text = f"""# Libvirt / QEMU future Windows VM restore plan

## Authority boundary

Row 17 owns host-side VM recoverability metadata for libvirt/QEMU/swtpm. It does not install packages, transport VM disk bytes, or perform in-guest Windows backup.

## Restore order

1. Restore native libvirt/QEMU/swtpm packages through Row 10.
2. Restore host filesystem payloads containing domain XML, NVRAM, swtpm state, VirtIO ISO references, and any VM disk files through Borg/rsync according to lower-row authority.
3. Confirm `virsh -c {uri()} uri` returns `{uri()}`.
4. Confirm libvirt networks and pools exist or recreate them from captured XML.
5. Review domain XML, disk paths, NVRAM paths, TPM definitions, NICs, display devices, boot order, and passthrough devices.
6. Do not define/start a Windows VM until its disk, NVRAM, swtpm state, and BitLocker recovery key availability have been reviewed.
7. Define the VM manually from the generated define-domain plan only after review.
8. Run the VM smoke checklist and stop if Windows requests BitLocker recovery unexpectedly.

## Required warnings

- Windows BitLocker can bind recovery to TPM, Secure Boot, firmware, machine type, boot order, disk identity, and NVRAM changes.
- Keep BitLocker recovery keys outside this row.
- Disk cold-copy transport belongs to {cfg_get('policy.rsync_cold_copy_owner')}.
- In-guest Windows backup is {cfg_get('policy.in_guest_windows_backup_owner')}.

## Useful commands

~~~bash
scripts/17_libvirt.sh discover-system
scripts/17_libvirt.sh capture-inventory
scripts/17_libvirt.sh capture-domain-xml
scripts/17_libvirt.sh capture-network-xml
scripts/17_libvirt.sh capture-pool-xml
scripts/17_libvirt.sh capture-qemu-img-info
scripts/17_libvirt.sh verify-no-live-disk-copy --disk /path/to/vm.qcow2
scripts/17_libvirt.sh define-domain-plan --domain <name>
scripts/17_libvirt.sh vm-smoke-plan
~~~
"""
    write_text(plan_path, text)
    plan_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["restore_plan"] = {"path": rel(plan_path)}
    output_file(report, plan_path, "markdown", "libvirt_vm_restore_plan")
    return finalize_report(report, run_dir)


def cmd_define_domain_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("define-domain-plan")
    report = report_base("define-domain-plan", run_dir)
    report["mode"] = "plan"
    preflight(report, require_uri=True)
    records = domain_xml_records(report, run_dir)
    existing_names = {rec.get("domain") for rec in records}
    if args.domain and args.domain not in existing_names:
        report["failures"].append(f"requested domain not found for define-domain-plan: {args.domain}")
    selected = []
    for rec in records:
        if not args.domain or rec.get("domain") == args.domain:
            selected.append(rec)
    generated = resolve_path(str(cfg_get("project.generated_root", "state/generated/17_libvirt")))
    generated.mkdir(parents=True, exist_ok=True)
    plan_path = generated / str(cfg_get("policy.generated_define_plan_name", "libvirt_define_domain_plan.md"))
    lines = [
        "# Libvirt define-domain plan",
        "",
        "This is a review-only plan. Row 17 does not run `virsh define` automatically.",
        "",
        "## Preconditions",
        "",
        "- Confirm package restore through Row 10.",
        "- Confirm disk/NVRAM/swtpm payload restore through the owning payload rows.",
        "- Confirm BitLocker recovery keys are available before first boot.",
        "- Confirm `verify-no-live-disk-copy` passes for any disk transport.",
        "",
        "## Candidate define commands",
        "",
    ]
    if not selected:
        lines.append("No existing domain XML was captured. Future Windows VM definition will appear here after a domain exists.")
    for rec in selected:
        xml_path = rec.get("xml_path")
        domain = rec.get("domain")
        if xml_path:
            lines.append(f"### {domain}")
            lines.append("")
            lines.append("~~~bash")
            lines.append(f"virsh -c {shlex.quote(uri())} define {shlex.quote(str(resolve_path(xml_path)))}")
            lines.append("virsh -c " + shlex.quote(uri()) + " dominfo " + shlex.quote(str(domain)))
            lines.append("~~~")
            lines.append("")
    write_text(plan_path, "\n".join(lines))
    plan_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["restore_plan"] = {"define_plan": rel(plan_path), "candidate_count": len(selected)}
    output_file(report, plan_path, "markdown", "libvirt_define_domain_plan")
    return finalize_report(report, run_dir)


def cmd_vm_smoke_plan(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("vm-smoke-plan")
    report = report_base("vm-smoke-plan", run_dir)
    report["mode"] = "plan"
    generated = resolve_path(str(cfg_get("project.generated_root", "state/generated/17_libvirt")))
    generated.mkdir(parents=True, exist_ok=True)
    plan_path = generated / str(cfg_get("policy.generated_smoke_plan_name", "libvirt_vm_smoke_plan.md"))
    text = """# Windows VM smoke-test checklist

## Before first boot

- Confirm domain XML matches intended domain UUID, vCPU, memory, CPU mode, machine type, firmware, TPM, disk, NIC, display, and boot order.
- Confirm every disk path exists and `qemu-img info` is readable.
- Confirm `qemu-img check` was run only while the VM was inactive.
- Confirm NVRAM path exists when UEFI is configured.
- Confirm swtpm path/definition exists when TPM is configured.
- Confirm VirtIO ISO availability if Windows drivers are required.
- Confirm BitLocker recovery key availability before any TPM/Secure Boot/NVRAM/firmware-sensitive boot.

## First boot

- Start VM manually from virt-manager or `virsh start` only after review.
- Confirm firmware reaches the intended boot device.
- Confirm Windows does not unexpectedly request BitLocker recovery.
- Confirm NIC is present and expected network profile appears.
- Confirm display/SPICE/VNC works.
- Confirm time sync, disk visibility, and device manager state.
- Shut down cleanly from guest OS after smoke.

## Stop conditions

- Stop if BitLocker recovery appears unexpectedly and keys are not available.
- Stop if Windows sees the disk as moved/changed and repair is requested.
- Stop if the domain XML points to missing NVRAM, missing swtpm state, or the wrong disk.
- Stop if a passthrough device has changed IOMMU identity.
"""
    write_text(plan_path, text)
    plan_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    report["restore_plan"] = {"smoke_plan": rel(plan_path)}
    output_file(report, plan_path, "markdown", "libvirt_vm_smoke_plan")
    return finalize_report(report, run_dir)


def cmd_gate(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("gate")
    report = report_base("gate", run_dir)
    report["mode"] = "verify"
    preflight(report, require_uri=True, require_qemu_img=True)
    inv = {}
    if not report["failures"]:
        inv["domains"] = domain_names(report)
        inv["networks"] = network_names(report)
        inv["pools"] = pool_names(report)
        inv["running_disk_users"] = running_domain_disk_users(report)
        default_network = str(cfg_get("libvirt.expected_default_network", "default"))
        if default_network not in inv["networks"]:
            report["warnings"].append(f"default libvirt network not present: {default_network}")
        if not inv["domains"]:
            report["warnings"].append("no libvirt domains are currently defined; Row 17 passes as future-VM-ready metadata layer")
    payload = {
        "uri": uri(),
        "tool_versions": report["tool"],
        "inventory": inv,
        "bitlocker_tpm_warning_required": boolish(cfg_get("policy.bitlocker_tpm_warning_required", True)),
        "disk_copy_owner": cfg_get("policy.rsync_cold_copy_owner"),
        "row17_performs_disk_copy": False,
        "secret_values_read": False,
    }
    path = run_dir / "libvirt_gate.json"
    write_json(path, payload)
    report["gate"] = {"manifest": rel(path), "domain_count": len(inv.get("domains", [])), "network_count": len(inv.get("networks", []))}
    output_file(report, path, "json", "libvirt_gate")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("discover-system").set_defaults(func=cmd_discover_system)
    sub.add_parser("capture-inventory").set_defaults(func=cmd_capture_inventory)

    p = sub.add_parser("capture-domain-xml")
    p.add_argument("--domain", default=None)
    p.set_defaults(func=cmd_capture_domain_xml)

    sub.add_parser("capture-network-xml").set_defaults(func=cmd_capture_network_xml)
    sub.add_parser("capture-pool-xml").set_defaults(func=cmd_capture_pool_xml)
    sub.add_parser("capture-secret-refs").set_defaults(func=cmd_capture_secret_refs)

    p = sub.add_parser("capture-qemu-img-info")
    p.add_argument("--disk", default=None)
    p.add_argument("--domain", default=None)
    p.set_defaults(func=cmd_capture_qemu_img_info)

    p = sub.add_parser("run-qemu-img-check")
    p.add_argument("--disk", default=None)
    p.add_argument("--domain", default=None)
    p.set_defaults(func=cmd_run_qemu_img_check)

    sub.add_parser("capture-nvram").set_defaults(func=cmd_capture_nvram)
    sub.add_parser("capture-swtpm").set_defaults(func=cmd_capture_swtpm)

    p = sub.add_parser("verify-no-live-disk-copy")
    p.add_argument("--disk", default=None)
    p.set_defaults(func=cmd_verify_no_live_disk_copy)

    sub.add_parser("generate-restore-plan").set_defaults(func=cmd_generate_restore_plan)

    p = sub.add_parser("define-domain-plan")
    p.add_argument("--domain", default=None)
    p.set_defaults(func=cmd_define_domain_plan)

    sub.add_parser("vm-smoke-plan").set_defaults(func=cmd_vm_smoke_plan)
    sub.add_parser("gate").set_defaults(func=cmd_gate)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
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


if __name__ == "__main__":
    raise SystemExit(main(ARGS))
PYCODE