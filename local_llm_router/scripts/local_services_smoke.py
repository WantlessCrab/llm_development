#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))

from local_llm_router.config import load_config  # noqa: E402
from local_llm_router.paths import default_config_path  # noqa: E402
from local_llm_router.service_control import LocalServiceController  # noqa: E402


def request_json(url: str, *, timeout: float = 10.0) -> tuple[bool, dict[str, Any] | None, str]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
        return True, payload if isinstance(payload, dict) else {
            "value": payload}, f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")[:1000]
        return False, None, f"HTTP {exc.code}: {body}"
    except Exception as exc:
        return False, None, str(exc)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Supervisor-backed status smoke for host-local local_llm service control. No Docker or app-specific systemd lifecycle commands are used.")
    parser.add_argument("--target", choices=["local_llm", "local_llm_router"], default=None)
    parser.add_argument("--api", action="store_true",
                        help="Also query running daemon API status endpoint.")
    args = parser.parse_args(argv)

    config_path = default_config_path()
    cfg = load_config(config_path if config_path.exists() else ROOT / "config.example.yaml")
    controller = LocalServiceController.from_config(cfg.local_services)
    result = controller.action("status", service_id=args.target)

    output: dict[str, Any] = {
        "direct_status": {
            "enabled": cfg.local_services.enabled,
            **result.to_dict(),
        }
    }

    if args.api:
        base = f"http://{cfg.server.host}:{cfg.server.port}"
        suffix = f"?target={args.target}" if args.target else ""
        ok, payload, message = request_json(f"{base}/api/v1/local-services/status{suffix}")
        output["api_status"] = {
            "ok": ok,
            "message": message,
            "payload": payload,
        }
        if not ok:
            print(json.dumps(output, indent=2, ensure_ascii=False))
            print("FAIL local service API status smoke failed", file=sys.stderr)
            return 1

    print(json.dumps(output, indent=2, ensure_ascii=False))
    print("OK Supervisor-backed local service status smoke completed")
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())