from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field


APP_SLUG = "local-llm"


def expand_path(value: str | Path) -> Path:
    return Path(value).expanduser().resolve()


def config_dir() -> Path:
    return Path.home() / ".config" / APP_SLUG


def default_config_path() -> Path:
    return config_dir() / "config.yaml"


class ServerConfig(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8020


class StorageConfig(BaseModel):
    database_path: str = "~/.local/share/local-llm/local_llm.sqlite"
    artifact_dir: str = "~/.local/share/local-llm/artifacts"


class ModelDefaults(BaseModel):
    temperature: float = 0.2
    max_tokens: int = 900


class ModelProfile(BaseModel):
    provider: str = "openai_compatible"
    base_url: str
    api_key: str = "not-needed"
    model: str
    context_window: int = 8192
    defaults: ModelDefaults = Field(default_factory=ModelDefaults)


class CorpusConfig(BaseModel):
    roots: list[str]
    include_globs: list[str]
    exclude_globs: list[str] = Field(default_factory=list)


class RetrievalConfig(BaseModel):
    method: Literal["sqlite_fts", "vector", "hybrid", "reranked"] = "sqlite_fts"
    top_k: int = 8


class ChunkingConfig(BaseModel):
    target_chars: int = 1800
    overlap_chars: int = 250


class ContextConfig(BaseModel):
    max_context_chars: int = 14000
    include_source_headers: bool = True


class RagProfile(BaseModel):
    enabled: bool = True
    corpus: str
    retrieval: RetrievalConfig = Field(default_factory=RetrievalConfig)
    chunking: ChunkingConfig = Field(default_factory=ChunkingConfig)
    context: ContextConfig = Field(default_factory=ContextConfig)


class PromptProfile(BaseModel):
    grounding_mode: Literal["none", "prefer_sources", "require_sources"] = "require_sources"
    system: str
    user_template: str


class WorkflowConfig(BaseModel):
    kind: Literal[
        "rag_answer",
        "retrieval_audit",
        "claim_audit",
        "source_summary",
        "eval_judgment",
        "specialist_answer",
    ] = "rag_answer"
    model_profile: str
    rag_profile: str
    prompt_profile: str


class AppConfig(BaseModel):
    version: int = 1
    server: ServerConfig = Field(default_factory=ServerConfig)
    storage: StorageConfig = Field(default_factory=StorageConfig)
    model_profiles: dict[str, ModelProfile]
    corpora: dict[str, CorpusConfig]
    rag_profiles: dict[str, RagProfile]
    prompt_profiles: dict[str, PromptProfile]
    workflows: dict[str, WorkflowConfig]

    @property
    def database_path(self) -> Path:
        return expand_path(self.storage.database_path)

    @property
    def artifact_dir(self) -> Path:
        return expand_path(self.storage.artifact_dir)


def load_config(path: Path | None = None) -> AppConfig:
    import yaml

    config_path = path or default_config_path()
    if not config_path.exists():
        raise FileNotFoundError(f"config not found: {config_path}")

    data: Any = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"config root must be mapping: {config_path}")

    config = AppConfig.model_validate(data)
    if config.version != 1:
        raise ValueError("config.version must be 1")
    return config
