from __future__ import annotations

import hashlib
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class FinalizedArtifact:
    path: str
    sha256: str
    size_bytes: int
    mime_type: str | None
    outcome: str = "written"


class ArtifactWriter:
    def __init__(self, root: Path):
        self.root = Path(root).expanduser().resolve()

    def _target_path(self, *, turn_packet_id: str, artifact_type: str, suffix: str) -> Path:
        target_dir = self.root / "packets" / turn_packet_id
        target_dir.mkdir(parents=True, exist_ok=True)
        safe_type = "".join(ch if ch.isalnum() or ch in {"_", "-"} else "_" for ch in artifact_type)
        return target_dir / f"{safe_type}{suffix}"

    def finalize_text(
            self,
            *,
            turn_packet_id: str,
            artifact_type: str,
            text: str,
            suffix: str = ".txt",
            mime_type: str | None = "text/plain",
            outcome: str = "written",
    ) -> FinalizedArtifact:
        final_path = self._target_path(turn_packet_id=turn_packet_id, artifact_type=artifact_type,
                                       suffix=suffix)
        data = text.encode("utf-8")
        fd, tmp_name = tempfile.mkstemp(prefix=f".{final_path.stem}.", suffix=".tmp",
                                        dir=final_path.parent)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            digest = hashlib.sha256(data).hexdigest()
            os.replace(tmp_name, final_path)
            if hashlib.sha256(final_path.read_bytes()).hexdigest() != digest:
                raise RuntimeError(f"artifact verification failed: {final_path}")
            return FinalizedArtifact(path=str(final_path), sha256=digest, size_bytes=len(data),
                                     mime_type=mime_type, outcome=outcome)
        except Exception:
            Path(tmp_name).unlink(missing_ok=True)
            raise

    def finalize_omission_marker(self, *, turn_packet_id: str, artifact_type: str,
                                 reason: str) -> FinalizedArtifact:
        marker = {
            "artifact_type": artifact_type,
            "body_persisted": False,
            "payload_policy": "omitted_body",
            "reason": reason,
        }
        import json
        return self.finalize_text(
            turn_packet_id=turn_packet_id,
            artifact_type=f"{artifact_type}_omitted",
            text=json.dumps(marker, sort_keys=True, indent=2),
            suffix=".omitted.json",
            mime_type="application/json",
            outcome="omitted",
        )