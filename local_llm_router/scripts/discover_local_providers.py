#!/usr/bin/env python3
"""Discover local model runtimes and emit local_llm_router provider config candidates.

Read-only by default. Use --api-apply to ask a running local_llm_router daemon to
add ready discovered providers to the live registry. Active config.yaml is never
modified by this script.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = PROJECT_ROOT / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

from local_llm_router.config import load_config  # noqa: E402
from local_llm_router.paths import default_config_path  # noqa: E402
from local_llm_router.provider_discovery import ProviderDiscoveryEngine  # noqa: E402
from local_llm_router.providers import ProviderRegistry  # noqa: E402


def request_json(url: str, *, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:1000]
        raise SystemExit(f"API request failed with HTTP {exc.code}: {body}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="discover_local_providers.py",
                                     description="Discover local model provider candidates. Read-only by default; active config.yaml is never modified. --api-apply asks the running daemon for live registry apply only.")
    parser.add_argument("--root", action="append", help="Runtime root to scan. May be repeated.")
    parser.add_argument("--probe", action="store_true", help="Probe inferred provider endpoints.")
    parser.add_argument("--include-offline", action="store_true",
                        help="Include offline candidates.")
    parser.add_argument("--write-report", action="store_true",
                        help="Write report and provider YAML to cache.")
    parser.add_argument("--format", choices=["json", "yaml"], default="json")
    parser.add_argument("--api-apply", action="store_true",
                        help="Ask running daemon to apply ready providers to live registry.")
    args = parser.parse_args(argv)

    config_path = default_config_path()
    cfg = load_config(config_path if config_path.exists() else PROJECT_ROOT / "config.example.yaml")
    roots = args.root or cfg.provider_discovery.roots

    if args.api_apply:
        url = f"http://{cfg.server.host}:{cfg.server.port}/api/v1/provider-discovery/run"
        payload = request_json(
            url,
            payload={
                "roots": roots,
                "probe": True,
                "apply_runtime": True,
                "persist_report": True,
                "include_offline_candidates": args.include_offline,
            },
            timeout=max(30.0, cfg.provider_discovery.probe_timeout_seconds * 4),
        )
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0 if not payload.get("errors") else 1

    registry = ProviderRegistry(cfg)
    engine = ProviderDiscoveryEngine(
        existing_provider_ids=set(cfg.providers) | set(registry.provider_ids()),
        provider_id_prefix=cfg.provider_discovery.provider_id_prefix,
    )
    report = engine.discover(
        roots=roots,
        probe=args.probe,
        include_offline_candidates=args.include_offline,
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
        print(json.dumps(report.to_dict(), indent=2, ensure_ascii=False))

    return 0 if not report.errors else 1


if __name__ == "__main__":
    raise SystemExit(main())