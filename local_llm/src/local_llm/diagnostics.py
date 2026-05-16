from __future__ import annotations

from pathlib import Path

from local_llm.config import AppConfig, default_config_path, load_config
from local_llm.contracts import DoctorCheck, DoctorResponse
from local_llm.control.profiles import resolve_workflow
from local_llm.generation.providers.base import build_provider
from local_llm.store.sqlite_store import SQLiteStore


def run_doctor(config_path: Path | None = None, check_provider: bool = True) -> DoctorResponse:
    checks: list[DoctorCheck] = []

    def add(name: str, ok: bool, detail: str = "") -> None:
        checks.append(DoctorCheck(name=name, ok=ok, detail=detail))

    path = config_path or default_config_path()
    add("config exists", path.exists(), str(path))

    config: AppConfig | None = None
    try:
        config = load_config(path)
        add("config parses", True)
    except Exception as exc:
        add("config parses", False, str(exc))

    if config:
        try:
            store = SQLiteStore(config.database_path)
            store.init()
            add("database opens", True, str(config.database_path))
            add("SQLite FTS5 available", store.fts5_available())
        except Exception as exc:
            add("database opens", False, str(exc))

        try:
            config.artifact_dir.mkdir(parents=True, exist_ok=True)
            probe = config.artifact_dir / ".write_probe"
            probe.write_text("ok", encoding="utf-8")
            probe.unlink(missing_ok=True)
            add("artifact directory writable", True, str(config.artifact_dir))
        except Exception as exc:
            add("artifact directory writable", False, str(exc))

        for corpus_id, corpus in config.corpora.items():
            for root in corpus.roots:
                root_path = Path(root).expanduser()
                add(f"corpus root exists:{corpus_id}", root_path.exists(), str(root_path))

        for workflow_id in config.workflows:
            try:
                resolved = resolve_workflow(config, workflow_id)
                add(f"workflow resolves:{workflow_id}", True, resolved.workflow.kind)
            except Exception as exc:
                add(f"workflow resolves:{workflow_id}", False, str(exc))

        if check_provider:
            for model_id, model_profile in config.model_profiles.items():
                try:
                    provider = build_provider(model_profile)
                    ok, detail = provider.health_check()
                    add(f"provider health:{model_id}", ok, detail)
                except Exception as exc:
                    add(f"provider health:{model_id}", False, str(exc))

    return DoctorResponse(ok=all(c.ok for c in checks), checks=checks)
