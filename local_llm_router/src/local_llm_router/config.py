from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field

from .paths import default_config_path, expand_path


class ServerConfig(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8015
    cors_origins: list[str] = Field(default_factory=lambda: ["https://chatgpt.com"])


class StorageConfig(BaseModel):
    database_path: str = "~/.local/share/local-llm-router/router.sqlite"
    audit_dir: str = "~/.local/share/local-llm-router/audit"


class ProviderCapabilitiesConfig(BaseModel):
    can_capture: bool = False
    can_receive: bool = False
    can_insert_draft: bool = False
    can_manual_send: bool = False
    can_dispatch_request: bool = False
    can_return_response: bool = False
    supports_browser_session: bool = False
    supports_http_session: bool = False
    supports_streaming: bool = False
    supports_queue_groups: bool = True
    supports_manual_review: bool = True


class ProviderConfig(BaseModel):
    provider_id: str
    provider_type: str
    label: str
    enabled: bool = True
    availability: Literal[
        "ready", "needs_configuration", "unavailable", "disabled", "error"] = "ready"
    capabilities: ProviderCapabilitiesConfig = Field(default_factory=ProviderCapabilitiesConfig)
    config: dict[str, Any] = Field(default_factory=dict)


class TargetSpec(BaseModel):
    type: str
    id: str


class SourceSpec(BaseModel):
    provider: str
    role: str = "assistant"


class RouteConfig(BaseModel):
    route_id: str
    name: str = ""
    enabled: bool = True
    mode: str = "manual_draft_bridge"
    source: SourceSpec
    target: TargetSpec
    wrapper: str


class WrapperConfig(BaseModel):
    label: str = ""
    before: str = ""
    after: str = ""


class AppConfig(BaseModel):
    version: int = 1
    server: ServerConfig = Field(default_factory=ServerConfig)
    storage: StorageConfig = Field(default_factory=StorageConfig)
    providers: dict[str, ProviderConfig] = Field(default_factory=dict)
    targets: dict[str, Any] = Field(default_factory=dict)
    wrappers: dict[str, WrapperConfig] = Field(default_factory=dict)
    routes: list[RouteConfig] = Field(default_factory=list)

    @property
    def database_path(self) -> Path:
        return expand_path(self.storage.database_path)

    @property
    def audit_dir(self) -> Path:
        return expand_path(self.storage.audit_dir)


def _builtin_provider_defaults() -> dict[str, dict[str, Any]]:
    return {
        "local_draft": {
            "provider_id": "local_draft",
            "provider_type": "local_draft",
            "label": "Local draft inbox",
            "enabled": True,
            "availability": "ready",
            "capabilities": {
                "can_capture": False,
                "can_receive": True,
                "can_insert_draft": False,
                "can_manual_send": False,
                "can_dispatch_request": False,
                "can_return_response": False,
                "supports_browser_session": False,
                "supports_http_session": False,
                "supports_streaming": False,
                "supports_queue_groups": True,
                "supports_manual_review": True,
            },
            "config": {},
        },
        "chatgpt_browser": {
            "provider_id": "chatgpt_browser",
            "provider_type": "browser_llm",
            "label": "ChatGPT browser",
            "enabled": True,
            "availability": "ready",
            "capabilities": {
                "can_capture": True,
                "can_receive": True,
                "can_insert_draft": True,
                "can_manual_send": False,
                "can_dispatch_request": False,
                "can_return_response": True,
                "supports_browser_session": True,
                "supports_http_session": False,
                "supports_streaming": False,
                "supports_queue_groups": True,
                "supports_manual_review": True,
            },
            "config": {
                "host_pattern": "https://chatgpt.com/*",
                "extension_provider_key": "chatgpt",
                "capture_provider_keys": ["chatgpt"],
            },
        },
        "local_llm_primary": {
            "provider_id": "local_llm_primary",
            "provider_type": "local_llm_http",
            "label": "Local LLM primary",
            "enabled": True,
            "availability": "needs_configuration",
            "capabilities": {
                "can_capture": True,
                "can_receive": True,
                "can_insert_draft": False,
                "can_manual_send": True,
                "can_dispatch_request": True,
                "can_return_response": True,
                "supports_browser_session": False,
                "supports_http_session": True,
                "supports_streaming": False,
                "supports_queue_groups": True,
                "supports_manual_review": True,
            },
            "config": {
                "base_url": None,
                "health_endpoint": None,
                "chat_endpoint": None,
                "method": "POST",
                "request_format": None,
                "response_format": None,
                "response_text_path": None,
                "model": None,
                "timeout_seconds": 120,
                "stream": False,
                "system_prompt": None,
            },
        },
    }


def _merge_builtin_providers(data: dict[str, Any]) -> dict[str, Any]:
    providers = dict(data.get("providers") or {})
    for provider_id, provider_data in _builtin_provider_defaults().items():
        if provider_id not in providers:
            providers[provider_id] = provider_data
    data["providers"] = providers
    return data


def load_config(path: Path | None = None) -> AppConfig:
    import yaml

    config_path = path or default_config_path()
    if not config_path.exists():
        raise FileNotFoundError(f"config not found: {config_path}")

    data = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"config root must be mapping: {config_path}")

    data = _merge_builtin_providers(data)

    config = AppConfig.model_validate(data)
    if config.version != 1:
        raise ValueError("config.version must be 1")
    return config