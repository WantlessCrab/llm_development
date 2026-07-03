from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

from .paths import default_prompt_wrappers_path, expand_path

SUPPORTED_TRANSFORMS = {"none", "strip", "rstrip", "lstrip"}


class PromptWrapperError(ValueError):
    """Raised when prompt wrapper configuration or usage is invalid."""


@dataclass(frozen=True)
class PromptWrapper:
    wrapper_id: str
    label: str
    description: str = ""
    transform: str = "none"
    before: str = ""
    after: str = ""
    line_prefix: str = ""

    @property
    def has_before(self) -> bool:
        return bool(self.before)

    @property
    def has_after(self) -> bool:
        return bool(self.after)

    @property
    def has_line_prefix(self) -> bool:
        return bool(self.line_prefix)

    def summary(self) -> dict[str, Any]:
        return {
            "wrapper_id": self.wrapper_id,
            "label": self.label,
            "description": self.description,
            "transform": self.transform,
            "has_before": self.has_before,
            "has_after": self.has_after,
            "has_line_prefix": self.has_line_prefix,
        }


def _clean_id(value: str) -> str:
    value = str(value or "").strip()
    if not value:
        raise PromptWrapperError("prompt wrapper id must not be blank")
    if not all(ch.isalnum() or ch in "._-" for ch in value):
        raise PromptWrapperError(f"prompt wrapper id contains unsupported characters: {value!r}")
    return value


def _string_field(raw: dict[str, Any], key: str, default: str = "") -> str:
    value = raw.get(key, default)
    if value is None:
        return default
    if not isinstance(value, str):
        raise PromptWrapperError(f"prompt_wrappers.*.{key} must be a string")
    return value


def _wrapper_from_mapping(wrapper_id: str, raw: Any) -> PromptWrapper:
    wrapper_id = _clean_id(wrapper_id)
    if not isinstance(raw, dict):
        raise PromptWrapperError(f"prompt_wrappers.{wrapper_id} must be a mapping")

    label = _string_field(raw, "label", wrapper_id).strip()
    if not label:
        raise PromptWrapperError(f"prompt_wrappers.{wrapper_id}.label must not be blank")

    transform = _string_field(raw, "transform", "none").strip() or "none"
    if transform not in SUPPORTED_TRANSFORMS:
        raise PromptWrapperError(
            f"prompt_wrappers.{wrapper_id}.transform must be one of {sorted(SUPPORTED_TRANSFORMS)}"
        )

    return PromptWrapper(
        wrapper_id=wrapper_id,
        label=label,
        description=_string_field(raw, "description", ""),
        transform=transform,
        before=_string_field(raw, "before", ""),
        after=_string_field(raw, "after", ""),
        line_prefix=_string_field(raw, "line_prefix", ""),
    )


def load_prompt_wrappers(path: str | Path | None = None) -> dict[str, PromptWrapper]:
    config_path = expand_path(path) if path is not None else default_prompt_wrappers_path()
    if not config_path.exists():
        return {}

    data = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise PromptWrapperError(f"prompt wrapper config root must be a mapping: {config_path}")
    if data.get("version") != 1:
        raise PromptWrapperError("prompt wrapper config version must be 1")

    raw_wrappers = data.get("prompt_wrappers")
    if not isinstance(raw_wrappers, dict) or not raw_wrappers:
        raise PromptWrapperError("prompt_wrappers must be a non-empty mapping")

    wrappers: dict[str, PromptWrapper] = {}
    for wrapper_id, raw in raw_wrappers.items():
        wrapper = _wrapper_from_mapping(str(wrapper_id), raw)
        wrappers[wrapper.wrapper_id] = wrapper
    return wrappers


def list_prompt_wrappers(path: str | Path | None = None) -> list[PromptWrapper]:
    return sorted(load_prompt_wrappers(path).values(), key=lambda item: item.label.casefold())


def get_prompt_wrapper(wrapper_id: str, path: str | Path | None = None) -> PromptWrapper:
    wrapper_id = _clean_id(wrapper_id)
    wrappers = load_prompt_wrappers(path)
    try:
        return wrappers[wrapper_id]
    except KeyError as exc:
        raise PromptWrapperError(f"prompt wrapper not found: {wrapper_id}") from exc


def apply_prompt_wrapper(text: str, wrapper: PromptWrapper) -> str:
    value = str(text or "")
    if wrapper.transform == "strip":
        value = value.strip()
    elif wrapper.transform == "rstrip":
        value = value.rstrip()
    elif wrapper.transform == "lstrip":
        value = value.lstrip()
    elif wrapper.transform == "none":
        pass
    else:
        raise PromptWrapperError(f"unsupported transform: {wrapper.transform}")

    if wrapper.line_prefix:
        lines = value.splitlines()
        value = "\n".join(
            f"{wrapper.line_prefix}{line}" for line in lines) if lines else wrapper.line_prefix

    return f"{wrapper.before}{value}{wrapper.after}"


def apply_prompt_wrapper_by_id(
        text: str,
        wrapper_id: str | None,
        path: str | Path | None = None,
) -> tuple[str, PromptWrapper | None, dict[str, Any]]:
    if not wrapper_id:
        return str(text or ""), None, {"enabled": False}

    wrapper = get_prompt_wrapper(wrapper_id, path)
    original = str(text or "")
    wrapped = apply_prompt_wrapper(original, wrapper)
    metadata = {
        "enabled": True,
        "wrapper_id": wrapper.wrapper_id,
        "label": wrapper.label,
        "transform": wrapper.transform,
        "original_length": len(original),
        "wrapped_length": len(wrapped),
    }
    return wrapped, wrapper, metadata