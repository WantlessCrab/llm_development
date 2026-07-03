from __future__ import annotations

from typing import Protocol

from local_llm.config import ModelProfile
from local_llm.contracts import ModelProviderResponse


class ModelProvider(Protocol):
    def health_check(self) -> tuple[bool, str]:
        ...

    def build_request_payload(
            self,
            messages: list[dict[str, str]],
            settings: dict[str, object],
    ) -> dict[str, object]:
        ...

    async def chat(self, messages: list[dict[str, str]],
                   settings: dict[str, object]) -> ModelProviderResponse:
        ...


def build_provider(profile: ModelProfile) -> ModelProvider:
    if profile.provider == "openai_compatible":
        from local_llm.generation.providers.openai_compatible import OpenAICompatibleProvider
        return OpenAICompatibleProvider(profile)

    raise ValueError(f"unsupported provider: {profile.provider}")