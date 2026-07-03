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
from datetime import datetime
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "01_smartmontools.sh"
SCHEMA_NAME = "recovery.smartmontools.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "project": {
        "output_root": "state/dry_runs/01_smartmontools",
    },
    "commands": {
        "smartctl": "/usr/sbin/smartctl",
        "lsblk": "/usr/bin/lsblk",
    },
    "roles": {
        "source": {
            "label": "source_nvme",
            "required": True,
            "smart_device": "/dev/nvme0",
            "block_device": "/dev/nvme0n1",
            "expected_model_regex": "Samsung|990 PRO|NVMe",
            "min_capacity_bytes": 1900000000000,
            "require_smart_status": True,
            "require_usb_transport": False,
        },
        "backup_hdd": {
            "label": "backup_hdd_ironwolf_24tb",
            "required": True,
            "smart_device": "",
            "block_device": "",
            "expected_model_regex": "IronWolf|ST24000|Seagate",
            "min_capacity_bytes": 23000000000000,
            "require_smart_status": True,
            "require_usb_transport": True,
            "require_dock_passthrough": True,
        },
        "replacement_ssd": {
            "label": "replacement_ssd_future",
            "required": False,
            "smart_device": "",
            "block_device": "",
            "expected_model_regex": "SSD|NVMe|Samsung|Crucial|WD|Western Digital|Seagate",
            "min_capacity_bytes": 1900000000000,
            "require_smart_status": True,
            "require_usb_transport": False,
        },
    },
    "thresholds": {
        "max_reallocated_sectors": 0,
        "max_current_pending_sectors": 0,
        "max_offline_uncorrectable_sectors": 0,
        "max_udma_crc_errors": 0,
        "max_nvme_critical_warning": 0,
        "max_nvme_media_errors": 0,
        "max_nvme_error_log_entries_warn": 0,
        "max_temperature_celsius_warn": 55,
        "max_temperature_celsius_fail": 65,
        "max_nvme_percentage_used_warn": 80,
        "max_nvme_percentage_used_fail": 95,
    },
    "gate_modes": {
        "local": {
            "require_source": True,
            "require_backup_hdd": False,
            "require_replacement_ssd": False,
        },
        "full": {
            "require_source": True,
            "require_backup_hdd": True,
            "require_replacement_ssd": False,
        },
    },
}


