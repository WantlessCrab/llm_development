globalThis.LLMR = globalThis.LLMR || {};

LLMR.API_BASE = "http://127.0.0.1:8015";

LLMR.cleanText = function cleanText(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
};

LLMR.preserveText = function preserveText(value) {
    return String(value || "")
        .replace(/\r\n/g, "\n")
        .replace(/\r/g, "\n")
        .replace(/\u00a0/g, " ")
        .trim();
};

LLMR.shortId = function shortId(value, left = 8, right = 4) {
    const s = String(value || "");
    if (s.length <= left + right + 3) return s;
    return `${s.slice(0, left)}…${s.slice(-right)}`;
};

LLMR.hashText = function hashText(text) {
    let h = 2166136261;
    for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619);
    return (h >>> 0).toString(36);
};

LLMR.api = async function api(path, options = {}) {
    const response = await fetch(`${LLMR.API_BASE}${path}`, {
        ...options,
        headers: {
            "Content-Type": "application/json",
            ...(options.headers || {})
        }
    });

    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
        throw new Error(`daemon request failed: ${response.status} ${JSON.stringify(body)}`);
    }
    return body;
};


LLMR.PROMPT_WRAPPER_SELECTION_KEY = "llmr.promptWrapperSelection.v1";

LLMR.promptWrapperSelectionStorageKey = function promptWrapperSelectionStorageKey({
                                                                                      sourceSessionId = "global",
                                                                                      queueGroupId = "default"
                                                                                  } = {}) {
    return `${sourceSessionId || "global"}::${queueGroupId || "default"}`;
};

LLMR.listPromptWrappers = async function listPromptWrappers() {
    return LLMR.api("/api/v1/prompt-wrappers");
};

LLMR.applyPromptWrapper = async function applyPromptWrapper({wrapperId, text} = {}) {
    return LLMR.api("/api/v1/prompt-wrappers/apply", {
        method: "POST",
        body: JSON.stringify({wrapper_id: wrapperId, text: String(text || "")})
    });
};

LLMR.getPromptWrapperSelections = async function getPromptWrapperSelections() {
    const value = await LLMR.storageGet(LLMR.PROMPT_WRAPPER_SELECTION_KEY);
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
};

LLMR.getPromptWrapperSelection = async function getPromptWrapperSelection({sourceSessionId, queueGroupId} = {}) {
    const selections = await LLMR.getPromptWrapperSelections();
    return selections[LLMR.promptWrapperSelectionStorageKey({sourceSessionId, queueGroupId})] || {
        enabled: false,
        wrapper_id: null
    };
};

LLMR.setPromptWrapperSelection = async function setPromptWrapperSelection({
                                                                              sourceSessionId,
                                                                              queueGroupId,
                                                                              enabled,
                                                                              wrapperId
                                                                          } = {}) {
    const selections = await LLMR.getPromptWrapperSelections();
    selections[LLMR.promptWrapperSelectionStorageKey({sourceSessionId, queueGroupId})] = {
        enabled: Boolean(enabled),
        wrapper_id: enabled ? (wrapperId || null) : null,
        updated_at: new Date().toISOString()
    };
    await LLMR.storageSet(LLMR.PROMPT_WRAPPER_SELECTION_KEY, selections);
    return selections;
};

LLMR.postCapture = async function postCapture(payload) {
    return LLMR.api("/api/v1/capture", {
        method: "POST",
        body: JSON.stringify(payload)
    });
};


LLMR.statusDetail = async function statusDetail() {
    return LLMR.api("/api/v1/status/detail");
};

LLMR.listProviderSessions = async function listProviderSessions() {
    const data = await LLMR.api("/api/v1/provider-sessions");
    return data.provider_sessions || [];
};

LLMR.setSessionLabel = async function setSessionLabel({
                                                          sourceSessionId,
                                                          provider = "chatgpt",
                                                          label,
                                                          labelSource = "user_saved"
                                                      } = {}) {
    return LLMR.api("/api/v1/sessions/label", {
        method: "POST",
        body: JSON.stringify({
            source_session_id: sourceSessionId,
            provider,
            label,
            label_source: labelSource
        })
    });
};

