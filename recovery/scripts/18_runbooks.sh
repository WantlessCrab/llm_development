#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec /usr/bin/python3 - "$PROJECT_ROOT" "$@" <<'PYCODE'
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import stat
import sys
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(sys.argv[1]).resolve()
ARGS = sys.argv[2:]
SCRIPT_NAME = "18_runbooks.sh"
SCHEMA_NAME = "recovery.runbooks.v1"

DEFAULT_CONFIG: dict[str, Any] = {
    "version": 1,
    "tool": {"name": "restore_runbooks", "layer": "18_human_recovery_execution_validation_stop_condition"},
    "project": {"root": str(PROJECT_ROOT), "output_root": "state/dry_runs/18_runbooks", "generated_root": "state/generated/18_runbooks", "proof_bundle_root": "state/proof_bundles"},
    "runbooks": {
        "canonical_restore_first": "runbooks/RESTORE_FIRST.md",
        "canonical_known_host_warnings": "runbooks/KNOWN_HOST_WARNINGS.md",
        "generated_index": "runbooks/INDEX.md",
        "retired_placeholder_root": "runbooks/_retired_placeholders",
        "old_placeholder_globs": "runbooks/[0-9][0-9]*.md;runbooks/[0-9][0-9]_*.md;runbooks/[0-9][0-9]-*.md",
        "placeholder_signal_words": "placeholder;stub;todo;tbd;empty;draft only;not implemented",
        "fail_on_active_placeholder_authority": True,
    },
    "proof": {
        "proof_bundle_index_json": "state/generated/18_runbooks/proof_bundle_index.json",
        "proof_bundle_index_md": "state/generated/18_runbooks/proof_bundle_index.md",
        "proof_roots": "state/dry_runs;state/generated;state/exports;state/proof_bundles;runbooks",
        "row_dry_run_dirs": "state/dry_runs/01_smartmontools;state/dry_runs/02_rescuezilla;state/dry_runs/03_cryptsetup;state/dry_runs/04_integrity;state/dry_runs/05_rsync;state/dry_runs/06_borg;state/dry_runs/07_borgmatic;state/dry_runs/08_systemd;state/dry_runs/09_journalctl;state/dry_runs/10_packages;state/dry_runs/11_flatpak;state/dry_runs/12_pipx;state/dry_runs/13_desktop;state/dry_runs/14_docker;state/dry_runs/15_portainer;state/dry_runs/16_postgresql;state/dry_runs/17_libvirt",
        "row_generated_dirs": "state/generated/07_borgmatic;state/generated/08_systemd;state/generated/13_desktop;state/generated/14_docker;state/generated/15_portainer;state/generated/16_postgresql;state/generated/17_libvirt;state/generated/18_runbooks",
        "max_index_entries_per_row": 200,
    },
    "validation": {
        "required_runbook_sections": "Emergency rule;Authority map;Source repo versus vault separation;Baseline image versus Borg delta workflow;Logical database authority;Docker and Portainer boundary;VM cold-copy authority;Integrity gates;Smoke tests;Layer order;First-build procedure;Normal backup procedure;SSD-corruption decision tree;Bare-metal restore;Post-image delta restore;Package and app restore;Desktop restore;Docker PostgreSQL and Portainer restore;Future Windows VM restore;Validation checklist;Known-host warnings;Stop conditions;Proof bundle;Post-recovery backup requirement",
        "required_warning_sections": "Known host identity;Destructive operation warnings;Storage and disk warnings;Desktop session warnings;Docker and PostgreSQL warnings;Portainer warning;Future VM and BitLocker warning;Audio input display warning;Old runbook authority warning",
        "required_stop_conditions": "STOP-WRONG-DISK;STOP-ROOT-DISK;STOP-UNKNOWN-VAULT;STOP-FAILED-SMART;STOP-MISSING-DUMP;STOP-UNVERIFIED-DUMP;STOP-LIVE-VM-DISK;STOP-PORTAINER-LATEST;STOP-SECRET-EXPOSURE;STOP-UNMOUNTED-VAULT;STOP-UNCLEAR-AUTHORITY;STOP-BITLOCKER-UNKNOWN;STOP-PLACEHOLDER-RUNBOOK",
        "required_checklist_sections": "Pre-restore authority checks;Media and vault checks;Bare-metal image checks;Filesystem delta checks;Database checks;Docker and Portainer checks;Desktop checks;VM checks;Final validation checks",
        "checklist_token_pattern": r"\[CHK-[A-Z0-9-]+\]",
    },
    "required_files": {
        "runtime_files": "",
        "executable_scripts": "",
    },
    "source_gate": {
        "fail_on_empty_required_files": True,
        "fail_on_invalid_json_schemas": True,
        "fail_on_invalid_recovery_yaml_configs": True,
        "fail_on_empty_unit_files": True,
        "forbidden_files": "systemd/system/wantless-desktop-capture.service",
    },
    "policy": {
        "copy_config_snapshot_into_run": True,
        "report_name": "runbooks_report.json",
        "generated_script_mode": "0600",
        "retire_requires_execute": True,
        "retire_guard_env": "CONFIRM_RUNBOOK_PLACEHOLDER_RETIRE",
        "retire_guard_value": "I_UNDERSTAND_THIS_MOVES_OLD_RUNBOOK_AUTHORITIES",
        "retire_confirm_token": "RETIRE_OLD_PLACEHOLDER_RUNBOOKS",
        "no_lower_tool_execution": True,
        "no_backup_media_mutation": True,
        "no_destructive_delete": True,
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
    path = PROJECT_ROOT / "configs" / "18_runbooks.yaml"
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


def make_run_dir(command: str) -> Path:
    root = resolve_path(str(cfg_get("project.output_root", "state/dry_runs/18_runbooks")))
    run_dir = root / now_stamp() / command
    run_dir.mkdir(parents=True, exist_ok=True)
    config_path = PROJECT_ROOT / "configs" / "18_runbooks.yaml"
    if boolish(cfg_get("policy.copy_config_snapshot_into_run", True)) and config_path.exists():
        shutil.copy2(config_path, run_dir / "18_runbooks.config.snapshot.yaml")
    return run_dir


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=str) + "\n", encoding="utf-8")


