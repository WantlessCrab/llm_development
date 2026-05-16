globalThis.LLMR = globalThis.LLMR || {};

LLMR.ChatGPTAdapter = {
    provider: "chatgpt",

    detect() {
        return location.hostname === "chatgpt.com";
    },

    getSessionIdentity() {
        const parts = location.pathname.split("/").filter(Boolean);
        const c = parts.indexOf("c");
        const g = parts.indexOf("g");

        const conversation_id = c >= 0 ? parts[c + 1] || null : null;
        const gizmo_id = g >= 0 ? parts[g + 1] || null : null;

        const source_session_id = gizmo_id
            ? `chatgpt:${gizmo_id}:${conversation_id || "unknown"}`
            : `chatgpt:standard:${conversation_id || "unknown"}`;

        return {
            provider: "chatgpt",
            source_session_id,
            conversation_id,
            gizmo_id,
            conversation_url: location.href,
            conversation_title: document.title
        };
    },

    getSessionLabel() {
        const session = this.getSessionIdentity();
        const conv = LLMR.shortId(session.conversation_id || "unknown", 8, 5);
        const gizmo = session.gizmo_id ? LLMR.shortId(session.gizmo_id, 8, 5) : "standard";
        return `${gizmo} / ${conv}`;
    },

    getComposer() {
        return document.querySelector("#prompt-textarea");
    },

    getLatestAssistantRoot() {
        const roots = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));
        return roots.at(-1) || null;
    },

    getAssistantContentRoot(root) {
        if (!root) return null;
        return root.querySelector(".markdown, [class*='markdown']") || root;
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

    insertTextByExecCommand(composer, text) {
        const started = performance.now();
        const textToInsert = String(text || "");
        this.focusComposer(composer);

        try {
            const ok = document.execCommand("insertText", false, textToInsert);
            const verification = ok
                ? this.verifyInsertedText(composer, textToInsert)
                : {ok: false, reason: "execCommand_returned_false"};

            if (ok && verification.ok) {
                return {
                    ok: true,
                    method: "execCommand.insertText",
                    strategy: "native_verified",
                    elapsed_ms: Math.round(performance.now() - started),
                    text_length: textToInsert.length,
                    verification,
                    preserves_multiline_markdown: true
                };
            }

            return {
                ok: false,
                method: "execCommand.insertText",
                strategy: "native_not_verified",
                reason: ok ? "native insert did not verify visible text" : "execCommand.insertText_returned_false",
                elapsed_ms: Math.round(performance.now() - started),
                text_length: textToInsert.length,
                verification
            };
        } catch (err) {
            console.warn("[local_llm_router] execCommand insertText failed", err);
            return {
                ok: false,
                method: "execCommand.insertText",
                strategy: "native_exception",
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
        this.focusComposer(composer);

        const selection = window.getSelection();
        let range = null;

        if (selection && selection.rangeCount && composer.contains(selection.anchorNode)) {
            range = selection.getRangeAt(0);
        } else {
            range = document.createRange();
            range.selectNodeContents(composer);
            range.collapse(false);
        }

        range.deleteContents();

        const fragment = this.buildMultilineFragment(textToInsert);
        const marker = document.createTextNode("");
        fragment.appendChild(marker);
        range.insertNode(fragment);

        range.setStartAfter(marker);
        range.collapse(true);

        if (selection) {
            selection.removeAllRanges();
            selection.addRange(range);
        }

        try {
            composer.dispatchEvent(
                new InputEvent("input", {
                    bubbles: true,
                    inputType: "insertFromPaste",
                    data: textToInsert
                })
            );
        } catch (_) {
            composer.dispatchEvent(new Event("input", {bubbles: true}));
        }

        const verification = this.verifyInsertedText(composer, textToInsert);

        return {
            ok: verification.ok,
            method: "range-insert-br-fragment",
            strategy: verification.ok ? "range_verified" : "range_not_verified",
            reason: verification.ok ? undefined : "range insert did not verify visible text",
            elapsed_ms: Math.round(performance.now() - started),
            text_length: textToInsert.length,
            verification,
            preserves_multiline_markdown: "fallback_only"
        };
    },

    insertDraft(text) {
        const composer = this.getComposer();
        if (!composer) return {ok: false, reason: "composer_not_found"};

        const textToInsert = String(text || "");
        const mode = this.getInsertMode();
        const threshold = this.fastInsertThreshold();

        const shouldTryPaste =
            composer.isContentEditable &&
            mode !== "native" &&
            (mode === "paste" || mode === "fast" || textToInsert.length >= threshold);

        const beforeHtml = composer.innerHTML;

        /*
         * Preferred large-text path:
         *
         * Synthetic text/plain paste is the closest available mechanism to the
         * manually validated user-level paste path. It lets ChatGPT's editor own the
         * insertion semantics instead of forcing one giant execCommand transaction.
         */
        if (shouldTryPaste) {
            const pasted = this.insertTextBySyntheticPaste(composer, textToInsert);

            if (pasted.ok) {
                return {
                    ...pasted,
                    insert_mode: mode,
                    threshold
                };
            }

            this.restoreComposerHtml(composer, beforeHtml);

            if (mode === "paste") {
                return {
                    ...pasted,
                    ok: false,
                    insert_mode: mode,
                    threshold,
                    reason: pasted.reason || "paste mode failed"
                };
            }

            console.warn(
                "[local_llm_router] synthetic paste failed; restored composer and falling back",
                pasted
            );
        }

        /*
         * Proven correctness path:
         *
         * Keep execCommand as the default for small text and as the first fallback
         * after paste failure. This preserves the existing perfect output behavior.
         */
        if (mode !== "fast") {
            const nativeInsert = this.insertTextByExecCommand(composer, textToInsert);

            if (nativeInsert.ok) {
                return {
                    ...nativeInsert,
                    insert_mode: mode,
                    threshold,
                    strategy: shouldTryPaste ? "native_fallback_after_paste" : "native"
                };
            }

            this.restoreComposerHtml(composer, beforeHtml);
            console.warn("[local_llm_router] native insert failed; restored composer and trying range fallback", nativeInsert);
        }

        /*
         * Final emergency path:
         *
         * Range insertion is fastest but least editor-native. It remains guarded by
         * visible text verification and is only final fallback unless mode=fast.
         */
        if (composer.isContentEditable) {
            const rangeInserted = this.insertTextByRange(composer, textToInsert);

            if (rangeInserted.ok) {
                return {
                    ...rangeInserted,
                    insert_mode: mode,
                    threshold,
                    strategy: mode === "fast" ? "fast_range_verified" : "range_fallback_verified"
                };
            }

            this.restoreComposerHtml(composer, beforeHtml);

            return {
                ...rangeInserted,
                ok: false,
                insert_mode: mode,
                threshold,
                reason: rangeInserted.reason || "range insert failed verification"
            };
        }

        return {
            ok: false,
            reason: "all_methods_failed",
            insert_mode: mode,
            threshold,
            text_length: textToInsert.length
        };
    },

    insertFormatCapture(formatCapture) {
        return this.insertDraft(LLMR.FormatRenderers.toMarkdown(formatCapture));
    },

    getLatestAssistantMessage() {
        const root = this.getLatestAssistantRoot();
        if (!root) return null;

        const roots = Array.from(document.querySelectorAll('[data-message-author-role="assistant"]'));
        const turn = root.closest('section[data-testid*="conversation-turn"]');
        const contentRoot = this.getAssistantContentRoot(root);

        const formatCapture = LLMR.FormatSerializer.fromDom(contentRoot, {
            provider: "chatgpt",
            role: "assistant",
            rootSelector: ".markdown",
            includeSourceHtml: true,
            providerHints: {
                adapter_version: "chatgpt-v0.3-formatcapture",
                assistant_root_count: roots.length,
                turn_testid: turn?.getAttribute("data-testid") || null
            }
        });

        const text = LLMR.FormatRenderers.toMarkdown(formatCapture);

        if (!text) return null;

        return {
            ...this.getSessionIdentity(),
            event_type: "message.captured",
            role: "assistant",
            turn_testid: turn?.getAttribute("data-testid") || null,
            capture_source: "format_capture",
            text,
            text_hash: LLMR.hashText(text),
            text_length: text.length,
            format_capture: formatCapture,
            captured_at: new Date().toISOString(),
            metadata: {
                root_count: roots.length,
                adapter_version: "chatgpt-v0.3-formatcapture",
                preserved_formatting: true,
                format_capture_summary: LLMR.FormatCapture.diagnosticsSummary(formatCapture)
            }
        };
    },

    status({includeLatest = false} = {}) {
        const session = this.getSessionIdentity();
        const composer = this.getComposer();
        const latest = includeLatest ? this.getLatestAssistantMessage() : null;

        return {
            ok: true,
            provider: "chatgpt",
            detected: this.detect(),
            href: location.href,
            session_label: this.getSessionLabel(),
            session,
            composer: {
                found: !!composer,
                tag: composer?.tagName?.toLowerCase() || null,
                id: composer?.id || null,
                role: composer?.getAttribute("role") || null,
                contenteditable: composer?.getAttribute("contenteditable") || null
            },
            latestAssistant: latest
                ? {
                    turn_testid: latest.turn_testid,
                    text_length: latest.text_length,
                    text_hash: latest.text_hash,
                    capture_source: latest.capture_source,
                    preserved_formatting: true,
                    format_capture_summary: LLMR.FormatCapture.diagnosticsSummary(latest.format_capture)
                }
                : null
        };
    },

    detailedStatus() {
        return this.status({includeLatest: true});
    }
};