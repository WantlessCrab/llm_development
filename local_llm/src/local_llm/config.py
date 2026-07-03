from __future__ import annotations

from pathlib import Path
from typing import Any, Literal
from urllib.parse import urlsplit, urlunsplit

from pydantic import BaseModel, Field, field_validator, model_validator
import os

APP_SLUG = "local-llm"
CaptureModeName = Literal["full", "privacy"]
PrivacyLevelName = Literal["none", "standard", "strict"]
FailurePolicyName = Literal["fail_closed", "fail_open_with_warning"]


def expand_path(value: str | Path) -> Path:
    return Path(value).expanduser().resolve()


def config_dir() -> Path:
    return Path.home() / ".config" / APP_SLUG


def default_config_path() -> Path:
    return config_dir() / "config.yaml"


def default_runtime_env_path() -> Path:
    return config_dir() / "local-llm.env"


def load_runtime_env_file(path: Path | None = None, *, override: bool = False) -> Path:
    """Load local_llm host-side runtime environment values.

    This supports every invocation path, including the installed launcher,
    project virtualenv console scripts, `python -m local_llm.cli`, and
    Supervisor-managed service starts.

    The file format is intentionally small: KEY=VALUE lines, with blank lines
    and comments ignored. Existing process environment values are preserved
    unless override=True.
    """
    env_path = path or default_runtime_env_path()
    if not env_path.exists():
        return env_path

    for raw in env_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")

        if not key:
            continue
        if override or key not in os.environ:
            os.environ[key] = value

    return env_path

def safe_database_label(database_url: str) -> str:
    """Return a passwordless database identity safe for CLI/API output."""
    parts = urlsplit(database_url)
    username = parts.username or ""
    hostname = parts.hostname or ""
    port = f":{parts.port}" if parts.port else ""

    if username:
        netloc = f"{username}@{hostname}{port}"
    else:
        netloc = f"{hostname}{port}"

    return urlunsplit((parts.scheme, netloc, parts.path, "", ""))


