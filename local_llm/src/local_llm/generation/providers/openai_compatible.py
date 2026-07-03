from __future__ import annotations

import time
import httpx

from local_llm.config import ModelProfile
from local_llm.contracts import ModelProviderResponse


class OpenAICompatibleProvider:
    def __init__(self, profile: ModelProfile):
        self.profile = profile
        self.base_url = str(profile.base_url).rstrip("/")

    def _url(self, path: str) -> str:
        return f"{self.base_url}/{path.lstrip('/')}"

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        api_key = getattr(self.profile, "api_key", None)
        if api_key is not None and str(api_key).strip():
            headers["Authorization"] = f"Bearer {str(api_key)}"
        return headers

    def health_check(self) -> tuple[bool, str]:
        try:
            with httpx.Client(timeout=10.0) as client:
                response = client.get(self._url("models"), headers=self._headers())

            if response.status_code == 401:
                return False, "unauthorized status=401"
            if response.status_code < 200 or response.status_code >= 300:
                return False, f"unhealthy status={response.status_code}: {response.text[:300]}"

            try:
                body = response.json()
            except Exception:
                return False, f"models endpoint returned non-json status={response.status_code}"

            model_ids = [item.get("id") for item in body.get("data", []) if isinstance(item, dict)]
            if self.profile.model not in model_ids:
                return False, f"model {self.profile.model!r} not found; available={model_ids}"
            return True, f"ready status={response.status_code} model={self.profile.model}"
        except Exception as exc:
            return False, str(exc)

    def build_request_payload(
            self,
            messages: list[dict[str, str]],
            settings: dict[str, object],
    ) -> dict[str, object]:
        payload: dict[str, object] = {"model": self.profile.model, "messages": messages}
        for key, value in settings.items():
            if value is not None:
                payload[key] = value
        return payload

    async def chat(self, messages: list[dict[str, str]],
                   settings: dict[str, object]) -> ModelProviderResponse:
        payload = self.build_request_payload(messages, settings)

        start = time.monotonic()
        async with httpx.AsyncClient(timeout=180.0) as client:
            response = await client.post(self._url("chat/completions"), headers=self._headers(),
                                         json=payload)
        latency_ms = int((time.monotonic() - start) * 1000)

        try:
            body = response.json()
        except Exception:
            body = {"raw_text": response.text}

        if response.status_code >= 400:
            raise RuntimeError(
                f"provider error status={response.status_code}: {response.text[:500]}")

        try:
            text = body["choices"][0]["message"]["content"] or ""
        except Exception:
            text = ""

        if not text:
            raise RuntimeError(f"provider returned no assistant content: {body}")

        return ModelProviderResponse(
            text=text,
            raw_response=body,
            provider_metadata={
                "base_url": self.base_url,
                "model": self.profile.model,
                "status_code": response.status_code,
            },
            latency_ms=latency_ms,
        )