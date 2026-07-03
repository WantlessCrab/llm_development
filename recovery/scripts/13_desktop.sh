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
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "13_desktop.sh"
SCHEMA_NAME = "recovery.desktop.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {
        "name": "desktop",
        "verified_dconf_cli_version": "0.40.0-4ubuntu0.1",
        "verified_dconf_editor_version": "45.0.1-1build2",
        "layer": "13_desktop_session_user_experience_settings",
    },
    "project": {
        "root": str(PROJECT_ROOT),
        "output_root": "state/dry_runs/13_desktop",
        "generated_root": "state/generated/13_desktop",
    },
    "commands": {
        "dconf": "/usr/bin/dconf",
        "xrandr": "/usr/bin/xrandr",
        "loginctl": "/usr/bin/loginctl",
        "systemctl": "/usr/bin/systemctl",
        "pactl": "/usr/bin/pactl",
        "wpctl": "/usr/bin/wpctl",
        "xdg_mime": "/usr/bin/xdg-mime",
        "gio": "/usr/bin/gio",
        "python": "/usr/bin/python3",
        "sha256sum": "/usr/bin/sha256sum",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "desktop_report.json",
        "generated_script_mode": "0600",
        "dconf_load_guard_env": "CONFIRM_DCONF_LOAD",
        "dconf_load_guard_value": "I_UNDERSTAND_THIS_MUTATES_DESKTOP_SETTINGS",
        "fail_if_dconf_missing": True,
        "fail_if_not_cinnamon_x11_for_restore": True,
        "fail_if_dbus_unavailable_for_restore": True,
        "fail_if_display_unavailable_for_monitor_capture": False,
        "copy_small_file_backed_configs": True,
        "file_copy_max_bytes": 10485760,
        "inventory_max_entries_per_root": 25000,
        "hash_small_files": True,
        "hash_max_bytes": 1048576,
        "include_system_autostart_inventory": True,
        "include_system_theme_inventory": False,
        "include_xrandr_verbose": True,
        "include_sysfs_edid": True,
        "include_pactl_full_cards": False,
        "include_pactl_full_sinks_sources": False,
        "include_input_remapper_inventory": True,
        "restore_preview_name": "desktop_restore_preview.md",
    },
    "session": {
        "expected_desktop": "X-Cinnamon",
        "expected_session_type": "x11",
        "expected_display": ":0",
    },
    "dconf": {
        "export_paths": "/org/cinnamon/;/org/gnome/desktop/;/org/nemo/;/org/gtk/settings/;/org/gnome/settings-daemon/;/org/cinnamon/settings-daemon/",
        "restore_allowed_paths": "/org/cinnamon/;/org/gnome/desktop/;/org/nemo/;/org/gtk/settings/;/org/gnome/settings-daemon/;/org/cinnamon/settings-daemon/",
        "wallpaper_keys": "/org/cinnamon/desktop/background/picture-uri;/org/gnome/desktop/background/picture-uri;/org/cinnamon/desktop/background/slideshow/image-source",
    },
    "files": {
        "copy_roots": "~/.cinnamon/configs;~/.config/autostart;~/.config/gtk-3.0;~/.config/gtk-4.0;~/.config/nemo;~/.config/cinnamon-session;~/.local/share/applications;~/.config/mimeapps.list;~/.local/share/applications/mimeapps.list",
        "inventory_roots": "~/.local/share/cinnamon/applets;~/.local/share/cinnamon/desklets;~/.local/share/cinnamon/extensions;~/.themes;~/.icons;~/.local/share/themes;~/.local/share/icons;~/.config/dconf;~/.config/pulse;~/.config/pipewire;~/.config/wireplumber",
        "input_inventory_roots": "~/.config/input-remapper-2;~/.config/solaar;~/.config/piper;~/.local/share/input-remapper-2",
        "system_autostart_roots": "/etc/xdg/autostart",
        "system_theme_roots": "/usr/share/themes;/usr/share/icons;/usr/share/cinnamon/applets;/usr/share/cinnamon/desklets;/usr/share/cinnamon/extensions",
    },
    "monitor": {
        "known_physical_map": {
            "DisplayPort-5": "top / ONN 100027813",
            "HDMI-A-2": "center primary / Samsung LS27D300G",
            "DisplayPort-4": "left / Sceptre E24",
            "DisplayPort-3": "right / HP 25es",
        },
        "preferred_framebuffer": "",
        "preferred_outputs": "",
        "preferred_layout_note": "Live capture is authoritative. Do not preserve stale hardcoded monitor geometry as a restore command.",
    },
    "audio_input": {
        "expected_default_sink_contains": "EDIFIER_M90",
        "expected_default_source_contains": "C920",
        "capture_commands": "pactl_info;pactl_short_cards;pactl_short_sinks;pactl_short_sources;wpctl_status",
    },
}

CAPTURE_SESSION_SUBCOMMANDS = [
    "validate-restore-context",
    "export-dconf",
    "export-cinnamon-files",
    "capture-monitor-layout",
    "capture-monitor-edid",
    "capture-audio-input",
    "capture-theme-icon-cursor",
    "capture-wallpaper",
    "capture-autostart",
]


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
    path = PROJECT_ROOT / "configs" / "13_desktop.yaml"
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


DCONF = cmd_path("dconf")
XRANDR = cmd_path("xrandr")
LOGINCTL = cmd_path("loginctl")
SYSTEMCTL = cmd_path("systemctl")
PACTL = cmd_path("pactl")
WPCTL = cmd_path("wpctl")
XDG_MIME = cmd_path("xdg_mime")
GIO = cmd_path("gio")
PYTHON = cmd_path("python")
SHA256SUM = cmd_path("sha256sum")


