from __future__ import annotations

from local_llm.config import AppConfig
from local_llm.store.base import StoreProtocol
from local_llm.store.postgres_store import PostgresStore


def build_store(config: AppConfig) -> StoreProtocol:
    if config.storage.backend != "postgres":
        raise ValueError(f"unsupported storage backend for Phase 1.5: {config.storage.backend!r}")
    return PostgresStore.from_config(config)