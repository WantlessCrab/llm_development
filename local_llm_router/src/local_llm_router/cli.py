from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from typing import Any

import uvicorn

from . import __version__
from .config import load_config
from .format_capture import FORMAT_CAPTURE_VERSION
from .paths import default_config_path, project_source_path
from .providers import ProviderRegistry
from .store import Store

SERVICE_NAME = "local-llm-router.service"


def run_process(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, text=True, capture_output=True)


def model_to_plain(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump()
    return value


def json_print(value: Any) -> None:
    print(json.dumps(model_to_plain(value), indent=2, ensure_ascii=False, default=str))


def fetch_json(url: str, *, timeout: float = 2.0) -> tuple[bool, dict[str, Any] | None, str]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw)
            if isinstance(parsed, dict):
                return True, parsed, f"HTTP {response.status}"
            return False, None, "response root was not a JSON object"
    except urllib.error.HTTPError as exc:
        return False, None, f"HTTP {exc.code}: {exc.reason}"
    except Exception as exc:
        return False, None, str(exc)


def cmd_doctor(_: argparse.Namespace) -> int:
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"{'OK' if ok else 'FAIL':4} {name:<38} {detail}")
        if not ok:
            failures += 1

    def info(name: str, detail: str = "") -> None:
        print(f"{'INFO':4} {name:<38} {detail}")

    check("python version", sys.version_info >= (3, 12), sys.version.split()[0])

    for module in ["fastapi", "uvicorn", "pydantic", "yaml"]:
        try:
            __import__(module)
            check(f"python module {module}", True)
        except Exception as exc:
            check(f"python module {module}", False, str(exc))

    config_path = default_config_path()
    check("config exists", config_path.exists(), str(config_path))

    cfg = None
    store: Store | None = None
    registry: ProviderRegistry | None = None

    try:
        cfg = load_config(config_path)
        check("config parses", True)
    except Exception as exc:
        check("config parses", False, str(exc))

    if cfg:
        try:
            store = Store(cfg.database_path)
            store.init()
            check("sqlite init", True, str(cfg.database_path))
        except Exception as exc:
            check("sqlite init", False, str(exc))

        try:
            registry = ProviderRegistry(cfg)
            profiles = registry.list_profiles()
            check("provider registry builds", True, f"{len(profiles)} provider(s)")
            provider_ids = {profile.provider_id for profile in profiles}
            check("provider local_draft present", "local_draft" in provider_ids)
            check("provider chatgpt_browser present", "chatgpt_browser" in provider_ids)
            check("provider local_llm_primary present", "local_llm_primary" in provider_ids)
        except Exception as exc:
            check("provider registry builds", False, str(exc))

        wrappers = set(cfg.wrappers.keys())
        for route in cfg.routes:
            check(
                f"route wrapper {route.route_id}",
                route.wrapper in wrappers,
                route.wrapper,
            )

        ss = run_process(["bash", "-lc", f"ss -ltn | grep -E ':{cfg.server.port}\\b' || true"])
        info(
            "port status",
            f"{cfg.server.port} {'already listening' if ss.stdout.strip() else 'available'}",
        )

        status_url = f"http://{cfg.server.host}:{cfg.server.port}/api/v1/status/detail"
        ok, detail, message = fetch_json(status_url, timeout=1.5)
        if ok and detail:
            check("daemon status detail endpoint", True, status_url)
            info("daemon app version", str(detail.get("version", "")))
            info("daemon provider count", str(len(detail.get("providers", []))))
        else:
            info("daemon status detail endpoint", f"not reachable now: {message}")

    source = project_source_path()
    check("source path exists", source.exists(), str(source))
    check("extension manifest exists", (source / "extension" / "manifest.json").exists())
    check("draft inbox asset exists", (source / "web" / "draft_inbox.html").exists())
    check("xdg-open installed", shutil.which("xdg-open") is not None,
          shutil.which("xdg-open") or "")

    if shutil.which("systemctl"):
        active = run_process(["systemctl", "--user", "is-active", SERVICE_NAME])
        enabled = run_process(["systemctl", "--user", "is-enabled", SERVICE_NAME])
        check("service active", active.returncode == 0,
              active.stdout.strip() or active.stderr.strip())
        check("service enabled", enabled.returncode == 0,
              enabled.stdout.strip() or enabled.stderr.strip())

    info("format capture version", FORMAT_CAPTURE_VERSION)
    return 0 if failures == 0 else 1