class ServerConfig(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8020


class StorageConfig(BaseModel):
    backend: Literal["postgres"] = "postgres"
    database_url: str = "postgresql://llm_database@127.0.0.1:8032/llm_database"
    database_password_env: str = "LOCAL_LLM_POSTGRES_PASSWORD"
    artifact_dir: str = "~/.local/share/local-llm/artifacts"

    @field_validator("database_url")
    @classmethod
    def validate_passwordless_database_url(cls, value: str) -> str:
        parts = urlsplit(value)
        if parts.password:
            raise ValueError("storage.database_url must not contain a password")
        if parts.scheme not in {"postgresql", "postgres"}:
            raise ValueError("storage.database_url must use postgresql://")
        if not parts.username:
            raise ValueError("storage.database_url must include a database user")
        if not parts.hostname:
            raise ValueError("storage.database_url must include a host")
        if not parts.path or parts.path == "/":
            raise ValueError("storage.database_url must include a database name")
        return value

    @field_validator("database_password_env")
    @classmethod
    def validate_database_password_env(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("storage.database_password_env must not be blank")
        return value


class EvalCaptureConfig(BaseModel):
    enabled: bool = True
    default_capture_mode: CaptureModeName = "full"
    default_privacy_level: PrivacyLevelName = "none"
    failure_policy: FailurePolicyName = "fail_closed"
    source_system: str = "local_llm"
    runtime_root: str | None = None
    runtime_capture_enabled: bool = True
    models_payload_capture_enabled: bool = True
    redaction_policy_version: int = 1

    @field_validator("source_system")
    @classmethod
    def validate_source_system(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("eval_capture.source_system must not be blank")
        return value

    @model_validator(mode="after")
    def validate_capture_privacy_pair(self) -> "EvalCaptureConfig":
        if self.default_capture_mode == "full" and self.default_privacy_level != "none":
            raise ValueError(
                "eval_capture.default_privacy_level must be none when default_capture_mode is full")
        if self.default_capture_mode == "privacy" and self.default_privacy_level == "none":
            raise ValueError(
                "eval_capture.default_privacy_level must be standard or strict when default_capture_mode is privacy")
        return self


class PrivacyConfig(BaseModel):
    allow_ui_toggle: bool = True
    allow_cli_toggle: bool = True
    strict_retrieval_identity_redaction: bool = True
    retrieval_identity_hmac_secret_env: str | None = None

    @field_validator("retrieval_identity_hmac_secret_env")
    @classmethod
    def blank_secret_env_to_none(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        return value or None


class TrainingConfig(BaseModel):
    experiment_default_replicates: int = Field(default=2, ge=1, le=20)
    experiment_max_replicates_per_condition: int = Field(default=20, ge=1, le=100)
    experiment_max_planned_packets: int = Field(default=100, ge=1, le=500)
    operator_score_min: float = 1.0
    operator_score_max: float = 5.0
    operator_label_options: list[str] = Field(
        default_factory=lambda: ["accept", "revise", "reject", "unclear"]
    )

    @model_validator(mode="after")
    def validate_training_bounds(self) -> "TrainingConfig":
        if self.experiment_default_replicates > self.experiment_max_replicates_per_condition:
            raise ValueError(
                "training.experiment_default_replicates cannot exceed "
                "training.experiment_max_replicates_per_condition"
            )
        if self.experiment_max_planned_packets < self.experiment_default_replicates:
            raise ValueError(
                "training.experiment_max_planned_packets cannot be less than "
                "training.experiment_default_replicates"
            )
        if self.operator_score_min >= self.operator_score_max:
            raise ValueError("training.operator_score_min must be less than operator_score_max")
        cleaned = [item.strip() for item in self.operator_label_options if item.strip()]
        if not cleaned:
            raise ValueError("training.operator_label_options must not be empty")
        if len(cleaned) != len(set(cleaned)):
            raise ValueError("training.operator_label_options must not contain duplicates")
        object.__setattr__(self, "operator_label_options", cleaned)
        return self


class ModelDefaults(BaseModel):
    temperature: float = 0.2
    max_tokens: int = 900


class CaptureDefaultsMixin(BaseModel):
    eval_capture_mode: CaptureModeName | None = None
    privacy_level: PrivacyLevelName | None = None
    privacy_required: bool = False

    @model_validator(mode="after")
    def validate_capture_pair(self) -> "CaptureDefaultsMixin":
        if self.eval_capture_mode == "full" and self.privacy_level not in (None, "none"):
            raise ValueError("privacy_level must be none when eval_capture_mode is full")
        if self.eval_capture_mode == "privacy" and self.privacy_level == "none":
            raise ValueError(
                "privacy_level must be standard or strict when eval_capture_mode is privacy")
        if self.privacy_required and self.eval_capture_mode == "full":
            raise ValueError("privacy_required cannot be combined with eval_capture_mode=full")
        return self


class ModelProfile(CaptureDefaultsMixin):
    provider: str = "openai_compatible"
    base_url: str
    api_key: str = "not-needed"
    model: str
    context_window: int = 8192
    runtime_root: str | None = None
    defaults: ModelDefaults = Field(default_factory=ModelDefaults)

    @field_validator("runtime_root")
    @classmethod
    def blank_runtime_root_to_none(cls, value: str | None) -> str | None:
        if value is None:
            return None
        value = value.strip()
        return value or None


class CorpusConfig(BaseModel):
    roots: list[str]
    include_globs: list[str]
    exclude_globs: list[str] = Field(default_factory=list)


class RetrievalConfig(BaseModel):
    method: Literal["postgres_fts"] = "postgres_fts"
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


class WorkflowConfig(CaptureDefaultsMixin):
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
    eval_capture: EvalCaptureConfig = Field(default_factory=EvalCaptureConfig)
    privacy: PrivacyConfig = Field(default_factory=PrivacyConfig)
    training: TrainingConfig = Field(default_factory=TrainingConfig)
    model_profiles: dict[str, ModelProfile]
    corpora: dict[str, CorpusConfig]
    rag_profiles: dict[str, RagProfile]
    prompt_profiles: dict[str, PromptProfile]
    workflows: dict[str, WorkflowConfig]

    @property
    def artifact_dir(self) -> Path:
        return expand_path(self.storage.artifact_dir)

    @property
    def database_label(self) -> str:
        return safe_database_label(self.storage.database_url)

    @property
    def storage_backend(self) -> str:
        return self.storage.backend

    @property
    def runtime_root(self) -> Path | None:
        return expand_path(
            self.eval_capture.runtime_root) if self.eval_capture.runtime_root else None


def load_config(path: Path | None = None) -> AppConfig:
    import yaml

    load_runtime_env_file()

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