def print_usage() -> None:
    print(
        f"""Usage:
  scripts/{SCRIPT_NAME} scan
  scripts/{SCRIPT_NAME} capture-source
  scripts/{SCRIPT_NAME} capture-backup-hdd
  scripts/{SCRIPT_NAME} capture-replacement-ssd
  scripts/{SCRIPT_NAME} selftest-short ROLE
  scripts/{SCRIPT_NAME} selftest-log ROLE
  scripts/{SCRIPT_NAME} assert-dock-passthrough
  scripts/{SCRIPT_NAME} assert-backup-hdd
  scripts/{SCRIPT_NAME} assert-replacement-ssd
  scripts/{SCRIPT_NAME} gate [local|full]

Roles:
  source
  backup-hdd
  replacement-ssd

Notes:
  - All commands are read-only except selftest-short, which starts a SMART short self-test.
  - Device writes, formatting, mounting, encryption, and backup actions are not performed here.
  - Device access may prompt through sudo for smartctl only; output files remain user-owned.
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
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        if not inner:
            return []
        return [parse_scalar(part.strip()) for part in inner.split(",")]
    if re.fullmatch(r"-?\d+", v):
        try:
            return int(v)
        except ValueError:
            return v
    if re.fullmatch(r"-?\d+\.\d+", v):
        try:
            return float(v)
        except ValueError:
            return v
    return v


def parse_simple_yaml(path: Path) -> dict[str, Any]:
    root: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, root)]

    for raw in path.read_text(encoding="utf-8").splitlines():
        line_no_comment = strip_comment(raw)
        if not line_no_comment.strip():
            continue
        if line_no_comment.lstrip().startswith("- "):
            raise SystemExit(
                f"{path}: list-item YAML is intentionally unsupported in this config. "
                "Use inline lists or mapping keys."
            )
        indent = len(line_no_comment) - len(line_no_comment.lstrip(" "))
        line = line_no_comment.strip()
        if ":" not in line:
            raise SystemExit(f"{path}: unsupported YAML line: {raw!r}")
        key, value = line.split(":", 1)
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
    path = PROJECT_ROOT / "configs" / "01_smartmontools.yaml"
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


SMARTCTL = str(cfg_get("commands.smartctl", "/usr/sbin/smartctl"))
LSBLK = str(cfg_get("commands.lsblk", "/usr/bin/lsblk"))


def now_stamp() -> str:
    return datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")


def iso_now() -> str:
    return datetime.now().astimezone().isoformat()


def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(PROJECT_ROOT))
    except ValueError:
        return str(path.resolve())


def make_run_dir(command: str) -> Path:
    root = PROJECT_ROOT / str(cfg_get("project.output_root", "state/dry_runs/01_smartmontools"))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def run_cmd(argv: list[str], *, smartctl: bool = False) -> dict[str, Any]:
    final_argv = argv[:]
    if smartctl and os.geteuid() != 0:
        if not shutil.which("sudo"):
            return {
                "argv": argv,
                "returncode": 127,
                "stdout": "",
                "stderr": "smartctl device access requires root and sudo is not available",
            }
        final_argv = ["sudo"] + final_argv

    proc = subprocess.run(final_argv, text=True, capture_output=True)
    return {
        "argv": final_argv,
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def smartctl_cmd(args: list[str]) -> dict[str, Any]:
    return run_cmd([SMARTCTL] + args, smartctl=True)


def lsblk_json() -> dict[str, Any]:
    result = run_cmd([LSBLK, "-J", "-b", "-O", "-e7"])
    if result["returncode"] != 0:
        return {
            "ok": False,
            "command": scrub_command(result),
            "blockdevices": [],
        }
    try:
        payload = json.loads(result["stdout"] or "{}")
        payload["ok"] = True
        return payload
    except json.JSONDecodeError:
        return {
            "ok": False,
            "command": scrub_command(result),
            "blockdevices": [],
            "parse_error": "lsblk did not return valid JSON",
        }


def flatten_lsblk(nodes: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for node in nodes:
        out.append(node)
        children = node.get("children") or []
        if isinstance(children, list):
            out.extend(flatten_lsblk(children))
    return out


def root_disk_paths_from_lsblk(lsblk_payload: dict[str, Any]) -> set[str]:
    roots: set[str] = set()

    def has_root_mount(node: dict[str, Any]) -> bool:
        mountpoint = node.get("mountpoint")
        if mountpoint == "/":
            return True
        mountpoints = node.get("mountpoints")
        if isinstance(mountpoints, list) and "/" in mountpoints:
            return True
        return False

    def walk(nodes: list[dict[str, Any]], current_disk: str | None = None) -> None:
        for node in nodes:
            node_type = str(node.get("type") or "")
            node_path = str(node.get("path") or "")
            next_disk = node_path if node_type == "disk" and node_path else current_disk

            if has_root_mount(node) and next_disk:
                roots.add(next_disk)

            children = node.get("children") or []
            if isinstance(children, list):
                walk(children, next_disk)

    walk(lsblk_payload.get("blockdevices", []) or [])
    return roots


def nvme_controller_from_namespace(path: str) -> str:
    match = re.match(r"^(/dev/nvme\d+)n\d+(?:p\d+)?$", path)
    if match:
        return match.group(1)
    return path


def device_matches_root(device_report: dict[str, Any], lsblk_payload: dict[str, Any]) -> bool:
    roots = root_disk_paths_from_lsblk(lsblk_payload)
    summary = device_report.get("summary", {})
    candidates = {
        str(device_report.get("smart_device") or ""),
        str(summary.get("lsblk_path") or ""),
    }
    normalized_candidates = {nvme_controller_from_namespace(value) for value in candidates if value}

    for root in roots:
        normalized_root = nvme_controller_from_namespace(root)
        if root in candidates or normalized_root in normalized_candidates:
            return True

    return False


def scrub_command(result: dict[str, Any], stdout_path: str | None = None) -> dict[str, Any]:
    payload = {
        "argv": [str(x) for x in result.get("argv", [])],
        "returncode": int(result.get("returncode", 0)),
        "stderr": result.get("stderr", ""),
    }
    if stdout_path:
        payload["stdout_path"] = stdout_path
    return payload


def parse_json_stdout(result: dict[str, Any]) -> dict[str, Any] | None:
    try:
        return json.loads(result.get("stdout") or "")
    except json.JSONDecodeError:
        return None


def command_report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "smartmontools",
            "script": SCRIPT_NAME,
            "smartctl_path": SMARTCTL,
            "lsblk_path": LSBLK,
        },
        "command": command,
        "generated_at": iso_now(),
        "host": socket.gethostname(),
        "project_root": str(PROJECT_ROOT),
        "run_dir": rel(run_dir),
        "ok": True,
        "failures": [],
        "warnings": [],
    }


def smart_scan(run_dir: Path) -> dict[str, Any]:
    text_result = smartctl_cmd(["--scan-open"])
    text_path = run_dir / "smartctl_scan_open.txt"
    write_text(text_path, text_result["stdout"])

    json_result = smartctl_cmd(["--json", "--scan-open"])
    json_path = run_dir / "smartctl_scan_open.json"
    parsed_json = parse_json_stdout(json_result)
    if parsed_json is not None:
        write_json(json_path, parsed_json)
    else:
        write_text(json_path, json_result["stdout"])

    block = lsblk_json()
    lsblk_path = run_dir / "lsblk.json"
    write_json(lsblk_path, block)

    report = command_report_base("scan", run_dir)
    report["commands"] = {
        "smartctl_scan_open_text": scrub_command(text_result, rel(text_path)),
        "smartctl_scan_open_json": scrub_command(json_result, rel(json_path)),
        "lsblk": {
            "argv": [LSBLK, "-J", "-b", "-O", "-e7"],
            "returncode": 0 if block.get("ok") else 1,
            "stdout_path": rel(lsblk_path),
            "stderr": "",
        },
    }
    report["scan_devices"] = (parsed_json or {}).get("devices", [])
    report["lsblk_devices"] = flatten_lsblk(block.get("blockdevices", []))

    if json_result["returncode"] != 0:
        report["warnings"].append(
            f"smartctl --json --scan-open returned {json_result['returncode']}; parsed output may still be usable"
        )
    if parsed_json is None:
        report["failures"].append("smartctl --json --scan-open did not produce valid JSON")
    if not block.get("ok"):
        report["warnings"].append("lsblk JSON inventory was not available")

    report["ok"] = not report["failures"]
    write_json(run_dir / "scan_report.json", report)
    return report


def sanitize_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip("/")) or "device"


def smart_report(run_dir: Path, device: str, dev_type: str | None, label: str) -> dict[str, Any]:
    base = sanitize_name(label or device)
    args = ["--json", "-x"]
    if dev_type:
        args += ["-d", dev_type]
    args.append(device)
    json_result = smartctl_cmd(args)

    json_path = run_dir / f"{base}_smartctl_x.json"
    parsed = parse_json_stdout(json_result)
    if parsed is not None:
        write_json(json_path, parsed)
    else:
        write_text(json_path, json_result["stdout"])

    text_args = ["-x"]
    if dev_type:
        text_args += ["-d", dev_type]
    text_args.append(device)
    text_result = smartctl_cmd(text_args)
    text_path = run_dir / f"{base}_smartctl_x.txt"
    write_text(text_path, text_result["stdout"])

    return {
        "device": device,
        "type": dev_type or "",
        "json": parsed,
        "json_command": scrub_command(json_result, rel(json_path)),
        "text_command": scrub_command(text_result, rel(text_path)),
    }


def first_of(*values: Any) -> Any:
    for value in values:
        if value not in (None, ""):
            return value
    return None


def ata_attr_value(payload: dict[str, Any], attr_name: str) -> int | None:
    table = payload.get("ata_smart_attributes", {}).get("table", [])
    if not isinstance(table, list):
        return None
    for item in table:
        if item.get("name") == attr_name:
            raw = item.get("raw")
            if isinstance(raw, dict):
                value = raw.get("value")
            else:
                value = raw
            try:
                return int(value)
            except (TypeError, ValueError):
                return None
    return None


def json_path_get(payload: dict[str, Any], *parts: str) -> Any:
    cur: Any = payload
    for part in parts:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def find_lsblk_node(lsblk_payload: dict[str, Any], smart_device: str, block_device: str | None) -> dict[str, Any] | None:
    nodes = flatten_lsblk(lsblk_payload.get("blockdevices", []))

    candidates = []
    if block_device:
        candidates.append(block_device)
    candidates.append(smart_device)

    for want in candidates:
        for node in nodes:
            if node.get("path") == want:
                return node

    if smart_device.startswith("/dev/nvme"):
        for node in nodes:
            path = str(node.get("path") or "")
            if path.startswith(smart_device + "n"):
                return node

    return None


def summarize_device(payload: dict[str, Any] | None, smart_device: str, smart_type: str, lsblk_node: dict[str, Any] | None) -> dict[str, Any]:
    payload = payload or {}
    nvme_log = payload.get("nvme_smart_health_information_log") or {}

    summary = {
        "model": first_of(payload.get("model_name"), payload.get("device_model"), payload.get("model_family")),
        "serial": first_of(payload.get("serial_number"), payload.get("serial")),
        "firmware": first_of(payload.get("firmware_version"), payload.get("firmware")),
        "capacity_bytes": json_path_get(payload, "user_capacity", "bytes"),
        "smart_passed": json_path_get(payload, "smart_status", "passed"),
        "temperature_celsius": first_of(
            json_path_get(payload, "temperature", "current"),
            nvme_log.get("temperature"),
        ),
        "power_on_hours": first_of(payload.get("power_on_time", {}).get("hours"), nvme_log.get("power_on_hours")),
        "nvme_critical_warning": nvme_log.get("critical_warning"),
        "nvme_media_errors": nvme_log.get("media_errors"),
        "nvme_error_log_entries": nvme_log.get("num_err_log_entries"),
        "nvme_percentage_used": nvme_log.get("percentage_used"),
        "ata_reallocated_sectors": ata_attr_value(payload, "Reallocated_Sector_Ct"),
        "ata_current_pending_sectors": ata_attr_value(payload, "Current_Pending_Sector"),
        "ata_offline_uncorrectable_sectors": ata_attr_value(payload, "Offline_Uncorrectable"),
        "ata_udma_crc_errors": ata_attr_value(payload, "UDMA_CRC_Error_Count"),
        "lsblk_path": lsblk_node.get("path") if lsblk_node else None,
        "lsblk_name": lsblk_node.get("name") if lsblk_node else None,
        "lsblk_model": lsblk_node.get("model") if lsblk_node else None,
        "lsblk_serial": lsblk_node.get("serial") if lsblk_node else None,
        "lsblk_transport": lsblk_node.get("tran") if lsblk_node else None,
        "lsblk_size_bytes": lsblk_node.get("size") if lsblk_node else None,
    }

    if summary["capacity_bytes"] is None and summary["lsblk_size_bytes"] is not None:
        try:
            summary["capacity_bytes"] = int(summary["lsblk_size_bytes"])
        except (TypeError, ValueError):
            pass

    return {
        "smart_device": smart_device,
        "smart_type": smart_type,
        "summary": summary,
    }


def role_key(role: str) -> str:
    normalized = role.replace("-", "_").lower()
    aliases = {
        "backup": "backup_hdd",
        "hdd": "backup_hdd",
        "backup_hdd": "backup_hdd",
        "source": "source",
        "source_nvme": "source",
        "replacement": "replacement_ssd",
        "replacement_ssd": "replacement_ssd",
    }
    if normalized not in aliases:
        raise SystemExit(f"Unknown role: {role}")
    return aliases[normalized]


def role_cfg(role: str) -> dict[str, Any]:
    key = role_key(role)
    roles = CFG.get("roles", {})
    return deepcopy(roles.get(key, DEFAULT_CONFIG["roles"][key]))


def regex_match(pattern: str | None, value: str | None) -> bool:
    if not pattern:
        return True
    if value is None:
        return False
    return re.search(str(pattern), str(value), flags=re.IGNORECASE) is not None


def int_or_none(value: Any) -> int | None:
    try:
        if value is None or value == "":
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def evaluate_device(role: str, device_report: dict[str, Any], rcfg: dict[str, Any]) -> tuple[list[str], list[str]]:
    failures: list[str] = []
    warnings: list[str] = []
    summary = device_report.get("summary", {})

    model = str(summary.get("model") or summary.get("lsblk_model") or "")
    capacity = int_or_none(summary.get("capacity_bytes"))
    min_capacity = int_or_none(rcfg.get("min_capacity_bytes"))
    expected_model_regex = rcfg.get("expected_model_regex")

    if expected_model_regex and not regex_match(str(expected_model_regex), model):
        failures.append(f"{role}: model {model!r} does not match {expected_model_regex!r}")

    if min_capacity is not None:
        if capacity is None:
            failures.append(f"{role}: capacity is unknown; expected at least {min_capacity} bytes")
        elif capacity < min_capacity:
            failures.append(f"{role}: capacity {capacity} is below required minimum {min_capacity}")

    require_smart_status = bool(rcfg.get("require_smart_status", True))
    smart_passed = summary.get("smart_passed")
    if require_smart_status and smart_passed is None:
        failures.append(f"{role}: SMART health status is unavailable")
    elif smart_passed is False:
        failures.append(f"{role}: SMART health status reports failure")

    require_usb = bool(rcfg.get("require_usb_transport", False))
    transport = summary.get("lsblk_transport")
    if require_usb and str(transport or "").lower() != "usb":
        failures.append(f"{role}: expected USB transport through dock, got {transport!r}")

    thresholds = CFG.get("thresholds", {})

    temp = int_or_none(summary.get("temperature_celsius"))
    if temp is not None:
        fail_temp = int_or_none(thresholds.get("max_temperature_celsius_fail"))
        warn_temp = int_or_none(thresholds.get("max_temperature_celsius_warn"))
        if fail_temp is not None and temp >= fail_temp:
            failures.append(f"{role}: temperature {temp}C is at or above fail threshold {fail_temp}C")
        elif warn_temp is not None and temp >= warn_temp:
            warnings.append(f"{role}: temperature {temp}C is at or above warn threshold {warn_temp}C")

    nvme_critical = int_or_none(summary.get("nvme_critical_warning"))
    max_nvme_critical = int_or_none(thresholds.get("max_nvme_critical_warning"))
    if nvme_critical is not None and max_nvme_critical is not None and nvme_critical > max_nvme_critical:
        failures.append(f"{role}: NVMe critical_warning={nvme_critical} exceeds {max_nvme_critical}")

    nvme_media_errors = int_or_none(summary.get("nvme_media_errors"))
    max_nvme_media_errors = int_or_none(thresholds.get("max_nvme_media_errors"))
    if nvme_media_errors is not None and max_nvme_media_errors is not None and nvme_media_errors > max_nvme_media_errors:
        failures.append(f"{role}: NVMe media_errors={nvme_media_errors} exceeds {max_nvme_media_errors}")

    nvme_error_log_entries = int_or_none(summary.get("nvme_error_log_entries"))
    max_nvme_error_log_entries_warn = int_or_none(thresholds.get("max_nvme_error_log_entries_warn"))
    if (
        nvme_error_log_entries is not None
        and max_nvme_error_log_entries_warn is not None
        and nvme_error_log_entries > max_nvme_error_log_entries_warn
    ):
        warnings.append(
            f"{role}: NVMe error log entries={nvme_error_log_entries} exceeds warn threshold {max_nvme_error_log_entries_warn}"
        )

    nvme_pct_used = int_or_none(summary.get("nvme_percentage_used"))
    max_pct_fail = int_or_none(thresholds.get("max_nvme_percentage_used_fail"))
    max_pct_warn = int_or_none(thresholds.get("max_nvme_percentage_used_warn"))
    if nvme_pct_used is not None:
        if max_pct_fail is not None and nvme_pct_used >= max_pct_fail:
            failures.append(f"{role}: NVMe percentage_used={nvme_pct_used} is at or above fail threshold {max_pct_fail}")
        elif max_pct_warn is not None and nvme_pct_used >= max_pct_warn:
            warnings.append(f"{role}: NVMe percentage_used={nvme_pct_used} is at or above warn threshold {max_pct_warn}")

    ata_checks = [
        ("ata_reallocated_sectors", "max_reallocated_sectors"),
        ("ata_current_pending_sectors", "max_current_pending_sectors"),
        ("ata_offline_uncorrectable_sectors", "max_offline_uncorrectable_sectors"),
        ("ata_udma_crc_errors", "max_udma_crc_errors"),
    ]
    for summary_key, threshold_key in ata_checks:
        value = int_or_none(summary.get(summary_key))
        maximum = int_or_none(thresholds.get(threshold_key))
        if value is not None and maximum is not None and value > maximum:
            failures.append(f"{role}: {summary_key}={value} exceeds {maximum}")

    return failures, warnings


def scan_devices_list(run_dir: Path) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    scan = smart_scan(run_dir)
    return scan.get("scan_devices", []), scan


def capture_role(role_arg: str, run_dir: Path, *, required_override: bool | None = None) -> dict[str, Any]:
    role = role_key(role_arg)
    rcfg = role_cfg(role)
    required = bool(rcfg.get("required", False)) if required_override is None else required_override

    scan_devices, _scan_report = scan_devices_list(run_dir)
    block = lsblk_json()

    explicit_device = str(rcfg.get("smart_device") or "").strip()
    explicit_type = str(rcfg.get("smart_type") or "").strip()
    block_device = str(rcfg.get("block_device") or "").strip()

    if role == "replacement_ssd" and not explicit_device and not block_device:
        role_report = {
            "role": role,
            "required": required,
            "found": False,
            "ok": not required,
            "failures": [] if not required else [
                "replacement_ssd: explicit smart_device or block_device is required to avoid selecting the current root disk"
            ],
            "warnings": ["replacement_ssd: skipped because no explicit device is configured"] if not required else [],
            "device": None,
        }
        write_json(run_dir / f"{role}_report.json", role_report)
        return role_report

    selected: dict[str, Any] | None = None
    selected_smart: dict[str, Any] | None = None

    candidates: list[tuple[str, str | None]] = []
    if explicit_device:
        dtype = explicit_type or None
        for dev in scan_devices:
            if dev.get("name") == explicit_device:
                dtype = dev.get("type") or dtype
                break
        candidates.append((explicit_device, dtype))

    for dev in scan_devices:
        name = str(dev.get("name") or "")
        dtype = dev.get("type")
        if name and (name, dtype) not in candidates:
            candidates.append((name, dtype))

    for dev_name, dev_type in candidates:
        raw = smart_report(run_dir, dev_name, dev_type, f"{role}_{sanitize_name(dev_name)}")
        payload = raw.get("json")
        lsblk_node = find_lsblk_node(block, dev_name, block_device if dev_name == explicit_device else None)
        device_report = summarize_device(payload, dev_name, dev_type or "", lsblk_node)
        model = str(device_report["summary"].get("model") or device_report["summary"].get("lsblk_model") or "")
        capacity = int_or_none(device_report["summary"].get("capacity_bytes"))

        is_root_match = device_matches_root(device_report, block)
        if role != "source" and is_root_match:
            continue

        if explicit_device and dev_name == explicit_device:
            selected = device_report
            selected_smart = raw
            break

        model_ok = regex_match(str(rcfg.get("expected_model_regex") or ""), model)
        min_capacity = int_or_none(rcfg.get("min_capacity_bytes"))
        capacity_ok = min_capacity is None or (capacity is not None and capacity >= min_capacity)

        if model_ok and capacity_ok:
            selected = device_report
            selected_smart = raw
            break

    role_report = {
        "role": role,
        "required": required,
        "found": selected is not None,
        "ok": True,
        "failures": [],
        "warnings": [],
        "device": selected,
    }

    if selected is None:
        if required:
            role_report["ok"] = False
            role_report["failures"].append(f"{role}: required device was not found")
        else:
            role_report["ok"] = True
            role_report["warnings"].append(f"{role}: optional device was not found")
        write_json(run_dir / f"{role}_report.json", role_report)
        return role_report

    failures, warnings = evaluate_device(role, selected, rcfg)
    role_report["failures"] = failures
    role_report["warnings"] = warnings

    if selected_smart:
        role_report["smartctl_json_command"] = selected_smart.get("json_command")
        role_report["smartctl_text_command"] = selected_smart.get("text_command")

    role_report["ok"] = not failures
    write_json(run_dir / f"{role}_report.json", role_report)
    return role_report


def cmd_scan() -> int:
    run_dir = make_run_dir("scan")
    report = smart_scan(run_dir)
    print(f"scan report: {rel(run_dir / 'scan_report.json')}")
    return 0 if report.get("ok") else 2


def cmd_capture_role(command: str, role: str) -> int:
    run_dir = make_run_dir(command)
    report = command_report_base(command, run_dir)
    role_report = capture_role(role, run_dir)
    report["roles"] = {role_key(role): role_report}
    report["ok"] = bool(role_report.get("ok"))
    report["failures"] = list(role_report.get("failures", []))
    report["warnings"] = list(role_report.get("warnings", []))
    write_json(run_dir / f"{command}_report.json", report)
    print(f"{command} report: {rel(run_dir / f'{command}_report.json')}")
    return 0 if report["ok"] else 2


def resolve_role_device(role: str, run_dir: Path) -> tuple[str, str]:
    role_report = capture_role(role, run_dir, required_override=True)
    if not role_report.get("ok") or not role_report.get("device"):
        raise SystemExit("\n".join(role_report.get("failures") or [f"{role}: device not available"]))
    device = role_report["device"]["smart_device"]
    dtype = role_report["device"]["smart_type"]
    return device, dtype


def cmd_selftest_short(role_arg: str | None) -> int:
    if not role_arg:
        raise SystemExit("selftest-short requires an explicit role: source, backup-hdd, or replacement-ssd")

    role = role_key(role_arg)
    run_dir = make_run_dir(f"selftest-short-{role}")
    device, dtype = resolve_role_device(role, run_dir)

    args = ["-t", "short"]
    if dtype:
        args += ["-d", dtype]
    args.append(device)
    result = smartctl_cmd(args)

    text_path = run_dir / f"{role}_selftest_short.txt"
    write_text(text_path, result["stdout"] + result["stderr"])

    report = command_report_base("selftest-short", run_dir)
    report["role"] = role
    report["device"] = device
    report["smart_type"] = dtype
    report["commands"] = {"smartctl_selftest_short": scrub_command(result, rel(text_path))}
    if result["returncode"] != 0:
        report["ok"] = False
        report["failures"].append(f"smartctl short self-test command returned {result['returncode']}")
    write_json(run_dir / "selftest_short_report.json", report)

    print(f"selftest-short report: {rel(run_dir / 'selftest_short_report.json')}")
    return 0 if report["ok"] else 2


def cmd_selftest_log(role_arg: str | None) -> int:
    if not role_arg:
        raise SystemExit("selftest-log requires an explicit role: source, backup-hdd, or replacement-ssd")

    role = role_key(role_arg)
    run_dir = make_run_dir(f"selftest-log-{role}")
    device, dtype = resolve_role_device(role, run_dir)

    json_args = ["--json", "-l", "selftest"]
    if dtype:
        json_args += ["-d", dtype]
    json_args.append(device)
    json_result = smartctl_cmd(json_args)

    json_path = run_dir / f"{role}_selftest_log.json"
    parsed = parse_json_stdout(json_result)
    if parsed is not None:
        write_json(json_path, parsed)
    else:
        write_text(json_path, json_result["stdout"])

    text_args = ["-l", "selftest"]
    if dtype:
        text_args += ["-d", dtype]
    text_args.append(device)
    text_result = smartctl_cmd(text_args)

    text_path = run_dir / f"{role}_selftest_log.txt"
    write_text(text_path, text_result["stdout"] + text_result["stderr"])

    report = command_report_base("selftest-log", run_dir)
    report["role"] = role
    report["device"] = device
    report["smart_type"] = dtype
    report["commands"] = {
        "smartctl_selftest_log_json": scrub_command(json_result, rel(json_path)),
        "smartctl_selftest_log_text": scrub_command(text_result, rel(text_path)),
    }
    if parsed is None:
        report["warnings"].append("self-test log JSON was unavailable or unparsable; text log was still captured")
    report["ok"] = True
    write_json(run_dir / "selftest_log_report.json", report)

    print(f"selftest-log report: {rel(run_dir / 'selftest_log_report.json')}")
    return 0


def cmd_assert_dock_passthrough() -> int:
    run_dir = make_run_dir("assert-dock-passthrough")
    report = command_report_base("assert-dock-passthrough", run_dir)
    role_report = capture_role("backup_hdd", run_dir, required_override=True)
    report["roles"] = {"backup_hdd": role_report}

    failures = list(role_report.get("failures", []))
    warnings = list(role_report.get("warnings", []))

    device = role_report.get("device") or {}
    summary = device.get("summary", {})
    if not role_report.get("found"):
        failures.append("backup_hdd: cannot prove dock passthrough because backup HDD was not found")
    else:
        if summary.get("smart_passed") is None:
            failures.append("backup_hdd: SMART data is not available through the dock")
        if str(summary.get("lsblk_transport") or "").lower() != "usb":
            failures.append(f"backup_hdd: expected USB transport through dock, got {summary.get('lsblk_transport')!r}")

    report["failures"] = failures
    report["warnings"] = warnings
    report["ok"] = not failures
    write_json(run_dir / "assert_dock_passthrough_report.json", report)

    print(f"assert-dock-passthrough report: {rel(run_dir / 'assert_dock_passthrough_report.json')}")
    return 0 if report["ok"] else 2


def cmd_assert_role(command: str, role: str) -> int:
    run_dir = make_run_dir(command)
    report = command_report_base(command, run_dir)
    role_report = capture_role(role, run_dir, required_override=True)
    report["roles"] = {role_key(role): role_report}
    report["failures"] = list(role_report.get("failures", []))
    report["warnings"] = list(role_report.get("warnings", []))
    report["ok"] = bool(role_report.get("ok"))
    write_json(run_dir / f"{command}_report.json", report)

    print(f"{command} report: {rel(run_dir / f'{command}_report.json')}")
    return 0 if report["ok"] else 2


def gate_role(role: str, run_dir: Path) -> dict[str, Any]:
    return capture_role(role, run_dir, required_override=True)


def dock_passthrough_failures_from_role(role_report: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    device = role_report.get("device") or {}
    summary = device.get("summary", {})
    if not role_report.get("found"):
        failures.append("backup_hdd: cannot prove dock passthrough because backup HDD was not found")
    else:
        if summary.get("smart_passed") is None:
            failures.append("backup_hdd: SMART data is not available through the dock")
        if str(summary.get("lsblk_transport") or "").lower() != "usb":
            failures.append(f"backup_hdd: expected USB transport through dock, got {summary.get('lsblk_transport')!r}")
    return failures


def cmd_gate(mode: str | None) -> int:
    gate_mode = mode or "local"
    gate_cfg = cfg_get(f"gate_modes.{gate_mode}")
    if not isinstance(gate_cfg, dict):
        raise SystemExit(f"Unknown gate mode: {gate_mode}")

    run_dir = make_run_dir(f"gate-{gate_mode}")
    report = command_report_base("gate", run_dir)
    report["gate_mode"] = gate_mode
    report["roles"] = {}

    role_requirements = {
        "source": bool(gate_cfg.get("require_source", True)),
        "backup_hdd": bool(gate_cfg.get("require_backup_hdd", False)),
        "replacement_ssd": bool(gate_cfg.get("require_replacement_ssd", False)),
    }

    for role, required in role_requirements.items():
        if not required:
            continue
        role_report = gate_role(role, run_dir)
        report["roles"][role] = role_report
        report["failures"].extend(role_report.get("failures", []))
        report["warnings"].extend(role_report.get("warnings", []))

    if gate_mode == "full":
        backup_report = report["roles"].get("backup_hdd")
        if backup_report is not None:
            report["failures"].extend(dock_passthrough_failures_from_role(backup_report))
        else:
            report["failures"].append("full gate: backup_hdd role was not captured")

    report["ok"] = not report["failures"]
    write_json(run_dir / "gate_report.json", report)

    print(f"gate report: {rel(run_dir / 'gate_report.json')}")
    if report["ok"]:
        print(f"gate {gate_mode}: PASS")
    else:
        print(f"gate {gate_mode}: FAIL", file=sys.stderr)
        for failure in report["failures"]:
            print(f"  - {failure}", file=sys.stderr)
    return 0 if report["ok"] else 2


def main() -> int:
    if not ARGS or ARGS[0] in {"help", "-h", "--help"}:
        print_usage()
        return 0

    command = ARGS[0]
    arg1 = ARGS[1] if len(ARGS) > 1 else None

    if command == "scan":
        return cmd_scan()
    if command == "capture-source":
        return cmd_capture_role(command, "source")
    if command == "capture-backup-hdd":
        return cmd_capture_role(command, "backup_hdd")
    if command == "capture-replacement-ssd":
        return cmd_capture_role(command, "replacement_ssd")
    if command == "selftest-short":
        return cmd_selftest_short(arg1)
    if command == "selftest-log":
        return cmd_selftest_log(arg1)
    if command == "assert-dock-passthrough":
        return cmd_assert_dock_passthrough()
    if command == "assert-backup-hdd":
        return cmd_assert_role(command, "backup_hdd")
    if command == "assert-replacement-ssd":
        return cmd_assert_role(command, "replacement_ssd")
    if command == "gate":
        return cmd_gate(arg1)

    print_usage()
    raise SystemExit(f"Unknown command: {command}")


if __name__ == "__main__":
    raise SystemExit(main())
PY