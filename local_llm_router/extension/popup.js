const API_BASE = "http://127.0.0.1:8015";
const SECTION_STATE_KEY = "llmr.popup.sections.v1";
const MANUAL_ALIAS_CACHE_KEY = "llmr.popup.manualAliases.v1";
const PROMPT_WRAPPER_SELECTION_KEY = "llmr.promptWrapperSelection.v1";
const ROUTE_TARGET_SELECTION_KEY = "llmr.popup.routeTargetSelection.v1";
const LIVE_REFRESH_MS = 4500;

const els = Object.fromEntries([
    "refreshAll", "expandAll", "collapseAll", "routeSource", "routeTarget", "routeWrapperEnabled", "routeWrapperSelect",
    "routeExecute", "routeContext", "routeSummary", "selectedDraftSummary", "sessionCount", "refreshSessions",
    "useActiveAsTarget", "liveSessions", "currentSessionSummary", "currentSessionCard", "sessionAlias", "saveAlias",
    "saveInferredAlias", "queueGroupSelect", "assignGroup", "renameGroup", "groupName", "createAssignGroup",
    "queueSourceMode", "loadQueue", "insertNext", "queueList", "queueSummary", "dispatchProvider", "probeProvider",
    "refreshProviders", "providerSummary", "localServicesStatus", "localServices", "servicesSummary", "status",
    "refreshOverlay", "openInbox", "disconnect", "output", "diagnosticsSummary",
    "queueUser", "queueAssistant", "identityPill", "routePill", "sessionsPill", "queuePill", "providerPill", "servicesPill", "diagnosticsPill"
].map(id => [id, document.getElementById(id)]));

const state = {
    providers: [],
    statusDetail: null,
    liveSessions: [],
    queueGroups: [],
    selectedDraft: null,
    latestQueue: [],
    routeLock: false,
    dispatchProviderId: localStorage.getItem("llmr.dispatchProviderId") || "",
    activeStatus: null,
    manualAliases: {},
    promptWrappers: [],
    promptWrapperSelections: {},
    routeTargetSelections: {},
    routeTargetLabels: {},
    routeTargetLastSeen: {},
    localServices: [],
    refreshInFlight: false,
    lastRefreshAt: 0,
    activeSummary: "detecting"
};

function shortId(value, left = 8, right = 4) {
    const s = String(value || "");
    if (s.length <= left + right + 3) return s;
    return `${s.slice(0, left)}…${s.slice(-right)}`;
}

function cleanText(value) {
    return String(value || "").replace(/\s+/g, " ").trim();
}

function escapeHtml(value) {
    return String(value ?? "")
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/\"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function print(value) {
    if (!els.output) return;
    els.output.textContent = typeof value === "string" ? value : JSON.stringify(value, null, 2);
    setHint("diagnosticsSummary", typeof value === "string" ? value.split("\n")[0] : (value?.ok === false ? "error" : "updated"));
}

function setHint(id, text) {
    const el = els[id];
    if (el) el.textContent = cleanText(text || "");
}

function normalizeStateKind(kind) {
    if (["missing", "warn", "choose", "error", "unavailable"].includes(kind)) return "missing";
    if (["loading", "refreshing", "working"].includes(kind)) return "loading";
    if (["custom", "selected", "ready", "default", "off", "ok"].includes(kind)) return kind;
    return "ready";
}

function stateLabel(kind) {
    const normalized = normalizeStateKind(kind);
    if (normalized === "missing") return "Choose";
    if (normalized === "loading") return "Loading";
    if (normalized === "custom") return "Custom";
    if (normalized === "selected") return "Selected";
    if (normalized === "default") return "Default";
    if (normalized === "off") return "Off";
    return "Ready";
}

function setPill(id, kind, label = null) {
    const pill = els[id];
    if (!pill) return;
    const normalized = normalizeStateKind(kind);
    pill.className = `pill state-${normalized}`;
    pill.textContent = label || stateLabel(normalized);
}

function setSectionState(sectionName, kind, summary = "") {
    const section = document.querySelector(`.section[data-section="${sectionName}"]`);
    if (!section) return;
    const normalized = normalizeStateKind(kind);
    for (const cls of Array.from(section.classList)) {
        if (cls.startsWith("state-")) section.classList.remove(cls);
    }
    section.classList.add(`state-${normalized}`);
    const pillMap = {
        identity: "identityPill",
        route: "routePill",
        sessions: "sessionsPill",
        queue: "queuePill",
        providers: "providerPill",
        services: "servicesPill",
        diagnostics: "diagnosticsPill"
    };
    setPill(pillMap[sectionName], normalized);
    if (summary) {
        const hintMap = {
            identity: "currentSessionSummary",
            route: "routeSummary",
            sessions: "sessionCount",
            queue: "queueSummary",
            providers: "providerSummary",
            services: "servicesSummary",
            diagnostics: "diagnosticsSummary"
        };
        setHint(hintMap[sectionName], summary);
    }
}

function setSummaryState(el, kind) {
    if (!el) return;
    const normalized = normalizeStateKind(kind);
    for (const cls of Array.from(el.classList)) {
        if (cls.startsWith("state-")) el.classList.remove(cls);
    }
    el.classList.add(`state-${normalized}`);
}

function setInputCurrentPlaceholder(input, value, fallback = "") {
    if (!input) return;
    const clean = cleanText(value || "");
    input.placeholder = clean || fallback;
    input.dataset.currentValue = clean;
    input.classList.toggle("input-current", Boolean(clean));
    if (document.activeElement !== input && input.value === clean) {
        input.value = "";
    }
}

