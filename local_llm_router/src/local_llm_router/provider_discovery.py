from __future__ import annotations

import asyncio
import json
import re
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

from .config import AppConfig, ProviderConfig
from .paths import cache_dir, expand_path
from .providers.local_llm_http import LocalLLMHttpProviderConnector


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def slugify(value: str) -> str:
    text = str(value or "").strip().lower()
    text = re.sub(r"^local[-_]", "", text)
    text = re.sub(r"[-_]llamacpp$", "", text)
    text = re.sub(r"[-_]vllm$", "", text)
    text = re.sub(r"[^a-z0-9]+", "_", text)
    text = re.sub(r"_+", "_", text).strip("_")
    return text or "model"


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists() or not path.is_file():
        return values

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue

        key, value = stripped.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key:
            values[key] = value

    return values


def compose_files(runtime_dir: Path) -> list[Path]:
    return sorted(
        [
            *runtime_dir.glob("docker-compose*.yml"),
            *runtime_dir.glob("docker-compose*.yaml"),
            *runtime_dir.glob("compose*.yml"),
            *runtime_dir.glob("compose*.yaml"),
        ]
    )


def _substitute_env(value: str, env: dict[str, str]) -> str:
    """
    Resolve Docker Compose-style environment substitutions used in runtime files.

    Supported forms:
      ${NAME}
      ${NAME:-default}
      $NAME

    Unsupported shell operators intentionally resolve conservatively rather than
    attempting full shell expansion semantics.
    """

    def repl(match: re.Match[str]) -> str:
        braced_name = match.group(1)
        braced_default = match.group(2)
        bare_name = match.group(3)

        if braced_name:
            return env.get(braced_name, braced_default or "")
        if bare_name:
            return env.get(bare_name, "")
        return ""

    return re.sub(
        r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)",
        repl,
        value,
    )


def infer_host_port_from_compose(runtime_dir: Path, env: dict[str, str]) -> int | None:
    for compose_path in compose_files(runtime_dir):
        try:
            data = yaml.safe_load(compose_path.read_text(encoding="utf-8")) or {}
        except Exception:
            continue

        services = data.get("services") if isinstance(data, dict) else None
        if not isinstance(services, dict):
            continue

        for service in services.values():
            if not isinstance(service, dict):
                continue

            ports = service.get("ports") or []
            if not isinstance(ports, list):
                continue

            for item in ports:
                if isinstance(item, int):
                    continue

                if isinstance(item, dict):
                    target = item.get("target")
                    published = item.get("published")
                    if target in {8000, "8000"} and published:
                        try:
                            return int(_substitute_env(str(published), env))
                        except ValueError:
                            continue
                    continue

                text = _substitute_env(str(item), env).strip().strip('"').strip("'")
                parts = text.split(":")

                if len(parts) == 3:
                    host_port, container_port = parts[1], parts[2]
                elif len(parts) == 2:
                    host_port, container_port = parts[0], parts[1]
                else:
                    continue

                if container_port.split("/")[0] != "8000":
                    continue

                try:
                    return int(host_port)
                except ValueError:
                    continue

    return None


def provider_capabilities() -> dict[str, bool]:
    return {
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
    }


def openai_compatible_provider_config(
        *,
        provider_id: str,
        label: str,
        base_url: str,
        model: str,
        api_key: str = "not-needed",
        timeout_seconds: int = 300,
) -> dict[str, Any]:
    return {
        "provider_id": provider_id,
        "provider_type": "local_llm_http",
        "label": label,
        "enabled": True,
        "availability": "ready",
        "capabilities": provider_capabilities(),
        "config": {
            "base_url": base_url.rstrip("/"),
            "health_endpoint": "../health",
            "models_endpoint": "models",
            "chat_endpoint": "chat/completions",
            "method": "POST",
            "request_format": "openai_chat_compatible",
            "response_format": "openai_chat_compatible",
            "response_text_path": None,
            "api_key": api_key,
            "model": model,
            "timeout_seconds": timeout_seconds,
            "stream": False,
            "system_prompt": None,
            "temperature": 0.2,
            "max_tokens": 384,
        },
    }


@dataclass
class ProviderDiscoveryCandidate:
    provider_id: str
    status: str
    engine_family: str
    runtime_dir: str
    label: str
    base_url: str | None = None
    health_url: str | None = None
    models_url: str | None = None
    chat_url: str | None = None
    served_model_id: str | None = None
    reason: str = ""
    provider_config: dict[str, Any] | None = None
    probe_result: dict[str, Any] | None = None
    already_configured: bool = False
    applied_runtime: bool = False
    warnings: list[str] = field(default_factory=list)


