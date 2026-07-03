from __future__ import annotations

import fnmatch
import hashlib
from dataclasses import dataclass
from pathlib import Path

from local_llm.config import CorpusConfig, expand_path


@dataclass(frozen=True)
class FileCandidate:
    corpus_id: str
    path: Path
    root: Path
    relative_path: str
    size_bytes: int
    mtime_ns: int
    file_hash: str
    extension: str


def _is_binary_sample(data: bytes) -> bool:
    return bool(data and b"\x00" in data)


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def matches_any(relative: str, patterns: list[str]) -> bool:
    normalized = relative.replace("\\", "/")
    for pattern in patterns:
        normalized_pattern = pattern.replace("\\", "/")
        if fnmatch.fnmatch(normalized, normalized_pattern):
            return True
        if normalized_pattern.startswith("**/") and fnmatch.fnmatch(normalized,
                                                                    normalized_pattern[3:]):
            return True
    return False

def scan_corpus(corpus_id: str, corpus: CorpusConfig) -> list[FileCandidate]:
    candidates: list[FileCandidate] = []

    for root_value in corpus.roots:
        root = expand_path(root_value)
        if not root.exists() or not root.is_dir():
            continue

        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if corpus.exclude_globs and matches_any(rel, corpus.exclude_globs):
                continue
            if corpus.include_globs and not matches_any(rel, corpus.include_globs):
                continue
            try:
                stat = path.stat()
                sample = path.read_bytes()[:4096]
                if _is_binary_sample(sample):
                    continue
                digest = file_sha256(path)
            except OSError:
                continue

            candidates.append(
                FileCandidate(
                    corpus_id=corpus_id,
                    path=path,
                    root=root,
                    relative_path=rel,
                    size_bytes=stat.st_size,
                    mtime_ns=stat.st_mtime_ns,
                    file_hash=digest,
                    extension=path.suffix.lower().lstrip("."),
                )
            )
    return candidates