from __future__ import annotations

import json
from pathlib import Path

from local_llm.store.sqlite_store import SQLiteStore


def show_run(store: SQLiteStore, run_id: str) -> str:
    run = store.get_run(run_id)
    if not run:
        raise KeyError(f"run not found: {run_id}")
    return json.dumps(run, indent=2, default=str)


def show_prompt(store: SQLiteStore, run_id: str) -> str:
    run = store.get_run(run_id)
    if not run:
        raise KeyError(f"run not found: {run_id}")
    return str(run["final_prompt"])


def show_retrievals(store: SQLiteStore, run_id: str) -> str:
    return json.dumps(store.get_run_retrievals(run_id), indent=2, default=str)


def show_context(store: SQLiteStore, run_id: str) -> str:
    retrievals = store.get_run_retrievals(run_id)
    parts = []
    for item in retrievals:
        parts.append(
            f"[Source {item['rank']}]\n"
            f"source_id: {item['source_id']}\n"
            f"document_path: {item['document_path']}\n"
            f"chunk_id: {item['chunk_id']}\n\n"
            f"{item['chunk_text_snapshot']}"
        )
    return "\n\n".join(parts)


def show_artifacts(store: SQLiteStore, run_id: str) -> str:
    artifacts = store.get_run_artifacts(run_id)
    for item in artifacts:
        path = Path(str(item["path"]))
        item["exists"] = path.exists()
    return json.dumps(artifacts, indent=2, default=str)