@dataclass
class ProviderDiscoveryReport:
    ok: bool
    run_id: str
    created_at: str
    roots: list[str]
    probe: bool
    apply_runtime_requested: bool
    candidates: list[ProviderDiscoveryCandidate]
    applied_provider_ids: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    report_path: str | None = None
    yaml_path: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class ProviderDiscoveryEngine:
    def __init__(
            self,
            *,
            existing_provider_ids: set[str] | None = None,
            provider_id_prefix: str = "local",
    ):
        self.existing_provider_ids = existing_provider_ids or set()
        self.provider_id_prefix = slugify(provider_id_prefix or "local")

    def discover(
            self,
            *,
            roots: list[str],
            probe: bool = True,
            apply_runtime_requested: bool = False,
            include_offline_candidates: bool = True,
            probe_timeout_seconds: float = 10.0,
            persist_report: bool = False,
            report_dir: str | None = None,
    ) -> ProviderDiscoveryReport:
        run_id = str(uuid.uuid4())
        candidates: list[ProviderDiscoveryCandidate] = []
        errors: list[str] = []
        expanded_roots = [str(expand_path(root)) for root in roots]

        for root_value in expanded_roots:
            root = Path(root_value)
            if not root.exists():
                errors.append(f"root does not exist: {root}")
                continue
            if not root.is_dir():
                errors.append(f"root is not a directory: {root}")
                continue

            for runtime_dir in sorted([item for item in root.iterdir() if item.is_dir()]):
                candidate = self._candidate_from_runtime_dir(
                    runtime_dir,
                    probe=probe,
                    probe_timeout_seconds=probe_timeout_seconds,
                )
                if candidate is None:
                    continue
                if candidate.status == "offline" and not include_offline_candidates:
                    continue
                candidates.append(candidate)

        report = ProviderDiscoveryReport(
            ok=not errors,
            run_id=run_id,
            created_at=utc_now(),
            roots=expanded_roots,
            probe=probe,
            apply_runtime_requested=apply_runtime_requested,
            candidates=candidates,
            errors=errors,
        )

        if persist_report:
            self.persist_report(report, report_dir=report_dir)

        return report

    def _prefixed_provider_id(self, engine_family: str, value: str) -> str:
        return f"{self.provider_id_prefix}_{engine_family}_{slugify(value)}"

    def _candidate_from_runtime_dir(
            self,
            runtime_dir: Path,
            *,
            probe: bool,
            probe_timeout_seconds: float,
    ) -> ProviderDiscoveryCandidate | None:
        env = {**read_env_file(runtime_dir / ".env.example"), **read_env_file(runtime_dir / ".env")}
        name = runtime_dir.name.lower()
        compose_text = "\n".join(path.name for path in compose_files(runtime_dir)).lower()

        if "VLLM_SERVED_MODEL_NAME" in env or "vllm" in name or "vllm" in compose_text:
            return self._vllm_candidate(
                runtime_dir,
                env,
                probe=probe,
                probe_timeout_seconds=probe_timeout_seconds,
            )

        if "LLAMA_ARG_ALIAS" in env or "llamacpp" in name or "llama" in name or "llama" in compose_text:
            return self._llamacpp_candidate(
                runtime_dir,
                env,
                probe=probe,
                probe_timeout_seconds=probe_timeout_seconds,
            )

        return None

    def _vllm_candidate(
            self,
            runtime_dir: Path,
            env: dict[str, str],
            *,
            probe: bool,
            probe_timeout_seconds: float,
    ) -> ProviderDiscoveryCandidate:
        served_model = env.get("VLLM_SERVED_MODEL_NAME") or env.get("MODEL") or ""
        api_key = env.get("VLLM_API_KEY") or "not-needed"
        host_port = infer_host_port_from_compose(runtime_dir, env)
        provider_id = (
            self._prefixed_provider_id("vllm", served_model)
            if served_model
            else self._prefixed_provider_id("vllm", runtime_dir.name)
        )
        label = f"vLLM {served_model or runtime_dir.name}"

        return self._openai_candidate(
            runtime_dir=runtime_dir,
            engine_family="vllm",
            provider_id=provider_id,
            label=label,
            host_port=host_port,
            served_model=served_model,
            api_key=api_key,
            timeout_seconds=120,
            probe=probe,
            probe_timeout_seconds=probe_timeout_seconds,
        )

    def _llamacpp_candidate(
            self,
            runtime_dir: Path,
            env: dict[str, str],
            *,
            probe: bool,
            probe_timeout_seconds: float,
    ) -> ProviderDiscoveryCandidate:
        served_model = env.get("LLAMA_ARG_ALIAS") or env.get("MODEL") or ""
        host_port = None

        try:
            if env.get("HOST_PORT"):
                host_port = int(env["HOST_PORT"])
        except ValueError:
            host_port = None

        host_port = host_port or infer_host_port_from_compose(runtime_dir, env)

        provider_id = (
            self._prefixed_provider_id("llamacpp", served_model)
            if served_model
            else f"{self.provider_id_prefix}_{slugify(runtime_dir.name.replace('rocm_', ''))}"
        )
        provider_id = provider_id.replace(
            f"{self.provider_id_prefix}_llamacpp_llamacpp_",
            f"{self.provider_id_prefix}_llamacpp_",
        )
        label = f"llama.cpp {served_model or runtime_dir.name}"

        return self._openai_candidate(
            runtime_dir=runtime_dir,
            engine_family="llamacpp",
            provider_id=provider_id,
            label=label,
            host_port=host_port,
            served_model=served_model,
            api_key="not-needed",
            timeout_seconds=300,
            probe=probe,
            probe_timeout_seconds=probe_timeout_seconds,
        )

    def _openai_candidate(
            self,
            *,
            runtime_dir: Path,
            engine_family: str,
            provider_id: str,
            label: str,
            host_port: int | None,
            served_model: str,
            api_key: str,
            timeout_seconds: int,
            probe: bool,
            probe_timeout_seconds: float,
    ) -> ProviderDiscoveryCandidate:
        warnings: list[str] = []
        if not host_port:
            warnings.append("missing host port")
        if not served_model:
            warnings.append("missing served model id")

        base_url = f"http://127.0.0.1:{host_port}/v1" if host_port else None
        health_url = f"http://127.0.0.1:{host_port}/health" if host_port else None
        models_url = f"{base_url}/models" if base_url else None
        chat_url = f"{base_url}/chat/completions" if base_url else None
        provider_config = None
        already_configured = provider_id in self.existing_provider_ids
        status = "incomplete" if warnings else "candidate"
        reason = "; ".join(warnings) if warnings else "candidate satisfies static provider contract"

        if base_url and served_model:
            provider_config = openai_compatible_provider_config(
                provider_id=provider_id,
                label=label,
                base_url=base_url,
                model=served_model,
                api_key=api_key,
                timeout_seconds=timeout_seconds,
            )

        if already_configured:
            status = "already_configured"
            reason = "provider id already exists in active config/registry; discovery will not replace it by default"

        candidate = ProviderDiscoveryCandidate(
            provider_id=provider_id,
            status=status,
            engine_family=engine_family,
            runtime_dir=str(runtime_dir),
            label=label,
            base_url=base_url,
            health_url=health_url,
            models_url=models_url,
            chat_url=chat_url,
            served_model_id=served_model or None,
            reason=reason,
            provider_config=provider_config,
            already_configured=already_configured,
            warnings=warnings,
        )

        if probe and provider_config:
            self._probe_candidate(candidate, timeout_seconds=probe_timeout_seconds)

        return candidate

    def _probe_candidate(self, candidate: ProviderDiscoveryCandidate, *,
                         timeout_seconds: float) -> None:
        if not candidate.provider_config:
            return

        config_data = dict(candidate.provider_config)
        config_data["config"] = dict(config_data.get("config") or {})
        config_data["config"]["timeout_seconds"] = timeout_seconds
        provider_config = ProviderConfig.model_validate(config_data)
        connector = LocalLLMHttpProviderConnector(provider_config)

        try:
            result = asyncio.run(connector.probe())
        except Exception as exc:
            candidate.probe_result = {"ok": False, "error": str(exc)}
            if not candidate.already_configured:
                candidate.status = "error"
                candidate.reason = f"probe raised unexpected error: {exc}"
            return

        candidate.probe_result = result.model_dump()

        if result.ok:
            if candidate.already_configured:
                candidate.status = "already_configured"
            else:
                candidate.status = "ready"
                candidate.reason = result.message
            return

        if candidate.already_configured:
            candidate.status = "already_configured"
            return

        if result.availability == "needs_configuration":
            candidate.status = "incomplete"
        elif result.availability == "unavailable":
            message = result.message.lower()
            if "not found in models endpoint" in message or "configured model" in message:
                candidate.status = "misaligned"
            else:
                candidate.status = "offline"
        else:
            candidate.status = result.availability

        candidate.reason = result.message

    @staticmethod
    def persist_report(report: ProviderDiscoveryReport, *, report_dir: str | None = None) -> None:
        target_dir = expand_path(report_dir) if report_dir else cache_dir() / "provider_discovery"
        target_dir.mkdir(parents=True, exist_ok=True)
        stem = f"provider_discovery_{report.created_at.replace(':', '').replace('+', 'Z')}_{report.run_id[:8]}"
        json_path = target_dir / f"{stem}.json"
        yaml_path = target_dir / f"{stem}.providers.yaml"
        report.report_path = str(json_path)
        report.yaml_path = str(yaml_path)
        json_path.write_text(
            json.dumps(report.to_dict(), indent=2, ensure_ascii=False),
            encoding="utf-8",
        )

        provider_blocks = {
            candidate.provider_id: candidate.provider_config
            for candidate in report.candidates
            if candidate.provider_config and candidate.status in {"ready", "offline",
                                                                  "already_configured"}
        }
        yaml_path.write_text(
            yaml.safe_dump({"providers": provider_blocks}, sort_keys=False),
            encoding="utf-8",
        )