LLMR.listProviders = async function listProviders() {
    return LLMR.api("/api/v1/providers");
};

LLMR.probeProvider = async function probeProvider(providerId) {
    return LLMR.api(`/api/v1/providers/${encodeURIComponent(providerId)}/probe`, {
        method: "POST"
    });
};

LLMR.dispatchToProvider = async function dispatchToProvider(providerId, {
    deliveryId,
    queueGroupId = null,
    manualConfirmed = true,
    options = {}
} = {}) {
    return LLMR.api(`/api/v1/providers/${encodeURIComponent(providerId)}/dispatch`, {
        method: "POST",
        body: JSON.stringify({
            delivery_id: deliveryId,
            queue_group_id: queueGroupId,
            manual_confirmed: manualConfirmed,
            options: options || {}
        })
    });
};


LLMR.executeRouteAction = async function executeRouteAction(payload) {
    return LLMR.api("/api/v1/route-actions/execute", {
        method: "POST",
        body: JSON.stringify(payload || {})
    });
};

LLMR.listLocalServices = async function listLocalServices({target = null} = {}) {
    const params = new URLSearchParams();
    if (target) params.set("target", target);
    const suffix = params.toString() ? `?${params.toString()}` : "";
    return LLMR.api(`/api/v1/local-services/status${suffix}`);
};

LLMR.localServiceAction = async function localServiceAction(action, {target = null} = {}) {
    return LLMR.api(`/api/v1/local-services/${encodeURIComponent(action)}`, {
        method: "POST",
        body: JSON.stringify({target})
    });
};

LLMR.queueProviderFilterForSourceMode = function queueProviderFilterForSourceMode(sourceMode, {providerId = null} = {}) {
    if (sourceMode === "chatgpt_captures") return "chatgpt";
    if (sourceMode === "provider_responses" && providerId) return providerId;
    return null;
};

LLMR.isProviderResponseDraft = function isProviderResponseDraft(draft) {
    return Boolean(draft && draft.provider && draft.provider !== "chatgpt");
};

LLMR.getQueuedDraftsBySourceMode = async function getQueuedDraftsBySourceMode({
                                                                                  sourceMode = "all_insertable",
                                                                                  excludeSourceSessionId = null,
                                                                                  providerId = null,
                                                                                  queueGroupId = null
                                                                              } = {}) {
    const provider = LLMR.queueProviderFilterForSourceMode(sourceMode, {providerId});
    const drafts = await LLMR.getQueuedDrafts({
        excludeSourceSessionId,
        provider,
        queueGroupId
    });
    if (sourceMode === "provider_responses" && !providerId) {
        return drafts.filter(LLMR.isProviderResponseDraft);
    }
    return drafts;
};

LLMR.getNextDraftBySourceMode = async function getNextDraftBySourceMode({
                                                                            sourceMode = "all_insertable",
                                                                            excludeSourceSessionId = null,
                                                                            providerId = null,
                                                                            queueGroupId = null
                                                                        } = {}) {
    const provider = LLMR.queueProviderFilterForSourceMode(sourceMode, {providerId});
    if (sourceMode === "provider_responses" && !providerId) {
        const drafts = await LLMR.getQueuedDraftsBySourceMode({
            sourceMode,
            excludeSourceSessionId,
            providerId,
            queueGroupId
        });
        return drafts.length
            ? {found: true, draft: drafts[0], reason: null}
            : {found: false, draft: null, reason: "no queued provider response matched request"};
    }
    return LLMR.getNextDraft({
        excludeSourceSessionId,
        provider,
        queueGroupId
    });
};

LLMR.listDrafts = async function listDrafts({includeHandled = true, queueGroupId = null} = {}) {
    const params = new URLSearchParams();
    params.set("include_handled", includeHandled ? "true" : "false");
    if (queueGroupId) params.set("queue_group_id", queueGroupId);
    return LLMR.api(`/api/v1/drafts?${params.toString()}`);
};