def write_text(path: Path, payload: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(payload, encoding="utf-8")


def report_base(command: str, run_dir: Path) -> dict[str, Any]:
    return {
        "schema": SCHEMA_NAME,
        "tool": {"name": "restore_runbooks", "script": SCRIPT_NAME},
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
    report_path = run_dir / str(cfg_get("policy.report_name", "runbooks_report.json"))
    write_json(report_path, report)
    print(json.dumps(report, indent=2, sort_keys=True, default=str))
    print(f"report: {rel(report_path)}", file=sys.stderr)
    return 0 if report["ok"] else 2


def output_file(report: dict[str, Any], path: Path, kind: str, label: str, extra: dict[str, Any] | None = None) -> None:
    entry = {"label": label, "kind": kind, "path": rel(path), "bytes": path.stat().st_size if path.exists() else 0}
    if extra:
        entry.update(extra)
    report["outputs"].append(entry)


def file_record(path: Path) -> dict[str, Any]:
    try:
        st = path.lstat()
    except OSError as exc:
        return {"path": rel(path), "exists": False, "error": str(exc)}
    return {
        "path": rel(path),
        "exists": path.exists(),
        "is_file": path.is_file(),
        "is_dir": path.is_dir(),
        "is_symlink": path.is_symlink(),
        "size_bytes": st.st_size,
        "mode": oct(stat.S_IMODE(st.st_mode)),
        "mtime_ns": st.st_mtime_ns,
    }


def read_text_or_empty(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def heading_set(text: str) -> set[str]:
    headings = set()
    for line in text.splitlines():
        match = re.match(r"^\s{0,3}#{1,6}\s+(.+?)\s*$", line)
        if match:
            headings.add(match.group(1).strip().lower())
    return headings


def has_section(text: str, required: str) -> bool:
    required_l = required.strip().lower()
    return required_l in heading_set(text) or any(required_l == h.split(" {#")[0].strip() for h in heading_set(text))


def canonical_paths() -> tuple[Path, Path]:
    return (
        resolve_path(str(cfg_get("runbooks.canonical_restore_first", "runbooks/RESTORE_FIRST.md"))),
        resolve_path(str(cfg_get("runbooks.canonical_known_host_warnings", "runbooks/KNOWN_HOST_WARNINGS.md"))),
    )


def runbook_section_status() -> dict[str, Any]:
    restore_path, warnings_path = canonical_paths()
    restore_text = read_text_or_empty(restore_path)
    warnings_text = read_text_or_empty(warnings_path)
    required_restore = split_semicolon(cfg_get("validation.required_runbook_sections", ""))
    required_warnings = split_semicolon(cfg_get("validation.required_warning_sections", ""))
    return {
        "restore_first": {
            "path": rel(restore_path),
            "exists": restore_path.exists(),
            "missing_sections": [item for item in required_restore if not has_section(restore_text, item)],
            "section_count": len(heading_set(restore_text)),
        },
        "known_host_warnings": {
            "path": rel(warnings_path),
            "exists": warnings_path.exists(),
            "missing_sections": [item for item in required_warnings if not has_section(warnings_text, item)],
            "section_count": len(heading_set(warnings_text)),
        },
    }


def placeholder_candidates() -> list[Path]:
    paths: set[Path] = set()
    retired_root = resolve_path(str(cfg_get("runbooks.retired_placeholder_root", "runbooks/_retired_placeholders")))
    for pattern in split_semicolon(cfg_get("runbooks.old_placeholder_globs", "runbooks/[0-9][0-9]*.md")):
        for path in PROJECT_ROOT.glob(pattern):
            try:
                path.resolve().relative_to(retired_root.resolve())
                continue
            except ValueError:
                pass
            if path.is_file():
                paths.add(path.resolve())
    return sorted(paths)


def is_placeholder_like(path: Path) -> bool:
    text = read_text_or_empty(path)
    stripped = text.strip()
    if not stripped:
        return True
    basename = path.name.lower()
    if not re.match(r"^\d{2}", basename):
        return False
    lower = stripped.lower()
    signals = split_semicolon(cfg_get("runbooks.placeholder_signal_words", "placeholder;stub;todo;tbd;empty"))
    has_signal = any(signal in lower for signal in signals)
    if not has_signal:
        return False
    authority_markers = (
        "chk-",
        "stop-",
        "scripts/",
        "configs/",
        "manifests/schema",
        "authority map",
        "validation checklist",
        "stop conditions",
        "proof bundle",
        "restore plan",
        "do not retire",
        "active authority",
        "canonical runbook",
    )
    has_authority_marker = any(marker in lower for marker in authority_markers)
    section_count = len(heading_set(text))
    return not has_authority_marker and section_count <= 2


def active_placeholder_status() -> dict[str, Any]:
    rows = []
    for path in placeholder_candidates():
        rows.append({"path": rel(path), "placeholder_like": is_placeholder_like(path), "bytes": path.stat().st_size if path.exists() else 0})
    return {"candidates": rows, "placeholder_like_count": sum(1 for row in rows if row["placeholder_like"]), "non_placeholder_numbered_count": sum(1 for row in rows if not row["placeholder_like"])}



def source_gate_enabled(key: str, default: bool = True) -> bool:
    return boolish(cfg_get(f"source_gate.{key}", default))


def json_schema_parse_error(path: Path) -> str | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        return str(exc)
    if not isinstance(payload, dict):
        return "JSON schema root is not an object"
    if "$schema" not in payload:
        return "JSON schema missing $schema"
    if "type" not in payload:
        return "JSON schema missing type"
    return None


def recovery_yaml_parse_error(path: Path) -> str | None:
    try:
        parse_simple_yaml(path)
        return None
    except SystemExit as exc:
        return str(exc)
    except Exception as exc:
        return str(exc)


def source_gate_file_kind(path: Path) -> str:
    relative = rel(path)
    if relative.startswith("configs/") and path.suffix in {".yaml", ".yml"}:
        return "recovery_yaml_config"
    if relative.startswith("manifests/schema/") and path.suffix == ".json":
        return "json_schema"
    if relative.startswith("systemd/") and path.suffix in {".service", ".timer"}:
        return "systemd_unit"
    if relative.startswith("scripts/") and path.suffix == ".sh":
        return "script"
    return "file"

def required_file_status() -> dict[str, Any]:
    files = [resolve_path(item) for item in split_semicolon(cfg_get("required_files.runtime_files", ""))]
    scripts = {rel(resolve_path(item)) for item in split_semicolon(cfg_get("required_files.executable_scripts", ""))}
    rows = []
    missing = []
    non_executable = []
    empty_required_files = []
    empty_unit_files = []
    invalid_json_schema_files = []
    invalid_recovery_yaml_config_files = []
    forbidden_files_present = []

    for item in split_semicolon(cfg_get("source_gate.forbidden_files", "")):
        forbidden = resolve_path(item)
        if forbidden.exists():
            forbidden_files_present.append(rel(forbidden))

    for path in files:
        rec = file_record(path)
        relative = rel(path)
        kind = source_gate_file_kind(path)
        rec["source_gate_kind"] = kind
        if not path.exists():
            missing.append(relative)
            rows.append(rec)
            continue

        size = int(rec.get("size_bytes", 0) or 0)
        if size == 0:
            if source_gate_enabled("fail_on_empty_required_files", True):
                empty_required_files.append(relative)
            if kind == "systemd_unit" and source_gate_enabled("fail_on_empty_unit_files", True):
                empty_unit_files.append(relative)

        if relative in scripts:
            executable = os.access(path, os.X_OK)
            rec["executable"] = executable
            if not executable:
                non_executable.append(relative)

        if kind == "json_schema" and source_gate_enabled("fail_on_invalid_json_schemas", True):
            error = json_schema_parse_error(path)
            if error:
                rec["json_schema_error"] = error
                invalid_json_schema_files.append({"path": relative, "error": error})

        if kind == "recovery_yaml_config" and source_gate_enabled("fail_on_invalid_recovery_yaml_configs", True):
            error = recovery_yaml_parse_error(path)
            if error:
                rec["recovery_yaml_error"] = error
                invalid_recovery_yaml_config_files.append({"path": relative, "error": error})

        rows.append(rec)

    return {
        "files": rows,
        "missing": missing,
        "non_executable_scripts": non_executable,
        "empty_required_files": empty_required_files,
        "empty_unit_files": empty_unit_files,
        "invalid_json_schema_files": invalid_json_schema_files,
        "invalid_recovery_yaml_config_files": invalid_recovery_yaml_config_files,
        "forbidden_files_present": forbidden_files_present,
        "checked_count": len(rows),
    }



def append_required_file_failures(report: dict[str, Any], files: dict[str, Any]) -> None:
    if files["missing"]:
        report["failures"].append(f"missing required runtime files: {files['missing']}")
    if files["non_executable_scripts"]:
        report["failures"].append(f"required scripts are not executable: {files['non_executable_scripts']}")
    if files.get("empty_required_files"):
        report["failures"].append(f"required runtime files are empty: {files['empty_required_files']}")
    if files.get("empty_unit_files"):
        report["failures"].append(f"required systemd unit files are empty: {files['empty_unit_files']}")
    if files.get("invalid_json_schema_files"):
        report["failures"].append(f"invalid JSON schema files: {files['invalid_json_schema_files']}")
    if files.get("invalid_recovery_yaml_config_files"):
        report["failures"].append(f"invalid recovery YAML config files: {files['invalid_recovery_yaml_config_files']}")
    if files.get("forbidden_files_present"):
        report["failures"].append(f"forbidden stale files present: {files['forbidden_files_present']}")

def stop_condition_status() -> dict[str, Any]:
    restore_path, warnings_path = canonical_paths()
    restore_text = read_text_or_empty(restore_path)
    warnings_text = read_text_or_empty(warnings_path)
    combined = restore_text + "\n" + warnings_text
    required = split_semicolon(cfg_get("validation.required_stop_conditions", ""))
    found = sorted(set(re.findall(r"\[?(STOP-[A-Z0-9-]+)\]?", combined)))
    missing = [item for item in required if item not in found]
    return {"required": required, "found": found, "missing": missing}


def checklist_status(require_checked: bool = False) -> dict[str, Any]:
    restore_path, _ = canonical_paths()
    text = read_text_or_empty(restore_path)
    sections = split_semicolon(cfg_get("validation.required_checklist_sections", ""))
    missing_sections = [section for section in sections if not has_section(text, section)]
    pattern = re.compile(str(cfg_get("validation.checklist_token_pattern", r"\[CHK-[A-Z0-9-]+\]")))
    checkboxes = []
    for line_no, line in enumerate(text.splitlines(), start=1):
        checkbox = re.match(r"^\s*-\s+\[( |x|X)\]\s+(.*)$", line)
        if not checkbox:
            continue
        token = pattern.search(line)
        checkboxes.append({
            "line": line_no,
            "checked": checkbox.group(1).lower() == "x",
            "token": token.group(0).strip("[]") if token else None,
            "text": checkbox.group(2).strip(),
        })
    missing_tokens = [row for row in checkboxes if not row["token"]]
    unchecked = [row for row in checkboxes if not row["checked"]]
    return {
        "path": rel(restore_path),
        "missing_sections": missing_sections,
        "checkbox_count": len(checkboxes),
        "tokenized_checkbox_count": sum(1 for row in checkboxes if row["token"]),
        "missing_token_count": len(missing_tokens),
        "unchecked_count": len(unchecked),
        "require_checked": require_checked,
        "missing_token_lines": [row["line"] for row in missing_tokens],
        "unchecked_tokens": [row["token"] for row in unchecked if row["token"]],
    }


def scan_proof_root(root: Path, max_entries: int) -> dict[str, Any]:
    rec: dict[str, Any] = {"root": rel(root), "exists": root.exists(), "entries": [], "report_json_count": 0}
    if not root.exists():
        return rec
    count = 0
    try:
        for path in sorted(root.rglob("*")):
            if count >= max_entries:
                rec["truncated"] = True
                break
            if path.is_file():
                item = file_record(path)
                item["kind"] = "report_json" if path.name.endswith("_report.json") or path.name in {"runbooks_report.json", "proof_bundle_index.json"} else "file"
                if item["kind"] == "report_json":
                    rec["report_json_count"] += 1
                rec["entries"].append(item)
                count += 1
    except OSError as exc:
        rec["scan_error"] = str(exc)
    return rec


def proof_bundle_payload() -> dict[str, Any]:
    max_entries = int(cfg_get("proof.max_index_entries_per_row", 200))
    roots = [resolve_path(item) for item in split_semicolon(cfg_get("proof.proof_roots", ""))]
    dry_rows = [resolve_path(item) for item in split_semicolon(cfg_get("proof.row_dry_run_dirs", ""))]
    generated_rows = [resolve_path(item) for item in split_semicolon(cfg_get("proof.row_generated_dirs", ""))]
    return {
        "generated_at": iso_now(),
        "proof_roots": [scan_proof_root(root, max_entries) for root in roots],
        "row_dry_run_dirs": [scan_proof_root(root, max_entries) for root in dry_rows],
        "row_generated_dirs": [scan_proof_root(root, max_entries) for root in generated_rows],
    }


def proof_missing_status(payload: dict[str, Any]) -> dict[str, Any]:
    dry_missing = [row["root"] for row in payload.get("row_dry_run_dirs", []) if not row.get("exists")]
    generated_missing = [row["root"] for row in payload.get("row_generated_dirs", []) if not row.get("exists")]
    dry_without_reports = [row["root"] for row in payload.get("row_dry_run_dirs", []) if row.get("exists") and row.get("report_json_count", 0) == 0]
    return {"dry_missing": dry_missing, "generated_missing": generated_missing, "dry_without_reports": dry_without_reports}


def render_proof_markdown(payload: dict[str, Any]) -> str:
    lines = ["# Recovery proof bundle index", "", f"Generated: `{payload.get('generated_at')}`", ""]
    for group_key, title in [("row_dry_run_dirs", "Row dry-run proof directories"), ("row_generated_dirs", "Generated proof directories"), ("proof_roots", "Proof roots")]:
        lines.append(f"## {title}")
        lines.append("")
        rows = payload.get(group_key, [])
        if not rows:
            lines.append("- none configured")
        for row in rows:
            lines.append(f"- `{row.get('root')}` exists={row.get('exists')} files={len(row.get('entries', []))} reports={row.get('report_json_count', 0)}")
            if row.get("truncated"):
                lines.append("  - truncated=true")
            if row.get("scan_error"):
                lines.append(f"  - scan_error={row.get('scan_error')}")
        lines.append("")
    return "\n".join(lines)


def cmd_retire_old_placeholders(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("retire-old-placeholders")
    report = report_base("retire-old-placeholders", run_dir)
    report["mode"] = "guarded-move" if args.execute else "plan"
    candidates = placeholder_candidates()
    planned = []
    skipped = []
    for path in candidates:
        row = {"source": rel(path), "placeholder_like": is_placeholder_like(path), "bytes": path.stat().st_size if path.exists() else 0}
        if row["placeholder_like"]:
            planned.append(row)
        else:
            skipped.append(row)
    if args.execute:
        expected_token = str(cfg_get("policy.retire_confirm_token", "RETIRE_OLD_PLACEHOLDER_RUNBOOKS"))
        env_name = str(cfg_get("policy.retire_guard_env", "CONFIRM_RUNBOOK_PLACEHOLDER_RETIRE"))
        env_value = str(cfg_get("policy.retire_guard_value", "I_UNDERSTAND_THIS_MOVES_OLD_RUNBOOK_AUTHORITIES"))
        if args.confirm_token != expected_token:
            report["failures"].append(f"retire requires --confirm-token {expected_token}")
        if os.environ.get(env_name) != env_value:
            report["failures"].append(f"retire requires {env_name}={env_value}")
    if args.execute and not report["failures"]:
        retired_root = resolve_path(str(cfg_get("runbooks.retired_placeholder_root", "runbooks/_retired_placeholders"))) / now_stamp()
        retired_root.mkdir(parents=True, exist_ok=True)
        moved = []
        for item in planned:
            src = resolve_path(item["source"])
            dest = retired_root / src.name
            if dest.exists():
                dest = retired_root / f"{src.stem}_{now_stamp()}{src.suffix}"
            shutil.move(str(src), str(dest))
            item["retired_to"] = rel(dest)
            moved.append(item)
        report["runbooks"] = {"planned": planned, "skipped": skipped, "moved": moved, "retired_root": rel(retired_root)}
    else:
        report["runbooks"] = {"planned": planned, "skipped": skipped, "execute": bool(args.execute)}
    plan_path = run_dir / "retire_old_placeholders_plan.json"
    write_json(plan_path, report["runbooks"])
    output_file(report, plan_path, "json", "retire_old_placeholders_plan")
    return finalize_report(report, run_dir)


def cmd_check_completeness(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("check-completeness")
    report = report_base("check-completeness", run_dir)
    report["mode"] = "verify"
    sections = runbook_section_status()
    placeholders = active_placeholder_status()
    stops = stop_condition_status()
    checklist = checklist_status(require_checked=False)
    files = required_file_status()
    if not sections["restore_first"]["exists"]:
        report["failures"].append("missing canonical runbook: RESTORE_FIRST.md")
    if not sections["known_host_warnings"]["exists"]:
        report["failures"].append("missing canonical runbook: KNOWN_HOST_WARNINGS.md")
    for key, value in sections.items():
        if value["missing_sections"]:
            report["failures"].append(f"{key} missing required sections: {value['missing_sections']}")
    if placeholders["placeholder_like_count"] and boolish(cfg_get("runbooks.fail_on_active_placeholder_authority", True)):
        report["failures"].append(f"active placeholder-like runbooks remain: {placeholders['placeholder_like_count']}")
    if stops["missing"]:
        report["failures"].append(f"missing required stop conditions: {stops['missing']}")
    if checklist["missing_sections"]:
        report["failures"].append(f"missing required checklist sections: {checklist['missing_sections']}")
    if checklist["missing_token_count"]:
        report["failures"].append(f"checklist entries without CHK tokens: {checklist['missing_token_lines']}")
    append_required_file_failures(report, files)
    payload = {"sections": sections, "placeholders": placeholders, "stop_conditions": stops, "checklist": checklist, "required_files": files}
    path = run_dir / "runbook_completeness.json"
    write_json(path, payload)
    report["runbooks"] = {"completeness": rel(path), "placeholder_like_count": placeholders["placeholder_like_count"]}
    output_file(report, path, "json", "runbook_completeness")
    return finalize_report(report, run_dir)


def cmd_render_index(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("render-index")
    report = report_base("render-index", run_dir)
    report["mode"] = "render"
    sections = runbook_section_status()
    files = required_file_status()
    stops = stop_condition_status()
    index_path = resolve_path(str(cfg_get("runbooks.generated_index", "runbooks/INDEX.md")))
    lines = [
        "# Recovery runbook index",
        "",
        "This file is generated by `scripts/18_runbooks.sh render-index`.",
        "",
        "It is a navigation aid. The active human authority remains `runbooks/RESTORE_FIRST.md` and `runbooks/KNOWN_HOST_WARNINGS.md`.",
        "",
        "## Canonical runbooks",
        "",
        f"- `runbooks/RESTORE_FIRST.md` exists={sections['restore_first']['exists']} missing_sections={len(sections['restore_first']['missing_sections'])}",
        f"- `runbooks/KNOWN_HOST_WARNINGS.md` exists={sections['known_host_warnings']['exists']} missing_sections={len(sections['known_host_warnings']['missing_sections'])}",
        "",
        "## Runtime file status",
        "",
        f"- checked_count={files['checked_count']}",
        f"- missing_count={len(files['missing'])}",
        f"- non_executable_scripts={len(files['non_executable_scripts'])}",
        f"- empty_required_files={len(files.get('empty_required_files', []))}",
        f"- empty_unit_files={len(files.get('empty_unit_files', []))}",
        f"- invalid_json_schema_files={len(files.get('invalid_json_schema_files', []))}",
        f"- invalid_recovery_yaml_config_files={len(files.get('invalid_recovery_yaml_config_files', []))}",
        f"- forbidden_files_present={len(files.get('forbidden_files_present', []))}",
        "",
        "| Exists | Executable | Source kind | Empty | Path | Bytes |",
        "|---|---|---|---|---|---:|",
    ]
    for rec in files["files"]:
        size = int(rec.get('size_bytes', 0) or 0)
        lines.append(
            f"| {'yes' if rec.get('exists') else 'no'} | "
            f"{'yes' if rec.get('executable') else 'no' if 'executable' in rec else ''} | "
            f"{rec.get('source_gate_kind', '')} | "
            f"{'yes' if rec.get('exists') and size == 0 else 'no' if rec.get('exists') else ''} | "
            f"`{rec.get('path')}` | {size} |"
        )
    lines.extend([
        "",
        "## Stop condition status",
        "",
        f"- required_count={len(stops['required'])}",
        f"- missing_count={len(stops['missing'])}",
        "",
        "## Use order",
        "",
        "1. Read `RESTORE_FIRST.md`.",
        "2. Read `KNOWN_HOST_WARNINGS.md`.",
        "3. Run `scripts/18_runbooks.sh check-completeness`.",
        "4. Run `scripts/18_runbooks.sh generate-proof-bundle-index`.",
        "5. Follow the row-specific restore plan indicated by the failure layer.",
        "",
    ])
    write_text(index_path, "\n".join(lines))
    index_path.chmod(int(str(cfg_get("policy.generated_script_mode", "0600")), 8))
    output_file(report, index_path, "markdown", "recovery_runbook_index")
    report["runbooks"] = {"index": rel(index_path)}
    return finalize_report(report, run_dir)


def cmd_generate_proof_bundle_index(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("generate-proof-bundle-index")
    report = report_base("generate-proof-bundle-index", run_dir)
    report["mode"] = "capture"
    payload = proof_bundle_payload()
    json_path = resolve_path(str(cfg_get("proof.proof_bundle_index_json", "state/generated/18_runbooks/proof_bundle_index.json")))
    md_path = resolve_path(str(cfg_get("proof.proof_bundle_index_md", "state/generated/18_runbooks/proof_bundle_index.md")))
    write_json(json_path, payload)
    write_text(md_path, render_proof_markdown(payload))
    report["proof_bundle"] = {"json": rel(json_path), "markdown": rel(md_path), **proof_missing_status(payload)}
    output_file(report, json_path, "json", "proof_bundle_index_json")
    output_file(report, md_path, "markdown", "proof_bundle_index_md")
    return finalize_report(report, run_dir)


def cmd_assert_required_artifacts(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("assert-required-artifacts")
    report = report_base("assert-required-artifacts", run_dir)
    report["mode"] = "verify"
    level = args.level
    files = required_file_status()
    payload: dict[str, Any] = {"level": level, "source": files}
    if level in {"source", "full"}:
        append_required_file_failures(report, files)
    if level in {"proof", "full"}:
        proof = proof_bundle_payload()
        missing = proof_missing_status(proof)
        payload["proof"] = missing
        if missing["dry_missing"]:
            report["failures"].append(f"missing row dry-run proof dirs: {missing['dry_missing']}")
        if missing["dry_without_reports"]:
            report["failures"].append(f"row dry-run dirs without report JSON: {missing['dry_without_reports']}")
    path = run_dir / "required_artifacts_assertion.json"
    write_json(path, payload)
    report["required_artifacts"] = {"manifest": rel(path), "level": level}
    output_file(report, path, "json", "required_artifacts_assertion")
    return finalize_report(report, run_dir)


def cmd_validate_checklist(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("validate-checklist")
    report = report_base("validate-checklist", run_dir)
    report["mode"] = "verify"
    status = checklist_status(require_checked=args.require_checked)
    if status["missing_sections"]:
        report["failures"].append(f"missing checklist sections: {status['missing_sections']}")
    if status["missing_token_count"]:
        report["failures"].append(f"checklist entries without CHK token lines: {status['missing_token_lines']}")
    if args.require_checked and status["unchecked_count"]:
        report["failures"].append(f"unchecked checklist items remain: {status['unchecked_tokens']}")
    path = run_dir / "checklist_validation.json"
    write_json(path, status)
    report["checklist"] = {"manifest": rel(path), "checkbox_count": status["checkbox_count"], "unchecked_count": status["unchecked_count"]}
    output_file(report, path, "json", "checklist_validation")
    return finalize_report(report, run_dir)


def cmd_validate_stop_conditions(args: argparse.Namespace) -> int:
    run_dir = make_run_dir("validate-stop-conditions")
    report = report_base("validate-stop-conditions", run_dir)
    report["mode"] = "verify"
    status = stop_condition_status()
    if status["missing"]:
        report["failures"].append(f"missing required stop conditions: {status['missing']}")
    path = run_dir / "stop_condition_validation.json"
    write_json(path, status)
    report["stop_conditions"] = {"manifest": rel(path), "missing": status["missing"], "found_count": len(status["found"])}
    output_file(report, path, "json", "stop_condition_validation")
    return finalize_report(report, run_dir)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=SCRIPT_NAME)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("retire-old-placeholders")
    p.add_argument("--execute", action="store_true")
    p.add_argument("--confirm-token", default="")
    p.set_defaults(func=cmd_retire_old_placeholders)

    sub.add_parser("check-completeness").set_defaults(func=cmd_check_completeness)
    sub.add_parser("render-index").set_defaults(func=cmd_render_index)
    sub.add_parser("generate-proof-bundle-index").set_defaults(func=cmd_generate_proof_bundle_index)

    p = sub.add_parser("assert-required-artifacts")
    p.add_argument("--level", choices=["source", "proof", "full"], default="source")
    p.set_defaults(func=cmd_assert_required_artifacts)

    p = sub.add_parser("validate-checklist")
    p.add_argument("--require-checked", action="store_true")
    p.set_defaults(func=cmd_validate_checklist)

    sub.add_parser("validate-stop-conditions").set_defaults(func=cmd_validate_stop_conditions)

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