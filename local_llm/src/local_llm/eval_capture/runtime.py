from __future__ import annotations

from pathlib import Path
from typing import Any

from local_llm.config import AppConfig


def build_runtime_links(config: AppConfig, *, runtime_root: str | None,
                        provider_summary: dict[str, Any]) -> dict[str, Any]:
    root = Path(runtime_root).expanduser().resolve() if runtime_root else None
    payload: dict[str, Any] = {
        "runtime_root": str(root) if root else None,
        "runtime_root_exists": bool(root and root.exists()),
        "provider": {
            "base_url": provider_summary.get("base_url"),
            "model": provider_summary.get("model"),
            "status_code": provider_summary.get("status_code"),
        },
    }
    if root:
        manifest = root / "runtime_manifest.yaml"
        model_manifest = root / "models" / "MANIFEST.sha256"
        payload["runtime_manifest_path"] = str(manifest)
        payload["runtime_manifest_exists"] = manifest.exists()
        payload["model_manifest_path"] = str(model_manifest)
        payload["model_manifest_exists"] = model_manifest.exists()
    payload["runtime_capture_enabled"] = config.eval_capture.runtime_capture_enabled
    payload["models_payload_capture_enabled"] = config.eval_capture.models_payload_capture_enabled
    return payload