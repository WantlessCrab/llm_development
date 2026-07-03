from __future__ import annotations

from typing import Any

FORBIDDEN_PRIVATE_MARKERS = ("SECRET_DO_NOT_PERSIST", "PRIVATE_DO_NOT_PERSIST")


def _walk(value: Any):
    if isinstance(value, dict):
        for key, item in value.items():
            yield str(key)
            yield from _walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk(item)
    else:
        yield str(value)


def assert_no_forbidden_text(payload: Any,
                             forbidden: tuple[str, ...] = FORBIDDEN_PRIVATE_MARKERS) -> None:
    text = "\n".join(_walk(payload))
    found = [item for item in forbidden if item and item in text]
    if found:
        raise AssertionError(f"privacy leak markers found: {found}")


def audit_packet_detail(packet_detail: dict[str, Any],
                        forbidden: tuple[str, ...] = FORBIDDEN_PRIVATE_MARKERS) -> None:
    assert_no_forbidden_text(packet_detail, forbidden)