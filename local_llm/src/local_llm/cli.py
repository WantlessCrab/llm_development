from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys

import uvicorn

from local_llm import __version__
from local_llm.config import default_config_path, load_config
from local_llm.contracts import RespondRequest
from local_llm.diagnostics import run_doctor
from local_llm.retrieval.indexer import ingest_corpus
from local_llm.retrieval.retriever import search
from local_llm.runs.inspector import show_artifacts, show_context, show_prompt, show_retrievals, show_run
from local_llm.runs.runner import respond
from local_llm.store.sqlite_store import SQLiteStore


def cmd_doctor(args: argparse.Namespace) -> int:
    response = run_doctor(check_provider=not args.skip_provider)
    for check in response.checks:
        mark = "OK" if check.ok else "FAIL"
        print(f"{mark:4} {check.name:<38} {check.detail}")
    return 0 if response.ok else 1


def cmd_serve(_: argparse.Namespace) -> int:
    cfg = load_config()
    SQLiteStore(cfg.database_path).init()
    uvicorn.run("local_llm.app:app", host=cfg.server.host, port=cfg.server.port, reload=False, log_level="info")
    return 0


def cmd_ingest(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = SQLiteStore(cfg.database_path)
    store.init()
    response = ingest_corpus(cfg, store, args.corpus_id)
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_search(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = SQLiteStore(cfg.database_path)
    store.init()
    response = search(cfg, store, rag_profile_id=args.rag_profile, query=args.query, top_k=args.top_k)
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_respond(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = SQLiteStore(cfg.database_path)
    store.init()
    request = RespondRequest(workflow_id=args.workflow_id, input=args.input, metadata={"source": "cli"})
    response = asyncio.run(respond(cfg, store, request))
    print(response.model_dump_json(indent=2))
    return 0 if response.ok else 1


def cmd_db_summary(_: argparse.Namespace) -> int:
    cfg = load_config()
    store = SQLiteStore(cfg.database_path)
    store.init()
    print(json.dumps({"database": str(cfg.database_path), **store.summary()}, indent=2))
    return 0


def cmd_open(args: argparse.Namespace) -> int:
    cfg = load_config()
    if args.target == "config":
        target = default_config_path()
    elif args.target == "artifacts":
        target = cfg.artifact_dir
    elif args.target == "data":
        target = cfg.database_path.parent
    else:
        raise ValueError(args.target)
    subprocess.Popen(["xdg-open", str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    cfg = load_config()
    store = SQLiteStore(cfg.database_path)
    store.init()

    if args.run_command == "show":
        print(show_run(store, args.run_id))
    elif args.run_command == "prompt":
        print(show_prompt(store, args.run_id))
    elif args.run_command == "retrievals":
        print(show_retrievals(store, args.run_id))
    elif args.run_command == "context":
        print(show_context(store, args.run_id))
    elif args.run_command == "artifacts":
        print(show_artifacts(store, args.run_id))
    else:
        raise ValueError(args.run_command)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="local-llm")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command", required=True)

    doctor = sub.add_parser("doctor")
    doctor.add_argument("--skip-provider", action="store_true")
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
    respond_cmd.set_defaults(func=cmd_respond)

    summary = sub.add_parser("db-summary")
    summary.set_defaults(func=cmd_db_summary)

    open_cmd = sub.add_parser("open")
    open_cmd.add_argument("target", choices=["config", "artifacts", "data"])
    open_cmd.set_defaults(func=cmd_open)

    run = sub.add_parser("run")
    run_sub = run.add_subparsers(dest="run_command", required=True)
    for name in ["show", "prompt", "retrievals", "context", "artifacts"]:
        p = run_sub.add_parser(name)
        p.add_argument("run_id")
        p.set_defaults(func=cmd_run)

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