function routeContextHtml() {
    const source = els.routeSource?.value || "latest_user";
    const target = selectedTargetValue();
    const wrapper = selectedPromptWrapper();
    const wrapperText = wrapper.enabled ? wrapper.label : (wrapper.missing_wrapper_id ? `Missing wrapper: ${wrapper.missing_wrapper_id}` : "Wrapper off");
    const sourceExtra = source === "selected_draft" && !state.selectedDraft
        ? "Select a queued item before routing."
        : (source === "selected_draft" ? `Queued item ${shortId(state.selectedDraft.delivery_id, 10, 6)}` : "Captured from the active ChatGPT session.");
    const targetExtra = target ? "Delivered to the selected target; browser send remains manual." : "Choose a target before routing.";
    return `
      <div class="route-flow">
        <div class="route-flow-line"><div class="route-flow-label">From</div><div class="route-flow-value" title="${escapeHtml(routeSourceLabel(source))}">${escapeHtml(routeSourceLabel(source))}</div></div>
        <div class="route-flow-extra">${escapeHtml(sourceExtra)}</div>
        <div class="route-flow-line"><div class="route-flow-label">To</div><div class="route-flow-value" title="${escapeHtml(targetLabel(target))}">${escapeHtml(targetLabel(target))}</div></div>
        <div class="route-flow-extra">${escapeHtml(targetExtra)}${wrapper.enabled || wrapper.missing_wrapper_id ? ` · ${escapeHtml(wrapperText)}` : ""}</div>
      </div>`;
}

function setBusy(button, busy, labelWhenDone = null) {
    if (!button) return;
    button.disabled = Boolean(busy);
    if (busy) {
        button.dataset.llmrLabel = button.textContent || "";
        button.textContent = "Working…";
    } else if (labelWhenDone) {
        button.textContent = labelWhenDone;
    } else if (button.dataset.llmrLabel) {
        button.textContent = button.dataset.llmrLabel;
    }
}

function isTextEditingActive() {
    const active = document.activeElement;
    if (!active) return false;
    const tag = String(active.tagName || "").toUpperCase();
    return tag === "INPUT" || tag === "TEXTAREA" || (tag === "SELECT" && active === els.routeTarget);
}

function send(message) {
    return new Promise(resolve => {
        chrome.runtime.sendMessage(message, response => {
            if (chrome.runtime.lastError) {
                resolve({ok: false, error: chrome.runtime.lastError.message});
                return;
            }
            resolve(response || {ok: false, error: "no response"});
        });
    });
}

