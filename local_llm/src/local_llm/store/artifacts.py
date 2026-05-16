from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class ArtifactWriter:
    def __init__(self, artifact_root: Path):
        self.artifact_root = artifact_root

    def run_dir(self, run_id: str) -> Path:
        return self.artifact_root / "runs" / run_id

    def write_text(self, run_id: str, name: str, text: str) -> tuple[Path, str]:
        run_dir = self.run_dir(run_id)
        run_dir.mkdir(parents=True, exist_ok=True)
        path = run_dir / name
        data = text.encode("utf-8")
        path.write_bytes(data)
        return path, sha256_bytes(data)

    def write_json(self, run_id: str, name: str, payload: Any) -> tuple[Path, str]:
        text = json.dumps(payload, indent=2, ensure_ascii=False, default=str)
        return self.write_text(run_id, name, text + "\n")
