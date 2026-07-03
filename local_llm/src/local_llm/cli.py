from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
from typing import Any

import uvicorn

from local_llm import __version__
from local_llm.config import default_config_path, load_config
from local_llm.contracts import PacketListRequest, ProjectionRequest, RespondRequest
from local_llm.diagnostics import run_doctor
from local_llm.eval_capture.projections import ProjectionService
from local_llm.retrieval.indexer import ingest_corpus
from local_llm.retrieval.retriever import search
from local_llm.store.factory import build_store
from local_llm.turns.execution import TurnExecutionService
from local_llm.turns.request import TurnExecutionRequest


def _print_model(value: Any) -> None:
    if hasattr(value, "model_dump_json"):
        print(value.model_dump_json(indent=2))
    else:
        print(json.dumps(value, indent=2, default=str))


def cmd_doctor(args: argparse.Namespace) -> int:
    response = run_doctor(
        check_provider=not args.skip_provider,
        workflow_id=args.workflow_id,
        model_profile_id=args.model_profile_id,
    )
    if args.json:
        print(response.model_dump_json(indent=2))
    else:
        width = max([len(check.name) for check in response.checks] + [0])
        for check in response.checks:
            mark = "OK" if check.ok else "FAIL"
            print(f"{mark:4} {check.name:<{width}}  {check.detail}")
    return 0 if response.ok else 1