async function api(path, options = {}) {
    const response = await fetch(`${API_BASE}${path}`, {
        ...options,
        headers: {"Content-Type": "application/json", ...(options.headers || {})}
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`daemon request failed: ${response.status} ${JSON.stringify(body)}`);
    return body;
}

function loadJson(key, fallback) {
    try {
        const raw = localStorage.getItem(key);
        return raw ? JSON.parse(raw) : fallback;
    } catch (_) {
        return fallback;
    }
}

function saveJson(key, value) {
    localStorage.setItem(key, JSON.stringify(value));
}

function storageGet(key) {
    return new Promise(resolve => chrome.storage?.local?.get(key, result => resolve(result?.[key] ?? null)) || resolve(null));
}

function storageSet(key, value) {
    return new Promise(resolve => chrome.storage?.local?.set({[key]: value}, () => resolve(true)) || resolve(false));
}

async function loadSharedMaps() {
    const [prompt, targets] = await Promise.all([
        storageGet(PROMPT_WRAPPER_SELECTION_KEY),
        storageGet(ROUTE_TARGET_SELECTION_KEY)
    ]);
    state.promptWrapperSelections = prompt && typeof prompt === "object" && !Array.isArray(prompt) ? prompt : {};
    state.routeTargetSelections = targets && typeof targets === "object" && !Array.isArray(targets) ? targets : {};
}

async function savePromptWrapperSelections() {
    await storageSet(PROMPT_WRAPPER_SELECTION_KEY, state.promptWrapperSelections);
}

async function saveRouteTargetSelections() {
    await storageSet(ROUTE_TARGET_SELECTION_KEY, state.routeTargetSelections);
}

function currentSession() {
    return state.activeStatus?.session || null;
}

function currentGroup() {
    return state.activeStatus?.queue_group || currentLiveSession()?.queue_group || {
        queue_group_id: "default",
        name: "Default queue",
        is_default: true
    };
}

function sessionGroupKey(session = currentSession(), group = currentGroup()) {
    return `${session?.source_session_id || "global"}::${group?.queue_group_id || "default"}`;
}

function promptWrapperSelectionKey() {
    return sessionGroupKey();
}

function currentPromptWrapperSelection() {
    return state.promptWrapperSelections[promptWrapperSelectionKey()] || {enabled: false, wrapper_id: null};
}

function selectedPromptWrapper() {
    const selection = currentPromptWrapperSelection();
    if (!selection.enabled || !selection.wrapper_id) return {enabled: false};
    const wrapper = state.promptWrappers.find(item => item.wrapper_id === selection.wrapper_id);
    if (!wrapper) return {enabled: false, missing_wrapper_id: selection.wrapper_id};
    return {enabled: true, wrapper_id: wrapper.wrapper_id, label: wrapper.label || wrapper.wrapper_id};
}

function promptWrapperOptions(source = "popup") {
    const selected = selectedPromptWrapper();
    if (!selected.enabled) return {};
    return {
        prompt_wrapper_id: selected.wrapper_id,
        prompt_wrapper_label: selected.label,
        prompt_wrapper_source: source
    };
}

async function savePromptWrapperSelection() {
    const key = promptWrapperSelectionKey();
    const enabled = Boolean(els.routeWrapperEnabled?.checked);
    const wrapperId = els.routeWrapperSelect?.value || null;
    state.promptWrapperSelections[key] = {
        enabled: enabled && Boolean(wrapperId),
        wrapper_id: enabled ? wrapperId : null,
        updated_at: new Date().toISOString()
    };
    await savePromptWrapperSelections();
}

async function refreshPromptWrappers() {
    const data = await api("/api/v1/prompt-wrappers");
    state.promptWrappers = data.prompt_wrappers || [];
    await loadSharedMaps();
    renderPromptWrapperControls();
}

function renderPromptWrapperControls() {
    if (!els.routeWrapperEnabled || !els.routeWrapperSelect) return;
    const selection = currentPromptWrapperSelection();
    els.routeWrapperSelect.innerHTML = "";
    if (!state.promptWrappers.length) {
        els.routeWrapperSelect.append(new Option("No wrappers configured", ""));
        els.routeWrapperEnabled.checked = false;
        els.routeWrapperEnabled.disabled = true;
        els.routeWrapperSelect.disabled = true;
        setHint("routeSummary", routeSummaryText());
        return;
    }

    for (const wrapper of state.promptWrappers) {
        const label = wrapper.label || wrapper.wrapper_id;
        const option = new Option(label, wrapper.wrapper_id);
        option.title = wrapper.description || label;
        els.routeWrapperSelect.append(option);
    }

    const selectedId = state.promptWrappers.some(item => item.wrapper_id === selection.wrapper_id)
        ? selection.wrapper_id
        : (state.promptWrappers[0]?.wrapper_id || "");
    els.routeWrapperEnabled.disabled = false;
    els.routeWrapperEnabled.checked = Boolean(selection.enabled && selectedId);
    els.routeWrapperSelect.value = selectedId;
    els.routeWrapperSelect.disabled = !els.routeWrapperEnabled.checked;
    setHint("routeSummary", routeSummaryText());
}

function sectionDefaults() {
    return {
        identity: true,
        route: true,
        sessions: true,
        queue: false,
        providers: false,
        services: false,
        diagnostics: false
    };
}

function sectionState() {
    return {...sectionDefaults(), ...loadJson(SECTION_STATE_KEY, {})};
}

function saveSectionState(next) {
    saveJson(SECTION_STATE_KEY, next);
}

function applySectionState(next = sectionState()) {
    for (const section of document.querySelectorAll(".section[data-section]")) {
        const name = section.dataset.section;
        section.classList.toggle("collapsed", !next[name]);
    }
}

function setAllSections(open) {
    const next = sectionState();
    for (const key of Object.keys(sectionDefaults())) next[key] = Boolean(open);
    saveSectionState(next);
    applySectionState(next);
}

function initSections() {
    applySectionState();
    for (const section of document.querySelectorAll(".section[data-section]")) {
        const name = section.dataset.section;
        section.querySelector(".section-toggle")?.addEventListener("click", () => {
            const current = sectionState();
            current[name] = section.classList.contains("collapsed");
            saveSectionState(current);
            applySectionState(current);
        });
    }
}

function providerLabel(provider) {
    if (!provider) return "No provider";
    return `${provider.label || provider.provider_id}${provider.availability ? ` · ${provider.availability}` : ""}`;
}

function dispatchCapableProviders() {
    return (state.providers || [])
        .filter(provider => provider.enabled)
        .filter(provider => provider.capabilities?.can_dispatch_request)
        .filter(provider => provider.provider_type !== "local_draft")
        .sort((a, b) => String(a.label || a.provider_id).localeCompare(String(b.label || b.provider_id)));
}

function selectedProvider() {
    const providers = dispatchCapableProviders();
    return providers.find(provider => provider.provider_id === state.dispatchProviderId) || providers[0] || null;
}

function sourceMode() {
    return els.queueSourceMode?.value || "all_insertable";
}

function knownSessionById(sourceSessionId) {
    return (state.statusDetail?.provider_sessions || []).find(item => item.source_session_id === sourceSessionId) || null;
}

function manualAliasFor(sourceSessionId) {
    return state.manualAliases[sourceSessionId]?.label || null;
}

function resolveSessionLabel(liveOrKnown) {
    const session = liveOrKnown?.session || liveOrKnown;
    const sourceSessionId = session?.source_session_id || liveOrKnown?.source_session_id;
    const durable = knownSessionById(sourceSessionId);
    const manual = manualAliasFor(sourceSessionId) || (durable?.label_source === "user_saved" ? durable.label : null);
    const inferred = liveOrKnown?.inferred_label || session?.inferred_label || durable?.inferred_label || durable?.conversation_title;
    const daemon = durable?.label;
    const fallback = session?.fallback_label || shortId(sourceSessionId || "unknown", 16, 6);

    if (manual) return {label: manual, source: "saved alias"};
    if (daemon && durable?.label_source === "user_saved") return {label: daemon, source: "saved alias"};
    if (inferred) return {
        label: inferred,
        source: session?.inferred_label_source || liveOrKnown?.inferred_label_source || "inherited"
    };
    if (daemon) return {label: daemon, source: "known"};
    return {label: fallback, source: "fallback"};
}

function currentLiveSession() {
    const sourceSessionId = currentSession()?.source_session_id;
    return state.liveSessions.find(item => item.session?.source_session_id === sourceSessionId) || null;
}

function liveTabId(item) {
    const id = Number(item?.tab?.id ?? item?.tab_id);
    return Number.isFinite(id) && id > 0 ? id : null;
}

function liveSessionGroupId(item) {
    return item?.queue_group?.queue_group_id || item?.queue_group_id || null;
}

function liveSessionGroupName(item) {
    return item?.queue_group?.name || item?.queue_group_name || liveSessionGroupId(item) || "unknown group";
}

function routeTargetKey(session = currentSession(), group = currentGroup()) {
    return sessionGroupKey(session, group);
}

function routeTargetRecord(session = currentSession(), group = currentGroup()) {
    return state.routeTargetSelections[routeTargetKey(session, group)] || null;
}

function rememberTarget(option) {
    if (!option?.value) return;
    state.routeTargetLabels[option.value] = option.label || option.value;
    state.routeTargetLastSeen[option.value] = Date.now();
}

async function setRouteTargetRecord(value, {manual = true, reason = "user_selected"} = {}) {
    const key = routeTargetKey();
    state.routeTargetSelections[key] = {
        value: value || "local_draft",
        manual: Boolean(manual),
        reason,
        queue_group_id: currentGroup()?.queue_group_id || "default",
        updated_at: Date.now()
    };
    await saveRouteTargetSelections();
}

function liveGroupMemberTargets() {
    const session = currentSession();
    const group = currentGroup();
    const groupId = group?.queue_group_id || "default";
    if (!session?.source_session_id || !groupId || groupId === "default") return [];
    const seen = new Set();
    return (state.liveSessions || [])
        .filter(item => liveTabId(item))
        .filter(item => item?.session?.source_session_id && item.session.source_session_id !== session.source_session_id)
        .filter(item => liveSessionGroupId(item) === groupId)
        .filter(item => {
            const key = String(liveTabId(item));
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
        })
        .sort((a, b) => cleanText(resolveSessionLabel(a).label).localeCompare(cleanText(resolveSessionLabel(b).label)))
        .map(item => ({
            value: `tab:${liveTabId(item)}`,
            label: `ChatGPT: ${resolveSessionLabel(item).label}`,
            detail: `Group member · ${liveSessionGroupName(item)} · tab ${liveTabId(item)}`,
            item
        }));
}

function targetOptions() {
    const providers = dispatchCapableProviders().map(provider => ({
        value: `provider:${provider.provider_id}`,
        label: providerLabel(provider),
        detail: `Provider · ${provider.availability || "unknown"}`
    }));
    const groupMemberValues = new Set();
    const groupMembers = liveGroupMemberTargets().map(item => {
        groupMemberValues.add(item.value);
        return item;
    });
    const liveTargets = (state.liveSessions || [])
        .filter(item => liveTabId(item))
        .filter(item => !groupMemberValues.has(`tab:${liveTabId(item)}`))
        .map(item => ({
            value: `tab:${liveTabId(item)}`,
            label: `ChatGPT: ${resolveSessionLabel(item).label}${item.tab?.active ? " · active" : ""}`,
            detail: `${liveSessionGroupName(item)} · tab ${liveTabId(item)}`,
            item
        }));
    return [
        {value: "local_draft", label: "Local draft inbox", detail: "Queue in current group"},
        ...providers,
        ...groupMembers,
        ...liveTargets
    ];
}

function routeTargetKind(options = targetOptions()) {
    const record = routeTargetRecord();
    const available = new Set(options.map(item => item.value));
    if (record?.manual && record.value) return record.value;
    const groupPreferred = liveGroupMemberTargets()[0];
    if (groupPreferred?.value) return groupPreferred.value;
    if (record?.value && available.has(record.value)) return record.value;
    return "local_draft";
}

function targetLabel(value) {
    if (value === "local_draft") return "Local draft inbox";
    if (value?.startsWith("provider:")) {
        const id = value.slice("provider:".length);
        const provider = dispatchCapableProviders().find(item => item.provider_id === id);
        return provider ? (provider.label || provider.provider_id) : id;
    }
    if (value?.startsWith("tab:")) {
        const tabId = Number(value.slice("tab:".length));
        const item = state.liveSessions.find(session => liveTabId(session) === tabId);
        return item ? `ChatGPT: ${resolveSessionLabel(item).label}` : (state.routeTargetLabels[value] || `ChatGPT tab ${tabId}`);
    }
    return value || "unknown target";
}

function routeSourceLabel(value = els.routeSource?.value || "latest_user") {
    if (value === "latest_assistant") return "Last assistant";
    if (value === "selected_draft") return "Selected queued";
    return "Last user";
}

function draftSourceLabel(draft) {
    if (!draft) return "unknown";
    if (draft.provider === "chatgpt") return `ChatGPT / ${draft.role || "unknown"}`;
    return `${draft.provider || "provider"} / generated ${draft.role || "assistant"}`;
}

function draftTitle(draft) {
    const title = draft.conversation_title || "Untitled conversation";
    const conv = draft.conversation_id ? ` · ${shortId(draft.conversation_id, 7, 4)}` : "";
    return `${title}${conv}`;
}

function draftMeta(draft) {
    return [
        draftSourceLabel(draft),
        `${draft.body_length || 0} chars`,
        draft.queue_group_name || draft.queue_group_id || "default",
        shortId(draft.source_session_id, 12, 7),
        draft.turn_testid || "no-turn"
    ].join(" · ");
}

function summarize(response) {
    if (!response) return {ok: false, error: "no response"};
    if (response.response?.delivery_ids) {
        const inner = response.response;
        return {
            ok: Boolean(response.ok),
            result: inner.deduped ? "requeued duplicate" : "queued",
            route_decision: inner.route_decision,
            message_id: shortId(inner.message_id),
            deliveries: (inner.delivery_ids || []).map(id => shortId(id))
        };
    }
    if (response.response?.status === "response_received") {
        const inner = response.response;
        return {
            ok: Boolean(response.ok),
            result: "provider response received",
            provider_id: inner.provider_id,
            generated_delivery_ids: (inner.generated_delivery_ids || []).map(id => shortId(id)),
            status: inner.status
        };
    }
    if (response.mode || response.target_tab) return response;
    return response;
}

function selectedTargetValue() {
    return els.routeTarget?.value || routeTargetKind();
}

function routeSummaryText() {
    const target = selectedTargetValue();
    const wrapper = selectedPromptWrapper();
    return `From: ${routeSourceLabel()} · To: ${targetLabel(target)}${wrapper.enabled ? ` · Wrapper: ${wrapper.label}` : ""}`;
}

function routeReadiness() {
    const source = els.routeSource?.value || "latest_user";
    const target = selectedTargetValue();
    const wrapper = selectedPromptWrapper();
    if (source === "selected_draft" && !state.selectedDraft) {
        return {kind: "missing", reason: "select queued item", source, target, wrapper};
    }
    if (!target) return {kind: "missing", reason: "select target", source, target, wrapper};
    if (wrapper.missing_wrapper_id) return {
        kind: "missing",
        reason: `missing wrapper ${wrapper.missing_wrapper_id}`,
        source,
        target,
        wrapper
    };
    const record = routeTargetRecord();
    if (record?.manual || source !== "latest_user" || wrapper.enabled) return {
        kind: "custom",
        reason: "custom route",
        source,
        target,
        wrapper
    };
    return {kind: "default", reason: "usable default", source, target, wrapper};
}

function updateHeaderSummaries() {
    const liveCount = state.liveSessions.length;
    const grouped = state.liveSessions.filter(item => liveSessionGroupId(item) && liveSessionGroupId(item) !== "default").length;
    const provider = selectedProvider();
    const services = state.localServices || [];
    const healthy = services.filter(item => item.supervisor_ok && item.health_ok).length;
    const session = currentSession();
    const group = currentGroup();
    const identity = session ? resolveSessionLabel(currentLiveSession() || {session}) : null;
    const route = routeReadiness();
    const queueCount = state.latestQueue.length || 0;

    setSectionState("identity", session ? (group?.queue_group_id === "default" ? "default" : "custom") : "missing", session ? `${identity?.label || "session"} · ${group?.name || "Default queue"}` : "active ChatGPT tab needed");
    setSectionState("route", route.kind, routeSummaryText());
    setSectionState("sessions", liveCount ? "ready" : "missing", `${liveCount} live${grouped ? ` · ${grouped} grouped` : ""}`);
    setSectionState("queue", "ready", `${queueCount} queued · ${sourceMode().replaceAll("_", " ")}`);
    setSectionState("providers", provider ? "ready" : "missing", provider ? `${provider.label || provider.provider_id} · ${provider.availability || "unknown"}` : "no provider");
    setSectionState("services", services.length ? (healthy === services.length ? "ready" : "missing") : "loading", services.length ? `${healthy}/${services.length} healthy` : "not loaded");
}

function updateRouteAvailability() {
    const source = els.routeSource?.value || "latest_user";
    const target = selectedTargetValue();
    const wrapper = selectedPromptWrapper();
    const record = routeTargetRecord();
    const route = routeReadiness();

    if (els.routeContext) {
        els.routeContext.innerHTML = routeContextHtml();
        setSummaryState(els.routeContext, route.kind);
    }
    if (els.selectedDraftSummary) {
        els.selectedDraftSummary.textContent = state.selectedDraft
            ? `Selected: ${draftSourceLabel(state.selectedDraft)} · ${shortId(state.selectedDraft.delivery_id, 10, 6)}`
            : "No queued item selected.";
    }


    if (source === "selected_draft" && !state.selectedDraft) {
        els.routeExecute.textContent = "Select queued item first";
        els.routeExecute.disabled = state.routeLock;
    } else {
        els.routeExecute.textContent = "Route";
        els.routeExecute.disabled = state.routeLock || !target;
    }
    updateHeaderSummaries();
}

function populateTargets() {
    if (!els.routeTarget) return;
    const options = targetOptions();
    const selected = routeTargetKind(options);
    options.forEach(rememberTarget);
    const finalOptions = [...options];
    if (selected && !finalOptions.some(item => item.value === selected)) {
        finalOptions.push({
            value: selected,
            label: `${state.routeTargetLabels[selected] || targetLabel(selected)} · reconnecting`,
            detail: "Previously selected target is not currently detected."
        });
    }
    els.routeTarget.innerHTML = "";
    for (const item of finalOptions) {
        const opt = new Option(item.label, item.value);
        opt.title = item.detail || item.label;
        els.routeTarget.append(opt);
    }
    els.routeTarget.value = finalOptions.some(item => item.value === selected) ? selected : "local_draft";
    updateRouteAvailability();
}

function populateDispatchProvider() {
    const providers = dispatchCapableProviders();
    els.dispatchProvider.innerHTML = "";
    if (!providers.length) {
        els.dispatchProvider.append(new Option("No dispatch-capable providers", ""));
        els.dispatchProvider.disabled = true;
        state.dispatchProviderId = "";
        populateTargets();
        updateHeaderSummaries();
        return;
    }
    els.dispatchProvider.disabled = false;
    for (const provider of providers) {
        const opt = new Option(providerLabel(provider), provider.provider_id);
        opt.selected = provider.provider_id === state.dispatchProviderId;
        els.dispatchProvider.append(opt);
    }
    if (!providers.some(provider => provider.provider_id === state.dispatchProviderId)) {
        state.dispatchProviderId = providers[0].provider_id;
        els.dispatchProvider.value = state.dispatchProviderId;
    }
    populateTargets();
    updateHeaderSummaries();
}

async function refreshProviders() {
    const data = await api("/api/v1/providers");
    state.providers = data.providers || [];
    populateDispatchProvider();
}

function populateQueueGroups() {
    if (!els.queueGroupSelect) return;
    const current = currentGroup();
    els.queueGroupSelect.innerHTML = "";
    for (const group of state.queueGroups || []) {
        const opt = new Option(`${group.name}${group.is_default ? " (default)" : ""}`, group.queue_group_id);
        opt.selected = group.queue_group_id === current?.queue_group_id;
        els.queueGroupSelect.append(opt);
    }
    if (current?.queue_group_id) els.queueGroupSelect.value = current.queue_group_id;
}

async function refreshStatusDetail() {
    state.statusDetail = await api("/api/v1/status/detail");
    state.queueGroups = state.statusDetail.queue_groups || [];
    populateQueueGroups();
}

async function refreshActiveStatus() {
    const response = await send({type: "LLMR_STATUS_ACTIVE_TAB"});
    if (response.ok) state.activeStatus = response;
    return response;
}

async function refreshLiveSessions() {
    const response = await send({type: "LLMR_LIST_LIVE_CHATGPT_SESSIONS"});
    state.liveSessions = (response.sessions || [])
        .filter(item => item.session?.source_session_id && item.tab?.id)
        .sort((a, b) => {
            if (a.tab?.active && !b.tab?.active) return -1;
            if (!a.tab?.active && b.tab?.active) return 1;
            return resolveSessionLabel(a).label.localeCompare(resolveSessionLabel(b).label);
        });
    renderLiveSessions();
    populateTargets();
    updateHeaderSummaries();
    return response;
}

function renderCurrentSession() {
    const active = state.activeStatus;
    const session = active?.session;
    const live = currentLiveSession();
    if (!session) {
        els.currentSessionCard.textContent = active?.error || "Active tab is not a detected ChatGPT session.";
        setHint("currentSessionSummary", "not detected");
        return;
    }
    const labelInfo = resolveSessionLabel(live || {session});
    const group = active.queue_group || live?.queue_group || currentGroup();
    if (document.activeElement !== els.sessionAlias) {
        setInputCurrentPlaceholder(els.sessionAlias, labelInfo.label, "Type a new session name");
    }
    setSummaryState(els.currentSessionCard, group?.queue_group_id === "default" ? "default" : "custom");
    els.currentSessionCard.innerHTML = `
      <div class="row-title">${escapeHtml(labelInfo.label)}</div>
      <div class="meta">${escapeHtml(labelInfo.source)} · group: ${escapeHtml(group?.name || "Default queue")}</div>
      <div class="meta">${escapeHtml(shortId(session.source_session_id, 20, 8))}</div>
      <div><span class="badge good">active</span><span class="badge blue">${escapeHtml(session.provider || "chatgpt")}</span></div>
    `;
    setHint("currentSessionSummary", `${labelInfo.label} · ${group?.name || "Default queue"}`);
    populateQueueGroups();
    renderPromptWrapperControls();
}

function renderLiveSessions() {
    els.liveSessions.innerHTML = "";
    if (!state.liveSessions.length) {
        els.liveSessions.innerHTML = `<div class="summary">No live ChatGPT sessions detected. Open ChatGPT tabs and click Refresh sessions.</div>`;
        setHint("sessionCount", "0 live");
        return;
    }
    const activeId = currentSession()?.source_session_id;
    for (const item of state.liveSessions) {
        const session = item.session || {};
        const labelInfo = resolveSessionLabel(item);
        const groupName = liveSessionGroupName(item);
        const tabId = liveTabId(item);
        const targetValue = `tab:${tabId}`;
        const row = document.createElement("div");
        const targetValueState = routeTargetKind() === targetValue ? " state-selected" : "";
        row.className = `row state-ready${session.source_session_id === activeId ? " live-current" : ""}${targetValueState}`;
        row.innerHTML = `
          <div class="row-title">${escapeHtml(labelInfo.label)}</div>
          <div><span class="badge pink">${routeTargetKind() === targetValue ? "selected target" : "live"}</span>${item.tab?.active ? `<span class="badge blue">active</span>` : ""}</div>
          <div class="meta">${escapeHtml(labelInfo.source)} · group: ${escapeHtml(groupName)} · tab ${tabId}</div>
          <div class="meta">${escapeHtml(shortId(session.source_session_id, 20, 8))}</div>
          <div class="row-actions">
            <button data-action="target">Use target</button>
            <button data-action="assign">Assign group</button>
            <button data-action="refresh">Refresh</button>
          </div>
        `;
        row.querySelector('[data-action="target"]').onclick = async () => {
            rememberTarget({value: targetValue, label: `ChatGPT: ${labelInfo.label}`});
            await setRouteTargetRecord(targetValue, {manual: true, reason: "live_session_card"});
            populateTargets();
            print({ok: true, target: `ChatGPT: ${labelInfo.label}`});
        };
        row.querySelector('[data-action="assign"]').onclick = async () => {
            await assignGroupForSession(session, els.queueGroupSelect.value, labelInfo.label);
        };
        row.querySelector('[data-action="refresh"]').onclick = async () => {
            await refreshLiveSessions();
            print({ok: true, result: "live sessions refreshed"});
        };
        els.liveSessions.append(row);
    }
    updateHeaderSummaries();
}

function filterDraftsForSourceMode(drafts) {
    const mode = sourceMode();
    return (drafts || []).filter(draft => {
        if (mode === "chatgpt_captures") return draft.provider === "chatgpt";
        if (mode === "provider_responses") return draft.provider && draft.provider !== "chatgpt";
        return true;
    });
}

async function queueLatest(role) {
    const type = role === "user" ? "LLMR_CAPTURE_USER_ACTIVE_TAB" : "LLMR_CAPTURE_ASSISTANT_ACTIVE_TAB";
    const response = await send({type});
    if (response?.ok) {
        await Promise.allSettled([refreshStatusDetail(), refreshLiveSessions(), loadQueue()]);
        print({ok: true, result: `queued latest ${role}`, response: summarize(response)});
    } else {
        print({ok: false, error: response?.error || `queue ${role} failed`, response});
    }
    return response;
}

async function loadQueue() {
    const active = await refreshActiveStatus();
    const queueGroupId = active.queue_group?.queue_group_id || currentGroup()?.queue_group_id || "default";
    const data = await api(`/api/v1/drafts?include_handled=true&queue_group_id=${encodeURIComponent(queueGroupId)}`);
    const drafts = filterDraftsForSourceMode((data.drafts || [])
        .filter(draft => draft.status === "queued")
        .filter(draft => !active.session?.source_session_id || draft.source_session_id !== active.session.source_session_id));
    state.latestQueue = drafts;
    renderQueue(drafts);
    updateRouteAvailability();
    return drafts;
}

function renderQueue(drafts) {
    els.queueList.innerHTML = "";
    if (!drafts.length) {
        els.queueList.innerHTML = `<div class="summary state-ready">No queued drafts for this session/group/source mode.</div>`;
        setHint("queueSummary", `0 queued · ${sourceMode().replaceAll("_", " ")}`);
        return;
    }
    for (const draft of drafts.slice(0, 14)) {
        const row = document.createElement("div");
        row.className = "row state-ready";
        if (state.selectedDraft?.delivery_id === draft.delivery_id) row.classList.add("selected");
        row.innerHTML = `
          <div class="row-title">${escapeHtml(draftTitle(draft))}</div>
          <div class="meta">${escapeHtml(draftMeta(draft))}</div>
          <div class="row-actions two"><button data-action="select">${state.selectedDraft?.delivery_id === draft.delivery_id ? "Selected" : "Select"}</button><button data-action="insert">Insert active</button></div>
        `;
        row.querySelector('[data-action="select"]').onclick = () => {
            state.selectedDraft = draft;
            renderQueue(state.latestQueue);
            updateRouteAvailability();
            print({ok: true, selected_delivery_id: draft.delivery_id, source: draftSourceLabel(draft)});
        };
        row.querySelector('[data-action="insert"]').onclick = async () => {
            const response = await send({
                type: "LLMR_INSERT_SELECTED_ACTIVE_TAB",
                draft,
                options: promptWrapperOptions("popup_active_insert")
            });
            print(summarize(response));
            await loadQueue().catch(() => null);
        };
        els.queueList.append(row);
    }
    setHint("queueSummary", `${drafts.length} queued · ${sourceMode().replaceAll("_", " ")}`);
}

async function insertNext() {
    const response = await send({type: "LLMR_INSERT_NEXT_ACTIVE_TAB", source_mode: sourceMode()});
    print(summarize(response));
    await loadQueue().catch(() => null);
}

async function saveAliasForSession(session, label) {
    const clean = cleanText(label || "");
    if (!session?.source_session_id || !clean) return {ok: false, error: "missing session or label"};
    const previous = state.manualAliases[session.source_session_id] || null;
    state.manualAliases[session.source_session_id] = {label: clean, saved_at: new Date().toISOString()};
    saveJson(MANUAL_ALIAS_CACHE_KEY, state.manualAliases);
    renderCurrentSession();
    renderLiveSessions();
    populateTargets();
    try {
        const response = await api("/api/v1/sessions/label", {
            method: "POST",
            body: JSON.stringify({
                source_session_id: session.source_session_id,
                provider: session.provider || "chatgpt",
                label: clean,
                label_source: "user_saved"
            })
        });
        await refreshStatusDetail();
        await refreshLiveSessions();
        renderCurrentSession();
        print({ok: true, result: "alias saved", label: response.label || clean});
        return response;
    } catch (err) {
        if (previous) state.manualAliases[session.source_session_id] = previous;
        else delete state.manualAliases[session.source_session_id];
        saveJson(MANUAL_ALIAS_CACHE_KEY, state.manualAliases);
        renderCurrentSession();
        renderLiveSessions();
        populateTargets();
        print({ok: false, error: `alias save failed: ${err}`, reverted_to: previous?.label || null});
        return {ok: false, error: String(err)};
    }
}

async function saveCurrentAlias(useInferred = false) {
    const session = currentSession();
    const live = currentLiveSession();
    const label = useInferred
        ? resolveSessionLabel(live || {session}).label
        : cleanText(els.sessionAlias.value || "");
    if (!useInferred && !label) {
        return print({ok: false, error: "type a new session name, or use inherited name"});
    }
    return saveAliasForSession(session, label);
}

async function assignGroupForSession(session, queueGroupId, label = null) {
    if (!session?.source_session_id) {
        print({ok: false, error: "ChatGPT session not detected"});
        return null;
    }
    const response = await api("/api/v1/sessions/queue-group", {
        method: "POST",
        body: JSON.stringify({
            source_session_id: session.source_session_id,
            provider: session.provider || "chatgpt",
            queue_group_id: queueGroupId,
            label: label || resolveSessionLabel({session}).label
        })
    });
    await refreshStatusDetail();
    await refreshActiveStatus();
    await refreshLiveSessions();
    renderCurrentSession();
    populateTargets();
    print({ok: true, result: "group assigned", session: label || session.source_session_id, response});
    return response;
}

async function assignCurrentGroup() {
    const session = currentSession();
    const live = currentLiveSession();
    const label = session ? resolveSessionLabel(live || {session}).label : null;
    return assignGroupForSession(session, els.queueGroupSelect.value, label);
}

async function createAssignGroup() {
    const name = els.groupName.value.trim();
    if (!name) return print({ok: false, error: "enter a group name"});
    const created = await api("/api/v1/queue-groups", {method: "POST", body: JSON.stringify({name})});
    await refreshStatusDetail();
    els.queueGroupSelect.value = created.queue_group_id;
    await assignCurrentGroup();
}

async function renameSelectedGroup() {
    const queueGroupId = els.queueGroupSelect.value;
    const name = els.groupName.value.trim();
    if (!name) return print({ok: false, error: "enter a new group name"});
    if (queueGroupId === "default") return print({ok: false, error: "default queue cannot be renamed"});
    const response = await api(`/api/v1/queue-groups/${encodeURIComponent(queueGroupId)}/rename`, {
        method: "POST",
        body: JSON.stringify({name})
    });
    await refreshStatusDetail();
    await refreshLiveSessions();
    renderCurrentSession();
    populateTargets();
    print({ok: true, result: "group renamed", response});
}

async function routeExecute() {
    if (state.routeLock) return;
    state.routeLock = true;
    setBusy(els.routeExecute, true);
    try {
        const source = els.routeSource.value;
        const target = els.routeTarget.value;
        let response;

        if (source === "selected_draft" && !state.selectedDraft) {
            response = {ok: false, error: "select a queued item first"};
        } else if (source === "selected_draft" && target === "local_draft") {
            response = {
                ok: true,
                mode: "already_queued",
                draft: state.selectedDraft,
                message: "selected queued item is already in the local draft queue"
            };
        } else if (source === "selected_draft" && target.startsWith("tab:")) {
            const targetTabId = Number(target.slice("tab:".length));
            response = await send({
                type: "LLMR_ROUTE_TO_CHATGPT_TAB",
                source_kind: source,
                target_tab_id: targetTabId,
                draft: state.selectedDraft,
                options: promptWrapperOptions("popup_chatgpt_insert")
            });
        } else if (source === "selected_draft" && target.startsWith("provider:")) {
            const providerId = target.slice("provider:".length);
            const opts = promptWrapperOptions("popup_provider_dispatch");
            response = {
                ok: true,
                response: await api(`/api/v1/providers/${encodeURIComponent(providerId)}/dispatch`, {
                    method: "POST",
                    body: JSON.stringify({
                        delivery_id: state.selectedDraft.delivery_id,
                        queue_group_id: state.selectedDraft.queue_group_id || "default",
                        manual_confirmed: true,
                        prompt_wrapper_id: opts.prompt_wrapper_id || null,
                        prompt_wrapper_label: opts.prompt_wrapper_label || null,
                        options: {
                            route_action: true,
                            ...opts,
                            route_source_kind: "selected_draft",
                            route_target_kind: `provider:${providerId}`,
                            duplicate_intent: true,
                            operator_action_id: (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()))
                        }
                    })
                })
            };
        } else if (target.startsWith("tab:")) {
            const targetTabId = Number(target.slice("tab:".length));
            response = await send({
                type: "LLMR_ROUTE_TO_CHATGPT_TAB",
                source_kind: source,
                target_tab_id: targetTabId,
                options: promptWrapperOptions("popup_chatgpt_insert")
            });
        } else if (target.startsWith("provider:")) {
            const providerId = target.slice("provider:".length);
            response = await send({
                type: "LLMR_ROUTE_ACTION_ACTIVE_TAB",
                source_kind: source,
                target_kind: `provider:${providerId}`,
                options: promptWrapperOptions("popup_route_action")
            });
        } else {
            response = await send({
                type: "LLMR_ROUTE_ACTION_ACTIVE_TAB",
                source_kind: source,
                target_kind: "local_draft",
                queue_source_mode: sourceMode(),
                options: promptWrapperOptions("popup_route_action")
            });
        }

        print({target: targetLabel(target), response: summarize(response)});
        await Promise.allSettled([refreshStatusDetail(), refreshLiveSessions(), loadQueue()]);
    } catch (err) {
        print({ok: false, error: String(err)});
    } finally {
        state.routeLock = false;
        setBusy(els.routeExecute, false, "Route");
        updateRouteAvailability();
    }
}

