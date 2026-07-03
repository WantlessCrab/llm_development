from __future__ import annotations

from pathlib import Path

APP_SLUG = "local-llm-router"


def expand_path(value: str | Path) -> Path:
    return Path(value).expanduser().resolve()


def config_dir() -> Path:
    return Path.home() / ".config" / APP_SLUG


def data_dir() -> Path:
    return Path.home() / ".local" / "share" / APP_SLUG


def cache_dir() -> Path:
    return Path.home() / ".cache" / APP_SLUG


def default_config_path() -> Path:
    return config_dir() / "config.yaml"


def default_prompt_wrappers_path() -> Path:
    return config_dir() / "prompt_wrappers.yaml"


def project_source_path() -> Path:
    return Path.home() / "PycharmProjects" / "automation" / "local_llm_router"