from __future__ import annotations

import html

from .config import AppConfig, WrapperConfig
from .format_capture import FormatCapture
from .models import CaptureEvent


def _value_or_empty(value: str | None) -> str:
    return "" if value is None else value


def render_template(template: str, event: CaptureEvent) -> str:
    fields = {
        "provider": _value_or_empty(event.provider),
        "source_session_id": _value_or_empty(event.source_session_id),
        "conversation_id": _value_or_empty(event.conversation_id),
        "gizmo_id": _value_or_empty(event.gizmo_id),
        "conversation_url": _value_or_empty(event.conversation_url),
        "conversation_title": _value_or_empty(event.conversation_title),
        "role": _value_or_empty(event.role),
        "turn_testid": _value_or_empty(event.turn_testid),
        "capture_source": _value_or_empty(event.capture_source),
        "text_hash": _value_or_empty(event.text_hash),
        "text_length": str(event.text_length),
        "captured_at": _value_or_empty(event.captured_at),
    }
    return template.format(**fields)


def _html_wrapper(before: str, inner_html: str | None, after: str) -> str:
    safe_before = f"<pre>{html.escape(before)}</pre>" if before else ""
    safe_after = f"<pre>{html.escape(after)}</pre>" if after else ""
    body = inner_html if inner_html else ""
    return f"{safe_before}{body}{safe_after}"


def apply_format_wrapper(config: AppConfig, wrapper_id: str, event: CaptureEvent) -> FormatCapture:
    base = event.resolved_format_capture()
    wrapper: WrapperConfig | None = config.wrappers.get(wrapper_id)

    if not wrapper:
        return base

    before = render_template(wrapper.before, event)
    after = render_template(wrapper.after, event)

    markdown = f"{before}{base.canonical_markdown}{after}"
    plain = f"{before}{base.plain_text or base.canonical_markdown}{after}"
    html_fragment = _html_wrapper(before, base.html_fragment, after)

    diagnostics = base.diagnostics
    diagnostics.markdown_char_count = len(markdown)
    diagnostics.plain_char_count = len(plain)
    diagnostics.html_char_count = len(html_fragment)
    diagnostics.markdown_fence_count = markdown.count("```") // 2

    provider_hints = dict(base.provider_hints or {})
    provider_hints["wrapper_id"] = wrapper_id
    provider_hints["wrapper_label"] = wrapper.label

    return FormatCapture(
        canonical_markdown=markdown,
        plain_text=plain,
        html_fragment=html_fragment,
        source_html=base.source_html,
        source_format=base.source_format,
        format_version=base.format_version,
        diagnostics=diagnostics,
        provider_hints=provider_hints,
    ).normalized()