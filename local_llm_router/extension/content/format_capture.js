globalThis.LLMR = globalThis.LLMR || {};

LLMR.FORMAT_CAPTURE_VERSION = "format_capture.v1";

LLMR.FormatCapture = {
    emptyDiagnostics() {
        return {
            source_char_count: 0,
            markdown_char_count: 0,
            plain_char_count: 0,
            html_char_count: 0,
            dom_pre_count: 0,
            dom_code_count: 0,
            markdown_fence_count: 0,
            heading_count: 0,
            list_item_count: 0,
            table_count: 0,
            blockquote_count: 0,
            link_count: 0,
            fallback_node_count: 0,
            warnings: []
        };
    },

    create({
               canonicalMarkdown,
               plainText,
               htmlFragment,
               sourceHtml,
               sourceFormat = "markdown",
               diagnostics = {},
               providerHints = {}
           } = {}) {
        const markdown = String(canonicalMarkdown || "");
        const plain = String(plainText || markdown);
        const html = htmlFragment == null ? null : String(htmlFragment);
        const source = sourceHtml == null ? null : String(sourceHtml);

        const mergedDiagnostics = {
            ...LLMR.FormatCapture.emptyDiagnostics(),
            ...diagnostics
        };

        mergedDiagnostics.markdown_char_count = markdown.length;
        mergedDiagnostics.plain_char_count = plain.length;
        mergedDiagnostics.html_char_count = html ? html.length : 0;
        mergedDiagnostics.markdown_fence_count = (markdown.match(/```/g) || []).length / 2 | 0;

        return {
            canonical_markdown: markdown,
            plain_text: plain,
            html_fragment: html,
            source_html: source,
            source_format: sourceFormat,
            format_version: LLMR.FORMAT_CAPTURE_VERSION,
            diagnostics: mergedDiagnostics,
            provider_hints: providerHints || {}
        };
    },

    fromLegacyText(text, providerHints = {}) {
        const value = String(text || "");
        return LLMR.FormatCapture.create({
            canonicalMarkdown: value,
            plainText: value,
            htmlFragment: null,
            sourceHtml: null,
            sourceFormat: "markdown",
            diagnostics: {
                source_char_count: value.length
            },
            providerHints: {
                ...providerHints,
                legacy_text_only: true
            }
        });
    },

    normalize(value) {
        if (!value || typeof value !== "object") {
            return LLMR.FormatCapture.fromLegacyText("");
        }

        return LLMR.FormatCapture.create({
            canonicalMarkdown: value.canonical_markdown || value.canonicalMarkdown || value.text || "",
            plainText: value.plain_text || value.plainText || value.canonical_markdown || value.text || "",
            htmlFragment: value.html_fragment || value.htmlFragment || null,
            sourceHtml: value.source_html || value.sourceHtml || null,
            sourceFormat: value.source_format || value.sourceFormat || "markdown",
            diagnostics: value.diagnostics || {},
            providerHints: value.provider_hints || value.providerHints || {}
        });
    },

    primaryText(value) {
        return LLMR.FormatCapture.normalize(value).canonical_markdown;
    },

    diagnosticsSummary(value) {
        const capture = LLMR.FormatCapture.normalize(value);
        const d = capture.diagnostics || {};
        return {
            format_version: capture.format_version,
            markdown_chars: d.markdown_char_count || 0,
            plain_chars: d.plain_char_count || 0,
            html_chars: d.html_char_count || 0,
            dom_pre_count: d.dom_pre_count || 0,
            dom_code_count: d.dom_code_count || 0,
            markdown_fence_count: d.markdown_fence_count || 0,
            fallback_node_count: d.fallback_node_count || 0,
            warning_count: Array.isArray(d.warnings) ? d.warnings.length : 0
        };
    }
};