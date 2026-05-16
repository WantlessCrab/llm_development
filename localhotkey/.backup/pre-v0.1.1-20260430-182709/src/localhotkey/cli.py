#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


APP_NAME = "localhotkey"
CONFIG_DIR = Path.home() / ".config" / APP_NAME
CONFIG_PATH = Path(os.environ.get("LOCALHOTKEY_CONFIG", CONFIG_DIR / "config.yaml"))
GENERATED_SXHKDRC = CONFIG_DIR / "generated.sxhkdrc"
LOCK_FILE = Path(tempfile.gettempdir()) / f"{APP_NAME}-{os.getuid()}.lock"
DEFAULT_EXECUTABLE = Path.home() / ".local" / "bin" / APP_NAME


class LocalHotkeyError(RuntimeError):
    """Expected application-level error."""


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str
    stderr: str


def run_process(
    argv: list[str],
    input_text: str | None = None,
    check: bool = True,
    timeout: float | None = 10.0,
) -> CommandResult:
    try:
        result = subprocess.run(
            argv,
            input=input_text,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise LocalHotkeyError(f"missing executable: {argv[0]}") from exc
    except subprocess.TimeoutExpired as exc:
        raise LocalHotkeyError(f"command timed out: {' '.join(argv)}") from exc

    wrapped = CommandResult(result.returncode, result.stdout, result.stderr)
    if check and wrapped.returncode != 0:
        message = wrapped.stderr.strip() or wrapped.stdout.strip() or f"exit {wrapped.returncode}"
        raise LocalHotkeyError(f"command failed: {' '.join(argv)} :: {message}")
    return wrapped


def require_yaml_module():
    try:
        import yaml  # type: ignore
    except ModuleNotFoundError as exc:
        raise LocalHotkeyError(
            "PyYAML is not installed. Install it with: sudo apt install python3-yaml"
        ) from exc
    return yaml


def load_config(path: Path = CONFIG_PATH) -> dict[str, Any]:
    yaml = require_yaml_module()

    if not path.exists():
        raise LocalHotkeyError(f"config not found: {path}")

    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise LocalHotkeyError(f"failed to parse config: {path}: {exc}") from exc

    if data is None:
        raise LocalHotkeyError(f"config is empty: {path}")
    if not isinstance(data, dict):
        raise LocalHotkeyError(f"config root must be a mapping/object: {path}")

    validate_config(data)
    return data


def validate_config(config: dict[str, Any]) -> None:
    if config.get("version") != 1:
        raise LocalHotkeyError("config.version must be 1")

    backend = config.get("backend", {})
    if backend is None:
        backend = {}
    if not isinstance(backend, dict):
        raise LocalHotkeyError("config.backend must be a mapping")

    paste_key = backend.get("paste_key", "ctrl+v")
    if not isinstance(paste_key, str) or not paste_key.strip():
        raise LocalHotkeyError("config.backend.paste_key must be a non-empty string")

    for bool_key in ("restore_clipboard",):
        value = backend.get(bool_key, True)
        if not isinstance(value, bool):
            raise LocalHotkeyError(f"config.backend.{bool_key} must be true or false")

    for int_key in ("restore_delay_ms", "clipboard_settle_ms"):
        value = backend.get(int_key, 250 if int_key == "restore_delay_ms" else 60)
        if not isinstance(value, int) or value < 0:
            raise LocalHotkeyError(f"config.backend.{int_key} must be a non-negative integer")

    wrappers = config.get("wrappers")
    if not isinstance(wrappers, dict) or not wrappers:
        raise LocalHotkeyError("config.wrappers must be a non-empty mapping")

    for name, wrapper in wrappers.items():
        if not isinstance(name, str) or not name.strip():
            raise LocalHotkeyError("wrapper names must be non-empty strings")
        if not isinstance(wrapper, dict):
            raise LocalHotkeyError(f"config.wrappers.{name} must be a mapping")
        for field in ("before", "after", "transform", "line_prefix"):
            if field in wrapper and not isinstance(wrapper[field], str):
                raise LocalHotkeyError(f"config.wrappers.{name}.{field} must be a string")
        transform = wrapper.get("transform", "none")
        if transform not in {"none", "strip", "rstrip", "lstrip"}:
            raise LocalHotkeyError(
                f"config.wrappers.{name}.transform unsupported: {transform!r}"
            )

    actions = config.get("actions")
    if not isinstance(actions, dict) or not actions:
        raise LocalHotkeyError("config.actions must be a non-empty mapping")

    for name, action in actions.items():
        if not isinstance(name, str) or not name.strip():
            raise LocalHotkeyError("action names must be non-empty strings")
        if not isinstance(action, dict):
            raise LocalHotkeyError(f"config.actions.{name} must be a mapping")

        action_type = action.get("type")
        if action_type == "wrap":
            wrapper_name = action.get("wrapper")
            if wrapper_name not in wrappers:
                raise LocalHotkeyError(
                    f"config.actions.{name}.wrapper references missing wrapper: {wrapper_name!r}"
                )
        elif action_type == "command":
            argv = action.get("argv")
            if not isinstance(argv, list) or not all(isinstance(x, str) for x in argv):
                raise LocalHotkeyError(
                    f"config.actions.{name}.argv must be a list of strings"
                )
        else:
            raise LocalHotkeyError(
                f"config.actions.{name}.type must be 'wrap' or 'command'"
            )

    bindings = config.get("bindings")
    if not isinstance(bindings, list) or not bindings:
        raise LocalHotkeyError("config.bindings must be a non-empty list")

    seen_hotkeys: set[str] = set()
    for idx, binding in enumerate(bindings):
        if not isinstance(binding, dict):
            raise LocalHotkeyError(f"config.bindings[{idx}] must be a mapping")
        hotkey = binding.get("hotkey")
        action = binding.get("action")
        if not isinstance(hotkey, str) or not hotkey.strip():
            raise LocalHotkeyError(f"config.bindings[{idx}].hotkey must be a non-empty string")
        if hotkey in seen_hotkeys:
            raise LocalHotkeyError(f"duplicate hotkey binding: {hotkey}")
        seen_hotkeys.add(hotkey)

        if action not in actions:
            raise LocalHotkeyError(
                f"config.bindings[{idx}].action references missing action: {action!r}"
            )


def backend_config(config: dict[str, Any]) -> dict[str, Any]:
    backend = config.get("backend") or {}
    return {
        "paste_key": backend.get("paste_key", "ctrl+v"),
        "restore_clipboard": backend.get("restore_clipboard", True),
        "restore_delay_ms": backend.get("restore_delay_ms", 250),
        "clipboard_settle_ms": backend.get("clipboard_settle_ms", 60),
    }


def get_clipboard() -> str:
    result = run_process(["xclip", "-selection", "clipboard", "-o"], check=False)
    if result.returncode != 0:
        return ""
    return result.stdout


def set_clipboard(text: str) -> None:
    run_process(["xclip", "-selection", "clipboard", "-in"], input_text=text)


def send_paste_key(paste_key: str) -> None:
    run_process(["xdotool", "key", "--clearmodifiers", paste_key])


def build_wrapped_text(text: str, wrapper: dict[str, Any]) -> str:
    transform = wrapper.get("transform", "none")
    if transform == "strip":
        text = text.strip()
    elif transform == "rstrip":
        text = text.rstrip()
    elif transform == "lstrip":
        text = text.lstrip()
    elif transform == "none":
        pass
    else:
        raise LocalHotkeyError(f"unknown transform: {transform}")

    line_prefix = wrapper.get("line_prefix", "")
    if line_prefix:
        lines = text.splitlines()
        if lines:
            text = "\n".join(f"{line_prefix}{line}" for line in lines)
        else:
            text = line_prefix

    return f"{wrapper.get('before', '')}{text}{wrapper.get('after', '')}"


def execute_wrap(wrapper_name: str, config: dict[str, Any]) -> None:
    wrappers = config["wrappers"]
    wrapper = wrappers.get(wrapper_name)
    if not wrapper:
        raise LocalHotkeyError(f"wrapper not found: {wrapper_name}")

    backend = backend_config(config)

    original = get_clipboard()
    wrapped = build_wrapped_text(original, wrapper)

    set_clipboard(wrapped)
    time.sleep(backend["clipboard_settle_ms"] / 1000)
    send_paste_key(backend["paste_key"])

    if backend["restore_clipboard"]:
        time.sleep(backend["restore_delay_ms"] / 1000)
        set_clipboard(original)


def execute_action(action_name: str, config: dict[str, Any]) -> None:
    action = config["actions"].get(action_name)
    if not action:
        raise LocalHotkeyError(f"action not found: {action_name}")

    action_type = action.get("type")
    if action_type == "wrap":
        execute_wrap(action["wrapper"], config)
    elif action_type == "command":
        argv = action["argv"]
        run_process(argv)
    else:
        raise LocalHotkeyError(f"unsupported action type: {action_type}")


def render_sxhkdrc(config: dict[str, Any], output_path: Path = GENERATED_SXHKDRC) -> None:
    exe = Path(os.environ.get("LOCALHOTKEY_EXECUTABLE", DEFAULT_EXECUTABLE))
    bindings = config["bindings"]

    lines = [
        "# Generated by localhotkey. Do not edit this file directly.",
        f"# Source config: {CONFIG_PATH}",
        "",
    ]

    for binding in bindings:
        hotkey = binding["hotkey"]
        action = binding["action"]
        lines.append(hotkey)
        lines.append(f"    {exe} run {shell_token(action)}")
        lines.append("")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_path.with_suffix(output_path.suffix + ".tmp")
    tmp.write_text("\n".join(lines), encoding="utf-8")
    tmp.replace(output_path)


def shell_token(value: str) -> str:
    # sxhkd runs commands through /bin/sh. Action names are validated as config strings,
    # but keep a conservative shell escaping implementation for future-safe names.
    if value and all(ch.isalnum() or ch in "._-/" for ch in value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def is_sxhkd_running_for_generated_config() -> bool:
    result = run_process(["pgrep", "-af", "sxhkd"], check=False)
    if result.returncode != 0:
        return False
    needle = str(GENERATED_SXHKDRC)
    return any(needle in line for line in result.stdout.splitlines())


def cmd_doctor(_: argparse.Namespace) -> int:
    checks: list[tuple[str, bool, str]] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        checks.append((name, ok, detail))

    add("session type is X11", os.environ.get("XDG_SESSION_TYPE") == "x11",
        f"XDG_SESSION_TYPE={os.environ.get('XDG_SESSION_TYPE', '')!r}")
    add("DISPLAY is set", bool(os.environ.get("DISPLAY")),
        f"DISPLAY={os.environ.get('DISPLAY', '')!r}")

    xauthority = Path(os.environ.get("XAUTHORITY", Path.home() / ".Xauthority"))
    add("XAUTHORITY exists/readable", xauthority.exists() and os.access(xauthority, os.R_OK),
        f"XAUTHORITY={xauthority}")

    for tool in ("sxhkd", "xclip", "xdotool"):
        add(f"{tool} installed", shutil.which(tool) is not None,
            shutil.which(tool) or "not found on PATH")

    try:
        require_yaml_module()
        add("PyYAML available", True, "yaml import ok")
    except Exception as exc:
        add("PyYAML available", False, str(exc))

    try:
        config = load_config()
        add("config parses and validates", True, str(CONFIG_PATH))
    except Exception as exc:
        config = None
        add("config parses and validates", False, str(exc))

    if config is not None:
        try:
            render_sxhkdrc(config)
            add("sxhkdrc renders", True, str(GENERATED_SXHKDRC))
        except Exception as exc:
            add("sxhkdrc renders", False, str(exc))

    try:
        current_clipboard = get_clipboard()
        add("clipboard readable", True, f"{len(current_clipboard)} chars")
    except Exception as exc:
        add("clipboard readable", False, str(exc))

    try:
        running = is_sxhkd_running_for_generated_config()
        add("sxhkd running generated config", running,
            "running" if running else "not running or different config")
    except Exception as exc:
        add("sxhkd running generated config", False, str(exc))

    width = max(len(name) for name, _, _ in checks)
    failed = 0
    for name, ok, detail in checks:
        mark = "OK" if ok else "FAIL"
        print(f"{mark:4} {name:<{width}}  {detail}")
        if not ok:
            failed += 1

    return 0 if failed == 0 else 1


def cmd_status(_: argparse.Namespace) -> int:
    config = load_config()
    backend = backend_config(config)
    print("localhotkey status")
    print(f"config={CONFIG_PATH}")
    print(f"generated_sxhkdrc={GENERATED_SXHKDRC}")
    print(f"executable={Path(os.environ.get('LOCALHOTKEY_EXECUTABLE', DEFAULT_EXECUTABLE))}")
    print(f"paste_key={backend['paste_key']}")
    print(f"restore_clipboard={backend['restore_clipboard']}")
    print(f"restore_delay_ms={backend['restore_delay_ms']}")
    print(f"clipboard_settle_ms={backend['clipboard_settle_ms']}")
    print(f"sxhkd_generated_config_running={is_sxhkd_running_for_generated_config()}")
    print("")
    print("wrappers:")
    for name, wrapper in config["wrappers"].items():
        label = wrapper.get("label", "")
        print(f"  - {name}: {label}")
    print("")
    print("actions:")
    for name, action in config["actions"].items():
        print(f"  - {name}: {action.get('type')}")
    print("")
    print("bindings:")
    for binding in config["bindings"]:
        print(f"  - {binding['hotkey']} -> {binding['action']}")
    return 0


def cmd_render(_: argparse.Namespace) -> int:
    config = load_config()
    render_sxhkdrc(config)
    print(f"rendered {GENERATED_SXHKDRC}")
    return 0


def cmd_wrap(args: argparse.Namespace) -> int:
    config = load_config()
    with LOCK_FILE.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        execute_wrap(args.wrapper, config)
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    config = load_config()
    with LOCK_FILE.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        execute_action(args.action, config)
    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    lines = str(args.lines)
    result = run_process(
        ["journalctl", "--user", "-u", "localhotkey.service", "-n", lines, "--no-pager"],
        check=False,
        timeout=20.0,
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="localhotkey",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent(
            """\
            localhotkey: lightweight user-local hotkey automation for Linux Mint Cinnamon/X11.

            Typical workflow:
              localhotkey doctor
              localhotkey render
              localhotkey status
            """
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor", help="validate session, dependencies, config, and backend state")
    doctor.set_defaults(func=cmd_doctor)

    status = sub.add_parser("status", help="print active config/actions/bindings state")
    status.set_defaults(func=cmd_status)

    render = sub.add_parser("render", help="generate sxhkdrc from config.yaml")
    render.set_defaults(func=cmd_render)

    wrap = sub.add_parser("wrap", help="wrap current clipboard with a named wrapper and paste")
    wrap.add_argument("wrapper")
    wrap.set_defaults(func=cmd_wrap)

    run = sub.add_parser("run", help="run a named action from config.yaml")
    run.add_argument("action")
    run.set_defaults(func=cmd_run)

    logs = sub.add_parser("logs", help="show localhotkey systemd user-service logs")
    logs.add_argument("-n", "--lines", type=int, default=80)
    logs.set_defaults(func=cmd_logs)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except LocalHotkeyError as exc:
        print(f"localhotkey error: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("localhotkey interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