def cmd_status(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = Store(cfg.database_path)
    store.init()
    registry = ProviderRegistry(cfg)

    print("local_llm_router status")
    print(f"version={__version__}")
    print(f"format_capture_version={FORMAT_CAPTURE_VERSION}")
    print(f"config={default_config_path()}")
    print(f"database={cfg.database_path}")
    print(f"server=http://{cfg.server.host}:{cfg.server.port}")

    print("\nroutes:")
    print(f"count={len(cfg.routes)}")
    for route in cfg.routes:
        print(
            f"  - {route.route_id}: enabled={route.enabled} "
            f"{route.source.provider}/{route.source.role} -> {route.target.type}:{route.target.id}"
        )

    print("\nproviders:")
    for profile in registry.list_profiles():
        print(
            f"  - {profile.provider_id}: type={profile.provider_type} "
            f"enabled={profile.enabled} availability={profile.availability} label={profile.label!r}"
        )

    print("\nstore:")
    for key, value in store.summary().items():
        print(f"  {key}={value}")

    return 0


def cmd_db_summary(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = Store(cfg.database_path)
    store.init()
    json_print({"database": str(cfg.database_path), **store.summary()})
    return 0


def cmd_providers(args: argparse.Namespace) -> int:
    cfg = load_config()
    registry = ProviderRegistry(cfg)

    if args.provider_id:
        connector = registry.get(args.provider_id)
        if connector is None:
            print(f"provider not found: {args.provider_id}", file=sys.stderr)
            return 1

        if args.probe:
            result = asyncio.run(connector.probe())
            json_print(result)
            return 0 if result.ok else 1

        json_print(connector.profile())
        return 0

    profiles = registry.list_profiles()
    if args.probe:
        results = []
        exit_code = 0
        for profile in profiles:
            connector = registry.require(profile.provider_id)
            result = asyncio.run(connector.probe())
            results.append(result.model_dump())
            if profile.enabled and result.availability not in {"ready", "needs_configuration"}:
                exit_code = 1
        json_print({"providers": results})
        return exit_code

    json_print({"providers": [profile.model_dump() for profile in profiles]})
    return 0


def cmd_config_check(_: argparse.Namespace) -> int:
    cfg = load_config()
    failures = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures
        print(f"{'OK' if ok else 'FAIL':4} {name:<38} {detail}")
        if not ok:
            failures += 1

    registry = ProviderRegistry(cfg)
    provider_ids = {profile.provider_id for profile in registry.list_profiles()}

    check("provider registry non-empty", bool(provider_ids), f"{len(provider_ids)} provider(s)")
    check("local_draft provider", "local_draft" in provider_ids)
    check("chatgpt_browser provider", "chatgpt_browser" in provider_ids)
    check("local_llm_primary provider", "local_llm_primary" in provider_ids)

    wrapper_ids = set(cfg.wrappers.keys())
    check("wrappers configured", bool(wrapper_ids), f"{len(wrapper_ids)} wrapper(s)")

    route_ids = set()
    for route in cfg.routes:
        check(f"route id unique {route.route_id}", route.route_id not in route_ids)
        route_ids.add(route.route_id)

        check(f"route wrapper exists {route.route_id}", route.wrapper in wrapper_ids, route.wrapper)
        check(f"route enabled flag valid {route.route_id}", isinstance(route.enabled, bool))

        if route.target.type == "local_draft":
            target_group = cfg.targets.get("local_draft", {})
            check(
                f"local_draft target exists {route.route_id}",
                route.target.id in target_group,
                route.target.id,
            )

    return 0 if failures == 0 else 1


def cmd_serve(_: argparse.Namespace) -> int:
    cfg = load_config()
    Store(cfg.database_path).init()
    uvicorn.run(
        "local_llm_router.app:app",
        host=cfg.server.host,
        port=cfg.server.port,
        reload=False,
        log_level="info",
    )
    return 0


def cmd_open(args: argparse.Namespace) -> int:
    cfg = load_config()
    targets = {
        "config": default_config_path(),
        "inbox": f"http://{cfg.server.host}:{cfg.server.port}/draft-inbox",
        "source": project_source_path(),
        "extension": project_source_path() / "extension",
    }
    subprocess.Popen(
        ["xdg-open", str(targets[args.target])],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return 0


def cmd_service(args: argparse.Namespace) -> int:
    if args.action == "enable":
        argv = ["systemctl", "--user", "enable", "--now", SERVICE_NAME]
    elif args.action == "disable":
        argv = ["systemctl", "--user", "disable", "--now", SERVICE_NAME]
    else:
        argv = ["systemctl", "--user", args.action, SERVICE_NAME]

    result = run_process(argv)
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def cmd_logs(args: argparse.Namespace) -> int:
    result = run_process(
        ["journalctl", "--user", "-u", SERVICE_NAME, "-n", str(args.lines), "--no-pager"]
    )
    if result.stdout:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    return result.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="local-llm-router")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")

    sub = parser.add_subparsers(dest="command", required=True)

    for name, func in [
        ("doctor", cmd_doctor),
        ("status", cmd_status),
        ("serve", cmd_serve),
        ("db-summary", cmd_db_summary),
        ("config-check", cmd_config_check),
    ]:
        p = sub.add_parser(name)
        p.set_defaults(func=func)

    p = sub.add_parser("providers")
    p.add_argument("provider_id", nargs="?")
    p.add_argument("--probe", action="store_true")
    p.set_defaults(func=cmd_providers)

    p = sub.add_parser("open")
    p.add_argument("target", choices=["config", "inbox", "source", "extension"])
    p.set_defaults(func=cmd_open)

    p = sub.add_parser("service")
    p.add_argument("action", choices=["status", "start", "stop", "restart", "enable", "disable"])
    p.set_defaults(func=cmd_service)

    p = sub.add_parser("logs")
    p.add_argument("-n", "--lines", type=int, default=100)
    p.set_defaults(func=cmd_logs)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        print(f"local-llm-router error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())