LLMR.getQueuedDrafts = async function getQueuedDrafts({
                                                          excludeSourceSessionId,
                                                          provider,
                                                          queueGroupId
                                                      } = {}) {
    const data = await LLMR.listDrafts({includeHandled: true, queueGroupId});
    return (data.drafts || [])
        .filter(draft => draft.status === "queued")
        .filter(draft => !provider || draft.provider === provider)
        .filter(draft => !excludeSourceSessionId || draft.source_session_id !== excludeSourceSessionId)
        .sort((a, b) => String(a.queued_at || a.captured_at || "").localeCompare(String(b.queued_at || b.captured_at || "")));
};

LLMR.getNextDraft = async function getNextDraft({
                                                    excludeSourceSessionId,
                                                    provider,
                                                    queueGroupId
                                                } = {}) {
    const params = new URLSearchParams();
    if (excludeSourceSessionId) params.set("exclude_source_session_id", excludeSourceSessionId);
    if (provider) params.set("provider", provider);
    if (queueGroupId) params.set("queue_group_id", queueGroupId);

    const suffix = params.toString() ? `?${params.toString()}` : "";
    return LLMR.api(`/api/v1/drafts/next${suffix}`);
};

LLMR.markDraftInserted = async function markDraftInserted(deliveryId, payload) {
    return LLMR.api(`/api/v1/drafts/${encodeURIComponent(deliveryId)}/draft-inserted`, {
        method: "POST",
        body: JSON.stringify(payload || {})
    });
};

LLMR.markDraftFailed = async function markDraftFailed(deliveryId, payload) {
    return LLMR.api(`/api/v1/drafts/${encodeURIComponent(deliveryId)}/failed`, {
        method: "POST",
        body: JSON.stringify(payload || {})
    });
};

LLMR.cancelDraft = async function cancelDraft(deliveryId, {reason = "cancelled by operator"} = {}) {
    return LLMR.api(`/api/v1/drafts/${encodeURIComponent(deliveryId)}/cancel`, {
        method: "POST",
        body: JSON.stringify({reason})
    });
};

LLMR.clearQueuedDrafts = async function clearQueuedDrafts({
                                                              queueGroupId = null,
                                                              provider = null,
                                                              reason = "clear queued by operator"
                                                          } = {}) {
    return LLMR.api("/api/v1/drafts/clear-queued", {
        method: "POST",
        body: JSON.stringify({
            queue_group_id: queueGroupId,
            provider,
            reason
        })
    });
};

LLMR.listQueueGroups = async function listQueueGroups() {
    return LLMR.api("/api/v1/queue-groups");
};

LLMR.createQueueGroup = async function createQueueGroup(name) {
    return LLMR.api("/api/v1/queue-groups", {
        method: "POST",
        body: JSON.stringify({name})
    });
};

LLMR.renameQueueGroup = async function renameQueueGroup(queueGroupId, name) {
    return LLMR.api(`/api/v1/queue-groups/${encodeURIComponent(queueGroupId)}/rename`, {
        method: "POST",
        body: JSON.stringify({name})
    });
};

LLMR.deleteQueueGroup = async function deleteQueueGroup(queueGroupId, {
    cancelQueued = true,
    reason = "queue group deleted"
} = {}) {
    return LLMR.api(`/api/v1/queue-groups/${encodeURIComponent(queueGroupId)}/delete`, {
        method: "POST",
        body: JSON.stringify({
            cancel_queued: cancelQueued,
            reason
        })
    });
};

LLMR.getSessionQueueGroup = async function getSessionQueueGroup({
                                                                    sourceSessionId,
                                                                    provider = null,
                                                                    label = null
                                                                } = {}) {
    const params = new URLSearchParams();
    params.set("source_session_id", sourceSessionId);
    if (provider) params.set("provider", provider);
    if (label) params.set("label", label);
    return LLMR.api(`/api/v1/sessions/queue-group?${params.toString()}`);
};

LLMR.setSessionQueueGroup = async function setSessionQueueGroup({
                                                                    sourceSessionId,
                                                                    queueGroupId,
                                                                    provider = null,
                                                                    label = null
                                                                } = {}) {
    return LLMR.api("/api/v1/sessions/queue-group", {
        method: "POST",
        body: JSON.stringify({
            source_session_id: sourceSessionId,
            queue_group_id: queueGroupId,
            provider,
            label
        })
    });
};

