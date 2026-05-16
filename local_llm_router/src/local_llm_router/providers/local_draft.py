from __future__ import annotations

from local_llm_router.models import ProviderProbeResult

from .base import ProviderConnector


class LocalDraftProviderConnector(ProviderConnector):
    provider_type = "local_draft"

    async def probe(self) -> ProviderProbeResult:
        return ProviderProbeResult(
            ok=True,
            provider_id=self.provider_id,
            availability="ready",
            message="Local draft inbox is available.",
            details={
                "provider_type": self.provider_type,
                "manual_review": True,
            },
        )