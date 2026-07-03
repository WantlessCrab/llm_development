from __future__ import annotations

from local_llm_router.config import AppConfig, ProviderConfig
from local_llm_router.models import ProviderProfile

from .base import ProviderConnector
from .local_draft import LocalDraftProviderConnector
from .local_llm_http import LocalLLMHttpProviderConnector


class ProviderRegistry:
    def __init__(self, config: AppConfig):
        self.config = config
        self._connectors = {
            provider_id: self._build_connector(provider_config)
            for provider_id, provider_config in config.providers.items()
        }

    def _build_connector(self, provider_config: ProviderConfig) -> ProviderConnector:
        if provider_config.provider_type == "local_draft":
            return LocalDraftProviderConnector(provider_config)
        if provider_config.provider_type == "local_llm_http":
            return LocalLLMHttpProviderConnector(provider_config)
        return ProviderConnector(provider_config)

    def provider_ids(self) -> list[str]:
        return sorted(self._connectors)

    def has_provider(self, provider_id: str) -> bool:
        return provider_id in self._connectors

    def upsert_provider(self, provider_config: ProviderConfig) -> None:
        self.config.providers[provider_config.provider_id] = provider_config
        self._connectors[provider_config.provider_id] = self._build_connector(provider_config)

    def list_profiles(self) -> list[ProviderProfile]:
        return [connector.profile() for connector in self._connectors.values()]

    def get(self, provider_id: str) -> ProviderConnector | None:
        return self._connectors.get(provider_id)

    def require(self, provider_id: str) -> ProviderConnector:
        connector = self.get(provider_id)
        if connector is None:
            raise KeyError(provider_id)
        return connector