def iso_now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def now_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def resolve_path(value: str | Path) -> Path:
    raw = str(value)
    p = Path(raw).expanduser()
    return p.resolve() if p.is_absolute() else (PROJECT_ROOT / p).resolve()


def rel(path: str | Path) -> str:
    p = Path(path).resolve()
    try:
        return str(p.relative_to(PROJECT_ROOT))
    except ValueError:
        return str(p)


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/13_desktop")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "13_desktop.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "13_desktop.config.snapshot.yaml")
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
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def file_record(path: Path, *, include_hash: bool = False) -> dict[str, Any]:
    try:
        st = path.lstat()
    except OSError as exc:
        return {"path": str(path), "exists": False, "error": str(exc)}
    payload: dict[str, Any] = {
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
    }
    if path.is_symlink():
        try:
            payload["symlink_target"] = os.readlink(path)
            target = path.resolve(strict=False)
            payload["target_resolved"] = str(target)
            payload["target_exists"] = target.exists()
        except OSError as exc:
            payload["symlink_error"] = str(exc)
    if include_hash and path.is_file() and not path.is_symlink():
        payload["sha256"] = sha256_file(path)
    return payload


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {
            "name": "desktop",
            "script": SCRIPT_NAME,
            "dconf_path": DCONF,
            "dconf_version": None,
            "xrandr_path": XRANDR,
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
    report_path = run_dir / str(cfg_get("policy.report_name", "desktop_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def run_cmd(argv: list[str], report: dict[str, Any], *, label: str, check: bool = False, env: dict[str, str] | None = None, input_text: str | None = None) -> dict[str, Any]:
    proc = subprocess.run(argv, text=True, capture_output=True, env=env, input=input_text)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", label)
    run_dir = resolve_path(report["run_dir"])
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)
    record = {"argv": argv[:], "returncode": proc.returncode, "stdout_path": rel(stdout_path), "stderr_path": rel(stderr_path), "stderr": proc.stderr}
    report["commands"].append(record)
    if check and proc.returncode != 0:
        report["failures"].append(f"command failed [{label}]: {' '.join(argv)} :: {proc.stderr.strip()}")
    return {"argv": argv[:], "returncode": proc.returncode, "stdout": proc.stdout, "stderr": proc.stderr, "record": record}


def command_exists(path: str) -> bool:
    return Path(path).exists() or shutil.which(path) is not None


def dconf_preflight(report: dict[str, Any]) -> None:
    if not command_exists(DCONF):
        msg = f"dconf command not found at configured path: {DCONF}"
        if boolish(cfg_get("policy.fail_if_dconf_missing", True)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
        return
    help_result = run_cmd([DCONF, "help"], report, label="dconf_help")
    report["tool"]["dconf_version"] = "dconf-cli present; this build does not expose --version"
    if help_result["returncode"] != 0:
        report["failures"].append("dconf help failed")


def session_context() -> dict[str, Any]:
    payload = {
        "XDG_CURRENT_DESKTOP": os.environ.get("XDG_CURRENT_DESKTOP"),
        "DESKTOP_SESSION": os.environ.get("DESKTOP_SESSION"),
        "XDG_SESSION_TYPE": os.environ.get("XDG_SESSION_TYPE"),
        "XDG_SESSION_ID": os.environ.get("XDG_SESSION_ID"),
        "XDG_SESSION_CLASS": os.environ.get("XDG_SESSION_CLASS"),
        "DISPLAY": os.environ.get("DISPLAY"),
        "WAYLAND_DISPLAY": os.environ.get("WAYLAND_DISPLAY"),
        "XAUTHORITY": os.environ.get("XAUTHORITY"),
        "DBUS_SESSION_BUS_ADDRESS": os.environ.get("DBUS_SESSION_BUS_ADDRESS"),
        "HOME": os.environ.get("HOME"),
    }
    return payload


def validate_session(report: dict[str, Any], *, restore: bool = False) -> dict[str, Any]:
    ctx = session_context()
    expected_desktop = str(cfg_get("session.expected_desktop", "X-Cinnamon"))
    expected_type = str(cfg_get("session.expected_session_type", "x11"))
    result = {"context": ctx, "expected_desktop": expected_desktop, "expected_session_type": expected_type, "ok_for_cinnamon_restore": True}
    if restore and boolish(cfg_get("policy.fail_if_not_cinnamon_x11_for_restore", True)):
        if ctx.get("XDG_CURRENT_DESKTOP") != expected_desktop:
            result["ok_for_cinnamon_restore"] = False
            report["failures"].append(f"restore requires XDG_CURRENT_DESKTOP={expected_desktop}; got {ctx.get('XDG_CURRENT_DESKTOP')}")
        if ctx.get("XDG_SESSION_TYPE") != expected_type:
            result["ok_for_cinnamon_restore"] = False
            report["failures"].append(f"restore requires XDG_SESSION_TYPE={expected_type}; got {ctx.get('XDG_SESSION_TYPE')}")
        if not ctx.get("DISPLAY"):
            result["ok_for_cinnamon_restore"] = False
            report["failures"].append("restore requires DISPLAY to be set")
        if boolish(cfg_get("policy.fail_if_dbus_unavailable_for_restore", True)) and not ctx.get("DBUS_SESSION_BUS_ADDRESS"):
            result["ok_for_cinnamon_restore"] = False
            report["failures"].append("restore requires DBUS_SESSION_BUS_ADDRESS to be set")
    return result


def normalize_dconf_path(path: str) -> str:
    value = path.strip()
    if not value.startswith("/"):
        value = "/" + value
    if not value.endswith("/"):
        value += "/"
    return value


def safe_name(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip("/").replace("/", "__")) or "root"


def export_dconf(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-dconf")
    report = report_base("export-dconf", run_dir)
    report["mode"] = "capture"
    dconf_preflight(report)
    report["session"] = validate_session(report)
    dump_root = run_dir / "dconf_dumps"
    dump_root.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, Any] = {"paths": [], "restore_allowed_paths": split_semicolon(cfg_get("dconf.restore_allowed_paths", ""))}
    if not report["failures"]:
        for raw_path in split_semicolon(cfg_get("dconf.export_paths", "")):
            path = normalize_dconf_path(raw_path)
            result = run_cmd([DCONF, "dump", path], report, label=f"dconf_dump_{safe_name(path)}")
            dump_path = dump_root / f"{safe_name(path)}.dconf"
            write_text(dump_path, result["stdout"])
            rec = {"dconf_path": path, "dump_path": rel(dump_path), "returncode": result["returncode"], "bytes": dump_path.stat().st_size}
            if result["returncode"] != 0:
                rec["error"] = result["stderr"]
                report["warnings"].append(f"dconf dump failed for {path}: {result['stderr'].strip()}")
            manifest["paths"].append(rec)
            output_file(report, dump_path, "dconf_dump", f"dconf_{safe_name(path)}", {"dconf_path": path})
    manifest_path = run_dir / "dconf_export_manifest.json"
    write_json(manifest_path, manifest)
    report["dconf"] = {"manifest": rel(manifest_path), "path_count": len(manifest["paths"])}
    output_file(report, manifest_path, "json", "dconf_export_manifest")
    return finalize_report(report, run_dir)


def find_latest_export_dir() -> Path | None:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/13_desktop")))
    if not root.exists():
        return None
    candidates = sorted(root.glob("*/export-dconf"), reverse=True)
    return candidates[0] if candidates else None


def find_latest_cinnamon_files_manifest() -> Path | None:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/13_desktop")))
    if not root.exists():
        return None
    candidates = sorted(root.glob("*/export-cinnamon-files/cinnamon_files_manifest.json"), reverse=True)
    return candidates[0] if candidates else None


def load_dconf_preview(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("load-dconf-preview")
    report = report_base("load-dconf-preview", run_dir)
    report["mode"] = "preview"
    dconf_preflight(report)
    source_dir = resolve_path(args.source) if args.source else find_latest_export_dir()
    allowed = {normalize_dconf_path(p) for p in split_semicolon(cfg_get("dconf.restore_allowed_paths", ""))}
    lines = [
        "# dconf restore preview",
        "",
        "This is a preview only. It does not load values into dconf.",
        "",
        "Guarded restore command shape:",
        "",
        f"{SCRIPT_NAME} load-dconf-guarded --source {source_dir or '<export-dconf-run-dir>'} --execute",
        "",
        "Required environment token:",
        "",
        f"{cfg_get('policy.dconf_load_guard_env')}={cfg_get('policy.dconf_load_guard_value')}",
        "",
        "## Candidate dconf dumps",
        "",
    ]
    manifest: dict[str, Any] = {"source_dir": str(source_dir) if source_dir else None, "allowed_paths": sorted(allowed), "dumps": []}
    if not source_dir or not source_dir.exists():
        report["failures"].append("no dconf export source directory was provided or discovered")
    else:
        for dump_path in sorted((source_dir / "dconf_dumps").glob("*.dconf")):
            inferred = dump_path.stem.replace("__", "/")
            rec = file_record(dump_path, include_hash=True)
            rec["inferred_from_name"] = inferred
            manifest["dumps"].append(rec)
            lines.append(f"- `{dump_path}` bytes={rec.get('size_bytes')}")
    preview_path = run_dir / str(cfg_get("policy.restore_preview_name", "desktop_restore_preview.md"))
    manifest_path = run_dir / "dconf_load_preview.json"
    write_text(preview_path, "\n".join(lines))
    write_json(manifest_path, manifest)
    report["restore_plan"] = {"preview": rel(preview_path), "manifest": rel(manifest_path)}
    output_file(report, preview_path, "markdown", "dconf_load_preview")
    output_file(report, manifest_path, "json", "dconf_load_preview_manifest")
    return finalize_report(report, run_dir)


def dconf_path_from_dump_filename(path: Path) -> str:
    text = path.stem.replace("__", "/")
    if text.startswith("org/"):
        text = "/" + text
    if not text.endswith("/"):
        text += "/"
    return text


def load_dconf_guarded(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("load-dconf-guarded")
    report = report_base("load-dconf-guarded", run_dir)
    report["mode"] = "restore"
    dconf_preflight(report)
    report["session"] = validate_session(report, restore=True)
    guard_env = str(cfg_get("policy.dconf_load_guard_env", "CONFIRM_DCONF_LOAD"))
    guard_value = str(cfg_get("policy.dconf_load_guard_value", "I_UNDERSTAND_THIS_MUTATES_DESKTOP_SETTINGS"))
    if not args.execute:
        report["failures"].append("load-dconf-guarded requires --execute")
    if os.environ.get(guard_env) != guard_value:
        report["failures"].append(f"load-dconf-guarded requires {guard_env}={guard_value}")
    source_dir = resolve_path(args.source) if args.source else None
    if not source_dir or not source_dir.exists():
        report["failures"].append("load-dconf-guarded requires --source pointing at an export-dconf run directory")
    allowed = {normalize_dconf_path(p) for p in split_semicolon(cfg_get("dconf.restore_allowed_paths", ""))}
    loaded: list[dict[str, Any]] = []
    candidate_dumps: list[tuple[Path, str]] = []
    if not report["failures"] and source_dir:
        for dump_path in sorted((source_dir / "dconf_dumps").glob("*.dconf")):
            dpath = dconf_path_from_dump_filename(dump_path)
            if dpath not in allowed:
                report["warnings"].append(f"skipping dconf dump outside restore allow-list: {dump_path} -> {dpath}")
                continue
            candidate_dumps.append((dump_path, dpath))

    if not report["failures"] and not candidate_dumps:
        report["failures"].append("load-dconf-guarded found no allow-listed .dconf dumps to load")
    if not report["failures"] and candidate_dumps:
        backup_dir = run_dir / "pre_load_dconf_backup"
        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_records = []
        for _dump_path, dpath in candidate_dumps:
            backup = run_cmd([DCONF, "dump", dpath], report, label=f"preload_dconf_dump_{safe_name(dpath)}")
            backup_path = backup_dir / f"{safe_name(dpath)}.dconf"
            write_text(backup_path, backup["stdout"])
            backup_records.append({"dconf_path": dpath, "backup_path": rel(backup_path), "returncode": backup["returncode"]})
        report.setdefault("outputs", []).append({"kind": "pre_load_dconf_backup", "path": rel(backup_dir), "record_count": len(backup_records)})
        for dump_path, dpath in candidate_dumps:
            text = dump_path.read_text(encoding="utf-8")
            result = run_cmd([DCONF, "load", dpath], report, label=f"dconf_load_{safe_name(dpath)}", input_text=text)
            loaded.append({"dconf_path": dpath, "dump_path": rel(dump_path), "returncode": result["returncode"]})
            if result["returncode"] != 0:
                report["failures"].append(f"dconf load failed for {dpath}")
    report["dconf"] = {"loaded": loaded, "pre_load_backups": backup_records if "backup_records" in locals() else [], "source_dir": str(source_dir) if source_dir else None}
    return finalize_report(report, run_dir)


def inventory_root(root: Path, report: dict[str, Any], *, copy_to: Path | None = None, include_hash: bool = True) -> dict[str, Any]:
    max_entries = int(cfg_get("policy.inventory_max_entries_per_root", 25000))
    max_copy = int(cfg_get("policy.file_copy_max_bytes", 10485760))
    hash_small = boolish(cfg_get("policy.hash_small_files", True))
    hash_max = int(cfg_get("policy.hash_max_bytes", 1048576))
    rec: dict[str, Any] = {"root": str(root), "exists": root.exists(), "entries": [], "truncated": False, "file_count": 0, "dir_count": 0, "copied_count": 0}
    if not root.exists():
        return rec
    candidates = [root] if root.is_file() or root.is_symlink() else sorted(root.rglob("*"))
    for index, path in enumerate(candidates):
        if index >= max_entries:
            rec["truncated"] = True
            break
        item = file_record(path, include_hash=include_hash and hash_small and path.is_file() and path.stat().st_size <= hash_max if path.exists() and not path.is_symlink() else False)
        try:
            item["relative_path"] = str(path.relative_to(root if root.is_dir() else root.parent))
        except ValueError:
            item["relative_path"] = path.name
        if item.get("is_file"):
            rec["file_count"] += 1
        if item.get("is_dir"):
            rec["dir_count"] += 1
        if copy_to and path.is_file() and not path.is_symlink():
            size = int(item.get("size_bytes", 0))
            if size <= max_copy:
                dest = copy_to / safe_name(str(root)) / item["relative_path"]
                dest.parent.mkdir(parents=True, exist_ok=True)
                try:
                    shutil.copy2(path, dest)
                    item["copied_to"] = rel(dest)
                    rec["copied_count"] += 1
                except OSError as exc:
                    item["copy_error"] = str(exc)
                    report["warnings"].append(f"could not copy {path}: {exc}")
        rec["entries"].append(item)
    return rec


def export_cinnamon_files(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("export-cinnamon-files")
    report = report_base("export-cinnamon-files", run_dir)
    report["mode"] = "capture"
    report["session"] = validate_session(report)
    copy_root = run_dir / "file_backed_config_snapshot" if boolish(cfg_get("policy.copy_small_file_backed_configs", True)) else None
    manifest: dict[str, Any] = {"copy_roots": [], "inventory_roots": [], "input_inventory_roots": [], "payload_boundary": "Borg owns complete byte-level file payload backup; Row 13 records desktop meaning and selected small config snapshots."}
    for raw in split_semicolon(cfg_get("files.copy_roots", "")):
        root = resolve_path(raw)
        manifest["copy_roots"].append(inventory_root(root, report, copy_to=copy_root, include_hash=True))
    for raw in split_semicolon(cfg_get("files.inventory_roots", "")):
        root = resolve_path(raw)
        manifest["inventory_roots"].append(inventory_root(root, report, copy_to=None, include_hash=True))
    if boolish(cfg_get("policy.include_input_remapper_inventory", True)):
        for raw in split_semicolon(cfg_get("files.input_inventory_roots", "")):
            root = resolve_path(raw)
            manifest["input_inventory_roots"].append(inventory_root(root, report, copy_to=None, include_hash=True))
    manifest_path = run_dir / "cinnamon_files_manifest.json"
    write_json(manifest_path, manifest)
    report["files"] = {"manifest": rel(manifest_path), "copy_roots": len(manifest["copy_roots"]), "inventory_roots": len(manifest["inventory_roots"])}
    output_file(report, manifest_path, "json", "cinnamon_files_manifest")
    return finalize_report(report, run_dir)


def restore_cinnamon_preview(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("restore-cinnamon-preview")
    report = report_base("restore-cinnamon-preview", run_dir)
    report["mode"] = "preview"
    report["session"] = validate_session(report)
    input_manifest = resolve_path(args.input_manifest) if args.input_manifest else find_latest_cinnamon_files_manifest()
    commands: list[dict[str, str]] = []
    if input_manifest:
        if not input_manifest.exists():
            report["failures"].append(f"input manifest does not exist: {input_manifest}")
        else:
            try:
                manifest = json.loads(input_manifest.read_text(encoding="utf-8"))
                for group in manifest.get("copy_roots", []):
                    for entry in group.get("entries", []):
                        copied_to = entry.get("copied_to")
                        destination = entry.get("path")
                        if copied_to and destination:
                            source_abs = str(resolve_path(copied_to))
                            commands.append({
                                "source": source_abs,
                                "destination": destination,
                                "command": f"install -D {shlex.quote(source_abs)} {shlex.quote(destination)}"
                            })
            except json.JSONDecodeError as exc:
                report["failures"].append(f"input manifest is not valid JSON: {exc}")
    else:
        report["warnings"].append("no export-cinnamon-files manifest was supplied or discovered")
    lines = [
        "# Cinnamon file-backed settings restore preview",
        "",
        "This is a preview only. It does not copy files into live config paths.",
        "",
        f"Input manifest: `{input_manifest}`" if input_manifest else "Input manifest: `<not found>`",
        "",
        "Row 13 restores file-backed desktop semantics only after Row 10/11 have restored native/Flatpak apps and Row 06/07 have restored payload files.",
        "",
        "## Intended restore sequence",
        "",
        "1. Restore packages, Flatpaks, and user file payloads first.",
        "2. Review `cinnamon_files_manifest.json` from `export-cinnamon-files`.",
        "3. Copy selected small config files only after confirming target paths.",
        "4. Log out/in or restart Cinnamon only after review.",
        "",
        "## Concrete preview commands",
        "",
    ]
    if commands:
        lines.extend(f"- `{item['command']}`" for item in commands)
    else:
        lines.append("- No copied user config entries were found. This remains a generic preview.")
    lines.extend([
        "",
        "## Explicit non-actions",
        "",
        "- no file copy",
        "- no dconf load",
        "- no Cinnamon restart",
        "- no xrandr application",
        "",
    ])
    path = run_dir / str(cfg_get("policy.restore_preview_name", "desktop_restore_preview.md"))
    manifest_path = run_dir / "desktop_restore_file_manifest.json"
    write_text(path, "\n".join(lines))
    write_json(manifest_path, {"input_manifest": str(input_manifest) if input_manifest else None, "commands": commands, "command_count": len(commands)})
    report["restore_plan"] = {"preview": rel(path), "manifest": rel(manifest_path), "command_count": len(commands)}
    output_file(report, path, "markdown", "restore_cinnamon_preview")
    output_file(report, manifest_path, "json", "desktop_restore_file_manifest")
    return finalize_report(report, run_dir)


def parse_xrandr_query(text: str) -> dict[str, Any]:
    result: dict[str, Any] = {"screen": {}, "outputs": []}
    first = text.splitlines()[0] if text.splitlines() else ""
    m = re.search(r"current\s+(\d+)\s+x\s+(\d+)", first)
    if m:
        result["screen"]["current_width"] = int(m.group(1))
        result["screen"]["current_height"] = int(m.group(2))
    output_re = re.compile(r"^(\S+)\s+(connected|disconnected)(?:\s+primary)?(?:\s+(\d+x\d+[-+]\d+[-+]\d+))?")
    current_output: dict[str, Any] | None = None
    for line in text.splitlines():
        m = output_re.match(line)
        if m:
            name, state, geometry = m.groups()
            item: dict[str, Any] = {"name": name, "state": state, "primary": " primary " in f" {line} ", "geometry": geometry, "raw": line}
            gm = re.match(r"(\d+)x(\d+)([-+]\d+)([-+]\d+)", geometry or "")
            if gm:
                item.update({"width": int(gm.group(1)), "height": int(gm.group(2)), "x": int(gm.group(3)), "y": int(gm.group(4))})
            result["outputs"].append(item)
            current_output = item
            continue
        if current_output and current_output.get("state") == "connected":
            mode_match = re.match(r"^\s+(\d+x\d+)\s+(.+)$", line)
            if mode_match and "*" in mode_match.group(2):
                current_output["active_mode"] = mode_match.group(1)
                rate_match = re.search(r"(\d+(?:\.\d+)?)\*", mode_match.group(2))
                if rate_match:
                    current_output["active_rate"] = rate_match.group(1)
    return result


def xrandr_command_from_layout(layout: dict[str, Any]) -> str:
    outputs = []
    for output in layout.get("outputs", []):
        if output.get("state") != "connected" or not output.get("geometry"):
            continue
        mode = output.get("active_mode") or f"{output.get('width')}x{output.get('height')}"
        pos = f"{output.get('x')}x{output.get('y')}"
        parts = [f"--output {shlex.quote(output['name'])}"]
        if output.get("primary"):
            parts.append("--primary")
        parts.extend([f"--mode {mode}"])
        if output.get("active_rate"):
            parts.extend([f"--rate {output['active_rate']}"])
        parts.extend([f"--pos {pos}", "--rotate normal", "--panning 0x0"])
        outputs.append(" ".join(parts))
    fb = ""
    screen = layout.get("screen", {})
    if screen.get("current_width") and screen.get("current_height"):
        fb = f"--fb {screen['current_width']}x{screen['current_height']} "
    return "xrandr " + fb + "\\\n  " + " \\\n  ".join(outputs) if outputs else "xrandr"


def preferred_xrandr_command() -> str:
    fb = str(cfg_get("monitor.preferred_framebuffer", "")).strip()
    chunks = []
    for spec in split_semicolon(cfg_get("monitor.preferred_outputs", "")):
        parts = spec.split(":")
        if len(parts) < 5:
            continue
        name, mode, rate, pos, rotate, *flags = parts
        line = f"--output {shlex.quote(name)}"
        if "primary" in flags:
            line += " --primary"
        line += f" --mode {mode} --rate {rate} --pos {pos} --rotate {rotate} --panning 0x0"
        chunks.append(line)
    if not chunks:
        return "# No static preferred XRandR layout configured. Use the captured current layout as the review authority."
    return "xrandr " + (f"--fb {fb} " if fb else "") + "\\\n  " + " \\\n  ".join(chunks)


def capture_monitor_layout(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-monitor-layout")
    report = report_base("capture-monitor-layout", run_dir)
    report["mode"] = "capture"
    report["session"] = validate_session(report)
    if not command_exists(XRANDR):
        msg = f"xrandr not found: {XRANDR}"
        if boolish(cfg_get("policy.fail_if_display_unavailable_for_monitor_capture", False)):
            report["failures"].append(msg)
        else:
            report["warnings"].append(msg)
            return finalize_report(report, run_dir)
    if not report["failures"]:
        query = run_cmd([XRANDR, "--query"], report, label="xrandr_query")
        verbose = None
        if boolish(cfg_get("policy.include_xrandr_verbose", True)):
            verbose = run_cmd([XRANDR, "--verbose"], report, label="xrandr_verbose")
        layout = parse_xrandr_query(query["stdout"]) if query["returncode"] == 0 else {}
        current_cmd = xrandr_command_from_layout(layout)
        preferred_cmd = preferred_xrandr_command()
        current_path = run_dir / "xrandr_current_layout.review.sh"
        preferred_path = run_dir / "xrandr_preferred_layout.review.sh"
        write_text(current_path, "#!/usr/bin/env bash\nset -euo pipefail\n\n" + current_cmd + "\n")
        write_text(preferred_path, "#!/usr/bin/env bash\nset -euo pipefail\n\n# Review before applying.\n" + preferred_cmd + "\n")
        current_path.chmod(0o600)
        preferred_path.chmod(0o600)
        manifest = {"layout": layout, "known_physical_map": cfg_get("monitor.known_physical_map", {}), "current_command": current_cmd, "preferred_command": preferred_cmd}
        manifest_path = run_dir / "monitor_layout_manifest.json"
        write_json(manifest_path, manifest)
        report["monitor"] = {"manifest": rel(manifest_path), "current_script": rel(current_path), "preferred_script": rel(preferred_path)}
        output_file(report, manifest_path, "json", "monitor_layout_manifest")
        output_file(report, current_path, "shell", "xrandr_current_layout_script")
        output_file(report, preferred_path, "shell", "xrandr_preferred_layout_review_script")
    return finalize_report(report, run_dir)


def extract_edid_blocks(xrandr_verbose: str) -> dict[str, str]:
    blocks: dict[str, str] = {}
    current: str | None = None
    collecting = False
    lines: list[str] = []
    for raw in xrandr_verbose.splitlines():
        if re.match(r"^\S+\s+(connected|disconnected)", raw):
            if current and lines:
                blocks[current] = "\n".join(lines)
            current = raw.split()[0]
            collecting = False
            lines = []
            continue
        if "EDID:" in raw:
            collecting = True
            lines = []
            continue
        if collecting:
            text = raw.strip()
            if re.fullmatch(r"[0-9a-fA-F]+", text):
                lines.append(text)
            elif text and not raw.startswith("\t"):
                collecting = False
    if current and lines:
        blocks[current] = "\n".join(lines)
    return blocks


def capture_monitor_edid(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-monitor-edid")
    report = report_base("capture-monitor-edid", run_dir)
    report["mode"] = "capture"
    report["session"] = validate_session(report)
    manifest: dict[str, Any] = {"xrandr_edid": {}, "sysfs_edid": []}
    if command_exists(XRANDR):
        verbose = run_cmd([XRANDR, "--verbose"], report, label="xrandr_verbose_edid")
        if verbose["returncode"] == 0:
            manifest["xrandr_edid"] = extract_edid_blocks(verbose["stdout"])
    else:
        report["warnings"].append(f"xrandr not found: {XRANDR}")
    if boolish(cfg_get("policy.include_sysfs_edid", True)):
        for edid in sorted(Path("/sys/class/drm").glob("*/edid")):
            rec = file_record(edid, include_hash=True)
            try:
                if edid.exists() and edid.stat().st_size > 0:
                    dest = run_dir / "sysfs_edid" / f"{edid.parent.name}.edid"
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(edid, dest)
                    rec["copied_to"] = rel(dest)
            except OSError as exc:
                rec["copy_error"] = str(exc)
            manifest["sysfs_edid"].append(rec)
    path = run_dir / "monitor_edid_manifest.json"
    write_json(path, manifest)
    report["edid"] = {"manifest": rel(path), "xrandr_blocks": len(manifest["xrandr_edid"]), "sysfs_records": len(manifest["sysfs_edid"])}
    output_file(report, path, "json", "monitor_edid_manifest")
    return finalize_report(report, run_dir)


def capture_audio_input(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-audio-input")
    report = report_base("capture-audio-input", run_dir)
    report["mode"] = "capture"
    report["session"] = validate_session(report)
    manifest: dict[str, Any] = {"expected": {"sink_contains": cfg_get("audio_input.expected_default_sink_contains"), "source_contains": cfg_get("audio_input.expected_default_source_contains")}, "command_outputs": {}, "input_config_roots": []}
    commands = {
        "pactl_info": [PACTL, "info"],
        "pactl_short_cards": [PACTL, "list", "short", "cards"],
        "pactl_short_sinks": [PACTL, "list", "short", "sinks"],
        "pactl_short_sources": [PACTL, "list", "short", "sources"],
        "wpctl_status": [WPCTL, "status"],
    }
    if boolish(cfg_get("policy.include_pactl_full_cards", False)):
        commands["pactl_full_cards"] = [PACTL, "list", "cards"]
    if boolish(cfg_get("policy.include_pactl_full_sinks_sources", False)):
        commands["pactl_full_sinks"] = [PACTL, "list", "sinks"]
        commands["pactl_full_sources"] = [PACTL, "list", "sources"]
    for name, argv in commands.items():
        if command_exists(argv[0]):
            result = run_cmd(argv, report, label=name)
            manifest["command_outputs"][name] = {"returncode": result["returncode"], "stdout_path": result["record"]["stdout_path"]}
        else:
            report["warnings"].append(f"command unavailable for audio/input capture: {argv[0]}")
    if boolish(cfg_get("policy.include_input_remapper_inventory", True)):
        for raw in split_semicolon(cfg_get("files.input_inventory_roots", "")):
            manifest["input_config_roots"].append(inventory_root(resolve_path(raw), report, copy_to=None, include_hash=True))
    path = run_dir / "audio_input_manifest.json"
    write_json(path, manifest)
    report["audio_input"] = {"manifest": rel(path)}
    output_file(report, path, "json", "audio_input_manifest")
    return finalize_report(report, run_dir)


def capture_theme_icon_cursor(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-theme-icon-cursor")
    report = report_base("capture-theme-icon-cursor", run_dir)
    report["mode"] = "capture"
    dconf_preflight(report)
    keys = {
        "cinnamon_theme": "/org/cinnamon/theme/name",
        "gtk_theme": "/org/cinnamon/desktop/interface/gtk-theme",
        "icon_theme": "/org/cinnamon/desktop/interface/icon-theme",
        "cursor_theme": "/org/cinnamon/desktop/interface/cursor-theme",
        "font_name": "/org/cinnamon/desktop/interface/font-name",
        "document_font_name": "/org/cinnamon/desktop/interface/document-font-name",
        "monospace_font_name": "/org/cinnamon/desktop/interface/monospace-font-name",
        "gnome_gtk_theme": "/org/gnome/desktop/interface/gtk-theme",
        "gnome_icon_theme": "/org/gnome/desktop/interface/icon-theme",
        "gnome_cursor_theme": "/org/gnome/desktop/interface/cursor-theme",
    }
    values: dict[str, Any] = {}
    if not report["failures"]:
        for label, key in keys.items():
            result = run_cmd([DCONF, "read", key], report, label=f"dconf_read_{safe_name(label)}")
            values[label] = {"key": key, "returncode": result["returncode"], "value": result["stdout"].strip()}
    roots = []
    for raw in split_semicolon(cfg_get("files.inventory_roots", "")):
        if any(token in raw for token in ["theme", "icon", "cinnamon/applets", "cinnamon/desklets", "cinnamon/extensions"]):
            roots.append(inventory_root(resolve_path(raw), report, copy_to=None, include_hash=True))
    if boolish(cfg_get("policy.include_system_theme_inventory", False)):
        for raw in split_semicolon(cfg_get("files.system_theme_roots", "")):
            roots.append(inventory_root(resolve_path(raw), report, copy_to=None, include_hash=False))
    manifest = {"dconf_values": values, "theme_icon_cursor_roots": roots, "payload_boundary": "Borg owns complete theme/icon payload files."}
    path = run_dir / "theme_icon_cursor_manifest.json"
    write_json(path, manifest)
    report["themes"] = {"manifest": rel(path), "root_count": len(roots)}
    output_file(report, path, "json", "theme_icon_cursor_manifest")
    return finalize_report(report, run_dir)


def parse_dconf_uri(raw: str) -> str | None:
    text = raw.strip().strip("'\"")
    if text.startswith("file://"):
        from urllib.parse import unquote, urlparse
        return unquote(urlparse(text).path)
    if text.startswith("/"):
        return text
    return None


def capture_wallpaper(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-wallpaper")
    report = report_base("capture-wallpaper", run_dir)
    report["mode"] = "capture"
    dconf_preflight(report)
    records: list[dict[str, Any]] = []
    if not report["failures"]:
        for key in split_semicolon(cfg_get("dconf.wallpaper_keys", "")):
            result = run_cmd([DCONF, "read", key], report, label=f"dconf_read_wallpaper_{safe_name(key)}")
            value = result["stdout"].strip()
            file_path = parse_dconf_uri(value)
            rec: dict[str, Any] = {"key": key, "returncode": result["returncode"], "value": value, "file_path": file_path}
            if file_path:
                rec["file"] = file_record(Path(file_path), include_hash=True)
            records.append(rec)
    manifest = {"wallpaper_records": records, "payload_boundary": "Borg owns wallpaper image payload files; Row 13 records desktop references and identity."}
    path = run_dir / "wallpaper_manifest.json"
    write_json(path, manifest)
    report["wallpaper"] = {"manifest": rel(path), "record_count": len(records)}
    output_file(report, path, "json", "wallpaper_manifest")
    return finalize_report(report, run_dir)


def capture_autostart(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-autostart")
    report = report_base("capture-autostart", run_dir)
    report["mode"] = "capture"
    user_roots = [resolve_path("~/.config/autostart")]
    system_roots = [resolve_path(p) for p in split_semicolon(cfg_get("files.system_autostart_roots", ""))] if boolish(cfg_get("policy.include_system_autostart_inventory", True)) else []
    manifest: dict[str, Any] = {"user_autostart": [], "system_autostart": [], "mime_associations": {}}
    for root in user_roots:
        manifest["user_autostart"].append(inventory_root(root, report, copy_to=(run_dir / "autostart_snapshot"), include_hash=True))
    for root in system_roots:
        manifest["system_autostart"].append(inventory_root(root, report, copy_to=None, include_hash=True))
    for candidate in [resolve_path("~/.config/mimeapps.list"), resolve_path("~/.local/share/applications/mimeapps.list")]:
        manifest["mime_associations"][str(candidate)] = file_record(candidate, include_hash=True)
        if candidate.exists():
            dest = run_dir / "mime_snapshot" / candidate.name
            dest.parent.mkdir(parents=True, exist_ok=True)
            try:
                shutil.copy2(candidate, dest)
                manifest["mime_associations"][str(candidate)]["copied_to"] = rel(dest)
            except OSError as exc:
                manifest["mime_associations"][str(candidate)]["copy_error"] = str(exc)
    if command_exists(XDG_MIME):
        result = run_cmd([XDG_MIME, "query", "default", "text/plain"], report, label="xdg_mime_query_text_plain")
        manifest["xdg_mime_text_plain"] = {"returncode": result["returncode"], "value": result["stdout"].strip()}
    path = run_dir / "autostart_mime_manifest.json"
    write_json(path, manifest)
    report["autostart"] = {"manifest": rel(path)}
    output_file(report, path, "json", "autostart_mime_manifest")
    return finalize_report(report, run_dir)



def run_capture_session_subcommand(command: str, report: dict[str, Any], run_dir: Path) -> dict[str, Any]:
    script_path = PROJECT_ROOT / "scripts" / SCRIPT_NAME
    argv = [str(script_path), command]
    proc = subprocess.run(argv, text=True, capture_output=True, cwd=PROJECT_ROOT)

    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", f"capture_session_{command}")
    stdout_path = run_dir / f"{safe}.stdout.txt"
    stderr_path = run_dir / f"{safe}.stderr.txt"
    write_text(stdout_path, proc.stdout)
    write_text(stderr_path, proc.stderr)

    record = {
        "subcommand": command,
        "argv": argv,
        "returncode": proc.returncode,
        "stdout_path": rel(stdout_path),
        "stderr_path": rel(stderr_path),
        "stderr": proc.stderr,
    }
    report["commands"].append(record)
    return record


def capture_session(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("capture-session")
    report = report_base("capture-session", run_dir)
    report["mode"] = "capture"
    report["session"] = validate_session(report, restore=False)
    report["capture_session"] = {
        "description": "Aggregate non-destructive Row 13 desktop/session capture.",
        "subcommands": CAPTURE_SESSION_SUBCOMMANDS,
        "required": CAPTURE_SESSION_SUBCOMMANDS,
        "results": [],
        "non_destructive": True,
        "partial_evidence_preserved": True,
    }

    script_path = PROJECT_ROOT / "scripts" / SCRIPT_NAME
    if not script_path.exists():
        report["failures"].append(f"desktop script missing: scripts/{SCRIPT_NAME}")
        return finalize_report(report, run_dir)
    if not os.access(script_path, os.X_OK):
        report["failures"].append(f"desktop script is not executable: scripts/{SCRIPT_NAME}")
        return finalize_report(report, run_dir)

    for command in CAPTURE_SESSION_SUBCOMMANDS:
        record = run_capture_session_subcommand(command, report, run_dir)
        report["capture_session"]["results"].append(record)
        if record["returncode"] != 0:
            report["failures"].append(
                f"capture-session subcommand failed: {command} returncode={record['returncode']}"
            )

    report["capture_session"]["completed_count"] = sum(
        1 for item in report["capture_session"]["results"] if item["returncode"] == 0
    )
    report["capture_session"]["failed_count"] = sum(
        1 for item in report["capture_session"]["results"] if item["returncode"] != 0
    )
    summary_path = run_dir / "capture_session_summary.json"
    write_json(summary_path, report["capture_session"])
    output_file(report, summary_path, "json", "capture_session_summary")
    return finalize_report(report, run_dir)

def validate_restore_context(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("validate-restore-context")
    report = report_base("validate-restore-context", run_dir)
    report["mode"] = "verify"
    report["session"] = validate_session(report, restore=args.restore)
    if command_exists(LOGINCTL) and os.environ.get("XDG_SESSION_ID"):
        run_cmd([LOGINCTL, "show-session", os.environ["XDG_SESSION_ID"]], report, label="loginctl_show_session")
    if command_exists(SYSTEMCTL):
        run_cmd([SYSTEMCTL, "--user", "is-active", "cinnamon-session.target"], report, label="systemctl_user_cinnamon_session_target")
    if command_exists(DCONF):
        dconf_preflight(report)
    else:
        report["failures"].append(f"dconf missing: {DCONF}")
    context_path = run_dir / "desktop_restore_context.json"
    write_json(context_path, {"session": report["session"], "environment": session_context()})
    output_file(report, context_path, "json", "desktop_restore_context")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("capture-session").set_defaults(func=capture_session)
    sub.add_parser("export-dconf").set_defaults(func=export_dconf)
    p = sub.add_parser("load-dconf-preview")
    p.add_argument("--source", default=None)
    p.set_defaults(func=load_dconf_preview)
    p = sub.add_parser("load-dconf-guarded")
    p.add_argument("--source", required=True)
    p.add_argument("--execute", action="store_true")
    p.set_defaults(func=load_dconf_guarded)
    sub.add_parser("export-cinnamon-files").set_defaults(func=export_cinnamon_files)
    p = sub.add_parser("restore-cinnamon-preview")
    p.add_argument("--input-manifest", default=None)
    p.set_defaults(func=restore_cinnamon_preview)
    sub.add_parser("capture-monitor-layout").set_defaults(func=capture_monitor_layout)
    sub.add_parser("capture-monitor-edid").set_defaults(func=capture_monitor_edid)
    sub.add_parser("capture-audio-input").set_defaults(func=capture_audio_input)
    sub.add_parser("capture-theme-icon-cursor").set_defaults(func=capture_theme_icon_cursor)
    sub.add_parser("capture-wallpaper").set_defaults(func=capture_wallpaper)
    sub.add_parser("capture-autostart").set_defaults(func=capture_autostart)
    p = sub.add_parser("validate-restore-context")
    p.add_argument("--restore", action="store_true")
    p.set_defaults(func=validate_restore_context)
    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(ARGS))
PYCODE