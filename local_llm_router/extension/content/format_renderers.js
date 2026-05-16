globalThis.LLMR = globalThis.LLMR || {};

LLMR.FormatRenderers = {
    toMarkdown(formatCapture) {
        return LLMR.FormatCapture.normalize(formatCapture).canonical_markdown;
    },

    toPlainText(formatCapture) {
        const capture = LLMR.FormatCapture.normalize(formatCapture);
        return capture.plain_text || capture.canonical_markdown;
    },

    toHtml(formatCapture) {
        const capture = LLMR.FormatCapture.normalize(formatCapture);
        if (capture.html_fragment) return capture.html_fragment;
        const safe = LLMR.FormatRenderers.escapeHtml(capture.canonical_markdown);
        return `<pre style="white-space:pre-wrap;font-family:monospace;">${safe}</pre>`;
    },

    escapeHtml(value) {
        return String(value || "")
            .replaceAll("&", "&amp;")
            .replaceAll("<", "&lt;")
            .replaceAll(">", "&gt;")
            .replaceAll('"', "&quot;")
            .replaceAll("'", "&#039;");
    },

    async writeClipboard(formatCapture, {rich = false} = {}) {
        const markdown = LLMR.FormatRenderers.toMarkdown(formatCapture);

        if (!rich || !window.ClipboardItem || !navigator.clipboard?.write) {
            await navigator.clipboard.writeText(markdown);
            return {ok: true, mode: "text/plain"};
        }

        const html = LLMR.FormatRenderers.toHtml(formatCapture);
        const item = new ClipboardItem({
            "text/plain": new Blob([markdown], {type: "text/plain"}),
            "text/html": new Blob([html], {type: "text/html"})
        });
        await navigator.clipboard.write([item]);
        return {ok: true, mode: "text/plain+text/html"};
    }
};