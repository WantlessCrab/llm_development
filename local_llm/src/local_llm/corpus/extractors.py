from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ExtractedText:
    text: str
    encoding: str
    extractor_type: str
    warnings: list[str]


SUPPORTED_EXTENSIONS = {"md", "py", "js", "html", "yaml", "yml", "toml", "txt", "json"}


def extract_text(path: Path) -> ExtractedText:
    ext = path.suffix.lower().lstrip(".")
    if ext not in SUPPORTED_EXTENSIONS:
        return ExtractedText("", "", "unsupported", [f"unsupported_extension:{ext}"])

    raw = path.read_bytes()
    warnings: list[str] = []
    for encoding in ("utf-8", "utf-8-sig", "latin-1"):
        try:
            return ExtractedText(raw.decode(encoding), encoding, "plain_text", warnings)
        except UnicodeDecodeError:
            continue

    warnings.append("decode_replacement_used")
    return ExtractedText(raw.decode("utf-8", errors="replace"), "utf-8-replace", "plain_text", warnings)
