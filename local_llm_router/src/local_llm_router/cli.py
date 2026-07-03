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
from .provider_discovery import ProviderDiscoveryEngine
from .prompt_wrappers import PromptWrapperError, apply_prompt_wrapper_by_id, list_prompt_wrappers
from .providers import ProviderRegistry
from .service_control import LocalServiceController
from .store import Store

SUPERVISOR_ROUTER_NAME = "code-host:local-llm-router"


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
            check("provider local_vllm_small present", "local_vllm_small" in provider_ids)
            check("provider local_llamacpp_qwen36_35b_q4 present",
                  "local_llamacpp_qwen36_35b_q4" in provider_ids)
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

    try:
        controller = LocalServiceController.from_config(cfg.local_services)
        router_status = controller.status("local_llm_router")[0]
        check("Supervisor CLI code-svc", router_status.supervisor_available,
              router_status.code_svc_path or "not found")
        check("Supervisor router program", router_status.supervisor_ok,
              f"{router_status.supervisor_name} state={router_status.supervisor_state}")
        check("router health via Supervisor authority", router_status.health_ok,
              router_status.health_status or router_status.health_error or "")
    except Exception as exc:
        check("Supervisor router service check", False, str(exc))

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
    check("local_vllm_small provider", "local_vllm_small" in provider_ids)
    check("local_llamacpp_qwen36_35b_q4 provider", "local_llamacpp_qwen36_35b_q4" in provider_ids)
    check("provider discovery config valid", isinstance(cfg.provider_discovery.enabled, bool))
    check("local services config valid", isinstance(cfg.local_services.enabled, bool))
    check("local service local_llm", "local_llm" in cfg.local_services.targets)
    check("local service local_llm_router", "local_llm_router" in cfg.local_services.targets)

    for service_id, service in cfg.local_services.targets.items():
        forbidden = ["docker", "compose", "portainer"]
        command_text = " ".join([
            service.authority,
            service.supervisor_name,
            service.code_svc_command,
        ]).lower()
        check(
            f"local service Supervisor authority {service_id}",
            service.authority == "supervisor" and service.supervisor_name.startswith("code-host:"),
            service.supervisor_name,
        )
        check(
            f"local service host-local only {service_id}",
            not any(term in command_text for term in forbidden),
            service.supervisor_name,
        )

    wrapper_ids = set(cfg.wrappers.keys())
    check("wrappers configured", bool(wrapper_ids), f"{len(wrapper_ids)} wrapper(s)")
    try:
        prompt_wrappers = list_prompt_wrappers()
        check("prompt wrappers configured", bool(prompt_wrappers),
              f"{len(prompt_wrappers)} prompt wrapper(s)")
    except PromptWrapperError as exc:
        check("prompt wrappers configured", False, str(exc))

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


def http_json_request(url: str, *, method: str = "GET", payload: dict[str, Any] | None = None,
                      timeout: float = 60.0) -> tuple[bool, dict[str, Any] | None, str]:
    data = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw)
            return True, parsed if isinstance(parsed, dict) else {
                "value": parsed}, f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:1000]
        return False, None, f"HTTP {exc.code}: {body}"
    except Exception as exc:
        return False, None, str(exc)


