globalThis.LLMR = globalThis.LLMR || {};

LLMR.FormatSerializer = {
    fromDom(root, options = {}) {
        const diagnostics = LLMR.FormatCapture.emptyDiagnostics();

        if (!root) {
            diagnostics.warnings.push("missing_root");
            return LLMR.FormatCapture.create({
                canonicalMarkdown: "",
                plainText: "",
                htmlFragment: null,
                sourceHtml: null,
                sourceFormat: "dom",
                diagnostics,
                providerHints: options.providerHints || {}
            });
        }

        diagnostics.source_char_count = String(root.innerText || root.textContent || "").length;
        diagnostics.dom_pre_count = root.querySelectorAll?.("pre").length || 0;
        diagnostics.dom_code_count = root.querySelectorAll?.("code").length || 0;
        diagnostics.heading_count = root.querySelectorAll?.("h1,h2,h3,h4,h5,h6").length || 0;
        diagnostics.list_item_count = root.querySelectorAll?.("li").length || 0;
        diagnostics.table_count = root.querySelectorAll?.("table").length || 0;
        diagnostics.blockquote_count = root.querySelectorAll?.("blockquote").length || 0;
        diagnostics.link_count = root.querySelectorAll?.("a[href]").length || 0;

        const markdown = LLMR.FormatSerializer.normalizeMarkdown(
            LLMR.FormatSerializer.serializeChildrenAsBlocks(root, diagnostics, 0)
        );

        const plain = LLMR.preserveText(root.innerText || root.textContent || "");
        const html = root.innerHTML || null;

        if (diagnostics.dom_pre_count > 0 && (markdown.match(/```/g) || []).length / 2 < diagnostics.dom_pre_count) {
            diagnostics.warnings.push("fewer_markdown_fences_than_dom_pre_blocks");
        }

        return LLMR.FormatCapture.create({
            canonicalMarkdown: markdown || plain,
            plainText: plain || markdown,
            htmlFragment: html,
            sourceHtml: options.includeSourceHtml === false ? null : html,
            sourceFormat: "dom",
            diagnostics,
            providerHints: {
                provider: options.provider || "",
                role: options.role || "",
                root_selector: options.rootSelector || "",
                ...options.providerHints
            }
        });
    },

    serializeChildrenAsBlocks(node, diagnostics, depth = 0) {
        const parts = [];
        for (const child of Array.from(node.childNodes || [])) {
            const text = LLMR.FormatSerializer.serializeBlock(child, diagnostics, depth);
            if (text) parts.push(text);
        }
        return parts.join("\n\n");
    },

    serializeBlock(node, diagnostics, depth = 0) {
        if (!node) return "";

        if (node.nodeType === Node.TEXT_NODE) {
            return LLMR.preserveText(node.textContent || "");
        }

        if (node.nodeType !== Node.ELEMENT_NODE) {
            return "";
        }

        const el = node;
        const tag = el.tagName.toLowerCase();

        if (LLMR.FormatSerializer.shouldSkipElement(el)) return "";

        if (tag === "pre") {
            return LLMR.FormatSerializer.serializePre(el);
        }

        if (/^h[1-6]$/.test(tag)) {
            const level = Number(tag.slice(1));
            const text = LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics).trim();
            return text ? `${"#".repeat(level)} ${text}` : "";
        }

        if (tag === "blockquote") {
            const inner = LLMR.FormatSerializer.serializeChildrenAsBlocks(el, diagnostics, depth);
            return inner
                .split("\n")
                .map(line => line.trim() ? `> ${line}` : ">")
                .join("\n");
        }

        if (tag === "ul") {
            return LLMR.FormatSerializer.serializeList(el, diagnostics, depth, false);
        }

        if (tag === "ol") {
            return LLMR.FormatSerializer.serializeList(el, diagnostics, depth, true);
        }

        if (tag === "table") {
            return LLMR.FormatSerializer.serializeTable(el, diagnostics);
        }

        if (tag === "hr") {
            return "---";
        }

        if (tag === "p") {
            return LLMR.FormatSerializer.serializeInlineOrNested(el, diagnostics, depth);
        }

        if (tag === "div" || tag === "section" || tag === "article") {
            if (el.querySelector("pre, table, ul, ol, blockquote, h1, h2, h3, h4, h5, h6")) {
                return LLMR.FormatSerializer.serializeChildrenAsBlocks(el, diagnostics, depth);
            }
            return LLMR.FormatSerializer.serializeInlineOrNested(el, diagnostics, depth);
        }

        if (tag === "li") {
            return LLMR.FormatSerializer.serializeInlineOrNested(el, diagnostics, depth);
        }

        if (tag === "br") {
            return "\n";
        }

        if (el.children && el.children.length) {
            return LLMR.FormatSerializer.serializeChildrenAsBlocks(el, diagnostics, depth);
        }

        diagnostics.fallback_node_count += 1;
        return LLMR.preserveText(el.innerText || el.textContent || "");
    },

    serializeInlineOrNested(el, diagnostics, depth = 0) {
        if (el.querySelector("pre, table, ul, ol, blockquote")) {
            return LLMR.FormatSerializer.serializeChildrenAsBlocks(el, diagnostics, depth);
        }
        return LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics).trim();
    },

    serializeInlineChildren(node, diagnostics) {
        const out = [];

        for (const child of Array.from(node.childNodes || [])) {
            if (child.nodeType === Node.TEXT_NODE) {
                out.push(String(child.textContent || ""));
                continue;
            }

            if (child.nodeType !== Node.ELEMENT_NODE) continue;

            const el = child;
            const tag = el.tagName.toLowerCase();

            if (LLMR.FormatSerializer.shouldSkipElement(el)) continue;

            if (tag === "br") {
                out.push("\n");
            } else if (tag === "code" && !el.closest("pre")) {
                out.push(LLMR.FormatSerializer.wrapInlineCode(el.innerText || el.textContent || ""));
            } else if (tag === "strong" || tag === "b") {
                out.push(`**${LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics).trim()}**`);
            } else if (tag === "em" || tag === "i") {
                out.push(`*${LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics).trim()}*`);
            } else if (tag === "a" && el.href) {
                const label = LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics).trim() || el.href;
                out.push(`[${label}](${el.href})`);
            } else if (tag === "pre") {
                out.push(`\n\n${LLMR.FormatSerializer.serializePre(el)}\n\n`);
            } else if (tag === "span" || tag === "div") {
                out.push(LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics));
            } else {
                out.push(LLMR.FormatSerializer.serializeInlineChildren(el, diagnostics));
            }
        }

        return LLMR.FormatSerializer.normalizeInline(out.join(""));
    },

    serializePre(pre) {
        const code = pre.querySelector("code") || pre;
        const raw = String(code.innerText || code.textContent || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").replace(/\n+$/g, "");
        const lang = LLMR.FormatSerializer.detectCodeLanguage(code, pre);
        return `\`\`\`${lang}\n${raw}\n\`\`\``;
    },

    detectCodeLanguage(code, pre) {
        const candidates = [
            code?.className,
            pre?.className,
            code?.getAttribute?.("data-language"),
            pre?.getAttribute?.("data-language"),
        ].map(x => String(x || ""));

        for (const value of candidates) {
            const match =
                value.match(/language-([a-zA-Z0-9_-]+)/) ||
                value.match(/lang-([a-zA-Z0-9_-]+)/) ||
                value.match(/\b([a-zA-Z0-9_-]+)\b/);
            if (match && !["hljs", "code", "group"].includes(match[1])) return match[1];
        }
        return "";
    },

    wrapInlineCode(value) {
        const text = String(value || "").replace(/\s+/g, " ").trim();
        if (!text) return "";
        const fence = text.includes("`") ? "``" : "`";
        return `${fence}${text}${fence}`;
    },

    serializeList(list, diagnostics, depth, ordered) {
        const rows = [];
        let index = 1;

        for (const child of Array.from(list.children || [])) {
            if (child.tagName?.toLowerCase() !== "li") continue;

            const marker = ordered ? `${index}.` : "-";
            const indent = "  ".repeat(depth);

            const nestedLists = Array.from(child.children || []).filter(x =>
                ["ul", "ol"].includes(x.tagName?.toLowerCase())
            );

            const shallowClone = child.cloneNode(true);
            for (const nested of Array.from(shallowClone.children || [])) {
                if (["ul", "ol"].includes(nested.tagName?.toLowerCase())) nested.remove();
            }

            const text = LLMR.FormatSerializer.serializeInlineChildren(shallowClone, diagnostics).trim();
            if (text) rows.push(`${indent}${marker} ${text}`);

            for (const nested of nestedLists) {
                rows.push(
                    LLMR.FormatSerializer.serializeList(
                        nested,
                        diagnostics,
                        depth + 1,
                        nested.tagName.toLowerCase() === "ol"
                    )
                );
            }

            index += 1;
        }

        return rows.filter(Boolean).join("\n");
    },

    serializeTable(table, diagnostics) {
        const rows = Array.from(table.querySelectorAll("tr"));
        if (!rows.length) {
            diagnostics.warnings.push("table_without_rows");
            diagnostics.fallback_node_count += 1;
            return LLMR.preserveText(table.innerText || "");
        }

        const cells = rows.map(row =>
            Array.from(row.querySelectorAll("th,td")).map(cell =>
                LLMR.cleanText(cell.innerText || cell.textContent || "").replaceAll("|", "\\|")
            )
        ).filter(row => row.length);

        if (!cells.length) {
            diagnostics.warnings.push("table_without_cells");
            diagnostics.fallback_node_count += 1;
            return LLMR.preserveText(table.innerText || "");
        }

        const width = Math.max(...cells.map(row => row.length));
        const normalized = cells.map(row => {
            const next = [...row];
            while (next.length < width) next.push("");
            return next;
        });

        const header = normalized[0];
        const divider = header.map(() => "---");
        const body = normalized.slice(1);

        return [
            `| ${header.join(" | ")} |`,
            `| ${divider.join(" | ")} |`,
            ...body.map(row => `| ${row.join(" | ")} |`)
        ].join("\n");
    },

    shouldSkipElement(el) {
        const tag = el.tagName?.toLowerCase();
        if (tag === "script" || tag === "style" || tag === "button" || tag === "svg") return true;
        if (el.getAttribute("aria-hidden") === "true") return true;
        if (el.matches?.("[data-testid*='copy'], [aria-label*='Copy'], [role='button']")) return true;
        return false;
    },

    normalizeInline(value) {
        return String(value || "")
            .replace(/[ \t]+\n/g, "\n")
            .replace(/\n[ \t]+/g, "\n")
            .replace(/[ \t]{2,}/g, " ");
    },

    normalizeMarkdown(value) {
        return String(value || "")
            .replace(/\r\n/g, "\n")
            .replace(/\r/g, "\n")
            .replace(/[ \t]+\n/g, "\n")
            .replace(/\n{3,}/g, "\n\n")
            .trim();
    }
};