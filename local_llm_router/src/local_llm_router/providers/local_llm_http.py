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
        base_url = str(cfg["base_url"]).rstrip("/") + "/"
        health_endpoint = cfg.get("health_endpoint")
        if not health_endpoint:
            return ProviderProbeResult(
                ok=True,
                provider_id=self.provider_id,
                availability="ready",
                message="Required local LLM dispatch configuration is present. No health endpoint configured.",
                details={"base_url": base_url},
            )

        health_url = urljoin(base_url, str(health_endpoint).lstrip("/"))

        def _request() -> tuple[int, str]:
            req = urllib.request.Request(health_url, method="GET")
            with urllib.request.urlopen(req, timeout=float(cfg.get("timeout_seconds", 10))) as res:
                body = res.read(2048).decode("utf-8", errors="replace")
                return int(res.status), body

        try:
            status, body = await asyncio.to_thread(_request)
        except Exception as exc:
            return ProviderProbeResult(
                ok=False,
                provider_id=self.provider_id,
                availability="unavailable",
                message=f"Health endpoint unavailable: {exc}",
                details={"health_url": health_url},
            )

        return ProviderProbeResult(
            ok=200 <= status < 300,
            provider_id=self.provider_id,
            availability="ready" if 200 <= status < 300 else "error",
            message=f"Health endpoint returned HTTP {status}.",
            details={"health_url": health_url, "body_sample": body[:500]},
        )

    def _prompt_from_delivery(self, delivery: DraftItem) -> str:
        return delivery.wrapped_body_markdown or delivery.wrapped_body or ""

    def _build_request_body(self, delivery: DraftItem) -> dict[str, Any]:
        cfg = self.config.config or {}
        prompt = self._prompt_from_delivery(delivery)
        request_format = cfg.get("request_format")
        model = cfg.get("model")
        stream = bool(cfg.get("stream", False))
        system_prompt = cfg.get("system_prompt")

        if request_format == "openai_chat_compatible":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            messages.append({"role": "user", "content": prompt})
            body = {"messages": messages, "stream": stream}
            if model:
                body["model"] = model
            return body

        if request_format == "ollama_chat":
            messages = []
            if system_prompt:
                messages.append({"role": "system", "content": system_prompt})
            messages.append({"role": "user", "content": prompt})
            return {"model": model, "messages": messages, "stream": stream}

        if request_format == "ollama_generate":
            body = {"model": model, "prompt": prompt, "stream": stream}
            if system_prompt:
                body["system"] = system_prompt
            return body

        if request_format == "plain_text_prompt":
            body = {"prompt": prompt, "stream": stream}
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
            return str(data["choices"][0]["message"]["content"])

        if response_format == "ollama_chat":
            return str(data["message"]["content"])

        if response_format == "ollama_generate":
            return str(data["response"])

        if response_format == "custom_json_path":
            path = cfg.get("response_text_path")
            if not path:
                raise ValueError("response_text_path required for custom_json_path")
            return str(self._get_json_path(data, str(path)))

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
        base_url = str(cfg["base_url"]).rstrip("/") + "/"
        chat_url = urljoin(base_url, str(cfg["chat_endpoint"]).lstrip("/"))
        timeout = float(cfg.get("timeout_seconds", 120))
        body = self._build_request_body(delivery)

        def _request() -> dict[str, Any]:
            raw = json.dumps(body).encode("utf-8")
            req = urllib.request.Request(
                chat_url,
                data=raw,
                method=str(cfg.get("method", "POST")).upper(),
                headers={"Content-Type": "application/json"},
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
            },
        )

        return ProviderDispatchResponse(
            ok=True,
            provider_id=self.provider_id,
            delivery_id=delivery.delivery_id,
            status="response_received",
            message="Local LLM response received.",
            generated_format_capture=generated,
            details={"chat_url": chat_url},
        )