def cmd_serve(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    uvicorn.run(
        "local_llm.app:app",
        host=cfg.server.host,
        port=cfg.server.port,
        reload=False,
        log_level="info",
    )
    return 0


def cmd_ingest(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    response = ingest_corpus(cfg, store, args.corpus_id)
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_search(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    response = search(
        cfg,
        store,
        rag_profile_id=args.rag_profile,
        query=args.query,
        top_k=args.top_k,
    )
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_respond(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    request = RespondRequest(
        workflow_id=args.workflow_id,
        input=args.input,
        metadata={"source": "cli"},
        eval_capture_mode=args.eval_capture_mode,
        privacy_mode=args.privacy_mode,
        privacy_level=args.privacy_level,
    )
    turn_request = TurnExecutionRequest(
        source_kind="respond",
        workflow_id=request.workflow_id,
        input=request.input,
        metadata=request.metadata,
        capture_mode=request.capture_mode or request.eval_capture_mode,
        privacy_mode=request.privacy_mode,
        privacy_level=request.privacy_level,
        idempotency_key=request.idempotency_key,
        idempotency_scope_hash=request.idempotency_scope_hash,
        source_system="local_llm",
    )
    response = asyncio.run(TurnExecutionService(cfg, store).respond(turn_request))
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_db_summary(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    health = store.database_health()
    payload: dict[str, Any] = {
        "storage_backend": cfg.storage_backend,
        "database_label": cfg.database_label,
        "artifact_dir": str(cfg.artifact_dir),
        "eval_capture_enabled": cfg.eval_capture.enabled,
        "eval_capture_failure_policy": cfg.eval_capture.failure_policy,
        "database_health": health,
    }

    if not health.get("connected"):
        payload["summary_available"] = False
        payload["summary_error"] = health.get("error") or "database connection failed"
        print(json.dumps(payload, indent=2, default=str))
        return 1

    if not health.get("packet_schema_ready"):
        payload["summary_available"] = False
        payload["summary_error"] = "PostgreSQL Phase 1.5 packet schema is not ready"
        print(json.dumps(payload, indent=2, default=str))
        return 1

    try:
        payload.update(store.summary())
        payload["summary_available"] = True
        print(json.dumps(payload, indent=2, default=str))
        return 0
    except Exception as exc:
        payload["summary_available"] = False
        payload["summary_error"] = str(exc)
        print(json.dumps(payload, indent=2, default=str))
        return 1


def cmd_open(args: argparse.Namespace) -> int:
    cfg = load_config()
    if args.target == "config":
        target = default_config_path()
    elif args.target == "artifacts":
        target = cfg.artifact_dir
    elif args.target == "data":
        target = cfg.artifact_dir.parent
    else:
        raise ValueError(args.target)
    subprocess.Popen(["xdg-open", str(target)], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)
    return 0


def cmd_packet(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    projection = ProjectionService(store)

    if args.packet_command == "show":
        result = projection.packet_detail(args.turn_packet_id)
    elif args.packet_command == "content":
        result = projection.load_content(args.content_ref_id)
    elif args.packet_command == "list":
        result = projection.list_packets(
            PacketListRequest(
                session_id=args.session_id,
                workflow_id=args.workflow_id,
                group_id=args.group_id,
                capture_mode=args.capture_mode,
                limit=args.limit,
            )
        )
    else:
        raise ValueError(args.packet_command)

    if result is None:
        print("not found", file=sys.stderr)
        return 1
    _print_model(result)
    return 0


def cmd_metrics(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    result = ProjectionService(store).available_metrics()
    print(result.model_dump_json(indent=2))
    return 0


def cmd_group(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    if args.group_command != "show":
        raise ValueError(args.group_command)
    result = ProjectionService(store).group_detail(args.packet_group_id)
    if not result:
        print("packet group not found", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, default=str))
    return 0


def cmd_projection(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = build_store(cfg)
    store.init()
    request = ProjectionRequest(
        packet_group_id=args.packet_group_id,
        session_ids=args.session_ids or [],
        packet_ids=args.packet_ids or [],
        metric_keys=args.metric_keys or [],
    )
    result = ProjectionService(store).projection_result(request)
    print(result.model_dump_json(indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="local-llm")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--skip-provider", action="store_true")
    doctor.add_argument("--workflow-id", default=None)
    doctor.add_argument("--model-profile", "--model-profile-id", dest="model_profile_id",
                        default=None)
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(func=cmd_doctor)

    serve = sub.add_parser("serve")
    serve.set_defaults(func=cmd_serve)

    ingest = sub.add_parser("ingest")
    ingest.add_argument("corpus_id")
    ingest.set_defaults(func=cmd_ingest)

    search_cmd = sub.add_parser("search")
    search_cmd.add_argument("rag_profile")
    search_cmd.add_argument("query")
    search_cmd.add_argument("--top-k", type=int, default=None)
    search_cmd.set_defaults(func=cmd_search)

    respond_cmd = sub.add_parser("respond")
    respond_cmd.add_argument("workflow_id")
    respond_cmd.add_argument("input")
    respond_cmd.add_argument("--eval-capture-mode", choices=["full", "privacy"], default=None)
    respond_cmd.add_argument("--privacy-mode", action="store_true", default=None)
    respond_cmd.add_argument("--privacy-level", choices=["none", "standard", "strict"],
                             default=None)
    respond_cmd.set_defaults(func=cmd_respond)

    summary = sub.add_parser("db-summary")
    summary.set_defaults(func=cmd_db_summary)

    open_cmd = sub.add_parser("open")
    open_cmd.add_argument("target", choices=["config", "artifacts", "data"])
    open_cmd.set_defaults(func=cmd_open)

    packet = sub.add_parser("packet")
    packet_sub = packet.add_subparsers(dest="packet_command", required=True)
    packet_show = packet_sub.add_parser("show")
    packet_show.add_argument("turn_packet_id")
    packet_show.set_defaults(func=cmd_packet)
    packet_content = packet_sub.add_parser("content")
    packet_content.add_argument("content_ref_id")
    packet_content.set_defaults(func=cmd_packet)
    packet_list = packet_sub.add_parser("list")
    packet_list.add_argument("--session-id", default=None)
    packet_list.add_argument("--workflow-id", default=None)
    packet_list.add_argument("--group-id", default=None)
    packet_list.add_argument("--capture-mode", choices=["full", "privacy"], default=None)
    packet_list.add_argument("--limit", type=int, default=50)
    packet_list.set_defaults(func=cmd_packet)

    metrics = sub.add_parser("metrics")
    metrics.set_defaults(func=cmd_metrics)

    group = sub.add_parser("group")
    group_sub = group.add_subparsers(dest="group_command", required=True)
    group_show = group_sub.add_parser("show")
    group_show.add_argument("packet_group_id")
    group_show.set_defaults(func=cmd_group)

    projection = sub.add_parser("projection")
    projection.add_argument("--packet-group-id")
    projection.add_argument("--session-ids", nargs="*")
    projection.add_argument("--packet-ids", nargs="*")
    projection.add_argument("--metric-keys", nargs="*")
    projection.set_defaults(func=cmd_projection)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:
        print(f"local-llm error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())