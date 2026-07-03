from __future__ import annotations

import asyncio
import json
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urljoin

from local_llm_router.format_capture import FormatCapture
from local_llm_router.models import (
    DraftItem,
    ProviderDispatchRequest,
    ProviderDispatchResponse,
    ProviderProbeResult,
)

from .base import ProviderConnector


class LocalLLMHttpProviderConnector(ProviderConnector):
    provider_type = "local_llm_http"

    required_config_keys = ["base_url", "chat_endpoint", "request_format", "response_format"]

    def public_config(self) -> dict[str, Any]:
        cfg = dict(self.config.config or {})
        for key in ["api_key", "authorization", "token"]:
            if key in cfg and cfg[key]:
                cfg[key] = "***"
        return cfg

    def _missing_config(self) -> list[str]:
        cfg = self.config.config or {}
        return [key for key in self.required_config_keys if not cfg.get(key)]

    def _base_url(self) -> str:
        cfg = self.config.config or {}
        return str(cfg["base_url"]).rstrip("/") + "/"

    def _endpoint_url(self, endpoint: str | None) -> str | None:
        if not endpoint:
            return None
        # Preserve relative endpoints such as ../health from a /v1 base URL.
        return urljoin(self._base_url(), str(endpoint).strip())

    def _headers(self, *, include_json: bool = False) -> dict[str, str]:
        cfg = self.config.config or {}
        headers: dict[str, str] = {}

        if include_json:
            headers["Content-Type"] = "application/json"

        authorization = cfg.get("authorization")
        token = cfg.get("token")
        api_key = cfg.get("api_key")

        if authorization:
            headers["Authorization"] = str(authorization)
        elif token:
            headers["Authorization"] = f"Bearer {token}"
        elif api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        return headers

    def _request_timeout(self, fallback: float = 10.0) -> float:
        cfg = self.config.config or {}
        try:
            value = float(cfg.get("timeout_seconds", fallback))
        except (TypeError, ValueError):
            value = fallback
        return max(1.0, value)

    def _read_json_get(self, url: str, *, timeout: float) -> tuple[int, dict[str, Any]]:
        req = urllib.request.Request(url, method="GET", headers=self._headers())
        with urllib.request.urlopen(req, timeout=timeout) as res:
            raw = res.read().decode("utf-8", errors="replace")
            parsed = json.loads(raw)
            if not isinstance(parsed, dict):
                raise ValueError("response root must be a JSON object")
            return int(res.status), parsed

    def _read_text_get(self, url: str, *, timeout: float) -> tuple[int, str]:
        req = urllib.request.Request(url, method="GET", headers=self._headers())
        with urllib.request.urlopen(req, timeout=timeout) as res:
            body = res.read(4096).decode("utf-8", errors="replace")
            return int(res.status), body

    @staticmethod
    def _model_ids_from_models_payload(payload: dict[str, Any]) -> list[str]:
        data = payload.get("data", [])
        if not isinstance(data, list):
            return []
        return [str(item.get("id")) for item in data if isinstance(item, dict) and item.get("id")]

    async def probe(self) -> ProviderProbeResult:
        if not self.config.enabled:
            return ProviderProbeResult(
                ok=False,
                provider_id=self.provider_id,
                availability="disabled",
                message="Provider is disabled.",
            )

        missing = self._missing_config()
        if missing:
            return ProviderProbeResult(
                ok=False,
                provider_id=self.provider_id,
                availability="needs_configuration",
                message="Local LLM provider needs configuration before dispatch.",
                missing_config=missing,
                details={"configured_keys": sorted((self.config.config or {}).keys())},
            )

        cfg = self.config.config or {}
        base_url = self._base_url()
        health_url = self._endpoint_url(cfg.get("health_endpoint"))
        models_url = self._endpoint_url(cfg.get("models_endpoint"))
        chat_url = self._endpoint_url(cfg.get("chat_endpoint"))
        timeout = self._request_timeout(10.0)

        details: dict[str, Any] = {
            "base_url": base_url,
            "health_url": health_url,
            "models_url": models_url,
            "chat_url": chat_url,
            "model": cfg.get("model"),
        }

        if health_url:
            try:
                health_status, health_body = await asyncio.to_thread(
                    self._read_text_get,
                    health_url,
                    timeout=timeout,
                )
            except Exception as exc:
                details["health_error"] = str(exc)
                return ProviderProbeResult(
                    ok=False,
                    provider_id=self.provider_id,
                    availability="unavailable",
                    message=f"Health endpoint unavailable: {exc}",
                    details=details,
                )

            details["health_status"] = health_status
            details["health_body_sample"] = health_body[:500]

            if health_status < 200 or health_status >= 300:
                return ProviderProbeResult(
                    ok=False,
                    provider_id=self.provider_id,
                    availability="error",
                    message=f"Health endpoint returned HTTP {health_status}.",
                    details=details,
                )

        if models_url:
            try:
                models_status, models_payload = await asyncio.to_thread(
                    self._read_json_get,
                    models_url,
                    timeout=timeout,
                )
            except Exception as exc:
                details["models_error"] = str(exc)
                return ProviderProbeResult(
                    ok=False,
                    provider_id=self.provider_id,
                    availability="unavailable",
                    message=f"Models endpoint unavailable or invalid: {exc}",
                    details=details,
                )

            model_ids = self._model_ids_from_models_payload(models_payload)
            expected_model = cfg.get("model")
            served_model_found = bool(expected_model and expected_model in model_ids)

            details.update(
                {
                    "models_status": models_status,
                    "served_model_ids": model_ids,
                    "served_model_found": served_model_found,
                }
            )

            if models_status < 200 or models_status >= 300:
                return ProviderProbeResult(
                    ok=False,
                    provider_id=self.provider_id,
                    availability="error",
                    message=f"Models endpoint returned HTTP {models_status}.",
                    details=details,
                )

            if expected_model and not served_model_found:
                return ProviderProbeResult(
                    ok=False,
                    provider_id=self.provider_id,
                    availability="unavailable",
                    message=f"Configured model {expected_model!r} not found in models endpoint.",
                    details=details,
                )

        if not health_url and not models_url:
            return ProviderProbeResult(
                ok=True,
                provider_id=self.provider_id,
                availability="ready",
                message="Required local LLM dispatch configuration is present. No health/models endpoint configured.",
                details=details,
            )

        return ProviderProbeResult(
            ok=True,
            provider_id=self.provider_id,
            availability="ready",
            message="Local LLM provider is reachable and served model validation passed.",
            details=details,
        )

    def _prompt_from_delivery(self, delivery: DraftItem) -> str:
        return delivery.wrapped_body_markdown or delivery.wrapped_body or ""

    def _configured_generation_options(self, request: ProviderDispatchRequest | None = None) -> \
    dict[str, Any]:
        cfg = self.config.config or {}
        options: dict[str, Any] = {}

        for key in [
            "temperature",
            "max_tokens",
            "top_p",
            "frequency_penalty",
            "presence_penalty",
            "stop",
            "seed",
        ]:
            if cfg.get(key) is not None:
                options[key] = cfg[key]

        if request is not None:
            for key, value in (request.options or {}).items():
                if value is not None:
                    options[key] = value

        return options

    def _build_request_body(
            self,
            delivery: DraftItem,
            request: ProviderDispatchRequest | None = None,
    ) -> dict[str, Any]:
        cfg = self.config.config or {}
        prompt = self._prompt_from_delivery(delivery)
        request_format = cfg.get("request_format")
        model = cfg.get("model")
        stream = bool(cfg.get("stream", False))
        system_prompt = cfg.get("system_prompt")
        generation_options = self._configured_generation_options(request)

        if request_format == "openai_chat_compatible":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            messages.append({"role": "user", "content": prompt})
            body: dict[str, Any] = {"messages": messages, "stream": stream, **generation_options}
            if model:
                body["model"] = model
            return body

        if request_format == "ollama_chat":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            messages.append({"role": "user", "content": prompt})
            return {"model": model, "messages": messages, "stream": stream, **generation_options}

        if request_format == "ollama_generate":
            body = {"model": model, "prompt": prompt, "stream": stream, **generation_options}
            if system_prompt:
                body["system"] = system_prompt
            return body

        if request_format == "plain_text_prompt":
            body = {"prompt": prompt, "stream": stream, **generation_options}
            if model:
                body["model"] = model
            if system_prompt:
                body["system_prompt"] = system_prompt
            return body

        raise ValueError(f"unsupported request_format: {request_format}")

    @staticmethod
    def _get_json_path(data: Any, path: str) -> Any:
        current = data
        for part in path.split("."):
            if isinstance(current, list):
                current = current[int(part)]
            elif isinstance(current, dict):
                current = current[part]
            else:
                raise KeyError(path)
        return current

    def _extract_response_text(self, data: dict[str, Any]) -> str:
        cfg = self.config.config or {}
        response_format = cfg.get("response_format")

        if response_format == "openai_chat_compatible":
            value = data["choices"][0]["message"].get("content")
            return str(value or "")

        if response_format == "ollama_chat":
            value = data["message"].get("content")
            return str(value or "")

        if response_format == "ollama_generate":
            return str(data.get("response") or "")

        if response_format == "custom_json_path":
            path = cfg.get("response_text_path")
            if not path:
                raise ValueError("response_text_path required for custom_json_path")
            value = self._get_json_path(data, str(path))
            return str(value or "")

        raise ValueError(f"unsupported response_format: {response_format}")

    async def dispatch(
            self,
            delivery: DraftItem,
            request: ProviderDispatchRequest,
    ) -> ProviderDispatchResponse:
        probe = await self.probe()
        if not probe.ok:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="blocked",
                message=probe.message,
                error_code=probe.availability,
                details=probe.details,
            )

        if not request.manual_confirmed:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="blocked",
                message="Manual confirmation is required before dispatch.",
                error_code="manual_confirmation_required",
            )

        cfg = self.config.config or {}
        chat_url = self._endpoint_url(cfg.get("chat_endpoint"))
        if not chat_url:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="blocked",
                message="chat_endpoint is not configured.",
                error_code="missing_chat_endpoint",
            )

        timeout = self._request_timeout(120.0)
        body = self._build_request_body(delivery, request)

        def _request() -> dict[str, Any]:
            raw = json.dumps(body).encode("utf-8")
            req = urllib.request.Request(
                chat_url,
                data=raw,
                method=str(cfg.get("method", "POST")).upper(),
                headers=self._headers(include_json=True),
            )
            with urllib.request.urlopen(req, timeout=timeout) as res:
                response_body = res.read().decode("utf-8", errors="replace")
                parsed = json.loads(response_body)
                if not isinstance(parsed, dict):
                    raise ValueError("local LLM response root must be a JSON object")
                return parsed

        try:
            data = await asyncio.to_thread(_request)
            text = self._extract_response_text(data).strip()
        except urllib.error.HTTPError as exc:
            error_body = exc.read().decode("utf-8", errors="replace")[:1000]
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="failed",
                message=f"Local LLM dispatch failed with HTTP {exc.code}: {error_body}",
                error_code="dispatch_http_error",
                details={"chat_url": chat_url, "status_code": exc.code},
            )
        except Exception as exc:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="failed",
                message=f"Local LLM dispatch failed: {exc}",
                error_code="dispatch_failed",
                details={"chat_url": chat_url},
            )

        if not text:
            return ProviderDispatchResponse(
                ok=False,
                provider_id=self.provider_id,
                delivery_id=delivery.delivery_id,
                status="failed",
                message="Local LLM returned empty response text.",
                error_code="empty_response",
                details={"chat_url": chat_url},
            )

        generated = FormatCapture.from_legacy_text(
            text,
            source_format="local_model_message",
            provider_hints={
                "provider_id": self.provider_id,
                "provider_type": self.provider_type,
                "parent_delivery_id": delivery.delivery_id,
                "model": cfg.get("model"),
            },
        )

        return ProviderDispatchResponse(
            ok=True,
            provider_id=self.provider_id,
            delivery_id=delivery.delivery_id,
            status="response_received",
            message="Local LLM response received.",
            generated_format_capture=generated,
            details={"chat_url": chat_url, "model": cfg.get("model")},
        )