async function probeProvider() {
    const provider = selectedProvider();
    if (!provider) return print({ok: false, error: "no provider selected"});
    const response = await api(`/api/v1/providers/${encodeURIComponent(provider.provider_id)}/probe`, {method: "POST"});
    print(response);
}

async function loadLocalServices() {
    const data = await api("/api/v1/local-services/status");
    state.localServices = data.services || [];
    els.localServices.innerHTML = "";
    for (const service of state.localServices) {
        const row = document.createElement("div");
        row.className = `row ${service.supervisor_ok && service.health_ok ? "state-ready" : "state-missing"}`;
        row.innerHTML = `<div class="row-title">${escapeHtml(service.label)}</div><div><span class="badge ${service.supervisor_ok && service.health_ok ? "pink" : "orange"}">${service.health_ok ? "healthy" : "needs check"}</span></div><div class="meta">${escapeHtml(service.supervisor_name)} · ${escapeHtml(service.supervisor_state)} · health=${service.health_ok ? "ok" : "fail"}</div>`;
        els.localServices.append(row);
    }
    updateHeaderSummaries();
    print({
        ok: true,
        services: state.localServices.map(s => ({
            service_id: s.service_id,
            state: s.supervisor_state,
            health_ok: s.health_ok
        }))
    });
}