def cmd_discover_providers(args: argparse.Namespace) -> int:
    cfg = load_config()
    roots = args.root or cfg.provider_discovery.roots

    if args.apply_runtime:
        url = f"http://{cfg.server.host}:{cfg.server.port}/api/v1/provider-discovery/run"
        ok, payload, message = http_json_request(
            url,
            method="POST",
            payload={
                "roots": roots,
                "probe": args.probe,
                "apply_runtime": True,
                "persist_report": True,
                "include_offline_candidates": args.include_offline,
            },
            timeout=max(30.0, cfg.provider_discovery.probe_timeout_seconds * 4),
        )
        if not ok or payload is None:
            print(f"provider discovery API request failed: {message}", file=sys.stderr)
            return 1
        json_print(payload)
        return 0 if not payload.get("errors") else 1

    registry = ProviderRegistry(cfg)
    engine = ProviderDiscoveryEngine(
        existing_provider_ids=set(cfg.providers) | set(registry.provider_ids()),
        provider_id_prefix=cfg.provider_discovery.provider_id_prefix,
    )
    report = engine.discover(
        roots=roots,
        probe=args.probe,
        apply_runtime_requested=False,
        include_offline_candidates=args.include_offline,
        probe_timeout_seconds=cfg.provider_discovery.probe_timeout_seconds,
        persist_report=args.write_report,
        report_dir=cfg.provider_discovery.report_dir,
    )

    if args.format == "yaml":
        import yaml
        provider_blocks = {
            candidate.provider_id: candidate.provider_config
            for candidate in report.candidates
            if candidate.provider_config
        }
        print(yaml.safe_dump({"providers": provider_blocks}, sort_keys=False))
    else:
        json_print(report.to_dict())
    return 0 if not report.errors else 1


def cmd_local_services(args: argparse.Namespace) -> int:
    cfg = load_config()
    controller = LocalServiceController.from_config(cfg.local_services)
    result = controller.action(args.action, service_id=args.target)
    json_print({
        "enabled": cfg.local_services.enabled,
        **result.to_dict(),
    })
    return 0 if result.ok else 1


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


def cmd_logs(args: argparse.Namespace) -> int:
    if not shutil.which("code-svc"):
        print(
            "code-svc not found. Supervisor is the host-local runtime authority; "
            "logs are available through code-svc or the Supervisor GUI.",
            file=sys.stderr,
        )
        return 1

    if not args.follow:
        print(
            "Supervisor log tail is interactive on this stack. Use:\n"
            f"  code-svc tail -f {SUPERVISOR_ROUTER_NAME}\n",
            file=sys.stderr,
        )
        return 0

    return subprocess.call(["code-svc", "tail", "-f", SUPERVISOR_ROUTER_NAME])


def cmd_prompt_wrappers(args: argparse.Namespace) -> int:
    try:
        if args.apply:
            text = args.text if args.text is not None else sys.stdin.read()
            wrapped, wrapper, metadata = apply_prompt_wrapper_by_id(text, args.apply)
            if args.json:
                json_print({"ok": True, "wrapper": wrapper.summary() if wrapper else None,
                            "metadata": metadata, "text": wrapped})
            else:
                print(wrapped, end="")
            return 0
        wrappers = list_prompt_wrappers()
        payload = {"prompt_wrappers": [wrapper.summary() for wrapper in wrappers]}
        json_print(payload)
        return 0
    except PromptWrapperError as exc:
        print(f"prompt wrapper error: {exc}", file=sys.stderr)
        return 1


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

    p = sub.add_parser("prompt-wrappers")
    p.add_argument("--apply", metavar="WRAPPER_ID")
    p.add_argument("--text", default=None)
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_prompt_wrappers)

    p = sub.add_parser("discover-providers")
    p.add_argument("--root", action="append", help="Runtime root to scan. May be repeated.")
    p.add_argument("--probe", action="store_true", help="Probe inferred health/models endpoints.")
    p.add_argument("--include-offline", action="store_true",
                   help="Include offline provider candidates in the report.")
    p.add_argument("--write-report", action="store_true",
                   help="Write report and provider YAML to cache.")
    p.add_argument("--apply-runtime", action="store_true",
                   help="Ask the running daemon to add ready discovered providers to the live registry.")
    p.add_argument("--format", choices=["json", "yaml"], default="json")
    p.set_defaults(func=cmd_discover_providers)

    p = sub.add_parser("local-services")
    p.add_argument("action", choices=["status", "start", "stop", "restart"])
    p.add_argument("--target", choices=["local_llm", "local_llm_router"], default=None)
    p.set_defaults(func=cmd_local_services)

    p = sub.add_parser("open")
    p.add_argument("target", choices=["config", "inbox", "source", "extension"])
    p.set_defaults(func=cmd_open)

    p = sub.add_parser("logs")
    p.add_argument("-f", "--follow", action="store_true",
                   help="Follow Supervisor logs through code-svc.")
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