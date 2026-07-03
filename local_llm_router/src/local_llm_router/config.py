from __future__ import annotations

from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, Field, model_validator

from .paths import default_config_path, expand_path


class ServerConfig(BaseModel):
    host: str = "127.0.0.1"
    port: int = 8015
    cors_origins: list[str] = Field(default_factory=lambda: ["https://chatgpt.com"])


class StorageConfig(BaseModel):
    database_path: str = "~/.local/share/local-llm-router/router.sqlite"
    audit_dir: str = "~/.local/share/local-llm-router/audit"


class ProviderDiscoveryConfig(BaseModel):
    enabled: bool = False
    run_after_startup: bool = True
    roots: list[str] = Field(
        default_factory=lambda: ["/home/wantless/PycharmProjects/automation/model_runtimes"])
    apply_runtime: bool = True
    persist_report: bool = True
    report_dir: str = "~/.cache/local-llm-router/provider_discovery"
    add_only_ready: bool = True
    include_offline_candidates: bool = True
    probe_timeout_seconds: float = 10.0
    provider_id_prefix: str = "local"
    replace_existing: bool = False


class LocalServiceTargetConfig(BaseModel):
    label: str
    authority: Literal["supervisor"] = "supervisor"
    supervisor_name: str = ""
    code_svc_command: str = "code-svc"
    health_url: str
    managed: bool = True


class LocalServicesConfig(BaseModel):
    enabled: bool = True
    targets: dict[str, LocalServiceTargetConfig] = Field(default_factory=lambda: {
        "local_llm": LocalServiceTargetConfig(
            label="local_llm backend",
            authority="supervisor",
            supervisor_name="code-host:local-llm",
            code_svc_command="code-svc",
            health_url="http://127.0.0.1:8020/health",
            managed=True,
        ),
        "local_llm_router": LocalServiceTargetConfig(
            label="local_llm_router daemon",
            authority="supervisor",
            supervisor_name="code-host:local-llm-router",
            code_svc_command="code-svc",
            health_url="http://127.0.0.1:8015/health",
            managed=True,
        ),
    })

    @model_validator(mode="after")
    def normalize_targets(self) -> "LocalServicesConfig":
        defaults = {
            "local_llm": "code-host:local-llm",
            "local_llm_router": "code-host:local-llm-router",
        }
        for service_id, target in self.targets.items():
            if not target.supervisor_name and service_id in defaults:
                target.supervisor_name = defaults[service_id]
        return self


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
    provider_discovery: ProviderDiscoveryConfig = Field(default_factory=ProviderDiscoveryConfig)
    local_services: LocalServicesConfig = Field(default_factory=LocalServicesConfig)
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


def _required_provider_defaults() -> dict[str, dict[str, Any]]:
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
            },
        },
    }


def _merge_required_providers(data: dict[str, Any]) -> dict[str, Any]:
    providers = dict(data.get("providers") or {})
    for provider_id, provider_data in _required_provider_defaults().items():
        providers.setdefault(provider_id, provider_data)
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

    data = _merge_required_providers(data)

    config = AppConfig.model_validate(data)
    if config.version != 1:
        raise ValueError("config.version must be 1")
    return config