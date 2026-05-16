from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

FORMAT_CAPTURE_VERSION = "format_capture.v1"


class FormatDiagnostics(BaseModel):
    source_char_count: int = 0
    markdown_char_count: int = 0
    plain_char_count: int = 0
    html_char_count: int = 0

    dom_pre_count: int = 0
    dom_code_count: int = 0
    markdown_fence_count: int = 0
    heading_count: int = 0
    list_item_count: int = 0
    table_count: int = 0
    blockquote_count: int = 0
    link_count: int = 0
    fallback_node_count: int = 0

    warnings: list[str] = Field(default_factory=list)


class FormatCapture(BaseModel):
    canonical_markdown: str
    plain_text: str = ""
    html_fragment: str | None = None
    source_html: str | None = None
    source_format: Literal[
        "dom", "html", "markdown", "plaintext", "api_message", "local_model_message"] = "markdown"
    format_version: str = FORMAT_CAPTURE_VERSION
    diagnostics: FormatDiagnostics = Field(default_factory=FormatDiagnostics)
    provider_hints: dict[str, Any] = Field(default_factory=dict)

    @classmethod
    def from_legacy_text(
            cls,
            text: str,
            *,
            source_format: str = "markdown",
            provider_hints: dict[str, Any] | None = None,
    ) -> "FormatCapture":
        text = str(text or "")
        diagnostics = FormatDiagnostics(
            source_char_count=len(text),
            markdown_char_count=len(text),
            plain_char_count=len(text),
            html_char_count=0,
            markdown_fence_count=text.count("```") // 2,
        )
        return cls(
            canonical_markdown=text,
            plain_text=text,
            html_fragment=None,
            source_html=None,
            source_format=source_format,  # type: ignore[arg-type]
            diagnostics=diagnostics,
            provider_hints=provider_hints or {},
        )

    def normalized(self) -> "FormatCapture":
        markdown = str(self.canonical_markdown or "")
        plain = str(self.plain_text or markdown)
        diagnostics = self.diagnostics
        diagnostics.markdown_char_count = len(markdown)
        diagnostics.plain_char_count = len(plain)
        diagnostics.html_char_count = len(self.html_fragment or "")
        diagnostics.markdown_fence_count = markdown.count("```") // 2

        return FormatCapture(
            canonical_markdown=markdown,
            plain_text=plain,
            html_fragment=self.html_fragment,
            source_html=self.source_html,
            source_format=self.source_format,
            format_version=self.format_version or FORMAT_CAPTURE_VERSION,
            diagnostics=diagnostics,
            provider_hints=self.provider_hints or {},
        )


def model_to_dict(model: BaseModel) -> dict[str, Any]:
    if hasattr(model, "model_dump"):
        return model.model_dump()
    return model.dict()