async function refreshAll({silent = false, forceOverlays = false} = {}) {
    if (state.refreshInFlight) return;
    state.refreshInFlight = true;
    try {
        if (forceOverlays) await send({type: "LLMR_REFRESH_ALL_OVERLAYS", reason: "popup"});
        await loadSharedMaps();
        await refreshProviders();
        await refreshStatusDetail();
        await refreshActiveStatus();
        state.manualAliases = loadJson(MANUAL_ALIAS_CACHE_KEY, {});
        await refreshPromptWrappers();
        await refreshLiveSessions();
        renderCurrentSession();
        populateTargets();
        updateRouteAvailability();
        state.lastRefreshAt = Date.now();
        if (!silent) print("Ready.");
    } catch (err) {
        if (!silent) print({ok: false, error: String(err)});
    } finally {
        state.refreshInFlight = false;
    }
}

function installHandlers() {
    els.refreshAll.onclick = () => refreshAll({silent: false, forceOverlays: true});
    els.expandAll.onclick = () => setAllSections(true);
    els.collapseAll.onclick = () => setAllSections(false);
    els.refreshSessions.onclick = async () => {
        await refreshAll({silent: true, forceOverlays: true});
        print({ok: true, result: "sessions refreshed"});
    };
    els.useActiveAsTarget.onclick = async () => {
        const live = currentLiveSession();
        const tabId = liveTabId(live);
        if (!tabId) return print({ok: false, error: "active ChatGPT tab is not available as a target"});
        const value = `tab:${tabId}`;
        await setRouteTargetRecord(value, {manual: true, reason: "active_tab_button"});
        populateTargets();
        print({ok: true, target: targetLabel(value)});
    };
    els.routeExecute.onclick = routeExecute;
    els.routeSource.onchange = updateRouteAvailability;
    els.routeTarget.onchange = async () => {
        await setRouteTargetRecord(els.routeTarget.value, {manual: true, reason: "route_target_select"});
        renderLiveSessions();
        updateRouteAvailability();
    };
    els.routeWrapperEnabled.onchange = async () => {
        await savePromptWrapperSelection();
        renderPromptWrapperControls();
        updateRouteAvailability();
    };
    els.routeWrapperSelect.onchange = async () => {
        await savePromptWrapperSelection();
        updateRouteAvailability();
    };
    els.dispatchProvider.onchange = () => {
        state.dispatchProviderId = els.dispatchProvider.value;
        localStorage.setItem("llmr.dispatchProviderId", state.dispatchProviderId);
        populateTargets();
    };
    els.probeProvider.onclick = probeProvider;
    els.refreshProviders.onclick = async () => {
        await refreshProviders();
        print({ok: true, providers: state.providers.length});
    };
    els.status.onclick = async () => {
        const status = await refreshActiveStatus();
        renderCurrentSession();
        print(summarize(status));
    };
    els.refreshOverlay.onclick = async () => print(await send({type: "LLMR_REFRESH_ACTIVE_OVERLAY", reason: "popup"}));
    els.openInbox.onclick = () => chrome.tabs.create({url: `${API_BASE}/draft-inbox`});
    els.disconnect.onclick = async () => print(await send({type: "LLMR_DISCONNECT_ACTIVE_SESSION"}));
    els.saveAlias.onclick = () => saveCurrentAlias(false);
    els.saveInferredAlias.onclick = () => saveCurrentAlias(true);
    els.assignGroup.onclick = assignCurrentGroup;
    els.createAssignGroup.onclick = createAssignGroup;
    els.renameGroup.onclick = renameSelectedGroup;
    if (els.queueUser) els.queueUser.onclick = () => queueLatest("user").catch(err => print({
        ok: false,
        error: String(err)
    }));
    if (els.queueAssistant) els.queueAssistant.onclick = () => queueLatest("assistant").catch(err => print({
        ok: false,
        error: String(err)
    }));
    els.loadQueue.onclick = async () => {
        const drafts = await loadQueue();
        print({ok: true, drafts: drafts.length, mode: sourceMode()});
    };
    els.insertNext.onclick = insertNext;
    els.queueSourceMode.onchange = () => loadQueue().catch(err => print({ok: false, error: String(err)}));
    els.localServicesStatus.onclick = loadLocalServices;
}

function startLiveRefresh() {
    setInterval(() => {
        if (isTextEditingActive() || state.routeLock) return;
        refreshAll({silent: true, forceOverlays: false}).catch(() => null);
    }, LIVE_REFRESH_MS);
}

initSections();
installHandlers();
refreshAll({silent: false, forceOverlays: false}).catch(err => print({ok: false, error: String(err)}));
startLiveRefresh();