#!/usr/bin/env python3
"""Route-action smoke for local_llm_router.

Validates durable session labels, queue-group assignment, duplicate capture/requeue,
manual provider-dispatch guard, generated provider-response visibility, and cleanup.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
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


def request_json(base_url: str, path: str, method: str = "GET",
                 payload: dict[str, Any] | None = None, timeout: float = 300.0) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(base_url.rstrip("/") + path, data=data,
                                 headers={"Content-Type": "application/json"}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise SmokeFailure(f"HTTP {exc.code} for {method} {path}: {body or exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise SmokeFailure(f"URL error for {method} {path}: {exc}") from exc
    return json.loads(raw) if raw else {}


def print_section(label: str, payload: object) -> None:
    print(f"\n===== {label} =====")
    print(json.dumps(payload, indent=2, ensure_ascii=False) if isinstance(payload, (dict,
                                                                                    list)) else payload)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SmokeFailure(message)


def list_drafts(base_url: str, queue_group_id: str, timeout: float) -> list[dict[str, Any]]:
    params = urllib.parse.urlencode({"include_handled": "true", "queue_group_id": queue_group_id})
    payload = request_json(base_url, f"/api/v1/drafts?{params}", timeout=timeout)
    drafts = payload.get("drafts", [])
    require(isinstance(drafts, list), "/api/v1/drafts did not return a list")
    return [item for item in drafts if isinstance(item, dict)]


def find_draft(drafts: list[dict[str, Any]], delivery_id: str) -> dict[str, Any] | None:
    return next((draft for draft in drafts if draft.get("delivery_id") == delivery_id), None)


def provider_response_drafts(drafts: list[dict[str, Any]], provider_id: str, queue_group_id: str,
                             source_session_id: str) -> list[dict[str, Any]]:
    return [
        draft for draft in drafts
        if draft.get("status") == "queued"
           and draft.get("provider") == provider_id
           and draft.get("queue_group_id") == queue_group_id
           and draft.get("source_session_id") != source_session_id
    ]


def mark_handled(base_url: str, delivery_id: str, timeout: float, label: str) -> dict[str, Any]:
    try:
        payload = request_json(base_url,
                               f"/api/v1/drafts/{urllib.parse.quote(delivery_id, safe='')}/handled",
                               "POST", {}, timeout)
        payload["_cleanup_label"] = label
        return payload
    except Exception as exc:
        return {"ok": False, "delivery_id": delivery_id, "_cleanup_label": label, "error": str(exc)}


def run(args: argparse.Namespace) -> dict[str, Any]:
    base_url = args.base_url.rstrip("/")
    stamp = f"{int(time.time())}-{os.getpid()}"
    text = args.prompt or f"Route action smoke {stamp}. Reply with one short sentence confirming receipt."
    source_session_id = f"chatgpt:route-action-smoke:{stamp}"
    conversation_id = f"route-action-smoke-{stamp}"
    label = f"Route action smoke label {stamp}"
    group_name = f"Route action smoke group {stamp}"
    renamed_group = f"Route action renamed smoke group {stamp}"

    health = request_json(base_url, "/health", timeout=args.timeout)
    print_section("daemon health", health)
    require(health.get("status") == "ok", "daemon health is not ok")

    wrappers = request_json(base_url, "/api/v1/prompt-wrappers", timeout=args.timeout)
    print_section("prompt wrappers", wrappers)
    prompt_wrappers = wrappers.get("prompt_wrappers", [])
    require(isinstance(prompt_wrappers, list) and prompt_wrappers, "prompt wrapper list is empty")
    wrapper_id = next((item.get("wrapper_id") for item in prompt_wrappers if
                       item.get("wrapper_id") == "basic_fence"), None) or prompt_wrappers[0].get(
        "wrapper_id")
    wrapper_apply = request_json(
        base_url,
        "/api/v1/prompt-wrappers/apply",
        "POST",
        {"wrapper_id": wrapper_id, "text": "wrapper smoke text"},
        args.timeout,
    )
    print_section("prompt wrapper apply", wrapper_apply)
    require(wrapper_apply.get("ok") is True, "prompt wrapper apply failed")
    require("wrapper smoke text" in str(wrapper_apply.get("text") or ""),
            "wrapped output lost source text")

    label_response = request_json(
        base_url,
        "/api/v1/sessions/label",
        "POST",
        {
            "source_session_id": source_session_id,
            "provider": "chatgpt",
            "label": label,
            "label_source": "user_saved",
        },
        args.timeout,
    )
    print_section("session label before capture", label_response)
    require(label_response.get("ok") is True, "session label update failed")
    require(label_response.get("label") == label,
            "session label response did not preserve requested alias")

    created_group = request_json(base_url, "/api/v1/queue-groups", "POST", {"name": group_name},
                                 args.timeout)
    print_section("created queue group", created_group)
    require(created_group.get("ok") is True, "queue group creation failed")
    group_id = str(created_group.get("queue_group_id"))

    assigned = request_json(
        base_url,
        "/api/v1/sessions/queue-group",
        "POST",
        {"source_session_id": source_session_id, "provider": "chatgpt", "queue_group_id": group_id},
        args.timeout,
    )
    print_section("assigned queue group before capture", assigned)
    require(assigned.get("ok") is True, "session queue group assignment failed")
    require((assigned.get("queue_group") or {}).get("queue_group_id") == group_id,
            "session group assignment returned wrong group")

    renamed = request_json(
        base_url,
        f"/api/v1/queue-groups/{urllib.parse.quote(group_id, safe='')}/rename",
        "POST",
        {"name": renamed_group},
        args.timeout,
    )
    print_section("renamed queue group", renamed)
    require(renamed.get("ok") is True, "queue group rename failed")
    require((renamed.get("queue_group") or {}).get("name") == renamed_group,
            "queue group rename did not persist requested name")

    capture_payload = {
        "event_type": "message.captured",
        "provider": "chatgpt",
        "source_session_id": source_session_id,
        "conversation_id": conversation_id,
        "gizmo_id": None,
        "conversation_url": f"https://chatgpt.com/c/{conversation_id}",
        "conversation_title": "Route action smoke",
        "role": "user",
        "turn_testid": f"route-action-user-turn-{stamp}",
        "capture_source": "api_route_action_smoke",
        "text": text,
        "text_hash": stable_hash(text),
        "text_length": len(text),
        "metadata": {"route_action": True, "duplicate_intent": True,
                     "operator_action_id": f"route-action-smoke-{stamp}",
                     "prompt_wrapper_id": wrapper_id,
                     "prompt_wrapper_source": "route_action_smoke_capture"},
    }

    first = request_json(base_url, "/api/v1/capture", "POST", capture_payload, args.timeout)
    second = request_json(base_url, "/api/v1/capture", "POST", capture_payload, args.timeout)
    print_section("first capture", first)
    print_section("duplicate capture", second)
    require(first.get("accepted") is True, "first capture was not accepted")
    require(second.get("accepted") is True, "duplicate capture was not accepted")
    require(first.get("message_id") == second.get("message_id"),
            "duplicate capture did not reuse message_id")
    require(second.get("deduped") is True, "second capture did not report deduped=true")
    require(first.get("delivery_ids") and second.get("delivery_ids"),
            "captures did not create deliveries")
    require(first["delivery_ids"][0] != second["delivery_ids"][0],
            "duplicate capture did not create a distinct delivery")

    status = request_json(base_url, "/api/v1/status/detail", timeout=args.timeout)
    sessions = status.get("provider_sessions", [])
    matched = next(
        (item for item in sessions if item.get("source_session_id") == source_session_id), None)
    print_section("provider session after label/group/capture", matched)
    require(matched is not None, "provider session not visible in status detail")
    require(matched.get("label") == label, "manual alias not visible in provider_sessions")
    require(matched.get("queue_group_id") == group_id,
            "queue group not visible in provider_sessions")

    first_draft = find_draft(list_drafts(base_url, group_id, args.timeout),
                             str(first["delivery_ids"][0]))
    duplicate_draft = find_draft(list_drafts(base_url, group_id, args.timeout),
                                 str(second["delivery_ids"][0]))
    print_section("group-scoped source drafts",
                  {"first": first_draft, "duplicate": duplicate_draft})
    require(first_draft is not None, "first delivery did not inherit assigned queue group")
    require(duplicate_draft is not None, "duplicate delivery did not inherit assigned queue group")

    duplicate_delivery_id = str(second["delivery_ids"][0])
    enc_provider = urllib.parse.quote(args.provider_id, safe="")

    blocked = request_json(base_url, f"/api/v1/providers/{enc_provider}/dispatch", "POST",
                           {"delivery_id": duplicate_delivery_id, "queue_group_id": group_id,
                            "manual_confirmed": False, "options": {"test": "phase5_manual_guard"}},
                           args.timeout)
    print_section("manual confirmation guard", blocked)
    require(blocked.get("error_code") == "manual_confirmation_required",
            "manual confirmation guard did not block unconfirmed dispatch")

    dispatch = request_json(base_url, f"/api/v1/providers/{enc_provider}/dispatch", "POST",
                            {"delivery_id": duplicate_delivery_id, "queue_group_id": group_id,
                             "manual_confirmed": True, "prompt_wrapper_id": wrapper_id,
                             "options": {"test": "phase5_route_action_smoke",
                                         "duplicate_intent": True, "prompt_wrapper_id": wrapper_id,
                                         "prompt_wrapper_source": "route_action_smoke_dispatch"}},
                            args.dispatch_timeout)
    print_section("confirmed dispatch", dispatch)
    require(dispatch.get("ok") is True, "provider dispatch failed")
    require(dispatch.get("status") == "response_received",
            "provider dispatch did not return response_received")
    generated_ids = dispatch.get("generated_delivery_ids") or []
    require(generated_ids, "provider dispatch did not create generated delivery")
    generated_id = str(generated_ids[0])

    drafts = list_drafts(base_url, group_id, args.timeout)
    generated = find_draft(drafts, generated_id)
    print_section("generated response draft by exact id", generated)
    require(generated is not None, "generated draft not visible by exact id")
    require(generated.get("status") == "queued", "generated draft is not queued")
    require(generated.get("provider") == args.provider_id, "generated draft provider mismatch")
    require(generated.get("role") == "assistant", "generated draft role mismatch")

    provider_responses = provider_response_drafts(drafts, args.provider_id, group_id,
                                                  source_session_id)
    print_section("queued provider-response candidates", provider_responses)
    require(generated_id in {item.get("delivery_id") for item in provider_responses},
            "provider-response filter did not find generated delivery")

    cleanup_results = []
    cleanup_results.append(mark_handled(base_url, str(first["delivery_ids"][0]), args.timeout,
                                        "first synthetic source delivery"))
    if not args.keep_generated:
        cleanup_results.append(mark_handled(base_url, generated_id, args.timeout,
                                            "generated provider response delivery"))
    delete_group = request_json(base_url,
                                f"/api/v1/queue-groups/{urllib.parse.quote(group_id, safe='')}/delete",
                                "POST", {"cancel_queued": False,
                                         "reason": "phase5 route action smoke cleanup"},
                                args.timeout)
    cleanup_results.append({"ok": delete_group.get("ok"), "_cleanup_label": "temporary queue group",
                            "queue_group_id": group_id})
    print_section("cleanup results", cleanup_results)
    require(all(item.get("ok") is True for item in cleanup_results),
            "one or more cleanup operations failed")

    final_status = request_json(base_url, "/api/v1/status/detail", timeout=args.timeout)
    store = final_status.get("store", {})
    print_section("final store summary", store)
    require(store.get("dispatching", 0) == 0, "store has stuck dispatching deliveries")
    require(store.get("failed", 0) == 0, "store has failed deliveries")

    return {"ok": True, "provider_id": args.provider_id, "source_session_id": source_session_id,
            "manual_alias": label, "temporary_group_id": group_id,
            "duplicate_delivery_id": duplicate_delivery_id, "generated_delivery_id": generated_id,
            "cleanup_generated": not args.keep_generated, "final_store": store}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Validate route actions, session aliases, queue groups, provider dispatch, and generated response visibility.")
    parser.add_argument("--base-url", default="http://127.0.0.1:8015")
    parser.add_argument("--provider-id", default="local_llamacpp_qwen36_35b_q4")
    parser.add_argument("--queue-group-id", default="default")
    parser.add_argument("--prompt", default=None)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--dispatch-timeout", type=float, default=360.0)
    parser.add_argument("--keep-generated", action="store_true",
                        help="Leave generated response draft queued instead of marking it handled.")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        summary = run(args)
    except SmokeFailure as exc:
        print(f"\nFAIL route action smoke: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nFAIL route action smoke: interrupted", file=sys.stderr)
        return 130
    print_section("route action smoke summary", summary)
    print("\nOK route action smoke passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())