class ProviderDiscoveryManager:
    def __init__(self, config: AppConfig, registry: Any):
        self.config = config
        self.registry = registry
        self.latest_report: ProviderDiscoveryReport | None = None
        self.latest_error: str | None = None

    def run(
            self,
            *,
            roots: list[str] | None = None,
            probe: bool = True,
            apply_runtime: bool | None = None,
            persist_report: bool | None = None,
            add_only_ready: bool | None = None,
            include_offline_candidates: bool | None = None,
            replace_existing: bool | None = None,
    ) -> ProviderDiscoveryReport:
        cfg = self.config.provider_discovery
        roots = roots or cfg.roots
        apply_runtime = cfg.apply_runtime if apply_runtime is None else apply_runtime
        persist_report = cfg.persist_report if persist_report is None else persist_report
        add_only_ready = cfg.add_only_ready if add_only_ready is None else add_only_ready
        include_offline_candidates = (
            cfg.include_offline_candidates
            if include_offline_candidates is None
            else include_offline_candidates
        )
        replace_existing = cfg.replace_existing if replace_existing is None else replace_existing

        engine = ProviderDiscoveryEngine(
            existing_provider_ids=set(self.config.providers) | set(self.registry.provider_ids()),
            provider_id_prefix=cfg.provider_id_prefix,
        )
        report = engine.discover(
            roots=roots,
            probe=probe,
            apply_runtime_requested=bool(apply_runtime),
            include_offline_candidates=bool(include_offline_candidates),
            probe_timeout_seconds=cfg.probe_timeout_seconds,
            persist_report=False,
            report_dir=cfg.report_dir,
        )

        if apply_runtime:
            for candidate in report.candidates:
                should_add = candidate.provider_config is not None

                if add_only_ready:
                    should_add = should_add and candidate.status == "ready"
                else:
                    should_add = should_add and candidate.status in {"ready", "offline"}

                if not should_add:
                    continue

                if self.registry.has_provider(candidate.provider_id) and not replace_existing:
                    candidate.already_configured = True
                    candidate.status = "already_configured"
                    candidate.reason = (
                        "provider id already exists in active config/registry; "
                        "runtime apply skipped because replace_existing=false"
                    )
                    continue

                provider_config = ProviderConfig.model_validate(candidate.provider_config)
                self.registry.upsert_provider(provider_config)
                candidate.applied_runtime = True
                report.applied_provider_ids.append(candidate.provider_id)

        if persist_report:
            engine.persist_report(report, report_dir=cfg.report_dir)

        self.latest_report = report
        self.latest_error = None
        return report

    def status(self) -> dict[str, Any]:
        return {
            "enabled": self.config.provider_discovery.enabled,
            "run_after_startup": self.config.provider_discovery.run_after_startup,
            "latest_error": self.latest_error,
            "latest_report": self.latest_report.to_dict() if self.latest_report else None,
        }