LLMR.isExtensionContextInvalidatedError = function isExtensionContextInvalidatedError(error) {
    const text = String(error?.message || error || "").toLowerCase();
    return text.includes("extension context invalidated") || text.includes("context invalidated");
};

LLMR.storageGet = function storageGet(key) {
    return new Promise(resolve => {
        try {
            if (typeof chrome === "undefined" || !chrome.storage?.local) {
                resolve(null);
                return;
            }
            chrome.storage.local.get(key, result => {
                const err = chrome.runtime?.lastError;
                if (err) {
                    console.debug("[local_llm_router] chrome.storage.local.get skipped", key, err.message);
                    resolve(null);
                    return;
                }
                resolve(result?.[key] ?? null);
            });
        } catch (err) {
            if (!LLMR.isExtensionContextInvalidatedError(err)) {
                console.debug("[local_llm_router] storageGet failed", key, err);
            }
            resolve(null);
        }
    });
};

LLMR.storageSet = function storageSet(key, value) {
    return new Promise(resolve => {
        try {
            if (typeof chrome === "undefined" || !chrome.storage?.local) {
                resolve(false);
                return;
            }
            chrome.storage.local.set({[key]: value}, () => {
                const err = chrome.runtime?.lastError;
                if (err) {
                    console.debug("[local_llm_router] chrome.storage.local.set skipped", key, err.message);
                    resolve(false);
                    return;
                }
                resolve(true);
            });
        } catch (err) {
            if (!LLMR.isExtensionContextInvalidatedError(err)) {
                console.debug("[local_llm_router] storageSet failed", key, err);
            }
            resolve(false);
        }
    });
};

LLMR.DISCONNECTED_SESSIONS_KEY = "llmr.disconnected.sessions.v1";
LLMR.OVERLAY_COLLAPSED_KEY = "llmr.overlay.collapsed.v1";

LLMR.getDisconnectedSessions = async function getDisconnectedSessions() {
    const value = await LLMR.storageGet(LLMR.DISCONNECTED_SESSIONS_KEY);
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
};

LLMR.isSessionDisconnected = async function isSessionDisconnected(sessionId) {
    if (!sessionId) return false;
    const disconnected = await LLMR.getDisconnectedSessions();
    return Boolean(disconnected[sessionId]);
};

LLMR.setSessionDisconnected = async function setSessionDisconnected(sessionId, disconnected) {
    if (!sessionId) return false;
    const map = await LLMR.getDisconnectedSessions();

    if (disconnected) {
        map[sessionId] = {
            disconnected_at: new Date().toISOString(),
            href: location.href,
            title: document.title
        };
    } else {
        delete map[sessionId];
    }

    await LLMR.storageSet(LLMR.DISCONNECTED_SESSIONS_KEY, map);
    return true;
};

LLMR.__routeWatchers = LLMR.__routeWatchers || [];
LLMR.__lastHref = LLMR.__lastHref || location.href;

LLMR.onRouteChange = function onRouteChange(callback) {
    if (typeof callback === "function") {
        LLMR.__routeWatchers.push(callback);
    }
};

LLMR.emitRouteChange = function emitRouteChange() {
    const payload = {
        href: location.href,
        pathname: location.pathname,
        title: document.title,
        changed_at: new Date().toISOString()
    };

    for (const callback of LLMR.__routeWatchers) {
        try {
            callback(payload);
        } catch (err) {
            console.warn("[local_llm_router] route watcher failed", err);
        }
    }
};

LLMR.installRouteWatcher = function installRouteWatcher() {
    if (LLMR.__routeWatcherInstalled) return;
    LLMR.__routeWatcherInstalled = true;

    window.addEventListener("popstate", () => {
        if (location.href !== LLMR.__lastHref) {
            LLMR.__lastHref = location.href;
            LLMR.emitRouteChange();
        }
    });

    setInterval(() => {
        if (location.href !== LLMR.__lastHref) {
            LLMR.__lastHref = location.href;
            LLMR.emitRouteChange();
        }
    }, 750);
};

LLMR.installRouteWatcher();