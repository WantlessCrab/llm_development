#!/usr/bin/env python3
"""Provider-contract smoke test for one configured local_llm_router provider.

This is the narrow provider-onboarding proof. For the full source → target route-action loop, use scripts/route_action_smoke.py.

Proves the model-onboarding contract for one configured provider:
provider probe -> queued synthetic user draft -> manual-confirmation block ->
confirmed dispatch -> generated assistant response -> generated local draft -> cleanup.

Uses only Python standard-library modules.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class SmokeFailure(RuntimeError):
    pass


def stable_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:24]


def request_json(base_url: str, path: str, *, method: str = "GET",
                 payload: dict[str, Any] | None = None, timeout: float = 300.0) -> dict[str, Any]:
    data: bytes | None = None
    headers = {"Content-Type": "application/json"}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(base_url.rstrip("/") + path, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SmokeFailure(f"HTTP {exc.code} for {method} {path}: {body or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise SmokeFailure(f"URL error for {method} {path}: {exc}") from exc
    if not raw:
        return {}
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SmokeFailure(f"Non-JSON response for {method} {path}: {raw[:500]}") from exc
    if not isinstance(parsed, dict):
        raise SmokeFailure(f"JSON response root is not an object for {method} {path}")
    return parsed


def print_section(label: str, payload: Any) -> None:
    print(f"\n===== {label} =====")
    print(json.dumps(payload, indent=2, sort_keys=False) if isinstance(payload,
                                                                       (dict, list)) else payload)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


def provider_ids(status_detail: dict[str, Any]) -> set[str]:
    return {str(p.get("provider_id")) for p in status_detail.get("providers", []) if
            p.get("provider_id")}


def draft_summary(draft: dict[str, Any]) -> dict[str, Any]:
    return {
        "delivery_id": draft.get("delivery_id"),
        "status": draft.get("status"),
        "provider": draft.get("provider"),
        "role": draft.get("role"),
        "target_type": draft.get("target_type"),
        "target_id": draft.get("target_id"),
        "queue_group_id": draft.get("queue_group_id"),
        "body_length": draft.get("body_length"),
        "source_session_id": draft.get("source_session_id"),
    }


def run(args: argparse.Namespace) -> dict[str, Any]:
    base_url = args.base_url.rstrip("/")
    provider_id = args.provider_id
    stamp = str(int(time.time()))
    prompt = args.prompt or (
        "Provider onboarding smoke test. Reply with one short sentence confirming "
        "that the local model received a manually dispatched router draft."
    )

    health = request_json(base_url, "/health", timeout=args.timeout)
    print_section("daemon health", health)
    require(health.get("status") == "ok", "daemon health did not return status=ok")

    status = request_json(base_url, "/api/v1/status/detail", timeout=args.timeout)
    print_section("daemon status summary", {
        "app": status.get("app"),
        "version": status.get("version"),
        "store": status.get("store"),
        "providers": sorted(provider_ids(status)),
        "routes": [route.get("route_id") for route in status.get("routes", [])],
    })
    require(provider_id in provider_ids(status), f"provider is not registered: {provider_id}")

    enc_provider = urllib.parse.quote(provider_id)
    probe = request_json(base_url, f"/api/v1/providers/{enc_provider}/probe", method="POST",
                         timeout=args.timeout)
    print_section("provider probe", probe)
    require(probe.get("ok") is True, f"provider probe failed for {provider_id}")

    capture_payload = {
        "event_type": "message.captured",
        "provider": "chatgpt",
        "source_session_id": f"chatgpt:provider-smoke:{provider_id}:{stamp}",
        "conversation_id": f"provider-smoke-{stamp}",
        "gizmo_id": None,
        "conversation_url": f"https://chatgpt.com/c/provider-smoke-{stamp}",
        "conversation_title": f"Provider smoke {provider_id}",
        "role": "user",
        "turn_testid": f"provider-smoke-user-turn-{stamp}",
        "capture_source": "provider_dispatch_smoke",
        "text": prompt,
        "text_hash": stable_hash(prompt),
        "text_length": len(prompt),
        "metadata": {"test": "provider_dispatch_smoke", "provider_id": provider_id,
                     "cleanup_generated": args.cleanup_generated},
    }

    capture = request_json(base_url, "/api/v1/capture", method="POST", payload=capture_payload,
                           timeout=args.timeout)
    print_section("capture", capture)
    require(capture.get("accepted") is True, "capture was not accepted")
    require(capture.get("delivery_ids"), "capture did not create a queued delivery")
    require(capture.get("target_session_id") == "local_draft:default",
            f"capture target_session_id unexpected: {capture.get('target_session_id')}")
    original_delivery_id = str(capture["delivery_ids"][0])

    blocked = request_json(base_url, f"/api/v1/providers/{enc_provider}/dispatch", method="POST",
                           payload={
                               "delivery_id": original_delivery_id,
                               "queue_group_id": args.queue_group_id,
                               "manual_confirmed": False,
                               "options": {"test": "manual_confirmation_block"},
                           }, timeout=args.timeout)
    print_section("manual confirmation block", blocked)
    require(blocked.get("ok") is False, "manual confirmation block unexpectedly returned ok=true")
    require(blocked.get("error_code") == "manual_confirmation_required",
            f"manual confirmation guard returned unexpected error_code: {blocked.get('error_code')}")

    dispatch = request_json(base_url, f"/api/v1/providers/{enc_provider}/dispatch", method="POST",
                            payload={
                                "delivery_id": original_delivery_id,
                                "queue_group_id": args.queue_group_id,
                                "manual_confirmed": True,
                                "options": {"test": "provider_dispatch_smoke",
                                            "prompt_hash": stable_hash(prompt)},
                            }, timeout=args.dispatch_timeout)
    print_section("dispatch", dispatch)
    require(dispatch.get("ok") is True, f"dispatch failed: {dispatch.get('message')}")
    require(dispatch.get("status") == "response_received",
            f"dispatch status is not response_received: {dispatch.get('status')}")
    require(dispatch.get("generated_message_id"), "dispatch did not return generated_message_id")
    require(dispatch.get("generated_delivery_ids"), "dispatch did not create generated delivery")
    generated_delivery_id = str(dispatch["generated_delivery_ids"][0])

    drafts_payload = request_json(base_url, "/api/v1/drafts?include_handled=true",
                                  timeout=args.timeout)
    drafts = drafts_payload.get("drafts", [])
    require(isinstance(drafts, list), "draft list response did not contain drafts list")
    matches = [d for d in drafts if
               d.get("delivery_id") in {original_delivery_id, generated_delivery_id}]
    print_section("draft status proof", [draft_summary(d) for d in matches])

    original = next((d for d in matches if d.get("delivery_id") == original_delivery_id), None)
    generated = next((d for d in matches if d.get("delivery_id") == generated_delivery_id), None)
    require(original is not None, "original delivery is not visible in draft list")
    require(original.get("status") == "response_received",
            f"original delivery status is not response_received: {original.get('status')}")
    require(generated is not None, "generated delivery is not visible in draft list")
    require(generated.get("status") == "queued",
            f"generated delivery status is not queued before cleanup: {generated.get('status')}")
    require(generated.get("provider") == provider_id,
            f"generated provider is not {provider_id}: {generated.get('provider')}")
    require(generated.get("role") == "assistant",
            f"generated role is not assistant: {generated.get('role')}")
    require(
        generated.get("target_type") == "local_draft" and generated.get("target_id") == "default",
        f"generated target is not local_draft:default: {generated.get('target_type')}:{generated.get('target_id')}")

    if args.cleanup_generated:
        cleanup = request_json(base_url,
                               f"/api/v1/drafts/{urllib.parse.quote(generated_delivery_id)}/handled",
                               method="POST", payload={}, timeout=args.timeout)
        print_section("generated response cleanup", cleanup)
        require(cleanup.get("ok") is True, "generated response cleanup did not return ok=true")

    final_status = request_json(base_url, "/api/v1/status/detail", timeout=args.timeout)
    store = final_status.get("store", {})
    print_section("final store summary", store)
    require(store.get("dispatching", 0) == 0, "store has stuck dispatching deliveries")
    require(store.get("failed", 0) == 0, "store has failed deliveries")

    return {
        "ok": True,
        "provider_id": provider_id,
        "original_delivery_id": original_delivery_id,
        "generated_message_id": dispatch.get("generated_message_id"),
        "generated_delivery_id": generated_delivery_id,
        "cleanup_generated": bool(args.cleanup_generated),
        "final_store": store,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="provider_dispatch_smoke.py",
                                     description="Validate a local_llm_router provider by probe + manual dispatch + generated response capture.")
    parser.add_argument("--provider-id", required=True,
                        help="Configured provider_id to validate, for example local_llamacpp_qwen36_35b_q4.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8015",
                        help="local_llm_router daemon base URL.")
    parser.add_argument("--queue-group-id", default="default",
                        help="Queue group used for the synthetic dispatch proof.")
    parser.add_argument("--prompt", default=None,
                        help="Optional prompt sent through the synthetic queued draft.")
    parser.add_argument("--timeout", type=float, default=30.0,
                        help="Timeout for normal daemon requests.")
    parser.add_argument("--dispatch-timeout", type=float, default=360.0,
                        help="Timeout for the model dispatch request.")
    parser.add_argument("--keep-generated", action="store_true",
                        help="Leave the generated response draft queued instead of marking it handled.")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.cleanup_generated = not args.keep_generated
    try:
        summary = run(args)
    except SmokeFailure as exc:
        print(f"\nFAIL provider dispatch smoke: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nFAIL provider dispatch smoke: interrupted", file=sys.stderr)
        return 130
    print_section("provider dispatch smoke summary", summary)
    print("\nOK provider dispatch smoke passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())