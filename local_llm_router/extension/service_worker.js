chrome.runtime.onInstalled.addListener(() => {
    console.log("[local_llm_router] extension installed or updated");
    refreshAllEligibleTabs("onInstalled").then((result) => {
        console.log("[local_llm_router] refresh onInstalled", result);
    });
});

chrome.runtime.onStartup.addListener(() => {
    console.log("[local_llm_router] browser startup");
    refreshAllEligibleTabs("onStartup").then((result) => {
        console.log("[local_llm_router] refresh onStartup", result);
    });
});

const LLMR_CONTENT_SCRIPT_FILES = [
    "content/format_capture.js",
    "content/format_renderers.js",
    "content/format_serializer.js",
    "content/adapter_base.js",
    "content/chatgpt.js",
    "content/overlay.js"
];

function chromeTabsQuery(queryInfo) {
    return new Promise((resolve) => {
        chrome.tabs.query(queryInfo, (tabs) => resolve(tabs || []));
    });
}

function chromeScriptingExecuteScript(tabId, files) {
    return new Promise((resolve) => {
        chrome.scripting.executeScript(
            {
                target: {tabId},
                files
            },
            () => {
                if (chrome.runtime.lastError) {
                    resolve({
                        ok: false,
                        error: chrome.runtime.lastError.message
                    });
                    return;
                }

                resolve({ok: true});
            }
        );
    });
}

function chromeTabsSendMessage(tabId, message) {
    return new Promise((resolve) => {
        chrome.tabs.sendMessage(tabId, message, (response) => {
            if (chrome.runtime.lastError) {
                resolve({
                    ok: false,
                    error: chrome.runtime.lastError.message
                });
                return;
            }

            resolve(response || {ok: false, error: "content script returned no response"});
        });
    });
}

function isEligibleChatGptTab(tab) {
    return Boolean(tab?.id && typeof tab.url === "string" && tab.url.startsWith("https://chatgpt.com/"));
}

async function refreshTabOverlay(tab, reason = "manual") {
    if (!isEligibleChatGptTab(tab)) {
        return {
            ok: false,
            skipped: true,
            reason: "not eligible",
            tab: {
                id: tab?.id ?? null,
                url: tab?.url ?? null,
                title: tab?.title ?? null
            }
        };
    }

    const injected = await chromeScriptingExecuteScript(tab.id, LLMR_CONTENT_SCRIPT_FILES);
    if (!injected.ok) {
        return {
            ok: false,
            stage: "inject",
            error: injected.error,
            tab: {
                id: tab.id,
                url: tab.url,
                title: tab.title
            }
        };
    }

    const refreshed = await chromeTabsSendMessage(tab.id, {
        type: "LLMR_REFRESH_OVERLAY_STATE",
        reason
    });

    return {
        ok: Boolean(refreshed?.ok),
        stage: "refresh",
        response: refreshed,
        tab: {
            id: tab.id,
            url: tab.url,
            title: tab.title
        }
    };
}

async function refreshAllEligibleTabs(reason = "manual") {
    const tabs = await chromeTabsQuery({url: "https://chatgpt.com/*"});
    const results = [];

    for (const tab of tabs) {
        results.push(await refreshTabOverlay(tab, reason));
    }

    const refreshed = results.filter((item) => item.ok).length;
    const failed = results.filter((item) => !item.ok && !item.skipped).length;

    return {
        ok: failed === 0,
        reason,
        matched_tabs: tabs.length,
        refreshed,
        failed,
        results
    };
}

function sendToActiveTab(message, sendResponse) {
    chrome.tabs.query({active: true, currentWindow: true}, (tabs) => {
        const tab = tabs && tabs[0];

        if (!tab?.id) {
            sendResponse({ok: false, error: "no active tab"});
            return;
        }

        chrome.tabs.sendMessage(tab.id, message, (response) => {
            if (chrome.runtime.lastError) {
                sendResponse({
                    ok: false,
                    error: chrome.runtime.lastError.message,
                    tab: {
                        id: tab.id,
                        url: tab.url,
                        title: tab.title
                    }
                });
                return;
            }

            if (response === undefined) {
                sendResponse({
                    ok: false,
                    error: "content script returned undefined response",
                    tab: {
                        id: tab.id,
                        url: tab.url,
                        title: tab.title
                    }
                });
                return;
            }

            sendResponse(response);
        });
    });
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request?.type === "LLMR_REFRESH_ALL_OVERLAYS") {
        refreshAllEligibleTabs(request.reason || "popup").then(sendResponse);
        return true;
    }

    if (request?.type === "LLMR_REFRESH_ACTIVE_OVERLAY") {
        chrome.tabs.query({active: true, currentWindow: true}, async (tabs) => {
            const tab = tabs && tabs[0];
            if (!tab?.id) {
                sendResponse({ok: false, error: "no active tab"});
                return;
            }
            sendResponse(await refreshTabOverlay(tab, request.reason || "popup-active"));
        });
        return true;
    }

    const passthrough = {
        LLMR_CAPTURE_ACTIVE_TAB: {type: "LLMR_CAPTURE_LATEST"},
        LLMR_INSERT_NEXT_ACTIVE_TAB: {type: "LLMR_INSERT_NEXT"},
        LLMR_QUEUE_ACTIVE_TAB: {type: "LLMR_QUEUE_STATUS"},
        LLMR_DISCONNECT_ACTIVE_SESSION: {type: "LLMR_DISCONNECT_SESSION"},
        LLMR_RECONNECT_ACTIVE_SESSION: {type: "LLMR_RECONNECT_SESSION"},
        LLMR_STATUS_ACTIVE_TAB: {type: "LLMR_STATUS"},
        LLMR_RESET_OVERLAY_ACTIVE_TAB: {type: "LLMR_RESET_OVERLAY"},
        LLMR_CLEAR_QUEUE_ACTIVE_TAB: {type: "LLMR_CLEAR_QUEUE"},
        LLMR_QUEUE_GROUP_STATUS_ACTIVE_TAB: {type: "LLMR_QUEUE_GROUP_STATUS"}
    };

    if (request?.type === "LLMR_INSERT_SELECTED_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_INSERT_SELECTED", draft: request.draft}, sendResponse);
        return true;
    }

    if (request?.type === "LLMR_CANCEL_DRAFT_ACTIVE_TAB") {
        sendToActiveTab({type: "LLMR_CANCEL_DRAFT", delivery_id: request.delivery_id}, sendResponse);
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
});