globalThis.LLMR = globalThis.LLMR || {};

LLMR.ChatGPTAdapter = {
    provider: "chatgpt",

    detect() {
        return location.hostname === "chatgpt.com";
    },

    parsePathIdentity() {
        const parts = location.pathname.split("/").filter(Boolean);
        const c = parts.indexOf("c");
        const g = parts.indexOf("g");
        return {
            conversation_id: c >= 0 ? parts[c + 1] || null : null,
            gizmo_id: g >= 0 ? parts[g + 1] || null : null
        };
    },

    cleanConversationTitle(value) {
        return String(value || "")
            .replace(/\s+/g, " ")
            .replace(/\s*[-–—|]\s*ChatGPT\s*$/i, "")
            .replace(/^ChatGPT\s*[-–—|]\s*/i, "")
            .trim();
    },

    isBadConversationTitle(value) {
        const text = this.cleanConversationTitle(value);
        return (
            !text ||
            /^chatgpt$/i.test(text) ||
            /^skip to content$/i.test(text) ||
            /^new chat$/i.test(text)
        );
    },

    projectPrefixFromGizmoId(gizmoId) {
        return String(gizmoId || "")
            .replace(/^g-p-[^-]+-/, "")
            .replace(/[-_]+/g, " ")
            .replace(/\s+/g, " ")
            .trim();
    },

    stripProjectPrefix(title, projectLabel) {
        const cleanTitle = this.cleanConversationTitle(title);
        const cleanProject = this.cleanConversationTitle(projectLabel);
        if (!cleanTitle || !cleanProject) return cleanTitle;
        const escaped = cleanProject.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        const pattern = new RegExp(`^${escaped}\\s*[-–—|:]\\s*`, "i");
        const stripped = cleanTitle.replace(pattern, "").trim();
        return stripped && stripped !== cleanTitle ? stripped : cleanTitle;
    },

    inferSidebarConversationTitle(conversationId) {
        if (!conversationId) return null;

        return Array.from(document.querySelectorAll("a[href]"))
            .map(a => ({
                text: this.cleanConversationTitle(a.innerText || a.textContent || ""),
                href: a.href || "",
                aria: this.cleanConversationTitle(a.getAttribute("aria-label")),
                title: this.cleanConversationTitle(a.getAttribute("title"))
            }))
            .filter(item => item.href.includes(`/c/${conversationId}`) || item.href.includes(conversationId))
            .filter(item => !item.href.includes("#main"))
            .map(item => item.text || item.title || item.aria)
            .find(value => !this.isBadConversationTitle(value)) || null;
    },

    inferConversationTitle() {
        const {conversation_id, gizmo_id} = this.parsePathIdentity();
        const project = this.projectPrefixFromGizmoId(gizmo_id);
        const sidebar = this.inferSidebarConversationTitle(conversation_id);
        if (sidebar) return {label: sidebar, source: "chatgpt_sidebar"};

        const stripped = this.stripProjectPrefix(document.title, project);
        if (!this.isBadConversationTitle(stripped)) {
            return {
                label: stripped,
                source: stripped !== this.cleanConversationTitle(document.title) ? "document_title_project_stripped" : "document_title"
            };
        }

        const full = this.cleanConversationTitle(document.title);
        if (!this.isBadConversationTitle(full)) return {label: full, source: "document_title"};

        return {label: null, source: null};
    },

    getSessionIdentity() {
        const {conversation_id, gizmo_id} = this.parsePathIdentity();

        const source_session_id = gizmo_id
            ? `chatgpt:${gizmo_id}:${conversation_id || "unknown"}`
            : `chatgpt:standard:${conversation_id || "unknown"}`;

        const inferred = this.inferConversationTitle();
        const fallbackLabel = this.getFallbackSessionLabel(source_session_id, conversation_id, gizmo_id);

        return {
            provider: "chatgpt",
            source_session_id,
            conversation_id,
            gizmo_id,
            conversation_url: location.href,
            conversation_title: document.title,
            inferred_label: inferred.label || fallbackLabel,
            inferred_label_source: inferred.source || "fallback",
            fallback_label: fallbackLabel
        };
    },

    getFallbackSessionLabel(sourceSessionId = null, conversationId = null, gizmoId = null) {
        const conv = LLMR.shortId(conversationId || "unknown", 8, 5);
        const gizmo = gizmoId ? LLMR.shortId(gizmoId, 8, 5) : "standard";
        return `${gizmo} / ${conv}`;
    },

    getSessionLabel() {
        const session = this.getSessionIdentity();
        return session.inferred_label || session.fallback_label || this.getFallbackSessionLabel(session.source_session_id, session.conversation_id, session.gizmo_id);
    },

    getComposer() {
        return document.querySelector("#prompt-textarea");
    },

    getMessageRoots(role) {
        const safeRole = role === "user" ? "user" : "assistant";
        return Array.from(document.querySelectorAll(`[data-message-author-role="${safeRole}"]`));
    },

    getLatestMessageRoot(role = "assistant") {
        return this.getMessageRoots(role).at(-1) || null;
    },

    getLatestAssistantRoot() {
        return this.getLatestMessageRoot("assistant");
    },

    getLatestUserRoot() {
        return this.getLatestMessageRoot("user");
    },

    getMessageContentRoot(root, role = "assistant") {
        if (!root) return null;

        if (role === "assistant") {
            return root.querySelector(".markdown, [class*='markdown']") || root;
        }

        return root.querySelector(
            ".markdown, [class*='markdown'], .whitespace-pre-wrap, [class*='whitespace-pre-wrap']"
        ) || root;
    },

    getAssistantContentRoot(root) {
        return this.getMessageContentRoot(root, "assistant");
    },

    getUserContentRoot(root) {
        return this.getMessageContentRoot(root, "user");
    },

    focusComposer(composer) {
        try {
            composer.focus();
            return true;
        } catch (err) {
            console.warn("[local_llm_router] composer focus failed", err);
            return false;
        }
    },

    getInsertMode() {
        try {
            return localStorage.getItem("llmr.insert.mode") || "hybrid";
        } catch (_) {
            return "hybrid";
        }
    },

    fastInsertThreshold() {
        try {
            const raw = Number(localStorage.getItem("llmr.insert.fast.threshold") || "4000");
            return Number.isFinite(raw) && raw >= 0 ? raw : 4000;
        } catch (_) {
            return 4000;
        }
    },

    normalizeForInsertionCheck(value) {
        return String(value || "")
            .replace(/\r\n/g, "\n")
            .replace(/\r/g, "\n")
            .replace(/\u00a0/g, " ")
            .replace(/[ \t]+\n/g, "\n")
            .replace(/\n{3,}/g, "\n\n")
            .trim();
    },

    composerVisibleText(composer) {
        return composer?.innerText || composer?.textContent || "";
    },

    verifyInsertedText(composer, expectedText) {
        const expected = this.normalizeForInsertionCheck(expectedText);
        const actual = this.normalizeForInsertionCheck(this.composerVisibleText(composer));

        if (!expected) {
            return {
                ok: true,
                reason: "empty_expected_text",
                expected_length: 0,
                actual_length: actual.length
            };
        }

        const sampleSize = Math.min(700, expected.length);
        const head = expected.slice(0, sampleSize);
        const tail = expected.slice(-sampleSize);

        const headOk = actual.includes(head);
        const tailOk = actual.includes(tail);

        return {
            ok: headOk && tailOk,
            head_ok: headOk,
            tail_ok: tailOk,
            expected_length: expected.length,
            actual_length: actual.length
        };
    },

    restoreComposerHtml(composer, html) {
        composer.innerHTML = html;

        try {
            composer.dispatchEvent(
                new InputEvent("input", {
                    bubbles: true,
                    inputType: "historyUndo",
                    data: null
                })
            );
        } catch (_) {
            composer.dispatchEvent(new Event("input", {bubbles: true}));
        }
    },

    insertTextBySyntheticPaste(composer, text) {
        const started = performance.now();
        const textToInsert = String(text || "");
        this.focusComposer(composer);

        let event = null;

        try {
            const dataTransfer = new DataTransfer();
            dataTransfer.setData("text/plain", textToInsert);

            /*
             * Use text/plain only.
             *
             * This intentionally preserves Markdown/code fences as literal prompt text.
             * Supplying text/html can cause rich rendering paths to consume the paste and
             * change the exact LLM-facing text.
             */
            event = new ClipboardEvent("paste", {
                bubbles: true,
                cancelable: true,
                clipboardData: dataTransfer
            });
        } catch (err) {
            return {
                ok: false,
                method: "synthetic-paste",
                strategy: "paste_event_unavailable",
                reason: `clipboard_event_create_failed: ${err}`,
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length
            };
        }

        const beforeText = this.composerVisibleText(composer);
        const dispatchResult = composer.dispatchEvent(event);
        const verification = this.verifyInsertedText(composer, textToInsert);
        const afterText = this.composerVisibleText(composer);

        /*
         * For editor paste handlers, dispatchResult=false usually means the editor
         * consumed and handled the paste with preventDefault().
         *
         * Some editors may still handle without making dispatchResult meaningful, so
         * the actual authority is visible text verification.
         */
        if (verification.ok && afterText !== beforeText) {
            return {
                ok: true,
                method: "synthetic-clipboard-paste",
                strategy: "paste_event_verified",
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length,
                dispatch_result: dispatchResult,
                verification,
                preserves_multiline_markdown: true
            };
        }

        return {
            ok: false,
            method: "synthetic-clipboard-paste",
            strategy: "paste_event_not_accepted",
            reason: "paste event did not produce verified composer text",
            elapsed_ms: Math.round(performance.now() - started),
            text_length: textToInsert.length,
            dispatch_result: dispatchResult,
            verification
        };
    },

    composerContainsNode(composer, node) {
        if (!composer || !node) return false;
        return node === composer || composer.contains(node);
    },

    setSelectionRange(range) {
        const selection = window.getSelection();
        if (!selection || !range) return false;
        selection.removeAllRanges();
        selection.addRange(range);
        return true;
    },

    insertionRangePreservingExisting(composer) {
        const selection = window.getSelection();

        if (selection && selection.rangeCount) {
            const anchorInComposer = this.composerContainsNode(composer, selection.anchorNode);
            const focusInComposer = this.composerContainsNode(composer, selection.focusNode);

            if (anchorInComposer && focusInComposer) {
                const range = selection.getRangeAt(0).cloneRange();
                /*
                 * Preserve existing composer content. Even when text is selected,
                 * route insertion should behave as an append-at-caret operation,
                 * not as replacement. Collapse to the end of the current selection
                 * instead of deleting selected contents.
                 */
                range.collapse(false);
                return range;
            }
        }

        const range = document.createRange();
        range.selectNodeContents(composer);
        range.collapse(false);
        return range;
    },

    dispatchComposerInput(composer, text, inputType = "insertText") {
        try {
            composer.dispatchEvent(
                new InputEvent("beforeinput", {
                    bubbles: true,
                    cancelable: true,
                    inputType,
                    data: text
                })
            );
        } catch (_) {
            /* beforeinput is advisory for this integration path. */
        }

        try {
            composer.dispatchEvent(
                new InputEvent("input", {
                    bubbles: true,
                    inputType,
                    data: text
                })
            );
        } catch (_) {
            composer.dispatchEvent(new Event("input", {bubbles: true}));
        }
    },

    verifyInsertedTextDelta(composer, expectedText, beforeText = "") {
        const expected = this.normalizeForInsertionCheck(expectedText);
        const before = this.normalizeForInsertionCheck(beforeText);
        const after = this.normalizeForInsertionCheck(this.composerVisibleText(composer));

        if (!expected) {
            return {
                ok: true,
                reason: "empty_expected_text",
                expected_length: 0,
                before_length: before.length,
                actual_length: after.length,
                grew_or_changed: after !== before
            };
        }

        const sampleSize = Math.min(700, expected.length);
        const head = expected.slice(0, sampleSize);
        const tail = expected.slice(-sampleSize);
        const headOk = after.includes(head);
        const tailOk = after.includes(tail);
        const changed = after !== before;

        return {
            ok: changed && headOk && tailOk,
            head_ok: headOk,
            tail_ok: tailOk,
            changed,
            before_length: before.length,
            expected_length: expected.length,
            actual_length: after.length
        };
    },

    insertTextByExecCommand(composer, text) {
        const started = performance.now();
        const textToInsert = String(text || "");
        const beforeText = this.composerVisibleText(composer);

        try {
            const range = this.insertionRangePreservingExisting(composer);
            this.focusComposer(composer);
            this.setSelectionRange(range);

            const ok = document.execCommand("insertText", false, textToInsert);
            const verification = ok
                ? this.verifyInsertedTextDelta(composer, textToInsert, beforeText)
                : {ok: false, reason: "execCommand_returned_false"};

            if (ok && verification.ok) {
                return {
                    ok: true,
                    method: "execCommand.insertText",
                    strategy: "cursor_text_native_verified",
                    elapsed_ms: Math.round(performance.now() - started),
                    text_length: textToInsert.length,
                    verification,
                    preserves_existing_composer_text: true,
                    avoids_paste_attachment: true,
                    preserves_multiline_markdown: true
                };
            }

            return {
                ok: false,
                method: "execCommand.insertText",
                strategy: "cursor_text_native_not_verified",
                reason: ok ? "native insert did not verify visible text delta" : "execCommand.insertText_returned_false",
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length,
                verification
            };
        } catch (err) {
            console.warn("[local_llm_router] execCommand insertText failed", err);
            return {
                ok: false,
                method: "execCommand.insertText",
                strategy: "cursor_text_native_exception",
                reason: `execCommand.insertText_failed: ${err}`,
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length
            };
        }
    },

    buildMultilineFragment(text) {
        const fragment = document.createDocumentFragment();
        const lines = String(text || "")
            .replace(/\r\n/g, "\n")
            .replace(/\r/g, "\n")
            .split("\n");

        lines.forEach((line, index) => {
            if (index > 0) fragment.appendChild(document.createElement("br"));
            if (line.length) fragment.appendChild(document.createTextNode(line));
        });

        return fragment;
    },

    insertTextByRange(composer, text) {
        const started = performance.now();
        const textToInsert = String(text || "");
        const beforeText = this.composerVisibleText(composer);

        try {
            const range = this.insertionRangePreservingExisting(composer);
            this.focusComposer(composer);
            this.setSelectionRange(range);

            const fragment = this.buildMultilineFragment(textToInsert);
            const marker = document.createTextNode("");
            fragment.appendChild(marker);
            range.insertNode(fragment);

            range.setStartAfter(marker);
            range.collapse(true);
            this.setSelectionRange(range);

            this.dispatchComposerInput(composer, textToInsert, "insertText");
            const verification = this.verifyInsertedTextDelta(composer, textToInsert, beforeText);

            return {
                ok: verification.ok,
                method: "range-insert-br-fragment",
                strategy: verification.ok ? "cursor_text_range_verified" : "cursor_text_range_not_verified",
                reason: verification.ok ? undefined : "range insert did not verify visible text delta",
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length,
                verification,
                preserves_existing_composer_text: true,
                avoids_paste_attachment: true,
                preserves_multiline_markdown: "fallback_only"
            };
        } catch (err) {
            return {
                ok: false,
                method: "range-insert-br-fragment",
                strategy: "cursor_text_range_exception",
                reason: `range insert failed: ${err}`,
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length
            };
        }
    },

    insertDraft(text) {
        const composer = this.getComposer();
        if (!composer) return {ok: false, reason: "composer_not_found"};

        const textToInsert = String(text || "");
        const mode = this.getInsertMode();
        const threshold = this.fastInsertThreshold();
        const beforeHtml = composer.innerHTML;

        /*
         * Router-owned insertion must not dispatch a ClipboardEvent paste.
         * ChatGPT can interpret synthetic paste as a pasted-text attachment while
         * still inserting text into the composer. Route insertion is therefore a
         * deterministic text insertion path: use the active caret if it is inside
         * the composer, otherwise append to the composer end. Existing composer
         * content is preserved; selected text is not deleted.
         */
        const nativeInsert = this.insertTextByExecCommand(composer, textToInsert);
        if (nativeInsert.ok) {
            return {
                ...nativeInsert,
                insert_mode: "cursor_text",
                requested_insert_mode: mode,
                threshold,
                strategy: "cursor_text_native"
            };
        }

        this.restoreComposerHtml(composer, beforeHtml);
        console.warn("[local_llm_router] cursor native insert failed; restored composer and trying range fallback", nativeInsert);

        if (composer.isContentEditable) {
            const rangeInserted = this.insertTextByRange(composer, textToInsert);

            if (rangeInserted.ok) {
                return {
                    ...rangeInserted,
                    insert_mode: "cursor_text",
                    requested_insert_mode: mode,
                    threshold,
                    strategy: "cursor_text_range_fallback"
                };
            }

            this.restoreComposerHtml(composer, beforeHtml);
            return {
                ...rangeInserted,
                ok: false,
                insert_mode: "cursor_text",
                requested_insert_mode: mode,
                threshold,
                reason: rangeInserted.reason || "range insert failed verification"
            };
        }

        return {
            ok: false,
            reason: nativeInsert.reason || "all_methods_failed",
            insert_mode: "cursor_text",
            requested_insert_mode: mode,
            threshold,
            text_length: textToInsert.length,
            native_insert: nativeInsert
        };
    },

    insertFormatCapture(formatCapture) {
        return this.insertDraft(LLMR.FormatRenderers.toMarkdown(formatCapture));
    },

    getLatestMessage(role = "assistant") {
        const safeRole = role === "user" ? "user" : "assistant";
        const root = this.getLatestMessageRoot(safeRole);
        if (!root) return null;

        const roots = this.getMessageRoots(safeRole);
        const turn = root.closest('section[data-testid*="conversation-turn"]');
        const contentRoot = this.getMessageContentRoot(root, safeRole);
        const rootSelector = safeRole === "assistant"
            ? ".markdown"
            : ".markdown, .whitespace-pre-wrap";

        const formatCapture = LLMR.FormatSerializer.fromDom(contentRoot, {
            provider: "chatgpt",
            role: safeRole,
            rootSelector,
            includeSourceHtml: true,
            providerHints: {
                adapter_version: "chatgpt-v0.4-role-capture",
                message_role: safeRole,
                role_root_count: roots.length,
                assistant_root_count: safeRole === "assistant" ? roots.length : this.getMessageRoots("assistant").length,
                user_root_count: safeRole === "user" ? roots.length : this.getMessageRoots("user").length,
                turn_testid: turn?.getAttribute("data-testid") || null
            }
        });

        const text = LLMR.FormatRenderers.toMarkdown(formatCapture);

        if (!text) return null;

        return {
            ...this.getSessionIdentity(),
            event_type: "message.captured",
            role: safeRole,
            turn_testid: turn?.getAttribute("data-testid") || null,
            capture_source: "format_capture",
            text,
            text_hash: LLMR.hashText(text),
            text_length: text.length,
            format_capture: formatCapture,
            captured_at: new Date().toISOString(),
            metadata: {
                root_count: roots.length,
                adapter_version: "chatgpt-v0.4-role-capture",
                message_role: safeRole,
                preserved_formatting: true,
                format_capture_summary: LLMR.FormatCapture.diagnosticsSummary(formatCapture)
            }
        };
    },

    getLatestAssistantMessage() {
        return this.getLatestMessage("assistant");
    },

    getLatestUserMessage() {
        return this.getLatestMessage("user");
    },

    summarizeCapturedMessage(message) {
        return message
            ? {
                role: message.role,
                turn_testid: message.turn_testid,
                text_length: message.text_length,
                text_hash: message.text_hash,
                capture_source: message.capture_source,
                preserved_formatting: true,
                format_capture_summary: LLMR.FormatCapture.diagnosticsSummary(message.format_capture)
            }
            : null;
    },

    status({includeLatest = false} = {}) {
        const session = this.getSessionIdentity();
        const composer = this.getComposer();
        const latestAssistant = includeLatest ? this.getLatestAssistantMessage() : null;
        const latestUser = includeLatest ? this.getLatestUserMessage() : null;

        return {
            ok: true,
            provider: "chatgpt",
            detected: this.detect(),
            href: location.href,
            session_label: this.getSessionLabel(),
            inferred_label: session.inferred_label || null,
            inferred_label_source: session.inferred_label_source || null,
            session,
            composer: {
                found: !!composer,
                tag: composer?.tagName?.toLowerCase() || null,
                id: composer?.id || null,
                role: composer?.getAttribute("role") || null,
                contenteditable: composer?.getAttribute("contenteditable") || null
            },
            latestAssistant: this.summarizeCapturedMessage(latestAssistant),
            latestUser: this.summarizeCapturedMessage(latestUser)
        };
    },

    detailedStatus() {
        return this.status({includeLatest: true});
    }
};