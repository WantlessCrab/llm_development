from __future__ import annotations

from typing import Any

from local_llm_router.config import ProviderConfig
from local_llm_router.models import (
    DraftItem,
    ProviderDispatchRequest,
    ProviderDispatchResponse,
    ProviderProbeResult,
    ProviderProfile,
)


class ProviderConnector:
    provider_type: str = "base"

    def __init__(self, config: ProviderConfig):
        self.config = config

    @property
    def provider_id(self) -> str:
        return self.config.provider_id

    def profile(self) -> ProviderProfile:
        return ProviderProfile(
            provider_id=self.config.provider_id,
            provider_type=self.config.provider_type,
            label=self.config.label,
            enabled=self.config.enabled,
            availability="disabled" if not self.config.enabled else self.config.availability,
            capabilities=self.config.capabilities.model_dump(),
            config=self.public_config(),
        )

    def public_config(self) -> dict[str, Any]:
        return dict(self.config.config or {})

    async def probe(self) -> ProviderProbeResult:
        profile = self.profile()
        return ProviderProbeResult(
            ok=profile.enabled and profile.availability == "ready",
            provider_id=self.provider_id,
            availability=profile.availability,
            message=f"{profile.label}: {profile.availability}",
            details={"provider_type": profile.provider_type},
        )

    async def dispatch(
            self,
            delivery: DraftItem,
            request: ProviderDispatchRequest,
    ) -> ProviderDispatchResponse:
        return ProviderDispatchResponse(
            ok=False,
            provider_id=self.provider_id,
            delivery_id=delivery.delivery_id,
            status="blocked",
            message="provider does not implement dispatch",
            error_code="dispatch_not_supported",
        )