chrome.runtime.onInstalled.addListener(() => {
    console.debug("[local_llm_router] extension installed or updated");
    refreshAllEligibleTabs("onInstalled").then(result => console.debug("[local_llm_router] refresh onInstalled", result));
});

chrome.runtime.onStartup.addListener(() => {
    console.debug("[local_llm_router] browser startup");
    refreshAllEligibleTabs("onStartup").then(result => console.debug("[local_llm_router] refresh onStartup", result));
});

const LLMR_CONTENT_SCRIPT_FILES = [
    "content/format_capture.js",
    "content/format_renderers.js",
    "content/format_serializer.js",
    "content/adapter_base.js",
    "content/chatgpt.js",
    "content/overlay.js"
];

const LLMR_API_BASE = "http://127.0.0.1:8015";

async function daemonApi(path, options = {}) {
    const response = await fetch(`${LLMR_API_BASE}${path}`, {
        ...options,
        headers: {"Content-Type": "application/json", ...(options.headers || {})}
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`daemon request failed: ${response.status} ${JSON.stringify(body)}`);
    return body;
}

async function applyPromptWrapperIfRequested(text, options = {}) {
    const wrapperId = options?.prompt_wrapper_id || null;
    if (!wrapperId) return {text: String(text || ""), metadata: {enabled: false}};
    const response = await daemonApi("/api/v1/prompt-wrappers/apply", {
        method: "POST",
        body: JSON.stringify({wrapper_id: wrapperId, text: String(text || "")})
    });
    return {text: response.text || "", metadata: response.metadata || {enabled: true, wrapper_id: wrapperId}};
}

function draftTextForWrapper(draft) {
    return draft?.wrapped_body_markdown || draft?.wrapped_body || draft?.body_markdown || draft?.body_plain || "";
}

function draftWithWrappedText(draft, wrappedText, promptWrapper) {
    return {
        ...(draft || {}),
        wrapped_body: wrappedText,
        wrapped_body_markdown: wrappedText,
        wrapped_body_plain: wrappedText,
        wrapped_body_html: null,
        wrapped_format_capture: null,
        metadata: {
            ...((draft && draft.metadata) || {}),
            prompt_wrapper: promptWrapper
        }
    };
}

function payloadWithWrappedText(payload, wrappedText, promptWrapper) {
    return {
        ...(payload || {}),
        text: wrappedText,
        format_capture: null,
        metadata: {
            ...((payload && payload.metadata) || {}),
            prompt_wrapper: promptWrapper
        }
    };
}

function chromeTabsQuery(queryInfo) {
    return new Promise(resolve => chrome.tabs.query(queryInfo, tabs => resolve(tabs || [])));
}

function chromeScriptingExecuteScript(tabId, files) {
    return new Promise(resolve => {
        chrome.scripting.executeScript({target: {tabId}, files}, () => {
            if (chrome.runtime.lastError) {
                resolve({ok: false, error: chrome.runtime.lastError.message});
                return;
            }
            resolve({ok: true});
        });
    });
}

function chromeTabsSendMessage(tabId, message) {
    return new Promise(resolve => {
        chrome.tabs.sendMessage(tabId, message, response => {
            if (chrome.runtime.lastError) {
                resolve({ok: false, error: chrome.runtime.lastError.message});
                return;
            }
            resolve(response || {ok: false, error: "content script returned no response"});
        });
    });
}

function chromeTabsUpdate(tabId, updateProperties) {
    return new Promise(resolve => {
        chrome.tabs.update(tabId, updateProperties, tab => {
            if (chrome.runtime.lastError) {
                resolve({ok: false, error: chrome.runtime.lastError.message});
                return;
            }
            resolve({ok: true, tab});
        });
    });
}

function chromeWindowsUpdate(windowId, updateInfo) {
    return new Promise(resolve => {
        if (!windowId) {
            resolve({ok: false, error: "missing windowId"});
            return;
        }
        chrome.windows.update(windowId, updateInfo, win => {
            if (chrome.runtime.lastError) {
                resolve({ok: false, error: chrome.runtime.lastError.message});
                return;
            }
            resolve({ok: true, window: win});
        });
    });
}

async function focusTabForInsertion(tab) {
    if (!tab?.id) return {ok: false, error: "missing target tab"};
    const windowResult = await chromeWindowsUpdate(tab.windowId, {focused: true});
    const tabResult = await chromeTabsUpdate(tab.id, {active: true});
    return {ok: Boolean(tabResult.ok), window: windowResult, tab: tabResult};
}

function isEligibleChatGptTab(tab) {
    return Boolean(tab?.id && typeof tab.url === "string" && tab.url.startsWith("https://chatgpt.com/"));
}

async function ensureContentScripts(tab) {
    if (!isEligibleChatGptTab(tab)) {
        return {ok: false, skipped: true, reason: "not eligible", tab: tabSummary(tab)};
    }
    return chromeScriptingExecuteScript(tab.id, LLMR_CONTENT_SCRIPT_FILES);
}

function tabSummary(tab) {
    return {
        id: tab?.id ?? null,
        window_id: tab?.windowId ?? null,
        active: Boolean(tab?.active),
        highlighted: Boolean(tab?.highlighted),
        url: tab?.url ?? null,
        title: tab?.title ?? null
    };
}

async function refreshTabOverlay(tab, reason = "manual") {
    const injected = await ensureContentScripts(tab);
    if (!injected.ok) {
        return {ok: false, stage: "inject", error: injected.error, tab: tabSummary(tab)};
    }

    const refreshed = await chromeTabsSendMessage(tab.id, {
        type: "LLMR_REFRESH_OVERLAY_STATE",
        reason
    });

    return {
        ok: Boolean(refreshed?.ok),
        stage: "refresh",
        response: refreshed,
        tab: tabSummary(tab)
    };
}

async function refreshAllEligibleTabs(reason = "manual") {
    const tabs = await chromeTabsQuery({url: "https://chatgpt.com/*"});
    const results = [];
    for (const tab of tabs) results.push(await refreshTabOverlay(tab, reason));
    const refreshed = results.filter(item => item.ok).length;
    const failed = results.filter(item => !item.ok && !item.skipped).length;
    return {ok: failed === 0, reason, matched_tabs: tabs.length, refreshed, failed, results};
}

async function sendToActiveTabAsync(message) {
    const tabs = await chromeTabsQuery({active: true, currentWindow: true});
    const tab = tabs && tabs[0];
    if (!tab?.id) return {ok: false, error: "no active tab"};
    return chromeTabsSendMessage(tab.id, message);
}

function sendToActiveTab(message, sendResponse) {
    sendToActiveTabAsync(message).then(sendResponse);
}

async function listLiveChatGptSessions() {
    const tabs = await chromeTabsQuery({url: "https://chatgpt.com/*"});
    const sessions = [];

    for (const tab of tabs.filter(isEligibleChatGptTab)) {
        const injected = await ensureContentScripts(tab);
        if (!injected.ok) {
            sessions.push({ok: false, tab: tabSummary(tab), error: injected.error});
            continue;
        }

        const status = await chromeTabsSendMessage(tab.id, {type: "LLMR_STATUS"});
        sessions.push({
            ok: Boolean(status?.ok),
            tab: tabSummary(tab),
            session: status?.session || null,
            queue_group: status?.queue_group || null,
            session_label: status?.session_label || status?.inferred_label || tab.title || null,
            inferred_label: status?.inferred_label || status?.session?.inferred_label || null,
            inferred_label_source: status?.inferred_label_source || status?.session?.inferred_label_source || null,
            disconnected: Boolean(status?.disconnected),
            composer_found: Boolean(status?.composer?.found),
            error: status?.ok === false ? status.error || "status failed" : null
        });
    }

    return {ok: true, sessions};
}

async function routeToChatGptTab(request) {
    const targetTabId = Number(request.target_tab_id);
    if (!Number.isFinite(targetTabId) || targetTabId <= 0) {
        return {ok: false, error: "target_tab_id is required"};
    }

    const tabs = await chromeTabsQuery({active: true, currentWindow: true});
    const sourceTab = tabs && tabs[0];
    if (!sourceTab?.id) return {ok: false, error: "no active source tab"};

    const targetTab = (await chromeTabsQuery({})).find(tab => tab.id === targetTabId);
    if (!targetTab) return {ok: false, error: "target tab not found"};

    const targetInjected = await ensureContentScripts(targetTab);
    if (!targetInjected.ok) return {ok: false, error: `target tab unavailable: ${targetInjected.error}`};

    const options = request.options || {};

    if (request.draft) {
        let draft = request.draft;
        let promptWrapper = {enabled: false};
        try {
            const wrapped = await applyPromptWrapperIfRequested(draftTextForWrapper(draft), options);
            promptWrapper = wrapped.metadata;
            if (promptWrapper?.enabled) draft = draftWithWrappedText(draft, wrapped.text, promptWrapper);
        } catch (err) {
            return {ok: false, error: `prompt wrapper failed: ${err}`, target_tab: tabSummary(targetTab)};
        }

        const focused = await focusTabForInsertion(targetTab);
        if (!focused.ok) return {
            ok: false,
            error: `target tab focus failed: ${focused.error || focused.tab?.error || "unknown"}`,
            target_tab: tabSummary(targetTab),
            focus: focused
        };
        const inserted = await chromeTabsSendMessage(targetTabId, {
            type: "LLMR_INSERT_SELECTED",
            draft,
            allow_same_session: Boolean(request.allow_same_session),
            options: {...options, prompt_wrapper: promptWrapper}
        });
        return {
            ok: Boolean(inserted?.ok),
            mode: "draft_to_target_tab",
            target_tab: tabSummary(targetTab),
            focus: focused,
            prompt_wrapper: promptWrapper,
            response: inserted
        };
    }

    const sourceKind = request.source_kind || "latest_user";
    const exported = await chromeTabsSendMessage(sourceTab.id, {
        type: "LLMR_EXPORT_ROUTE_SOURCE",
        source_kind: sourceKind
    });
    if (!exported?.ok || !exported.payload) {
        return {
            ok: false,
            error: exported?.error || "source export failed",
            source_tab: tabSummary(sourceTab),
            response: exported
        };
    }

    let payload = exported.payload;
    let promptWrapper = {enabled: false};
    try {
        const sourceText = payload?.format_capture?.canonical_markdown || payload?.text || "";
        const wrapped = await applyPromptWrapperIfRequested(sourceText, options);
        promptWrapper = wrapped.metadata;
        if (promptWrapper?.enabled) payload = payloadWithWrappedText(payload, wrapped.text, promptWrapper);
    } catch (err) {
        return {
            ok: false,
            error: `prompt wrapper failed: ${err}`,
            source_tab: tabSummary(sourceTab),
            target_tab: tabSummary(targetTab)
        };
    }

    const focused = await focusTabForInsertion(targetTab);
    if (!focused.ok) return {
        ok: false,
        error: `target tab focus failed: ${focused.error || focused.tab?.error || "unknown"}`,
        target_tab: tabSummary(targetTab),
        focus: focused
    };

    const inserted = await chromeTabsSendMessage(targetTabId, {
        type: "LLMR_INSERT_CAPTURE_PAYLOAD",
        payload,
        options: {...options, prompt_wrapper: promptWrapper}
    });

    return {
        ok: Boolean(inserted?.ok),
        mode: "latest_source_to_target_tab",
        source_kind: sourceKind,
        source_tab: tabSummary(sourceTab),
        target_tab: tabSummary(targetTab),
        focus: focused,
        source_session: exported.session || null,
        prompt_wrapper: promptWrapper,
        response: inserted
    };
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request?.type === "LLMR_REFRESH_ALL_OVERLAYS") {
        refreshAllEligibleTabs(request.reason || "popup").then(sendResponse);
        return true;
    }

    if (request?.type === "LLMR_REFRESH_ACTIVE_OVERLAY") {
        (async () => {
            const tabs = await chromeTabsQuery({active: true, currentWindow: true});
            const tab = tabs && tabs[0];
            if (!tab?.id) return {ok: false, error: "no active tab"};
            return refreshTabOverlay(tab, request.reason || "popup-active");
        })().then(sendResponse);
        return true;
    }

    if (request?.type === "LLMR_LIST_LIVE_CHATGPT_SESSIONS") {
        listLiveChatGptSessions().then(sendResponse);
        return true;
    }

    if (request?.type === "LLMR_ROUTE_TO_CHATGPT_TAB") {
        routeToChatGptTab(request).then(sendResponse);
        return true;
    }

    if (request?.type === "LLMR_SEND_TO_TAB") {
        chromeTabsSendMessage(Number(request.tab_id), request.message || {}).then(sendResponse);
        return true;
    }

    const passthrough = {
        LLMR_CAPTURE_ACTIVE_TAB: {type: "LLMR_CAPTURE_LATEST", role: request?.role || "assistant"},
        LLMR_CAPTURE_ASSISTANT_ACTIVE_TAB: {type: "LLMR_CAPTURE_LATEST", role: "assistant"},
        LLMR_CAPTURE_USER_ACTIVE_TAB: {type: "LLMR_CAPTURE_LATEST", role: "user"},
        LLMR_INSERT_NEXT_ACTIVE_TAB: {type: "LLMR_INSERT_NEXT", source_mode: request?.source_mode},
        LLMR_QUEUE_ACTIVE_TAB: {type: "LLMR_QUEUE_STATUS", source_mode: request?.source_mode},
        LLMR_DISCONNECT_ACTIVE_SESSION: {type: "LLMR_DISCONNECT_SESSION"},
        LLMR_RECONNECT_ACTIVE_SESSION: {type: "LLMR_RECONNECT_SESSION"},
        LLMR_STATUS_ACTIVE_TAB: {type: "LLMR_STATUS"},
        LLMR_RESET_OVERLAY_ACTIVE_TAB: {type: "LLMR_RESET_OVERLAY"},
        LLMR_CLEAR_QUEUE_ACTIVE_TAB: {type: "LLMR_CLEAR_QUEUE"},
        LLMR_QUEUE_GROUP_STATUS_ACTIVE_TAB: {type: "LLMR_QUEUE_GROUP_STATUS"}
    };

    if (request?.type === "LLMR_INSERT_SELECTED_ACTIVE_TAB") {
        sendToActiveTab({
            type: "LLMR_INSERT_SELECTED",
            draft: request.draft,
            options: request.options || {}
        }, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_CANCEL_DRAFT_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_CANCEL_DRAFT", delivery_id: request.delivery_id}, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_ROUTE_ACTION_ACTIVE_TAB") {
        sendToActiveTab({
            type: "LLMR_ROUTE_ACTION",
            source_kind: request.source_kind,
            target_kind: request.target_kind,
            queue_source_mode: request.queue_source_mode,
            options: request.options || {}
        }, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_DISPATCH_DRAFT_ACTIVE_TAB") {
        sendToActiveTab({
            type: "LLMR_DISPATCH_DRAFT",
            delivery_id: request.delivery_id,
            provider_id: request.provider_id,
            queue_group_id: request.queue_group_id,
            manual_confirmed: Boolean(request.manual_confirmed),
            options: request.options || {}
        }, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_SET_QUEUE_GROUP_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_SET_QUEUE_GROUP", queue_group_id: request.queue_group_id}, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_CREATE_QUEUE_GROUP_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_CREATE_QUEUE_GROUP", name: request.name}, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_DELETE_QUEUE_GROUP_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_DELETE_QUEUE_GROUP", queue_group_id: request.queue_group_id}, sendResponse);
        return true;
    }

    if (passthrough[request?.type]) {
        sendToActiveTab(passthrough[request.type], sendResponse);
        return true;
    }

    return false;
});