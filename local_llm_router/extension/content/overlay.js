globalThis.LLMR = globalThis.LLMR || {};

(function initOverlay() {
    if (!LLMR.ChatGPTAdapter?.detect()) return;

    const OVERLAY_VERSION = "route-actions-quick-group-queue-v1";
    const OVERLAY_POSITION_KEY = "llmr.overlay.position.v1";
    const DEFAULT_OFFSET = {right: 12, bottom: 84};
    const QUEUE_GROUP_CACHE_TTL_MS = 15000;
    const NEXT_DRAFT_CACHE_TTL_MS = 7000;
    const POST_INSERT_QUEUE_REFRESH_DELAY_MS = 250;
    const LIVE_CHATGPT_SESSIONS_CACHE_TTL_MS = 4500;
    const ROUTE_SETUP_SECTIONS_KEY = "llmr.overlay.routeSetupSections.v1";
    const ROUTE_PANEL_GROUPS_CACHE_TTL_MS = 10000;
    const QUICK_HANDOFF_SOURCE_MODE = "chatgpt_captures";

    LLMR.__overlayState = LLMR.__overlayState || {
        queueGroupBySession: {},
        nextDraftBySessionGroup: {},
        nextDraftInFlightByKey: {},
        pendingInsertedDeliveryIds: {},
        dispatchProviders: [],
        dispatchProvidersCachedAt: 0,
        selectedDispatchProviderId: null,
        postInsertRefreshTimer: null,
        queueSourceMode: "all_insertable",
        routeSourceKind: "latest_user",
        routeTargetKind: "local_draft",
        selectedDraftById: {},
        lastQueueDrafts: [],
        routeActionLocks: {},
        currentDisplayLabel: null,
        currentKnownSessionCachedAt: 0,
        liveChatGptSessions: [],
        liveChatGptSessionsCachedAt: 0,
        liveChatGptSessionsInFlight: null,
        knownProviderSessions: [],
        knownProviderSessionsCachedAt: 0,
        sessionAliasSaveInFlight: false,
        sessionAliasDraftBySession: {},
        sessionAliasEditingSessionId: null,
        sessionAliasDirty: false,
        sessionAliasLastInputAt: 0,
        routePanelRenderDeferred: false,
        routeTargetLabelByKey: {},
        routeTargetLastSeenByKey: {},
        routeTargetUserSelectedAt: 0,
        routeTargetEditing: false,
        routeTargetSelectionBySessionGroup: {},
        routeTargetLastSeenGroupBySession: {},
        promptWrappers: [],
        promptWrappersCachedAt: 0,
        promptWrapperSelectionsBySessionGroup: {},
        promptWrapperInFlight: null
    };

    LLMR.__overlayState.queueGroupBySession = LLMR.__overlayState.queueGroupBySession || {};
    LLMR.__overlayState.nextDraftBySessionGroup = LLMR.__overlayState.nextDraftBySessionGroup || {};
    LLMR.__overlayState.nextDraftInFlightByKey = LLMR.__overlayState.nextDraftInFlightByKey || {};
    LLMR.__overlayState.pendingInsertedDeliveryIds = LLMR.__overlayState.pendingInsertedDeliveryIds || {};
    LLMR.__overlayState.dispatchProviders = LLMR.__overlayState.dispatchProviders || [];
    LLMR.__overlayState.dispatchProvidersCachedAt = LLMR.__overlayState.dispatchProvidersCachedAt || 0;
    LLMR.__overlayState.selectedDispatchProviderId = LLMR.__overlayState.selectedDispatchProviderId || null;
    LLMR.__overlayState.postInsertRefreshTimer = LLMR.__overlayState.postInsertRefreshTimer || null;
    LLMR.__overlayState.queueSourceMode = LLMR.__overlayState.queueSourceMode || "all_insertable";
    LLMR.__overlayState.routeSourceKind = LLMR.__overlayState.routeSourceKind || "latest_user";
    LLMR.__overlayState.routeTargetKind = LLMR.__overlayState.routeTargetKind || "local_draft";
    LLMR.__overlayState.selectedDraftById = LLMR.__overlayState.selectedDraftById || {};
    LLMR.__overlayState.lastQueueDrafts = LLMR.__overlayState.lastQueueDrafts || [];
    LLMR.__overlayState.routeActionLocks = LLMR.__overlayState.routeActionLocks || {};
    LLMR.__overlayState.currentDisplayLabel = LLMR.__overlayState.currentDisplayLabel || null;
    LLMR.__overlayState.currentKnownSessionCachedAt = LLMR.__overlayState.currentKnownSessionCachedAt || 0;
    LLMR.__overlayState.liveChatGptSessions = LLMR.__overlayState.liveChatGptSessions || [];
    LLMR.__overlayState.liveChatGptSessionsCachedAt = LLMR.__overlayState.liveChatGptSessionsCachedAt || 0;
    LLMR.__overlayState.liveChatGptSessionsInFlight = LLMR.__overlayState.liveChatGptSessionsInFlight || null;
    LLMR.__overlayState.knownProviderSessions = LLMR.__overlayState.knownProviderSessions || [];
    LLMR.__overlayState.knownProviderSessionsCachedAt = LLMR.__overlayState.knownProviderSessionsCachedAt || 0;
    LLMR.__overlayState.sessionAliasSaveInFlight = Boolean(LLMR.__overlayState.sessionAliasSaveInFlight);
    LLMR.__overlayState.sessionAliasDraftBySession = LLMR.__overlayState.sessionAliasDraftBySession || {};
    LLMR.__overlayState.sessionAliasEditingSessionId = LLMR.__overlayState.sessionAliasEditingSessionId || null;
    LLMR.__overlayState.sessionAliasDirty = Boolean(LLMR.__overlayState.sessionAliasDirty);
    LLMR.__overlayState.sessionAliasLastInputAt = LLMR.__overlayState.sessionAliasLastInputAt || 0;
    LLMR.__overlayState.routePanelRenderDeferred = Boolean(LLMR.__overlayState.routePanelRenderDeferred);
    LLMR.__overlayState.routeTargetLabelByKey = LLMR.__overlayState.routeTargetLabelByKey || {};
    LLMR.__overlayState.routeTargetLastSeenByKey = LLMR.__overlayState.routeTargetLastSeenByKey || {};
    LLMR.__overlayState.routeTargetUserSelectedAt = LLMR.__overlayState.routeTargetUserSelectedAt || 0;
    LLMR.__overlayState.routeTargetEditing = Boolean(LLMR.__overlayState.routeTargetEditing);
    LLMR.__overlayState.routeTargetSelectionBySessionGroup = LLMR.__overlayState.routeTargetSelectionBySessionGroup || {};
    LLMR.__overlayState.routeTargetLastSeenGroupBySession = LLMR.__overlayState.routeTargetLastSeenGroupBySession || {};
    LLMR.__overlayState.promptWrappers = LLMR.__overlayState.promptWrappers || [];
    LLMR.__overlayState.promptWrappersCachedAt = LLMR.__overlayState.promptWrappersCachedAt || 0;
    LLMR.__overlayState.promptWrapperSelectionsBySessionGroup = LLMR.__overlayState.promptWrapperSelectionsBySessionGroup || {};
    LLMR.__overlayState.promptWrapperInFlight = LLMR.__overlayState.promptWrapperInFlight || null;
    LLMR.__overlayState.routeSetupSections = LLMR.__overlayState.routeSetupSections || {
        identity: true,
        source: true,
        target: true,
        wrapper: false
    };
    LLMR.__overlayState.routeSetupSectionsLoaded = Boolean(LLMR.__overlayState.routeSetupSectionsLoaded);
    LLMR.__overlayState.routePanelQueueGroups = LLMR.__overlayState.routePanelQueueGroups || [];
    LLMR.__overlayState.routePanelQueueGroupsCachedAt = LLMR.__overlayState.routePanelQueueGroupsCachedAt || 0;
    LLMR.__overlayState.routePanelLastSignature = LLMR.__overlayState.routePanelLastSignature || null;

    function byId(id) {
        return document.getElementById(id);
    }

    function escapeHtml(value) {
        return String(value ?? "")
            .replace(/&/g, "&amp;")
            .replace(/</g, "&lt;")
            .replace(/>/g, "&gt;")
            .replace(/"/g, "&quot;")
            .replace(/'/g, "&#39;");
    }

    function setResult(text) {
        const result = byId("llmr-result");
        if (result) result.textContent = text;
    }

    function currentSession() {
        return LLMR.ChatGPTAdapter.getSessionIdentity();
    }

    function fallbackSessionLabel(session = currentSession()) {
        return LLMR.ChatGPTAdapter.getSessionLabel() || session.conversation_title || session.conversation_id || session.source_session_id;
    }

    function currentSessionLabel() {
        return LLMR.__overlayState.currentDisplayLabel || fallbackSessionLabel();
    }

    function aliasDraftForSession(session = currentSession()) {
        const id = session?.source_session_id;
        if (!id) return "";
        return Object.prototype.hasOwnProperty.call(LLMR.__overlayState.sessionAliasDraftBySession, id)
            ? LLMR.__overlayState.sessionAliasDraftBySession[id]
            : "";
    }

    function aliasEditActive(session = currentSession()) {
        return Boolean(
            session?.source_session_id &&
            LLMR.__overlayState.sessionAliasEditingSessionId === session.source_session_id &&
            LLMR.__overlayState.sessionAliasDirty
        );
    }

    function beginAliasEdit(session = currentSession(), value = null) {
        if (!session?.source_session_id) return;
        LLMR.__overlayState.sessionAliasEditingSessionId = session.source_session_id;
        if (value !== null) {
            LLMR.__overlayState.sessionAliasDraftBySession[session.source_session_id] = String(value || "");
        }
        LLMR.__overlayState.sessionAliasDirty = true;
        LLMR.__overlayState.sessionAliasLastInputAt = nowMs();
    }

    function updateAliasDraft(value, session = currentSession()) {
        if (!session?.source_session_id) return;
        LLMR.__overlayState.sessionAliasDraftBySession[session.source_session_id] = String(value || "");
        LLMR.__overlayState.sessionAliasEditingSessionId = session.source_session_id;
        LLMR.__overlayState.sessionAliasDirty = true;
        LLMR.__overlayState.sessionAliasLastInputAt = nowMs();
    }

    function clearAliasDraft(session = currentSession()) {
        if (session?.source_session_id) {
            delete LLMR.__overlayState.sessionAliasDraftBySession[session.source_session_id];
        }
        if (LLMR.__overlayState.sessionAliasEditingSessionId === session?.source_session_id) {
            LLMR.__overlayState.sessionAliasEditingSessionId = null;
        }
        LLMR.__overlayState.sessionAliasDirty = false;
    }

    function aliasInputValueForRender(session = currentSession()) {
        const id = session?.source_session_id;
        if (id && Object.prototype.hasOwnProperty.call(LLMR.__overlayState.sessionAliasDraftBySession, id)) {
            return aliasDraftForSession(session);
        }
        return currentSessionLabel();
    }

    function knownSessionById(sourceSessionId) {
        if (!sourceSessionId) return null;
        return (LLMR.__overlayState.knownProviderSessions || [])
            .find(item => item.source_session_id === sourceSessionId) || null;
    }

    function resolveKnownSessionLabel(known, session = currentSession()) {
        if (known?.label_source === "user_saved" && known.label) return known.label;
        if (known?.manual_alias) return known.manual_alias;
        if (session?.manual_alias) return session.manual_alias;
        if (session?.label_source === "user_saved" && session.label) return session.label;
        if (session?.inferred_label) return session.inferred_label;
        if (known?.inferred_label) return known.inferred_label;
        if (known?.conversation_title) return known.conversation_title;
        if (known?.label) return known.label;
        return fallbackSessionLabel(session);
    }

    async function refreshKnownProviderSessions({force = false} = {}) {
        const age = nowMs() - (LLMR.__overlayState.knownProviderSessionsCachedAt || 0);
        if (!force && age < LIVE_CHATGPT_SESSIONS_CACHE_TTL_MS && Array.isArray(LLMR.__overlayState.knownProviderSessions)) {
            return LLMR.__overlayState.knownProviderSessions;
        }
        try {
            const detail = await LLMR.statusDetail();
            LLMR.__overlayState.knownProviderSessions = detail.provider_sessions || [];
            LLMR.__overlayState.knownProviderSessionsCachedAt = nowMs();
            return LLMR.__overlayState.knownProviderSessions;
        } catch (err) {
            console.debug("[local_llm_router] provider session refresh failed", err);
            return LLMR.__overlayState.knownProviderSessions || [];
        }
    }

    async function refreshCurrentDisplayLabel({force = false} = {}) {
        const session = currentSession();
        try {
            await refreshKnownProviderSessions({force});
            const known = knownSessionById(session.source_session_id);
            const label = resolveKnownSessionLabel(known, session);
            LLMR.__overlayState.currentDisplayLabel = label;
            LLMR.__overlayState.currentKnownSessionCachedAt = Date.now();
            return label;
        } catch (_) {
            const label = fallbackSessionLabel(session);
            LLMR.__overlayState.currentDisplayLabel = label;
            return label;
        }
    }

    async function saveCurrentSessionAlias(label, {source = "route_panel"} = {}) {
        const session = currentSession();
        const cleanLabel = LLMR.cleanText(label || aliasDraftForSession(session) || "");
        if (!cleanLabel) {
            setResult("enter a session name before saving");
            return {ok: false, error: "missing session label"};
        }

        const previousLabel = LLMR.__overlayState.currentDisplayLabel;
        updateAliasDraft(cleanLabel, session);
        LLMR.__overlayState.currentDisplayLabel = cleanLabel;
        LLMR.__overlayState.sessionAliasSaveInFlight = true;
        updateSessionBadge({refreshGroup: false}).catch(() => {
        });
        renderRoutePanel({force: true, reason: "alias-save-start"});

        try {
            const response = await LLMR.setSessionLabel({
                sourceSessionId: session.source_session_id,
                provider: session.provider,
                label: cleanLabel,
                labelSource: "user_saved"
            });
            await refreshKnownProviderSessions({force: true});
            await requestLiveChatGptSessions({force: true});
            LLMR.__overlayState.currentDisplayLabel = response.label || cleanLabel;
            clearAliasDraft(session);
            await updateSessionBadge({refreshGroup: true});
            renderRoutePanel({force: true, reason: "alias-save-success"});
            setResult(`saved session name: ${response.label || cleanLabel}`);
            return {ok: true, source, response};
        } catch (err) {
            LLMR.__overlayState.currentDisplayLabel = previousLabel || fallbackSessionLabel(session);
            updateAliasDraft(cleanLabel, session);
            await updateSessionBadge({refreshGroup: false}).catch(() => {
            });
            renderRoutePanel({force: true, reason: "alias-save-failed"});
            setResult(`session name save failed; typed name kept for retry: ${err}`);
            return {ok: false, error: String(err)};
        } finally {
            LLMR.__overlayState.sessionAliasSaveInFlight = false;
        }
    }

    async function currentDisconnected() {
        const session = currentSession();
        return LLMR.isSessionDisconnected(session.source_session_id);
    }

    function nowMs() {
        return Date.now();
    }

    function queueGroupCacheEntry(sessionId) {
        const entry = LLMR.__overlayState.queueGroupBySession[sessionId];
        if (!entry) return null;
        if (nowMs() - entry.cachedAt > QUEUE_GROUP_CACHE_TTL_MS) return null;
        return entry;
    }

    function staleQueueGroupCacheEntry(sessionId) {
        const entry = LLMR.__overlayState.queueGroupBySession[sessionId];
        return entry?.group ? entry : null;
    }

    function setCachedQueueGroup(sessionId, group) {
        if (!sessionId || !group) return;
        LLMR.__overlayState.queueGroupBySession[sessionId] = {
            group,
            cachedAt: nowMs()
        };
    }

    function invalidateQueueGroupCache(sessionId = null) {
        if (sessionId) {
            delete LLMR.__overlayState.queueGroupBySession[sessionId];
            return;
        }
        LLMR.__overlayState.queueGroupBySession = {};
    }

    function nextDraftCacheKey(sessionId, groupId, sourceMode = null) {
        return `${sessionId || "unknown"}::${groupId || "default"}::${sourceMode || LLMR.__overlayState.queueSourceMode || "all_insertable"}`;
    }

    function invalidateNextDraftCache(sessionId = null, groupId = null) {
        if (!sessionId) {
            LLMR.__overlayState.nextDraftBySessionGroup = {};
            return;
        }

        if (groupId) {
            const prefix = `${sessionId || "unknown"}::${groupId || "default"}::`;
            for (const key of Object.keys(LLMR.__overlayState.nextDraftBySessionGroup)) {
                if (key.startsWith(prefix)) delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            }
            return;
        }

        for (const key of Object.keys(LLMR.__overlayState.nextDraftBySessionGroup)) {
            if (key.startsWith(`${sessionId}::`)) {
                delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            }
        }
    }

    function markPendingInserted(deliveryId) {
        if (!deliveryId) return;
        LLMR.__overlayState.pendingInsertedDeliveryIds[deliveryId] = {
            markedAt: nowMs()
        };
    }

    function clearPendingInserted(deliveryId) {
        if (!deliveryId) return;
        delete LLMR.__overlayState.pendingInsertedDeliveryIds[deliveryId];
    }

    function prunePendingInserted(maxAgeMs = 120000) {
        const cutoff = nowMs() - maxAgeMs;
        for (const [deliveryId, entry] of Object.entries(LLMR.__overlayState.pendingInsertedDeliveryIds)) {
            if (!entry?.markedAt || entry.markedAt < cutoff) {
                delete LLMR.__overlayState.pendingInsertedDeliveryIds[deliveryId];
            }
        }
    }

    function isPendingInserted(deliveryId) {
        prunePendingInserted();
        return Boolean(deliveryId && LLMR.__overlayState.pendingInsertedDeliveryIds[deliveryId]);
    }

    function filterUsableDrafts(drafts) {
        return (drafts || []).filter(draft => !isPendingInserted(draft.delivery_id));
    }

    async function fetchQueueGroup(session = currentSession()) {
        const response = await LLMR.getSessionQueueGroup({
            sourceSessionId: session.source_session_id,
            provider: session.provider,
            label: currentSessionLabel()
        });
        setCachedQueueGroup(session.source_session_id, response.queue_group);
        return response.queue_group;
    }

    async function currentQueueGroup({force = false} = {}) {
        const session = currentSession();
        if (!force) {
            const cached = queueGroupCacheEntry(session.source_session_id);
            if (cached?.group) return cached.group;
        }
        return fetchQueueGroup(session);
    }

    function applyQueueGroupBadge(sessionId, group) {
        const groupBadge = byId("llmr-queue-group");
        if (!groupBadge || !group) return;

        const activeSession = currentSession();
        if (activeSession.source_session_id !== sessionId) return;

        groupBadge.textContent = `group: ${group.name}`;
        groupBadge.title = group.queue_group_id;
        const mini = byId("llmr-mini");
        const body = byId("llmr-body");
        if (mini && body?.style.display === "none") {
            const shortGroup = String(group.name || "group").length > 18 ? `${String(group.name).slice(0, 17)}…` : String(group.name || "group");
            mini.textContent = `Expand · ${shortGroup}`;
            mini.title = `Expand overlay · group: ${group.name}`;
        }
    }

    function refreshQueueGroupBadge({force = false} = {}) {
        const session = currentSession();
        const cached = !force ? queueGroupCacheEntry(session.source_session_id) : null;

        if (cached?.group) {
            applyQueueGroupBadge(session.source_session_id, cached.group);
            return;
        }

        const groupBadge = byId("llmr-queue-group");
        if (groupBadge) {
            groupBadge.textContent = "group: refreshing…";
            groupBadge.title = session.source_session_id;
        }

        fetchQueueGroup(session)
            .then(group => applyQueueGroupBadge(session.source_session_id, group))
            .catch(err => {
                const current = currentSession();
                if (current.source_session_id !== session.source_session_id) return;
                const badge = byId("llmr-queue-group");
                if (badge) {
                    badge.textContent = "group: unavailable";
                    badge.title = String(err);
                }
            });
    }

    async function updateSessionBadge({refreshGroup = false} = {}) {
        const badge = byId("llmr-session");
        if (!badge) return;

        try {
            const session = currentSession();
            const label = await refreshCurrentDisplayLabel();
            badge.textContent = `session: ${label}`;
            badge.title = session.source_session_id;

            refreshQueueGroupBadge({force: refreshGroup});
        } catch (err) {
            badge.textContent = "session: unavailable";
            badge.title = String(err);
            const groupBadge = byId("llmr-queue-group");
            if (groupBadge) groupBadge.textContent = "group: unavailable";
        }
    }

    function cacheNextDraft(sessionId, groupId, next, sourceMode = null) {
        const key = nextDraftCacheKey(sessionId, groupId, sourceMode);

        if (!next?.found || !next?.draft || isPendingInserted(next.draft.delivery_id)) {
            delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            return;
        }

        LLMR.__overlayState.nextDraftBySessionGroup[key] = {
            next,
            cachedAt: nowMs()
        };
    }

    function cachedNextDraft(sessionId, groupId, sourceMode = null) {
        const key = nextDraftCacheKey(sessionId, groupId, sourceMode);
        const entry = LLMR.__overlayState.nextDraftBySessionGroup[key];
        if (!entry) return null;
        if (nowMs() - entry.cachedAt > NEXT_DRAFT_CACHE_TTL_MS) {
            delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            return null;
        }
        return entry.next;
    }

    async function fetchNextDraftForSessionGroup(session, group, {force = false, sourceMode = null} = {}) {
        const effectiveSourceMode = sourceMode || queueSourceMode();
        const key = nextDraftCacheKey(session.source_session_id, group.queue_group_id, effectiveSourceMode);

        if (!force) {
            const cached = cachedNextDraft(session.source_session_id, group.queue_group_id, effectiveSourceMode);
            if (cached) return cached;
        }

        if (LLMR.__overlayState.nextDraftInFlightByKey[key]) {
            return LLMR.__overlayState.nextDraftInFlightByKey[key];
        }

        const promise = LLMR.getNextDraft({
            excludeSourceSessionId: session.source_session_id,
            provider: providerFilterForSourceMode(effectiveSourceMode),
            queueGroupId: group.queue_group_id
        }).then(async next => {
            if (next?.found && next?.draft && (!draftMatchesSourceMode(next.draft, effectiveSourceMode) || isPendingInserted(next.draft.delivery_id))) {
                const drafts = filterDraftsForSourceMode(filterUsableDrafts(await LLMR.getQueuedDrafts({
                    excludeSourceSessionId: session.source_session_id,
                    provider: providerFilterForSourceMode(effectiveSourceMode),
                    queueGroupId: group.queue_group_id
                })), effectiveSourceMode);

                next = drafts.length
                    ? {found: true, draft: drafts[0]}
                    : {
                        found: false,
                        draft: null,
                        reason: "no usable queued draft after local pending-insert/source-mode filter"
                    };
            }

            cacheNextDraft(session.source_session_id, group.queue_group_id, next, effectiveSourceMode);
            return next;
        }).finally(() => {
            delete LLMR.__overlayState.nextDraftInFlightByKey[key];
        });

        LLMR.__overlayState.nextDraftInFlightByKey[key] = promise;
        return promise;
    }

    function prefetchNextDraft(reason = "background", {force = false, sourceMode = null} = {}) {
        const session = currentSession();

        currentQueueGroup()
            .then(group => fetchNextDraftForSessionGroup(session, group, {force, sourceMode}))
            .catch(err => {
                console.debug("[local_llm_router] next draft prefetch skipped", reason, err);
            });
    }

    function scheduleQueueRefreshAfterInsert(reason = "post-insert") {
        if (LLMR.__overlayState.postInsertRefreshTimer) {
            clearTimeout(LLMR.__overlayState.postInsertRefreshTimer);
        }

        LLMR.__overlayState.postInsertRefreshTimer = setTimeout(() => {
            LLMR.__overlayState.postInsertRefreshTimer = null;

            updateSessionBadge({refreshGroup: false}).catch(() => {
            });

            if (byId("llmr-queue-panel")?.style.display !== "none") {
                loadQueue({silent: true}).catch(err => {
                    console.warn("[local_llm_router] post-insert queue refresh failed", reason, err);
                });
            } else {
                prefetchNextDraft(reason);
            }
        }, POST_INSERT_QUEUE_REFRESH_DELAY_MS);
    }

    function postInsertBookkeeping(draft, inserted, session) {
        LLMR.markDraftInserted(draft.delivery_id, {
            target_session_id: session.source_session_id,
            target_provider: session.provider,
            target_conversation_id: session.conversation_id,
            target_gizmo_id: session.gizmo_id,
            metadata: {
                adapter_method: inserted.method,
                source_session_id: draft.source_session_id,
                selected_insert: true,
                queue_group_id: draft.queue_group_id
            }
        }).then(update => {
            if (update?.ok) {
                clearPendingInserted(draft.delivery_id);
                return;
            }

            console.warn("[local_llm_router] markDraftInserted returned non-ok", update);
            setResult(
                `inserted text, but backend status update did not confirm\n` +
                `delivery: ${LLMR.shortId(draft.delivery_id)}`
            );
        }).catch(err => {
            console.warn("[local_llm_router] markDraftInserted failed after visible insertion", err);
            setResult(
                `inserted text, but backend status update failed\n` +
                `delivery: ${LLMR.shortId(draft.delivery_id)}\n` +
                `${String(err)}`
            );
        }).finally(() => {
            scheduleQueueRefreshAfterInsert("mark-inserted-complete");
        });
    }

    async function refreshOverlayState(reason = "manual", {forceLiveSessions = false} = {}) {
        const session = currentSession();
        const previousSessionId = LLMR.__overlayLastSessionId || null;
        const sessionChanged = Boolean(previousSessionId && previousSessionId !== session.source_session_id);

        LLMR.__overlayLastSessionId = session.source_session_id;

        await ensureOverlay(false);
        await Promise.allSettled([
            refreshKnownProviderSessions({force: forceLiveSessions || sessionChanged}),
            requestLiveChatGptSessions({force: forceLiveSessions || sessionChanged}),
            loadDispatchProviders({force: forceLiveSessions || sessionChanged}),
            loadPromptWrappers({force: forceLiveSessions || sessionChanged}),
            loadPromptWrapperSelections(),
            loadRouteSetupSections(),
            loadRoutePanelQueueGroups({force: forceLiveSessions || sessionChanged})
        ]);
        await updateSessionBadge({refreshGroup: sessionChanged});
        renderRoutePanelIfSafe("refresh-overlay-state");

        const queuePanel = byId("llmr-queue-panel");
        const groupPanel = byId("llmr-group-panel");

        if (sessionChanged) {
            if (queuePanel) queuePanel.style.display = "none";
            if (groupPanel) groupPanel.style.display = "none";
            const list = byId("llmr-queue-list");
            if (list) list.innerHTML = "";
            setResult("session changed; overlay state refreshed.");
        } else if (queuePanel?.style.display !== "none") {
            await loadQueue();
            setResult("overlay refreshed; session unchanged.");
        } else {
            prefetchNextDraft("overlay-refresh");
            setResult("overlay refreshed; session unchanged.");
        }

        return {
            ok: true,
            overlay_version: OVERLAY_VERSION,
            reason,
            session_changed: sessionChanged,
            previous_source_session_id: previousSessionId,
            source_session_id: session.source_session_id,
            session
        };
    }

    LLMR.__overlayRefreshState = refreshOverlayState;

    function clampPosition(left, top, box) {
        const rect = box.getBoundingClientRect();
        const margin = 8;
        const maxLeft = Math.max(margin, window.innerWidth - rect.width - margin);
        const maxTop = Math.max(margin, window.innerHeight - rect.height - margin);

        return {
            left: Math.min(Math.max(margin, left), maxLeft),
            top: Math.min(Math.max(margin, top), maxTop)
        };
    }

    function applyPosition(box, position) {
        if (!position || typeof position.left !== "number" || typeof position.top !== "number") {
            box.style.right = `${DEFAULT_OFFSET.right}px`;
            box.style.bottom = `${DEFAULT_OFFSET.bottom}px`;
            box.style.left = "auto";
            box.style.top = "auto";
            return;
        }

        const next = clampPosition(position.left, position.top, box);
        box.style.left = `${next.left}px`;
        box.style.top = `${next.top}px`;
        box.style.right = "auto";
        box.style.bottom = "auto";
    }

    async function safeOverlayStorageSet(key, value) {
        try {
            return await LLMR.storageSet(key, value);
        } catch (err) {
            console.debug("[local_llm_router] overlay storage write skipped", key, err);
            return false;
        }
    }

    async function saveCurrentPosition(box) {
        const rect = box.getBoundingClientRect();
        await safeOverlayStorageSet(OVERLAY_POSITION_KEY, {
            left: Math.round(rect.left),
            top: Math.round(rect.top)
        });
    }

    async function resetPosition(box) {
        await safeOverlayStorageSet(OVERLAY_POSITION_KEY, null);
        applyPosition(box, null);
        setResult("overlay position reset");
    }

    function installDrag(box) {
        const handle = byId("llmr-handle");
        if (!handle) return;

        handle.addEventListener("dblclick", async event => {
            event.preventDefault();
            await resetPosition(box);
        });

        handle.addEventListener("mousedown", event => {
            if (event.button !== 0) return;

            event.preventDefault();

            const rect = box.getBoundingClientRect();
            const start = {
                mouseX: event.clientX,
                mouseY: event.clientY,
                left: rect.left,
                top: rect.top
            };

            box.style.right = "auto";
            box.style.bottom = "auto";
            box.style.left = `${rect.left}px`;
            box.style.top = `${rect.top}px`;
            document.body.style.userSelect = "none";

            function move(moveEvent) {
                const rawLeft = start.left + (moveEvent.clientX - start.mouseX);
                const rawTop = start.top + (moveEvent.clientY - start.mouseY);
                const next = clampPosition(rawLeft, rawTop, box);
                box.style.left = `${next.left}px`;
                box.style.top = `${next.top}px`;
            }

            async function up() {
                document.removeEventListener("mousemove", move);
                document.body.style.userSelect = "";
                await saveCurrentPosition(box);
            }

            document.addEventListener("mousemove", move);
            document.addEventListener("mouseup", up, {once: true});
        });
    }

    async function setCollapsed(collapsed) {
        await safeOverlayStorageSet(LLMR.OVERLAY_COLLAPSED_KEY, Boolean(collapsed));
        applyCollapsed(Boolean(collapsed));
    }

    function applyCollapsed(collapsed) {
        const body = byId("llmr-body");
        const toggle = byId("llmr-mini");
        const box = byId("llmr-overlay");

        if (!body || !toggle || !box) return;

        body.style.display = collapsed ? "none" : "block";
        if (collapsed) {
            const groupText = (byId("llmr-queue-group")?.textContent || "group: unknown").replace(/^group:\s*/i, "");
            const shortGroup = groupText.length > 18 ? `${groupText.slice(0, 17)}…` : groupText;
            toggle.textContent = `Expand · ${shortGroup}`;
            toggle.title = `Expand overlay · group: ${groupText}`;
        } else {
            toggle.textContent = "Fold";
            toggle.title = "Fold overlay";
        }
        box.style.minWidth = collapsed ? "205px" : "220px";
    }

    function draftLabel(draft) {
        const title = draft.conversation_title || "Untitled";
        const turn = draft.turn_testid || "no-turn";
        return `${title} · ${LLMR.shortId(draft.conversation_id || "", 8, 5)} · ${turn}`;
    }

    function draftMeta(draft) {
        return `${draft.body_length} chars · ${LLMR.shortId(draft.source_session_id, 12, 7)} · ${draft.body_hash}`;
    }

    function extractBodyOnly(wrapped) {
        const text = String(wrapped || "");
        const start = "--- start content ---";
        const end = "--- end content ---";
        const startIndex = text.indexOf(start);
        const endIndex = text.lastIndexOf(end);
        if (startIndex >= 0 && endIndex > startIndex) {
            return text.slice(startIndex + start.length, endIndex).replace(/^\n+|\n+$/g, "");
        }
        return text;
    }

    function providerLabel(provider) {
        if (!provider) return "No provider";
        return provider.label || provider.provider_id;
    }

    function liveSessionTabId(item) {
        const raw = item?.tab?.id ?? item?.tab_id ?? item?.target_tab_id;
        const id = Number(raw);
        return Number.isFinite(id) && id > 0 ? id : null;
    }

    function liveSessionLabel(item) {
        const session = item?.session || {};
        const known = knownSessionById(session.source_session_id);
        const knownLabel = resolveKnownSessionLabel(known, session);
        const itemLabel = item?.label || item?.session_label;
        const inferred = item?.inferred_label || session.inferred_label;
        const title = session.conversation_title || item?.tab?.title;
        const fallback = session.source_session_id || item?.tab?.url || "ChatGPT session";
        return LLMR.cleanText(knownLabel || itemLabel || inferred || title || fallback);
    }

    function liveSessionGroupLabel(item) {
        return item?.queue_group?.name || item?.queue_group_name || "unknown group";
    }

    function liveSessionSummary(item) {
        const label = liveSessionLabel(item);
        const group = liveSessionGroupLabel(item);
        const tab = liveSessionTabId(item);
        const state = item?.tab?.active ? "current tab" : "live";
        return `${label} · ${group} · ${state}${tab ? ` · tab ${tab}` : ""}`;
    }

    async function requestLiveChatGptSessions({force = false} = {}) {
        const age = nowMs() - (LLMR.__overlayState.liveChatGptSessionsCachedAt || 0);
        if (!force && age < LIVE_CHATGPT_SESSIONS_CACHE_TTL_MS && Array.isArray(LLMR.__overlayState.liveChatGptSessions)) {
            return LLMR.__overlayState.liveChatGptSessions;
        }
        if (LLMR.__overlayState.liveChatGptSessionsInFlight) return LLMR.__overlayState.liveChatGptSessionsInFlight;

        const promise = refreshKnownProviderSessions({force}).then(() => new Promise(resolve => {
            if (typeof chrome === "undefined" || !chrome.runtime?.sendMessage) {
                resolve({ok: false, sessions: [], error: "chrome runtime unavailable"});
                return;
            }
            chrome.runtime.sendMessage({type: "LLMR_LIST_LIVE_CHATGPT_SESSIONS"}, response => {
                if (chrome.runtime.lastError) {
                    resolve({ok: false, sessions: [], error: chrome.runtime.lastError.message});
                    return;
                }
                resolve(response || {ok: false, sessions: [], error: "no response"});
            });
        })).then(response => {
            const sessions = (response.sessions || [])
                .filter(item => item && item.ok !== false)
                .filter(item => liveSessionTabId(item))
                .filter(item => !item.disconnected)
                .sort((a, b) => {
                    if (a?.tab?.active && !b?.tab?.active) return -1;
                    if (!a?.tab?.active && b?.tab?.active) return 1;
                    return liveSessionLabel(a).localeCompare(liveSessionLabel(b));
                });
            LLMR.__overlayState.liveChatGptSessions = sessions;
            LLMR.__overlayState.liveChatGptSessionsCachedAt = nowMs();
            return sessions;
        }).finally(() => {
            LLMR.__overlayState.liveChatGptSessionsInFlight = null;
        });

        LLMR.__overlayState.liveChatGptSessionsInFlight = promise;
        return promise;
    }

    function liveChatGptTargetOptions() {
        const seen = new Set();
        return (LLMR.__overlayState.liveChatGptSessions || [])
            .filter(item => liveSessionTabId(item))
            .filter(item => {
                const key = String(liveSessionTabId(item));
                if (seen.has(key)) return false;
                seen.add(key);
                return true;
            })
            .map(item => ({
                value: `chatgpt_tab:${liveSessionTabId(item)}`,
                label: `ChatGPT: ${liveSessionLabel(item)}`,
                detail: liveSessionSummary(item),
                item
            }));
    }

    function sendRuntimeMessage(payload) {
        return new Promise(resolve => {
            if (typeof chrome === "undefined" || !chrome.runtime?.sendMessage) {
                resolve({ok: false, error: "chrome runtime unavailable"});
                return;
            }
            chrome.runtime.sendMessage(payload, response => {
                if (chrome.runtime.lastError) {
                    resolve({ok: false, error: chrome.runtime.lastError.message});
                    return;
                }
                resolve(response || {ok: false, error: "no response"});
            });
        });
    }

    function dispatchCapableProviders() {
        return (LLMR.__overlayState.dispatchProviders || [])
            .filter(provider => provider.enabled)
            .filter(provider => provider.capabilities?.can_dispatch_request)
            .filter(provider => provider.provider_type !== "local_draft")
            .sort((a, b) => String(providerLabel(a)).localeCompare(String(providerLabel(b))));
    }

    function queueSourceMode() {
        return LLMR.__overlayState.queueSourceMode || "all_insertable";
    }

    function queueSourceModeLabel(mode = queueSourceMode()) {
        if (mode === "chatgpt_captures") return "ChatGPT captures";
        if (mode === "provider_responses") return "Provider responses";
        return "All insertable";
    }

    function providerFilterForSourceMode(mode = queueSourceMode()) {
        return mode === "chatgpt_captures" ? "chatgpt" : null;
    }

    function draftMatchesSourceMode(draft, mode = queueSourceMode()) {
        if (mode === "chatgpt_captures") return draft.provider === "chatgpt";
        if (mode === "provider_responses") return draft.provider && draft.provider !== "chatgpt";
        return true;
    }

    function filterDraftsForSourceMode(drafts, mode = queueSourceMode()) {
        return (drafts || []).filter(draft => draftMatchesSourceMode(draft, mode));
    }

    function sourceLabelForDraft(draft) {
        const provider = draft.provider || "unknown";
        const role = draft.role || "unknown";
        if (provider === "chatgpt") return `ChatGPT / ${role}`;
        return `${provider} / generated ${role}`;
    }

    function operationLockKey(sourceKind, targetKind) {
        const session = currentSession();
        return `${session.source_session_id}::${LLMR.__overlayState.queueSourceMode || "all"}::${sourceKind}::${targetKind}`;
    }

    function isOperationLocked(key) {
        return Boolean(LLMR.__overlayState.routeActionLocks[key]);
    }

    function setOperationLocked(key, locked) {
        if (locked) {
            LLMR.__overlayState.routeActionLocks[key] = {startedAt: new Date().toISOString()};
        } else {
            delete LLMR.__overlayState.routeActionLocks[key];
        }
    }

    function selectedQueueDraft() {
        const selectedId = LLMR.__overlayState.selectedDraftId;
        return (LLMR.__overlayState.lastQueueDrafts || []).find(draft => draft.delivery_id === selectedId) || null;
    }

    function setSelectedQueueDraft(draft) {
        LLMR.__overlayState.selectedDraftId = draft?.delivery_id || null;
        renderRoutePanel();
    }

    function routeSourceKind() {
        return LLMR.__overlayState.routeSourceKind || "latest_user";
    }

    function currentQueueGroupSnapshot(session = currentSession()) {
        const sessionId = session?.source_session_id;

        const cached = queueGroupCacheEntry(sessionId);
        if (cached?.group) return cached.group;

        const live = (LLMR.__overlayState.liveChatGptSessions || [])
            .find(item => item?.session?.source_session_id === sessionId);
        if (live?.queue_group) return live.queue_group;

        const known = knownSessionById(sessionId);
        if (known?.queue_group_id) {
            return {
                queue_group_id: known.queue_group_id,
                name: known.queue_group_name || known.queue_group_id,
                is_default: known.queue_group_id === "default"
            };
        }

        /*
         * Route-panel rendering must not fall back to Default queue merely
         * because the fresh queue-group TTL has expired and an async refresh is
         * in flight. The group selector and target auto-selection are display
         * surfaces; stale-but-known group identity is safer than a transient
         * default because actions still call currentQueueGroup() for an
         * authoritative fresh value before mutating/insert/routing.
         */
        const stale = staleQueueGroupCacheEntry(sessionId);
        if (stale?.group) return stale.group;

        return {queue_group_id: "default", name: "Default queue", is_default: true};
    }

    function promptWrapperSelectionKey(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        return LLMR.promptWrapperSelectionStorageKey
            ? LLMR.promptWrapperSelectionStorageKey({
                sourceSessionId: session?.source_session_id,
                queueGroupId: group?.queue_group_id
            })
            : `${session?.source_session_id || "global"}::${group?.queue_group_id || "default"}`;
    }

    async function loadPromptWrapperSelections() {
        if (LLMR.getPromptWrapperSelections) {
            LLMR.__overlayState.promptWrapperSelectionsBySessionGroup = await LLMR.getPromptWrapperSelections();
        } else {
            const stored = await LLMR.storageGet("llmr.promptWrapperSelection.v1");
            LLMR.__overlayState.promptWrapperSelectionsBySessionGroup = stored && typeof stored === "object" && !Array.isArray(stored) ? stored : {};
        }
        return LLMR.__overlayState.promptWrapperSelectionsBySessionGroup;
    }

    async function savePromptWrapperSelection({
                                                  enabled,
                                                  wrapperId,
                                                  session = currentSession(),
                                                  group = currentQueueGroupSnapshot(session)
                                              } = {}) {
        const key = promptWrapperSelectionKey(session, group);
        const record = {
            enabled: Boolean(enabled),
            wrapper_id: enabled ? (wrapperId || null) : null,
            updated_at: new Date().toISOString()
        };
        LLMR.__overlayState.promptWrapperSelectionsBySessionGroup[key] = record;
        if (LLMR.setPromptWrapperSelection) {
            await LLMR.setPromptWrapperSelection({
                sourceSessionId: session?.source_session_id,
                queueGroupId: group?.queue_group_id,
                enabled: record.enabled,
                wrapperId: record.wrapper_id
            });
        } else {
            await LLMR.storageSet("llmr.promptWrapperSelection.v1", LLMR.__overlayState.promptWrapperSelectionsBySessionGroup);
        }
        return record;
    }

    function currentPromptWrapperSelection(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        const key = promptWrapperSelectionKey(session, group);
        return LLMR.__overlayState.promptWrapperSelectionsBySessionGroup[key] || {enabled: false, wrapper_id: null};
    }

    async function loadPromptWrappers({force = false} = {}) {
        if (!force && LLMR.__overlayState.promptWrappersCachedAt && nowMs() - LLMR.__overlayState.promptWrappersCachedAt < 30000) {
            return LLMR.__overlayState.promptWrappers || [];
        }
        try {
            const response = await LLMR.listPromptWrappers();
            LLMR.__overlayState.promptWrappers = response.prompt_wrappers || [];
            LLMR.__overlayState.promptWrappersCachedAt = nowMs();
        } catch (err) {
            console.warn("[local_llm_router] prompt wrapper load failed", err);
            LLMR.__overlayState.promptWrappers = LLMR.__overlayState.promptWrappers || [];
        }
        return LLMR.__overlayState.promptWrappers || [];
    }

    function promptWrapperById(wrapperId) {
        return (LLMR.__overlayState.promptWrappers || []).find(item => item.wrapper_id === wrapperId) || null;
    }

    function validPromptWrapperSelection(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        const selection = currentPromptWrapperSelection(session, group);
        if (!selection?.enabled || !selection.wrapper_id) return {enabled: false, wrapper_id: null, label: null};
        const wrapper = promptWrapperById(selection.wrapper_id);
        if (!wrapper) return {enabled: false, wrapper_id: null, label: null, missing_wrapper_id: selection.wrapper_id};
        return {enabled: true, wrapper_id: wrapper.wrapper_id, label: wrapper.label || wrapper.wrapper_id};
    }

    function promptWrapperOptions({source = "overlay"} = {}) {
        const selection = validPromptWrapperSelection();
        if (!selection.enabled) return {};
        return {
            prompt_wrapper_id: selection.wrapper_id,
            prompt_wrapper_label: selection.label,
            prompt_wrapper_source: source
        };
    }

    async function draftWithPromptWrapperForInsert(draft, options = {}) {
        const wrapperId = options?.prompt_wrapper_id || null;
        if (!wrapperId || !draft) return draft;
        const text = draft.wrapped_body_markdown || draft.wrapped_body || draft.body_markdown || draft.body_plain || "";
        const response = await LLMR.applyPromptWrapper({wrapperId, text});
        const promptWrapper = response.metadata || {enabled: true, wrapper_id: wrapperId};
        return {
            ...draft,
            wrapped_body: response.text || "",
            wrapped_body_markdown: response.text || "",
            wrapped_body_plain: response.text || "",
            wrapped_body_html: null,
            wrapped_format_capture: null,
            metadata: {...(draft.metadata || {}), prompt_wrapper: promptWrapper}
        };
    }

    function rememberRouteTargetOption(option) {
        if (!option?.value) return;
        LLMR.__overlayState.routeTargetLabelByKey[option.value] = option.label || option.value;
        LLMR.__overlayState.routeTargetLastSeenByKey[option.value] = nowMs();
    }

    function routeTargetStorageKey(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        return `${session?.source_session_id || "global"}::${group?.queue_group_id || "default"}`;
    }

    function liveGroupMemberTargets(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        const groupId = group?.queue_group_id || "default";
        if (!groupId || groupId === "default") return [];

        const currentId = session?.source_session_id;
        const seen = new Set();
        return (LLMR.__overlayState.liveChatGptSessions || [])
            .filter(item => liveSessionTabId(item))
            .filter(item => item?.session?.source_session_id && item.session.source_session_id !== currentId)
            .filter(item => {
                const itemGroupId = item?.queue_group?.queue_group_id || item?.queue_group_id || null;
                return itemGroupId === groupId;
            })
            .filter(item => {
                const key = String(liveSessionTabId(item));
                if (seen.has(key)) return false;
                seen.add(key);
                return true;
            })
            .sort((a, b) => {
                const aActive = Boolean(a?.tab?.active);
                const bActive = Boolean(b?.tab?.active);
                if (aActive !== bActive) return aActive ? 1 : -1;
                return liveSessionLabel(a).localeCompare(liveSessionLabel(b));
            })
            .map(item => ({
                value: `chatgpt_tab:${liveSessionTabId(item)}`,
                label: `ChatGPT: ${liveSessionLabel(item)}`,
                detail: `Group member · ${liveSessionSummary(item)}`,
                item
            }));
    }

    function preferredGroupTargetOption(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        return liveGroupMemberTargets(session, group)[0] || null;
    }

    function routeTargetSelectionRecord(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        const key = routeTargetStorageKey(session, group);
        return LLMR.__overlayState.routeTargetSelectionBySessionGroup[key] || null;
    }

    function setRouteTargetSelectionRecord(value, {
        userSelected = false,
        session = currentSession(),
        group = currentQueueGroupSnapshot(session),
        reason = "manual"
    } = {}) {
        const target = value || "local_draft";
        const key = routeTargetStorageKey(session, group);
        LLMR.__overlayState.routeTargetKind = target;
        LLMR.__overlayState.routeTargetSelectionBySessionGroup[key] = {
            value: target,
            manual: Boolean(userSelected),
            reason,
            queue_group_id: group?.queue_group_id || "default",
            updated_at: nowMs()
        };
        if (userSelected) LLMR.__overlayState.routeTargetUserSelectedAt = nowMs();
        return target;
    }

    function noteRouteGroupSeen(session = currentSession(), group = currentQueueGroupSnapshot(session)) {
        const sessionId = session?.source_session_id || "global";
        const groupId = group?.queue_group_id || "default";
        const previous = LLMR.__overlayState.routeTargetLastSeenGroupBySession[sessionId];
        LLMR.__overlayState.routeTargetLastSeenGroupBySession[sessionId] = groupId;
        return previous !== groupId;
    }

    function routeTargetKind({targetOptions = null} = {}) {
        const session = currentSession();
        const group = currentQueueGroupSnapshot(session);
        const groupChanged = noteRouteGroupSeen(session, group);
        const record = routeTargetSelectionRecord(session, group);
        const availableValues = new Set((targetOptions || []).map(item => item.value));

        if (record?.manual) {
            return record.value;
        }

        const groupPreferred = preferredGroupTargetOption(session, group);
        if (groupPreferred?.value) {
            if (!record || record.value !== groupPreferred.value || groupChanged) {
                setRouteTargetSelectionRecord(groupPreferred.value, {
                    userSelected: false,
                    session,
                    group,
                    reason: "auto_group_member"
                });
            }
            return groupPreferred.value;
        }

        if (record?.value && (!targetOptions || availableValues.has(record.value))) {
            return record.value;
        }


        return setRouteTargetSelectionRecord("local_draft", {
            userSelected: false,
            session,
            group,
            reason: "default"
        });
    }

    function setRouteTargetKind(value, {userSelected = false} = {}) {
        return setRouteTargetSelectionRecord(value, {
            userSelected,
            reason: userSelected ? "user_selected" : "programmatic"
        });
    }

    function routeTargetProviders() {
        return dispatchCapableProviders();
    }

    function routeTargetLabel(kind = routeTargetKind()) {
        if (kind === "local_draft") return "Local draft inbox";
        if (kind.startsWith("chatgpt_tab:")) {
            const id = Number(kind.slice("chatgpt_tab:".length));
            const match = (LLMR.__overlayState.liveChatGptSessions || []).find(item => liveSessionTabId(item) === id);
            return match ? `ChatGPT: ${liveSessionLabel(match)}` : `ChatGPT tab ${id}`;
        }
        if (kind.startsWith("provider:")) {
            const id = kind.slice("provider:".length);
            const provider = routeTargetProviders().find(item => item.provider_id === id);
            return provider ? providerLabel(provider) : id;
        }
        return kind;
    }

    function routeSourceLabel(kind = routeSourceKind()) {
        if (kind === "latest_assistant") return "Last assistant response";
        if (kind === "selected_draft") return "Selected queued item";
        return "Last user message";
    }

    function latestPayloadForSourceKind(kind) {
        if (kind === "latest_assistant") return getLatestPayloadForRole("assistant");
        if (kind === "latest_user") return getLatestPayloadForRole("user");
        return null;
    }

    async function captureLatestForRoute(kind) {
        const role = kind === "latest_assistant" ? "assistant" : "user";
        const payload = latestPayloadForSourceKind(kind);
        if (!payload) return {ok: false, error: `no ${routeSourceLabel(kind).toLowerCase()} found`};
        const response = await LLMR.postCapture({
            ...payload,
            metadata: {
                ...(payload.metadata || {}),
                route_action: true,
                route_source_kind: kind,
                duplicate_intent: true,
                operator_action_id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now()),
                ...promptWrapperOptions({source: "overlay_capture"})
            }
        });
        invalidateNextDraftCache();
        return {ok: true, role, response};
    }

    async function executeRouteAction() {
        const sourceKind = routeSourceKind();
        const targetKind = routeTargetKind();
        const lockKey = operationLockKey(sourceKind, targetKind);
        const button = byId("llmr-route-execute");
        if (isOperationLocked(lockKey)) {
            setResult("Route action already in progress for this source/target/group.");
            return {ok: false, error: "route action already in progress"};
        }

        setOperationLocked(lockKey, true);
        if (button) {
            button.disabled = true;
            button.textContent = "Routing…";
        }

        try {
            if (await currentDisconnected()) {
                return {ok: false, error: "this session is disconnected"};
            }

            await Promise.allSettled([
                requestLiveChatGptSessions({force: true}),
                loadDispatchProviders({force: true}),
                loadPromptWrappers({force: true})
            ]);
            await updateSessionBadge();
            renderRoutePanel();
            const group = await currentQueueGroup();

            if (targetKind === "local_draft") {
                if (sourceKind === "selected_draft") {
                    const selected = selectedQueueDraft();
                    if (!selected) return {ok: false, error: "select a queued item first"};
                    setResult(`selected queued item is already in local draft queue\nqueue: ${group.name}\ndelivery: ${LLMR.shortId(selected.delivery_id)}`);
                    return {ok: true, mode: "already_queued", draft: selected};
                }
                const captured = await captureLatestForRoute(sourceKind);
                if (!captured.ok) return captured;
                const deliveries = captured.response.delivery_ids || [];
                setResult(`${captured.response.deduped ? "requeued duplicate" : "queued"} ${routeSourceLabel(sourceKind).toLowerCase()}\nqueue: ${group.name}\nroute: ${captured.response.route_decision}\ndeliveries: ${deliveries.map(id => LLMR.shortId(id)).join(", ")}`);
                if (byId("llmr-queue-panel")?.style.display !== "none") await loadQueue({silent: true});
                return {ok: true, mode: "capture_to_local_draft", response: captured.response};
            }

            if (targetKind.startsWith("provider:")) {
                const providerId = targetKind.slice("provider:".length);
                await loadDispatchProviders({force: true});
                const provider = routeTargetProviders().find(item => item.provider_id === providerId) || selectedDispatchProvider();
                if (!provider) return {ok: false, error: "no dispatch-capable provider selected"};

                let draft = null;
                if (sourceKind === "selected_draft") {
                    draft = selectedQueueDraft();
                    if (!draft) return {ok: false, error: "select a queued item first"};
                } else {
                    const captured = await captureLatestForRoute(sourceKind);
                    if (!captured.ok) return captured;
                    const deliveryId = (captured.response.delivery_ids || [])[0];
                    if (!deliveryId) return {ok: false, error: "capture did not create a delivery"};
                    const draftsResponse = await LLMR.listDrafts({
                        includeHandled: true,
                        queueGroupId: group.queue_group_id
                    });
                    draft = (draftsResponse.drafts || []).find(item => item.delivery_id === deliveryId) || null;
                    if (!draft) return {ok: false, error: "captured delivery was not visible in draft list"};
                }

                const response = await LLMR.dispatchToProvider(provider.provider_id, {
                    deliveryId: draft.delivery_id,
                    queueGroupId: draft.queue_group_id || group.queue_group_id,
                    manualConfirmed: true,
                    options: {
                        route_action: true,
                        route_source_kind: sourceKind,
                        route_target_kind: targetKind,
                        ...promptWrapperOptions({source: "overlay_provider_dispatch"}),
                        duplicate_intent: true,
                        operator_action_id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now())
                    }
                });
                invalidateNextDraftCache();
                await loadQueue({silent: true});
                if (response.ok) {
                    const generated = (response.generated_delivery_ids || []).map(id => LLMR.shortId(id)).join(", ") || "none";
                    setResult(`dispatched to ${providerLabel(provider)}\nsource: ${routeSourceLabel(sourceKind)}\nstatus: ${response.status}\ngenerated local draft: ${generated}`);
                } else {
                    setResult(`provider dispatch failed: ${response.message || response.error_code || "unknown error"}`);
                }
                return response;
            }

            if (targetKind.startsWith("chatgpt_tab:")) {
                const targetTabId = Number(targetKind.slice("chatgpt_tab:".length));
                const targetSession = (LLMR.__overlayState.liveChatGptSessions || []).find(item => liveSessionTabId(item) === targetTabId);
                if (!targetSession) return {
                    ok: false,
                    error: "selected ChatGPT target is no longer available; refresh live sessions"
                };

                const selected = sourceKind === "selected_draft" ? selectedQueueDraft() : null;
                if (sourceKind === "selected_draft" && !selected) return {
                    ok: false,
                    error: "select a queued item first"
                };

                const response = await sendRuntimeMessage({
                    type: "LLMR_ROUTE_TO_CHATGPT_TAB",
                    target_tab_id: targetTabId,
                    source_kind: sourceKind,
                    draft: selected || null,
                    allow_same_session: false,
                    options: {
                        route_action: true,
                        route_source_kind: sourceKind,
                        route_target_kind: targetKind,
                        target_label: liveSessionLabel(targetSession),
                        target_source_session_id: targetSession.session?.source_session_id || null,
                        ...promptWrapperOptions({source: "overlay_chatgpt_insert"}),
                        operator_action_id: crypto.randomUUID ? crypto.randomUUID() : String(Date.now())
                    }
                });

                if (response.ok) {
                    const targetLabel = liveSessionLabel(targetSession);
                    setResult(`inserted into ${targetLabel}
source: ${routeSourceLabel(sourceKind)}
review and send manually`);
                } else {
                    setResult(`ChatGPT target route failed: ${response.error || response.response?.error || "unknown"}`);
                }
                return response;
            }

            return {ok: false, error: `unsupported target ${targetKind}`};
        } catch (err) {
            setResult(`route action error: ${err}`);
            throw err;
        } finally {
            setOperationLocked(lockKey, false);
            if (button) {
                button.disabled = false;
                button.textContent = "Route";
            }
            renderRoutePanel();
        }
    }

    function routePanelInteractionActive() {
        const panel = byId("llmr-route-panel");
        const active = document.activeElement;
        if (!panel || !active || !panel.contains(active)) return false;
        const tag = String(active.tagName || "").toUpperCase();
        return ["INPUT", "SELECT", "TEXTAREA", "BUTTON"].includes(tag);
    }

    function routeSetupDefaultSections() {
        return {identity: true, source: true, target: true, wrapper: false};
    }

    function routeSetupSections() {
        return {...routeSetupDefaultSections(), ...(LLMR.__overlayState.routeSetupSections || {})};
    }

    async function loadRouteSetupSections() {
        if (LLMR.__overlayState.routeSetupSectionsLoaded) return routeSetupSections();
        const stored = await LLMR.storageGet(ROUTE_SETUP_SECTIONS_KEY).catch(() => null);
        if (stored && typeof stored === "object" && !Array.isArray(stored)) {
            LLMR.__overlayState.routeSetupSections = {...routeSetupDefaultSections(), ...stored};
        } else {
            LLMR.__overlayState.routeSetupSections = routeSetupDefaultSections();
        }
        LLMR.__overlayState.routeSetupSectionsLoaded = true;
        return routeSetupSections();
    }

    async function saveRouteSetupSections() {
        LLMR.__overlayState.routeSetupSections = routeSetupSections();
        await LLMR.storageSet(ROUTE_SETUP_SECTIONS_KEY, LLMR.__overlayState.routeSetupSections).catch(() => false);
        return LLMR.__overlayState.routeSetupSections;
    }

    async function toggleRouteSetupSection(section) {
        const current = routeSetupSections();
        current[section] = !current[section];
        LLMR.__overlayState.routeSetupSections = current;
        await saveRouteSetupSections();
        renderRoutePanel({force: true, reason: `route-setup-${section}-toggle`});
    }

    async function loadRoutePanelQueueGroups({force = false} = {}) {
        const age = nowMs() - (LLMR.__overlayState.routePanelQueueGroupsCachedAt || 0);
        if (!force && age < ROUTE_PANEL_GROUPS_CACHE_TTL_MS && Array.isArray(LLMR.__overlayState.routePanelQueueGroups) && LLMR.__overlayState.routePanelQueueGroups.length) {
            return LLMR.__overlayState.routePanelQueueGroups;
        }
        try {
            const response = await LLMR.listQueueGroups();
            LLMR.__overlayState.routePanelQueueGroups = response.queue_groups || [];
            LLMR.__overlayState.routePanelQueueGroupsCachedAt = nowMs();
        } catch (err) {
            console.debug("[local_llm_router] route panel group list refresh failed", err);
            LLMR.__overlayState.routePanelQueueGroups = LLMR.__overlayState.routePanelQueueGroups || [];
        }
        return LLMR.__overlayState.routePanelQueueGroups || [];
    }

    function setupStatusTone(tone = "default") {
        const selected = {
            pill: "border-color:#ff74c7;color:#ffe6f5;background:#351225;box-shadow:0 0 0 1px rgba(255,116,199,.16),0 0 14px rgba(255,116,199,.16);",
            section: "border-color:#ff74c7;background:#1d1019;box-shadow:inset 3px 0 0 #ff74c7;",
            header: "background:linear-gradient(90deg,#2a1523 0%,#201621 100%);",
            arrow: "#ff9bd7",
            title: "#ffd7ee",
            summary: "#f0b8dc"
        };
        const unset = {
            pill: "border-color:#ffac5c;color:#ffe5c4;background:#351e0e;box-shadow:0 0 0 1px rgba(255,172,92,.18),0 0 14px rgba(255,172,92,.16);",
            section: "border-color:#ffac5c;background:#21150d;box-shadow:inset 3px 0 0 #ffac5c;",
            header: "background:linear-gradient(90deg,#33200f 0%,#201621 100%);",
            arrow: "#ffc787",
            title: "#ffe1bc",
            summary: "#f0c897"
        };
        const muted = {
            ...selected,
            pill: "border-color:#d85cab;color:#ffd7ee;background:#27111d;box-shadow:0 0 0 1px rgba(216,92,171,.12);",
            section: "border-color:#d85cab;background:#1a1017;box-shadow:inset 3px 0 0 #d85cab;"
        };

        if (tone === "warn" || tone === "unset" || tone === "missing") return unset;
        if (tone === "off") return muted;
        return selected;
    }

    function setupPill(label, tone = "default") {
        const style = setupStatusTone(tone).pill;
        return `<span style="display:inline-block;padding:1px 6px;border:1px solid;border-radius:999px;font-size:8.8px;font-weight:800;line-height:1.25;white-space:nowrap;${style}">${escapeHtml(label)}</span>`;
    }

    function setupSectionHtml({section, title, statusLabel, statusTone = "default", summary, body}) {
        const sections = routeSetupSections();
        const expanded = sections[section] !== false;
        const tone = setupStatusTone(statusTone);
        return `
          <div class="llmr-route-setup-section" data-section="${escapeHtml(section)}" data-status-tone="${escapeHtml(statusTone)}" style="border:1px solid;border-radius:10px;margin-top:5px;overflow:hidden;${tone.section}">
            <button id="llmr-setup-toggle-${escapeHtml(section)}" type="button" title="Expand or collapse ${escapeHtml(title)}" style="box-sizing:border-box;width:100%;border:0;border-bottom:${expanded ? '1px solid rgba(255,255,255,.08)' : '0'};${tone.header}color:#f7eef8;padding:4px 6px;display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:5px;align-items:center;text-align:left;cursor:pointer;">
              <span style="color:${tone.arrow};font-size:9px;font-weight:800;">${expanded ? '▾' : '▸'}</span>
              <span style="min-width:0;display:flex;flex-direction:column;gap:1px;">
                <span style="font-size:9.8px;font-weight:850;color:${tone.title};line-height:1.1;">${escapeHtml(title)}</span>
                <span style="font-size:9px;color:${tone.summary};line-height:1.15;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(summary || '')}</span>
              </span>
              ${setupPill(statusLabel, statusTone)}
            </button>
            <div id="llmr-setup-body-${escapeHtml(section)}" style="display:${expanded ? 'block' : 'none'};padding:5px 6px 6px;">
              ${body || ''}
            </div>
          </div>`;
    }

    function routeSourceStatus(kind, selectedDraft) {
        if (kind === "selected_draft") {
            return selectedDraft
                ? {
                    label: "Selected",
                    tone: "custom",
                    summary: `Queued item · ${LLMR.shortId(selectedDraft.delivery_id)}`
                }
                : {label: "Choose", tone: "warn", summary: "Select an item from Queue before routing"};
        }
        if (kind === "latest_assistant") return {label: "Selected", tone: "custom", summary: "Last assistant response"};
        return {label: "Default", tone: "default", summary: "Last user message"};
    }

    function routeTargetStatus(target, targetOptions, currentGroup, selectionRecord) {
        const selected = targetOptions.find(item => item.value === target);
        if (!target || !selected) {
            return {label: "Choose", tone: "warn", summary: "Target needs attention"};
        }
        if (selectionRecord?.manual) {
            return {label: "Custom", tone: "custom", summary: selected.label};
        }
        if (selectionRecord?.reason === "auto_group_member" || target.startsWith("chatgpt_tab:")) {
            return {label: "Group target", tone: "ok", summary: selected.label};
        }
        if (target === "local_draft") {
            return {
                label: "Default",
                tone: "default",
                summary: `${selected.label} · ${currentGroup?.name || 'Default queue'}`
            };
        }
        return {label: "Ready", tone: "ok", summary: selected.label};
    }

    function identityStatus(currentLabel, currentGroup) {
        const session = currentSession();
        const known = knownSessionById(session.source_session_id);
        const userSaved = known?.label_source === "user_saved" || known?.manual_alias || session?.label_source === "user_saved";
        const groupDefault = !currentGroup || currentGroup.queue_group_id === "default" || currentGroup.is_default;
        const labelPart = userSaved ? "Saved name" : "Inherited name";
        const groupPart = groupDefault ? "Default group" : "Grouped";
        return {
            label: userSaved || !groupDefault ? "Custom" : "Default",
            tone: userSaved || !groupDefault ? "custom" : "default",
            summary: `${currentLabel || 'Unnamed session'} · ${currentGroup?.name || 'Default queue'} · ${labelPart} · ${groupPart}`
        };
    }

    function wrapperStatus(selection) {
        if (selection?.missing_wrapper_id) return {
            label: "Choose",
            tone: "warn",
            summary: `Missing wrapper: ${selection.missing_wrapper_id}`
        };
        if (selection?.enabled) return {label: "On", tone: "custom", summary: selection.label || selection.wrapper_id};
        return {label: "Off", tone: "off", summary: "No wrapper applied"};
    }

    function stableRouteTargetSignature(targetOptions) {
        return (targetOptions || []).map(item => [
            item.value || "",
            item.label || "",
            item.detail || ""
        ]);
    }

    function routePanelSignature({
                                     currentLabel,
                                     currentGroup,
                                     currentRouteSource,
                                     selectedDraft,
                                     target,
                                     targetOptions,
                                     targetRecord,
                                     wrapperSelection,
                                     groups
                                 } = {}) {
        const session = currentSession();
        return JSON.stringify({
            overlay_version: OVERLAY_VERSION,
            source_session_id: session.source_session_id,
            route_setup_sections: routeSetupSections(),
            current_label: currentLabel || "",
            queue_group_id: currentGroup?.queue_group_id || "default",
            queue_group_name: currentGroup?.name || "Default queue",
            route_source: currentRouteSource || "latest_user",
            selected_draft_id: selectedDraft?.delivery_id || null,
            target: target || "local_draft",
            target_record: targetRecord ? {
                value: targetRecord.value || null,
                manual: Boolean(targetRecord.manual),
                reason: targetRecord.reason || null,
                queue_group_id: targetRecord.queue_group_id || null
            } : null,
            target_options: stableRouteTargetSignature(targetOptions),
            wrapper: wrapperSelection ? {
                enabled: Boolean(wrapperSelection.enabled),
                wrapper_id: wrapperSelection.wrapper_id || null,
                label: wrapperSelection.label || null,
                missing_wrapper_id: wrapperSelection.missing_wrapper_id || null
            } : null,
            groups: (groups || []).map(group => [group.queue_group_id, group.name, Boolean(group.is_default)])
        });
    }

    function renderRoutePanelIfSafe(reason = "refresh") {
        if (routePanelInteractionActive() || aliasEditActive()) {
            LLMR.__overlayState.routePanelRenderDeferred = true;
            return false;
        }
        LLMR.__overlayState.routePanelRenderDeferred = false;
        renderRoutePanel({reason});
        return true;
    }

    function renderRoutePanel({force = false, reason = "manual"} = {}) {
        if (!force && (routePanelInteractionActive() || aliasEditActive())) {
            LLMR.__overlayState.routePanelRenderDeferred = true;
            return;
        }
        LLMR.__overlayState.routePanelRenderDeferred = false;
        const panel = byId("llmr-route-panel");
        if (!panel) return;
        const providers = routeTargetProviders();
        const selectedDraft = selectedQueueDraft();
        const currentGroup = currentQueueGroupSnapshot();
        const groupMemberTargets = liveGroupMemberTargets(currentSession(), currentGroup);
        const liveTargets = liveChatGptTargetOptions();
        const liveTargetValues = new Set(groupMemberTargets.map(item => item.value));
        const otherLiveTargets = liveTargets.filter(item => !liveTargetValues.has(item.value));
        const baseTargetOptions = [
            {value: "local_draft", label: "Local draft inbox", detail: "Queue in current group"},
            ...providers.map(provider => ({
                value: `provider:${provider.provider_id}`,
                label: providerLabel(provider),
                detail: `Provider · ${provider.availability || "unknown"}`
            })),
            ...groupMemberTargets,
            ...otherLiveTargets
        ];
        const target = routeTargetKind({targetOptions: baseTargetOptions});
        baseTargetOptions.forEach(rememberRouteTargetOption);

        const targetOptions = [...baseTargetOptions];
        if (target && !targetOptions.some(item => item.value === target)) {
            const previousLabel = LLMR.__overlayState.routeTargetLabelByKey[target] || routeTargetLabel(target);
            const isChatTarget = target.startsWith("chatgpt_tab:");
            targetOptions.push({
                value: target,
                label: isChatTarget ? `${previousLabel} · reconnecting` : previousLabel,
                detail: isChatTarget
                    ? "Previously selected ChatGPT target is not currently detected. Refresh or reopen the target tab."
                    : "Previously selected target is not currently available."
            });
        }

        const currentLabel = aliasInputValueForRender();
        const currentRouteSource = routeSourceKind();
        const targetRecord = routeTargetSelectionRecord(currentSession(), currentGroup);
        const sourceStatus = routeSourceStatus(currentRouteSource, selectedDraft);
        const targetStatusInfo = routeTargetStatus(target, targetOptions, currentGroup, targetRecord);
        const wrapperSelection = validPromptWrapperSelection();
        const wrapperStatusInfo = wrapperStatus(wrapperSelection);
        const identityStatusInfo = identityStatus(currentLabel, currentGroup);
        const groups = LLMR.__overlayState.routePanelQueueGroups && LLMR.__overlayState.routePanelQueueGroups.length
            ? LLMR.__overlayState.routePanelQueueGroups
            : [currentGroup];
        const groupOptions = groups.map(group => `<option value="${escapeHtml(group.queue_group_id)}" ${group.queue_group_id === currentGroup.queue_group_id ? 'selected' : ''}>${escapeHtml(group.name || group.queue_group_id)}${group.is_default ? ' · default' : ''}</option>`).join("");
        const panelSignature = routePanelSignature({
            currentLabel,
            currentGroup,
            currentRouteSource,
            selectedDraft,
            target,
            targetOptions,
            targetRecord,
            wrapperSelection,
            groups
        });
        if (!force && panel.dataset.llmrRoutePanelSignature === panelSignature) {
            return;
        }
        panel.dataset.llmrRoutePanelSignature = panelSignature;
        LLMR.__overlayState.routePanelLastSignature = panelSignature;

        panel.innerHTML = `
          <div style="display:flex;align-items:center;justify-content:space-between;gap:6px;margin-bottom:4px;">
            <div style="font-weight:800;color:#f0c9dd;font-size:11px;line-height:1.1;">Route setup</div>
            <button id="llmr-refresh" title="Refresh live sessions, groups, providers, wrappers, and queue" style="padding:2px 7px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.5px;cursor:pointer;">Refresh</button>
          </div>
          ${setupSectionHtml({
            section: "identity",
            title: "Session + group",
            statusLabel: identityStatusInfo.label,
            statusTone: identityStatusInfo.tone,
            summary: identityStatusInfo.summary,
            body: `
              <label style="display:block;color:#c9adca;font-size:9.2px;margin:0 0 3px;">Session name</label>
              <div style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px;align-items:center;">
                <input id="llmr-session-alias-main" value="${escapeHtml(currentLabel)}" title="Saved names override inherited labels and do not change routing identity" style="box-sizing:border-box;width:100%;min-width:0;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;" />
                <button id="llmr-save-session-alias-main" title="Save this name for the current ChatGPT session" style="padding:3px 7px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.3px;cursor:pointer;">Save</button>
              </div>
              <div style="color:#9e849f;font-size:9px;margin:3px 0 5px;line-height:1.2;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${escapeHtml(currentSession().source_session_id)}">stable id: ${escapeHtml(LLMR.shortId(currentSession().source_session_id, 13, 6))}</div>
              <label style="display:block;color:#c9adca;font-size:9.2px;margin:4px 0 3px;">Group</label>
              <div style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px;align-items:center;">
                <select id="llmr-current-group-select" style="box-sizing:border-box;width:100%;max-width:100%;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;">${groupOptions}</select>
                <button id="llmr-assign-current-group" title="Assign this session to the selected group" style="padding:3px 7px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.3px;cursor:pointer;">Assign</button>
              </div>
              <div style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px;align-items:center;margin-top:4px;">
                <input id="llmr-new-group-name-main" placeholder="New group name" style="box-sizing:border-box;width:100%;min-width:0;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;" />
                <button id="llmr-create-assign-group-main" title="Create a group and assign this session" style="padding:3px 7px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.3px;cursor:pointer;">Create</button>
              </div>`
        })}
          ${setupSectionHtml({
            section: "source",
            title: "Source",
            statusLabel: sourceStatus.label,
            statusTone: sourceStatus.tone,
            summary: sourceStatus.summary,
            body: `
              <select id="llmr-route-source" style="box-sizing:border-box;width:100%;max-width:100%;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;">
                <option value="latest_user">Last user message</option>
                <option value="latest_assistant">Last assistant response</option>
                <option value="selected_draft">Selected queued item${selectedDraft ? ` · ${LLMR.shortId(selectedDraft.delivery_id)}` : ""}</option>
              </select>
              <div style="color:#9e849f;font-size:9px;margin-top:3px;line-height:1.2;">Default is latest user. Select queued requires choosing an item in Queue.</div>`
        })}
          ${setupSectionHtml({
            section: "target",
            title: "Target",
            statusLabel: targetStatusInfo.label,
            statusTone: targetStatusInfo.tone,
            summary: targetStatusInfo.summary,
            body: `
              <select id="llmr-route-target" style="box-sizing:border-box;width:100%;max-width:100%;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;">
                ${targetOptions.map(item => `<option value="${escapeHtml(item.value)}" title="${escapeHtml(LLMR.cleanText(item.detail || item.label))}">${escapeHtml(item.label)}</option>`).join("")}
              </select>
              <div id="llmr-route-target-detail" style="color:#9e849f;font-size:9px;margin-top:3px;line-height:1.2;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></div>
              <div style="color:#8e748f;font-size:8.8px;margin-top:2px;line-height:1.2;">Group target auto-selects until you manually choose another target.</div>`
        })}
          ${setupSectionHtml({
            section: "wrapper",
            title: "Wrapper",
            statusLabel: wrapperStatusInfo.label,
            statusTone: wrapperStatusInfo.tone,
            summary: wrapperStatusInfo.summary,
            body: `
              <div style="display:flex;align-items:center;gap:5px;">
                <label style="display:flex;align-items:center;gap:4px;color:#c9adca;font-size:9.5px;white-space:nowrap;margin:0;">
                  <input id="llmr-wrapper-enabled" type="checkbox" style="margin:0;" /> Enabled
                </label>
                <select id="llmr-wrapper-select" style="box-sizing:border-box;flex:1;min-width:0;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:8px;padding:3px 5px;font-size:10.3px;line-height:1.15;"></select>
              </div>
              <div style="color:#9e849f;font-size:9px;margin-top:3px;line-height:1.2;">Optional route-time transform. Original capture stays unchanged.</div>`
        })}
          <button id="llmr-route-execute" style="margin-top:6px;padding:5px 8px;border-radius:999px;border:1px solid #b6d7a8;background:#1f2a1d;color:#f7eef8;width:100%;font-size:10.5px;font-weight:750;">Route</button>
          <div style="color:#9e849f;font-size:9px;margin-top:4px;line-height:1.2;">Direct · group-scoped · duplicates OK · no auto-send</div>
        `;

        for (const sectionName of ["identity", "source", "target", "wrapper"]) {
            const toggle = byId(`llmr-setup-toggle-${sectionName}`);
            if (toggle) {
                toggle.onclick = event => {
                    event.preventDefault();
                    event.stopPropagation();
                    toggleRouteSetupSection(sectionName).catch(err => setResult(`section toggle error: ${err}`));
                };
            }
        }

        const sourceSelect = byId("llmr-route-source");
        const targetSelect = byId("llmr-route-target");
        const execute = byId("llmr-route-execute");
        if (sourceSelect) {
            sourceSelect.value = routeSourceKind();
            sourceSelect.onchange = () => {
                LLMR.__overlayState.routeSourceKind = sourceSelect.value;
                renderRoutePanel();
            };
        }
        if (targetSelect) {
            targetSelect.value = targetOptions.some(item => item.value === target) ? target : "local_draft";
            const updateTargetDetail = () => {
                const detail = byId("llmr-route-target-detail");
                const selected = targetOptions.find(item => item.value === targetSelect.value);
                if (detail) detail.textContent = selected?.detail || "";
            };
            updateTargetDetail();
            targetSelect.onfocus = () => {
                LLMR.__overlayState.routeTargetEditing = true;
            };
            targetSelect.onblur = () => {
                LLMR.__overlayState.routeTargetEditing = false;
                if (LLMR.__overlayState.routePanelRenderDeferred) {
                    setTimeout(() => renderRoutePanelIfSafe("target-blur"), 50);
                }
            };
            targetSelect.onchange = () => {
                setRouteTargetKind(targetSelect.value, {userSelected: true});
                updateTargetDetail();
            };
        }
        const wrapperEnabled = byId("llmr-wrapper-enabled");
        const wrapperSelect = byId("llmr-wrapper-select");
        if (wrapperEnabled && wrapperSelect) {
            const wrappers = LLMR.__overlayState.promptWrappers || [];
            const selection = currentPromptWrapperSelection();
            wrapperSelect.innerHTML = wrappers.length
                ? wrappers.map(item => `<option value="${escapeHtml(item.wrapper_id)}" title="${escapeHtml(item.description || item.label || item.wrapper_id)}">${escapeHtml(item.label || item.wrapper_id)}</option>`).join("")
                : `<option value="">No wrappers configured</option>`;
            const selectedWrapperId = wrappers.some(item => item.wrapper_id === selection.wrapper_id)
                ? selection.wrapper_id
                : (wrappers[0]?.wrapper_id || "");
            wrapperEnabled.checked = Boolean(selection.enabled && selectedWrapperId);
            wrapperSelect.value = selectedWrapperId;
            wrapperSelect.disabled = !wrapperEnabled.checked || !wrappers.length;
            const persistWrapper = () => {
                savePromptWrapperSelection({enabled: wrapperEnabled.checked, wrapperId: wrapperSelect.value})
                    .then(() => renderRoutePanel({force: true, reason: "prompt-wrapper-changed"}))
                    .catch(err => setResult(`wrapper selection error: ${err}`));
            };
            wrapperEnabled.onchange = persistWrapper;
            wrapperSelect.onchange = persistWrapper;
        }
        const aliasInput = byId("llmr-session-alias-main");
        const aliasSave = byId("llmr-save-session-alias-main");
        if (aliasInput) {
            aliasInput.onfocus = () => beginAliasEdit(currentSession(), aliasInput.value);
            aliasInput.oninput = () => updateAliasDraft(aliasInput.value, currentSession());
            aliasInput.onkeydown = event => {
                if (event.key === "Enter") {
                    event.preventDefault();
                    saveCurrentSessionAlias(aliasInput.value, {source: "route_panel_enter"}).catch(err => setResult(`session name save error: ${err}`));
                }
            };
            aliasInput.onblur = () => {
                const session = currentSession();
                if (LLMR.__overlayState.sessionAliasEditingSessionId === session.source_session_id) {
                    LLMR.__overlayState.sessionAliasEditingSessionId = null;
                }
                if (!LLMR.__overlayState.sessionAliasSaveInFlight && !LLMR.__overlayState.sessionAliasDirty) {
                    clearAliasDraft(session);
                }
                if (LLMR.__overlayState.routePanelRenderDeferred) {
                    setTimeout(() => renderRoutePanelIfSafe("alias-blur"), 50);
                }
            };
        }
        if (aliasSave) {
            aliasSave.onclick = () => saveCurrentSessionAlias(aliasInput?.value || "", {source: "route_panel_button"}).catch(err => setResult(`session name save error: ${err}`));
        }
        const groupSelect = byId("llmr-current-group-select");
        const assignGroup = byId("llmr-assign-current-group");
        if (assignGroup && groupSelect) {
            assignGroup.onclick = async () => {
                try {
                    const session = currentSession();
                    const response = await LLMR.setSessionQueueGroup({
                        sourceSessionId: session.source_session_id,
                        queueGroupId: groupSelect.value,
                        provider: session.provider,
                        label: currentSessionLabel()
                    });
                    if (response?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, response.queue_group);
                    } else {
                        invalidateQueueGroupCache(session.source_session_id);
                    }
                    invalidateNextDraftCache(session.source_session_id);
                    await loadRoutePanelQueueGroups({force: true});
                    await updateSessionBadge({refreshGroup: false});
                    renderRoutePanel({force: true, reason: "route-panel-group-assigned"});
                    setResult("session group updated; target will use group member when available");
                } catch (err) {
                    setResult(`group assignment error: ${err}`);
                }
            };
        }
        const newGroupInput = byId("llmr-new-group-name-main");
        const createGroup = byId("llmr-create-assign-group-main");
        if (createGroup && newGroupInput) {
            createGroup.onclick = async () => {
                const name = newGroupInput.value.trim();
                if (!name) {
                    setResult("enter a group name before creating");
                    return;
                }
                try {
                    const created = await LLMR.createQueueGroup(name);
                    const session = currentSession();
                    const assigned = await LLMR.setSessionQueueGroup({
                        sourceSessionId: session.source_session_id,
                        queueGroupId: created.queue_group_id,
                        provider: session.provider,
                        label: currentSessionLabel()
                    });
                    if (assigned?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, assigned.queue_group);
                    } else if (created?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, created.queue_group);
                    } else {
                        invalidateQueueGroupCache(session.source_session_id);
                    }
                    invalidateNextDraftCache(session.source_session_id);
                    await loadRoutePanelQueueGroups({force: true});
                    await updateSessionBadge({refreshGroup: false});
                    renderRoutePanel({force: true, reason: "route-panel-group-created"});
                    setResult(`created and assigned group: ${created.queue_group?.name || name}`);
                } catch (err) {
                    setResult(`create group error: ${err}`);
                }
            };
        }
        const refreshButton = byId("llmr-refresh");
        if (refreshButton) refreshButton.onclick = () => refreshOverlayState("button", {forceLiveSessions: true}).catch(err => setResult(`refresh error: ${err}`));
        if (execute) execute.onclick = () => executeRouteAction().catch(err => setResult(`route error: ${err}`));
    }


    async function loadDispatchProviders({force = false} = {}) {
        if (!force && LLMR.__overlayState.dispatchProvidersCachedAt && nowMs() - LLMR.__overlayState.dispatchProvidersCachedAt < 30000) {
            return dispatchCapableProviders();
        }

        const response = await LLMR.listProviders();
        LLMR.__overlayState.dispatchProviders = response.providers || [];
        LLMR.__overlayState.dispatchProvidersCachedAt = nowMs();

        const providers = dispatchCapableProviders();
        const selected = LLMR.__overlayState.selectedDispatchProviderId;
        if (!selected || !providers.some(provider => provider.provider_id === selected)) {
            LLMR.__overlayState.selectedDispatchProviderId = providers[0]?.provider_id || null;
        }
        return providers;
    }

    function selectedDispatchProvider() {
        const providers = dispatchCapableProviders();
        return providers.find(provider => provider.provider_id === LLMR.__overlayState.selectedDispatchProviderId) || providers[0] || null;
    }

    async function dispatchDraftToProvider(draft, provider, buttonEl = null) {
        if (!provider) {
            setResult("No dispatch-capable provider is available.");
            return null;
        }

        if (buttonEl) {
            buttonEl.disabled = true;
            buttonEl.textContent = "Dispatching…";
        }

        try {
            const response = await LLMR.dispatchToProvider(provider.provider_id, {
                deliveryId: draft.delivery_id,
                queueGroupId: draft.queue_group_id || "default",
                manualConfirmed: true,
                options: promptWrapperOptions({source: "overlay_queue_provider_dispatch"})
            });

            invalidateNextDraftCache();
            await loadQueue({silent: true});

            if (response.ok) {
                const generated = (response.generated_delivery_ids || []).map(id => LLMR.shortId(id)).join(", ") || "none";
                setResult(
                    `provider response received
` +
                    `provider: ${provider.provider_id}
` +
                    `source delivery: ${LLMR.shortId(draft.delivery_id)}
` +
                    `generated local draft: ${generated}`
                );
            } else {
                setResult(`provider dispatch failed: ${response.message || response.error_code || "unknown error"}`);
            }
            return response;
        } catch (err) {
            setResult(`provider dispatch error: ${err}`);
            throw err;
        } finally {
            if (buttonEl) {
                buttonEl.disabled = false;
                buttonEl.textContent = `Dispatch to ${providerLabel(provider)}`;
            }
        }
    }

    function captureRoleLabel(role) {
        return role === "user" ? "user" : "assistant";
    }

    function getLatestPayloadForRole(role) {
        const safeRole = captureRoleLabel(role);
        return safeRole === "user"
            ? LLMR.ChatGPTAdapter.getLatestUserMessage()
            : LLMR.ChatGPTAdapter.getLatestAssistantMessage();
    }

    async function captureLatest(role = "assistant") {
        const safeRole = captureRoleLabel(role);

        if (await currentDisconnected()) {
            setResult("This session is disconnected. Reconnect from the extension popup to use LLMR here.");
            return;
        }

        await updateSessionBadge();
        const group = await currentQueueGroup();
        setResult(`queueing latest ${safeRole} for group: ${group.name}…`);

        const payload = getLatestPayloadForRole(safeRole);
        if (!payload) {
            setResult(`No latest ${safeRole} message found.`);
            return;
        }

        const response = await LLMR.postCapture(payload);
        const deliveries = response.delivery_ids || [];
        const deliveryText = deliveries.length ? deliveries.map(id => LLMR.shortId(id)).join(", ") : "none";

        if (response.deduped) {
            setResult(
                `queued duplicate ${safeRole} for group: ${group.name}
` +
                `${deliveries.length ? "created requeued delivery" : "no new delivery"}
` +
                `message: ${LLMR.shortId(response.message_id)}
` +
                `route: ${response.route_decision}
` +
                `deliveries: ${deliveryText}
` +
                `group handoff: another grouped ChatGPT session can use Insert next from group`
            );
        } else {
            setResult(
                `queued ${safeRole} for group: ${group.name}
` +
                `route: ${response.route_decision}
` +
                `message: ${LLMR.shortId(response.message_id)}
` +
                `deliveries: ${deliveryText}
` +
                `group handoff: another grouped ChatGPT session can use Insert next from group`
            );
        }

        invalidateNextDraftCache();
        if (byId("llmr-queue-panel")?.style.display !== "none") {
            await loadQueue();
        } else {
            prefetchNextDraft(`capture-latest-${safeRole}`, {force: true, sourceMode: QUICK_HANDOFF_SOURCE_MODE});
        }
        return response;
    }

    async function insertDraftItem(draft, {allowSameSession = false} = {}) {
        if (await currentDisconnected()) {
            return {ok: false, error: "this session is disconnected"};
        }

        const session = currentSession();

        if (!allowSameSession && draft.source_session_id === session.source_session_id) {
            return {ok: false, error: "same source session excluded", self_echo_guard: true};
        }

        const inserted = draft.wrapped_format_capture
            ? LLMR.ChatGPTAdapter.insertFormatCapture(draft.wrapped_format_capture)
            : LLMR.ChatGPTAdapter.insertDraft(draft.wrapped_body_markdown || draft.wrapped_body);

        if (!inserted.ok) {
            await LLMR.markDraftFailed(draft.delivery_id, {
                target_session_id: session.source_session_id,
                error: inserted.reason || "insertDraft failed",
                metadata: {adapter_result: inserted}
            });
            return {ok: false, error: inserted.reason || "insertDraft failed"};
        }

        markPendingInserted(draft.delivery_id);
        invalidateNextDraftCache(session.source_session_id, draft.queue_group_id || "default");
        postInsertBookkeeping(draft, inserted, session);

        return {
            ok: true,
            inserted,
            update: {
                ok: true,
                pending: true,
                mode: "post_insert_bookkeeping"
            },
            draft: {
                delivery_id: draft.delivery_id,
                source_session_id: draft.source_session_id,
                body_length: draft.body_length,
                body_hash: draft.body_hash,
                status: "draft_inserted"
            }
        };
    }

    async function insertNext() {
        setResult("finding prepared queued draft…");

        const result = await insertPreparedNextDraft({setOverlayResult: true});

        if (!result.ok) {
            setResult(
                `${result.error || "no queued draft found"}\n` +
                `${result.queue_group ? `queue: ${result.queue_group.name}\n` : ""}` +
                `${result.source_session_id ? `target: ${LLMR.shortId(result.source_session_id, 12, 7)}` : ""}`
            );
        }
    }

    async function insertPreparedNextDraft({setOverlayResult = true} = {}) {
        if (await currentDisconnected()) {
            return {ok: false, error: "this session is disconnected"};
        }

        const session = currentSession();
        const group = await currentQueueGroup();
        const sourceMode = QUICK_HANDOFF_SOURCE_MODE;
        const quickHandoff = true;
        const next = await fetchNextDraftForSessionGroup(session, group, {sourceMode, force: true});

        if (!next.found || !next.draft) {
            prefetchNextDraft("insert-prepared-empty", {force: true, sourceMode});
            return {
                ok: false,
                error: quickHandoff
                    ? "No queued ChatGPT capture found in this group from another session."
                    : (next.reason || "no queued draft found"),
                queue_group: group,
                source_session_id: session.source_session_id,
            };
        }

        const result = await insertDraftItem(next.draft);

        if (setOverlayResult) {
            if (!result.ok) {
                setResult(`insert failed: ${result.error || "unknown"}`);
            } else {
                setResult(
                    `inserted next draft\n` +
                    `queue: ${group.name}\n` +
                    `status: draft_inserted pending backend confirmation\n` +
                    `delivery: ${LLMR.shortId(next.draft.delivery_id)}\n` +
                    `from: ${LLMR.shortId(next.draft.source_session_id, 12, 7)}\n` +
                    `method: ${result.inserted.method}\n` +
                    `strategy: ${result.inserted.strategy || ""}\n` +
                    `insert_ms: ${result.inserted.elapsed_ms ?? ""}\n` +
                    `review and send manually`
                );
            }
        }

        if (result.ok) {
            scheduleQueueRefreshAfterInsert("insert-prepared-next");
        }

        return {
            ...result,
            queue_group: group,
            source_session_id: session.source_session_id,
        };
    }

    async function cancelDraft(deliveryId) {
        await LLMR.cancelDraft(deliveryId, {reason: "cancelled from overlay"});
        invalidateNextDraftCache();
        await loadQueue();
        setResult(`cancelled queued draft: ${LLMR.shortId(deliveryId)}`);
    }

    async function clearQueue() {
        const group = await currentQueueGroup();
        const response = await LLMR.clearQueuedDrafts({
            queueGroupId: group.queue_group_id,
            provider: providerFilterForSourceMode(),
            reason: `cleared from overlay (${queueSourceModeLabel()})`
        });
        invalidateNextDraftCache();
        await loadQueue();
        setResult(`cleared queue: ${group.name}\ncancelled: ${response.cancelled_count}`);
    }

    function renderQueue(drafts) {
        const list = byId("llmr-queue-list");
        if (!list) return;

        list.innerHTML = "";

        const producer = document.createElement("div");
        producer.style.cssText = "border:1px solid #3b293f;background:#120d13;border-radius:10px;padding:7px;margin-bottom:7px;";
        const producerTitle = document.createElement("div");
        producerTitle.style.cssText = "font-weight:800;color:#f0c9dd;font-size:11px;margin-bottom:5px;";
        producerTitle.textContent = "Add to group queue";
        const producerHint = document.createElement("div");
        producerHint.style.cssText = "color:#c9adca;font-size:10px;line-height:1.3;margin-bottom:6px;";
        producerHint.textContent = "Queue the latest message from this ChatGPT session so another grouped session can insert it with Insert next from group.";
        const producerGrid = document.createElement("div");
        producerGrid.style.cssText = "display:grid;grid-template-columns:1fr 1fr;gap:5px;";
        const queueUser = document.createElement("button");
        queueUser.type = "button";
        queueUser.textContent = "Queue user";
        queueUser.style.cssText = "padding:5px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        queueUser.onclick = () => captureLatest("user").catch(err => setResult(`queue user error: ${err}`));
        const queueAssistant = document.createElement("button");
        queueAssistant.type = "button";
        queueAssistant.textContent = "Queue assistant";
        queueAssistant.style.cssText = "padding:5px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        queueAssistant.onclick = () => captureLatest("assistant").catch(err => setResult(`queue assistant error: ${err}`));
        producerGrid.append(queueUser, queueAssistant);
        producer.append(producerTitle, producerHint, producerGrid);
        list.appendChild(producer);

        const clear = document.createElement("button");
        clear.type = "button";
        clear.textContent = "Clear this queue";
        clear.style.cssText = "margin-bottom:6px;padding:6px 8px;border-radius:999px;border:1px solid #e68a9c;background:#241828;color:#f7eef8;width:100%;";
        clear.onclick = () => clearQueue().catch(err => setResult(`clear queue error: ${err}`));
        list.appendChild(clear);

        if (!drafts.length) {
            const empty = document.createElement("div");
            empty.style.cssText = "padding:7px;color:#c9adca;font-family:ui-monospace,monospace;font-size:11px;";
            empty.textContent = "No queued drafts available for this session/group.";
            list.appendChild(empty);
            return;
        }

        for (const draft of drafts.slice(0, 12)) {
            const row = document.createElement("div");
            row.style.cssText = "border:1px solid #3b293f;background:#100b11;border-radius:10px;padding:7px;margin-top:6px;";

            const title = document.createElement("div");
            title.style.cssText = "font-weight:700;color:#f7eef8;font-size:11px;line-height:1.25;";
            title.textContent = draftLabel(draft);

            const meta = document.createElement("div");
            meta.style.cssText = "color:#c9adca;font-family:ui-monospace,monospace;font-size:10px;margin-top:3px;line-height:1.25;";
            meta.textContent = `${sourceLabelForDraft(draft)} · ${draftMeta(draft)}`;

            const selectDraft = document.createElement("button");
            selectDraft.type = "button";
            selectDraft.textContent = LLMR.__overlayState.selectedDraftId === draft.delivery_id ? "Selected for Route" : "Select for Route";
            selectDraft.style.cssText = "margin-top:6px;padding:5px 8px;border-radius:999px;border:1px solid #8fbbe8;background:#172033;color:#f7eef8;width:100%;";
            selectDraft.onclick = () => {
                setSelectedQueueDraft(draft);
                loadQueue({silent: true}).catch(err => setResult(`reload queue error: ${err}`));
                setResult(`selected queued item for Route
delivery: ${LLMR.shortId(draft.delivery_id)}
source: ${sourceLabelForDraft(draft)}`);
            };

            const insert = document.createElement("button");
            insert.type = "button";
            insert.textContent = "Insert this";
            insert.style.cssText = "margin-top:6px;padding:5px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
            insert.onclick = async () => {
                try {
                    insert.disabled = true;
                    insert.textContent = "Inserting…";
                    const result = await insertDraftItem(draft);
                    if (!result.ok) setResult(`insert failed: ${result.error || "unknown"}`);
                    else {
                        setResult(
                            `inserted selected draft\n` +
                            `delivery: ${LLMR.shortId(draft.delivery_id)}\n` +
                            `from: ${LLMR.shortId(draft.source_session_id, 12, 7)}\n` +
                            `method: ${result.inserted.method}`
                        );
                    }
                    scheduleQueueRefreshAfterInsert("selected-insert");
                    insert.disabled = false;
                    insert.textContent = "Insert this";
                } catch (err) {
                    setResult(`selected insert error: ${err}`);
                    insert.disabled = false;
                    insert.textContent = "Insert this";
                }
            };

            const dispatchProviders = dispatchCapableProviders();
            const provider = selectedDispatchProvider();
            const providerSelect = document.createElement("select");
            providerSelect.style.cssText = "margin-top:5px;padding:5px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
            if (!dispatchProviders.length) {
                const option = document.createElement("option");
                option.value = "";
                option.textContent = "No dispatch-capable providers";
                providerSelect.appendChild(option);
                providerSelect.disabled = true;
            } else {
                for (const item of dispatchProviders) {
                    const option = document.createElement("option");
                    option.value = item.provider_id;
                    option.textContent = `${providerLabel(item)} · ${item.availability}`;
                    option.selected = item.provider_id === provider?.provider_id;
                    providerSelect.appendChild(option);
                }
                providerSelect.onchange = () => {
                    LLMR.__overlayState.selectedDispatchProviderId = providerSelect.value;
                    loadQueue({silent: true}).catch(err => setResult(`reload queue error: ${err}`));
                };
            }

            const dispatch = document.createElement("button");
            dispatch.type = "button";
            dispatch.textContent = provider ? `Dispatch to ${providerLabel(provider)}` : "No dispatch provider";
            dispatch.disabled = !provider || !(draft.status === "queued" || draft.status === "failed");
            dispatch.style.cssText = "margin-top:5px;padding:5px 8px;border-radius:999px;border:1px solid #b6d7a8;background:#1f2a1d;color:#f7eef8;width:100%;";
            dispatch.onclick = () => dispatchDraftToProvider(draft, provider, dispatch).catch(err => setResult(`dispatch error: ${err}`));

            const cancel = document.createElement("button");
            cancel.type = "button";
            cancel.textContent = "Delete from queue";
            cancel.style.cssText = "margin-top:5px;padding:5px 8px;border-radius:999px;border:1px solid #e68a9c;background:#241828;color:#f7eef8;width:100%;";
            cancel.onclick = () => cancelDraft(draft.delivery_id).catch(err => setResult(`delete error: ${err}`));

            row.append(title, meta, selectDraft, insert, providerSelect, dispatch, cancel);
            list.appendChild(row);
        }
    }

    async function loadQueue({silent = false} = {}) {
        if (await currentDisconnected()) {
            renderQueue([]);
            if (!silent) {
                setResult("This session is disconnected. Reconnect from the extension popup to use LLMR here.");
            }
            return [];
        }

        const session = currentSession();
        const group = await currentQueueGroup();
        await loadDispatchProviders();
        const mode = queueSourceMode();
        const drafts = filterDraftsForSourceMode(filterUsableDrafts(await LLMR.getQueuedDrafts({
            excludeSourceSessionId: session.source_session_id,
            provider: providerFilterForSourceMode(mode),
            queueGroupId: group.queue_group_id
        })), mode);

        LLMR.__overlayState.lastQueueDrafts = drafts;
        renderQueue(drafts);
        renderRoutePanel();

        const next = drafts.length
            ? {found: true, draft: drafts[0]}
            : {found: false, draft: null, reason: "no queued draft matched request"};
        cacheNextDraft(session.source_session_id, group.queue_group_id, next);

        await updateSessionBadge({refreshGroup: false});

        if (!silent) {
            setResult(`queue loaded: ${drafts.length} available\nqueue: ${group.name}`);
        }

        return drafts;
    }

    async function toggleQueue() {
        const panel = byId("llmr-queue-panel");
        if (!panel) return;

        const isHidden = panel.style.display === "none";
        panel.style.display = isHidden ? "block" : "none";

        if (isHidden) await loadQueue();
    }

    async function renderGroupPanel() {
        const panel = byId("llmr-group-panel");
        if (!panel) return;

        const session = currentSession();
        const displayLabel = await refreshCurrentDisplayLabel();
        const current = await currentQueueGroup();
        const groups = (await LLMR.listQueueGroups()).queue_groups || [];

        panel.innerHTML = "";

        const aliasLabel = document.createElement("div");
        aliasLabel.style.cssText = "color:#c9adca;font-size:10px;margin:2px 0 3px;";
        aliasLabel.textContent = "Session name";

        const aliasInput = document.createElement("input");
        aliasInput.placeholder = displayLabel;
        aliasInput.value = "";
        aliasInput.style.cssText = "width:100%;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:10px;padding:6px;";

        const aliasSave = document.createElement("button");
        aliasSave.textContent = "Save session name";
        aliasSave.style.cssText = "margin-top:6px;padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        aliasSave.onclick = async () => {
            const label = aliasInput.value.trim() || displayLabel;
            await saveCurrentSessionAlias(label, {source: "group_panel"});
            await renderGroupPanel();
        };

        panel.append(aliasLabel, aliasInput, aliasSave);

        const select = document.createElement("select");
        select.style.cssText = "width:100%;margin-top:6px;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:10px;padding:6px;";
        for (const group of groups) {
            const opt = document.createElement("option");
            opt.value = group.queue_group_id;
            opt.textContent = `${group.name}${group.is_default ? " (default)" : ""}`;
            opt.selected = group.queue_group_id === current.queue_group_id;
            select.appendChild(opt);
        }

        const assign = document.createElement("button");
        assign.textContent = "Assign session to selected queue";
        assign.style.cssText = "margin-top:6px;padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        assign.onclick = async () => {
            const response = await LLMR.setSessionQueueGroup({
                sourceSessionId: session.source_session_id,
                queueGroupId: select.value,
                provider: session.provider,
                label: currentSessionLabel()
            });
            if (response?.queue_group) {
                setCachedQueueGroup(session.source_session_id, response.queue_group);
            } else {
                invalidateQueueGroupCache(session.source_session_id);
            }
            invalidateNextDraftCache(session.source_session_id);
            await updateSessionBadge({refreshGroup: false});
            renderRoutePanel({force: true, reason: "group-assigned"});
            await loadQueue();
            setResult("session queue group updated; target auto-selected from group if available");
        };

        const input = document.createElement("input");
        input.placeholder = "New queue group name";
        input.style.cssText = "width:100%;margin-top:6px;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:10px;padding:6px;";

        const create = document.createElement("button");
        create.textContent = "Create and assign";
        create.style.cssText = "margin-top:6px;padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        create.onclick = async () => {
            const name = input.value.trim();
            if (!name) {
                setResult("enter a queue group name");
                return;
            }
            const created = await LLMR.createQueueGroup(name);
            const assigned = await LLMR.setSessionQueueGroup({
                sourceSessionId: session.source_session_id,
                queueGroupId: created.queue_group_id,
                provider: session.provider,
                label: currentSessionLabel()
            });
            if (assigned?.queue_group) {
                setCachedQueueGroup(session.source_session_id, assigned.queue_group);
            } else if (created?.queue_group) {
                setCachedQueueGroup(session.source_session_id, created.queue_group);
            } else {
                invalidateQueueGroupCache(session.source_session_id);
            }
            invalidateNextDraftCache(session.source_session_id);
            await renderGroupPanel();
            await updateSessionBadge({refreshGroup: false});
            renderRoutePanel({force: true, reason: "group-created-assigned"});
            await loadQueue();
            setResult(`created queue group: ${created.queue_group?.name || name}; target auto-selected from group if available`);
        };

        const renameInput = document.createElement("input");
        renameInput.placeholder = "Rename selected group";
        renameInput.style.cssText = "width:100%;margin-top:6px;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:10px;padding:6px;";

        const rename = document.createElement("button");
        rename.textContent = "Rename selected group";
        rename.style.cssText = "margin-top:6px;padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;width:100%;";
        rename.onclick = async () => {
            if (select.value === "default") {
                setResult("default queue cannot be renamed");
                return;
            }
            const name = renameInput.value.trim();
            if (!name) {
                setResult("enter a new group name");
                return;
            }
            const renamed = await LLMR.renameQueueGroup(select.value, name);
            invalidateQueueGroupCache(session.source_session_id);
            await currentQueueGroup({force: true});
            await renderGroupPanel();
            await updateSessionBadge({refreshGroup: false});
            setResult(`renamed queue group: ${renamed.queue_group?.name || name}`);
        };

        const del = document.createElement("button");
        del.textContent = "Delete selected group";
        del.style.cssText = "margin-top:6px;padding:6px 8px;border-radius:999px;border:1px solid #e68a9c;background:#241828;color:#f7eef8;width:100%;";
        del.onclick = async () => {
            if (select.value === "default") {
                setResult("default queue cannot be deleted");
                return;
            }
            const result = await LLMR.deleteQueueGroup(select.value, {
                cancelQueued: true,
                reason: "deleted from overlay"
            });
            invalidateQueueGroupCache(session.source_session_id);
            invalidateNextDraftCache(session.source_session_id);
            await currentQueueGroup({force: true});
            await renderGroupPanel();
            await updateSessionBadge({refreshGroup: false});
            await loadQueue();
            setResult(`deleted queue group\ncancelled queued: ${result.cancelled_count || 0}`);
        };

        panel.append(select, assign, input, create, renameInput, rename, del);
    }

    async function toggleGroupPanel() {
        const panel = byId("llmr-group-panel");
        if (!panel) return;

        const isHidden = panel.style.display === "none";
        panel.style.display = isHidden ? "block" : "none";
        if (isHidden) await renderGroupPanel();
    }

    async function disconnectCurrentSession() {
        const session = currentSession();
        await LLMR.setSessionDisconnected(session.source_session_id, true);
        byId("llmr-overlay")?.remove();
        return {ok: true, disconnected: true, source_session_id: session.source_session_id};
    }

    async function reconnectCurrentSession() {
        const session = currentSession();
        await LLMR.setSessionDisconnected(session.source_session_id, false);
        await ensureOverlay(true);
        return {ok: true, disconnected: false, source_session_id: session.source_session_id};
    }

    async function resetOverlay() {
        byId("llmr-overlay")?.remove();
        await ensureOverlay(true);
        return {ok: true, overlay_version: OVERLAY_VERSION};
    }

    function overlayIsCurrent(existing) {
        if (!existing) return false;
        if (existing.dataset.llmrOverlayVersion !== OVERLAY_VERSION) return false;
        if (!existing.querySelector("#llmr-capture-assistant")) return false;
        if (!existing.querySelector("#llmr-capture-user")) return false;
        if (!existing.querySelector("#llmr-insert")) return false;
        if (!existing.querySelector("#llmr-queue")) return false;
        if (!existing.querySelector("#llmr-group")) return false;
        if (!existing.querySelector("#llmr-status")) return false;
        return true;
    }

    async function ensureOverlay(force = false) {
        const session = currentSession();

        if (await LLMR.isSessionDisconnected(session.source_session_id)) {
            byId("llmr-overlay")?.remove();
            return;
        }

        const existing = byId("llmr-overlay");
        if (existing && (force || !overlayIsCurrent(existing))) {
            existing.remove();
        } else if (existing) {
            await updateSessionBadge({refreshGroup: false});
            prefetchNextDraft("overlay-existing");
            return;
        }

        const box = document.createElement("div");
        box.id = "llmr-overlay";
        box.dataset.llmrOverlayVersion = OVERLAY_VERSION;
        box.style.cssText = "position:fixed;z-index:2147483647;right:12px;bottom:84px;background:#171018;color:#f7eef8;border:1px solid #5a3c5e;border-radius:14px;padding:0;font:11px system-ui,sans-serif;box-shadow:0 12px 34px rgba(0,0,0,.38);min-width:220px;max-width:285px";

        box.innerHTML = `
          <div id="llmr-handle" title="Drag to move. Double-click to reset." style="cursor:move;padding:9px 9px 0;">
            <div style="display:flex;gap:8px;align-items:center;justify-content:space-between;">
              <div style="font-weight:800;color:#f0c9dd;">LLMR ChatGPT</div>
              <div style="display:flex;gap:4px;align-items:center;">
                <button id="llmr-refresh-mini" title="Refresh live sessions, groups, providers, and queue" style="padding:2px 6px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.5px;cursor:pointer;">↻</button>
                <button id="llmr-mini" title="Fold or unfold overlay" style="padding:2px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:9.5px;cursor:pointer;min-width:44px;">Fold</button>
              </div>
            </div>
            <div id="llmr-session" style="margin-top:3px;color:#c9adca;font-family:ui-monospace,monospace;font-size:10px;max-width:255px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">session: detecting…</div>
            <div id="llmr-queue-group" style="margin-top:2px;margin-bottom:7px;color:#c9adca;font-family:ui-monospace,monospace;font-size:10px;max-width:255px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">group: detecting…</div>
          </div>
          <div id="llmr-body" style="padding:0 9px 9px;">
            <div id="llmr-route-panel" style="border:1px solid #3b293f;background:#100b11;border-radius:12px;padding:6px;margin-bottom:7px;"></div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:5px;">
              <button id="llmr-capture-assistant" title="Queue latest assistant message for grouped-session handoff" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Queue assistant</button>
              <button id="llmr-capture-user" title="Queue latest user message for grouped-session handoff" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Queue user</button>
              <button id="llmr-insert" title="Insert next queued ChatGPT capture from another session in this group" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Insert next from group</button>
              <button id="llmr-queue" title="Open queue panel and add/view group queued items" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Queue panel</button>
              <button id="llmr-group" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Group</button>
              <button id="llmr-status" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Status</button>
            </div>
            <div id="llmr-queue-panel" style="display:none;margin-top:7px;max-height:320px;overflow:auto;border-top:1px solid #3b293f;padding-top:6px;">
              <label style="display:block;color:#c9adca;font-size:10px;margin-bottom:3px;">Queue source</label>
              <select id="llmr-queue-source-mode" style="width:100%;background:#100b11;color:#f7eef8;border:1px solid #6a4c70;border-radius:10px;padding:5px;margin-bottom:6px;">
                <option value="all_insertable">All insertable</option>
                <option value="chatgpt_captures">ChatGPT captures</option>
                <option value="provider_responses">Provider responses</option>
              </select>
              <div id="llmr-queue-list"></div>
            </div>
            <div id="llmr-group-panel" style="display:none;margin-top:7px;max-height:260px;overflow:auto;border-top:1px solid #3b293f;padding-top:6px;"></div>
            <div id="llmr-result" style="margin-top:7px;max-width:310px;white-space:pre-wrap;color:#c9adca;font-family:ui-monospace,monospace;font-size:11px;"></div>
          </div>
        `;

        document.documentElement.appendChild(box);

        const saved = await LLMR.storageGet(OVERLAY_POSITION_KEY);
        applyPosition(box, saved);
        installDrag(box);
        await Promise.allSettled([
            requestLiveChatGptSessions({force: true}),
            loadDispatchProviders({force: true}),
            loadPromptWrappers({force: true}),
            loadPromptWrapperSelections(),
            loadRouteSetupSections(),
            loadRoutePanelQueueGroups({force: true})
        ]);
        await updateSessionBadge();
        renderRoutePanel();

        const collapsed = await LLMR.storageGet(LLMR.OVERLAY_COLLAPSED_KEY);
        applyCollapsed(Boolean(collapsed));

        byId("llmr-refresh-mini").onclick = async event => {
            event.preventDefault();
            event.stopPropagation();
            await refreshOverlayState("button", {forceLiveSessions: true});
        };

        byId("llmr-mini").onclick = async event => {
            event.preventDefault();
            event.stopPropagation();
            const body = byId("llmr-body");
            await setCollapsed(body?.style.display !== "none");
        };

        byId("llmr-status").onclick = async () => {
            const status = LLMR.ChatGPTAdapter.detailedStatus
                ? LLMR.ChatGPTAdapter.detailedStatus()
                : LLMR.ChatGPTAdapter.status({includeLatest: true});
            const group = await currentQueueGroup();
            await updateSessionBadge();
            setResult(JSON.stringify({
                detected: status.detected,
                overlay_version: OVERLAY_VERSION,
                session_label: status.session_label,
                source_session_id: status.session.source_session_id,
                conversation_id: status.session.conversation_id,
                queue_group: group,
                composer_found: status.composer.found,
                latest_assistant: status.latestAssistant,
                latest_user: status.latestUser
            }, null, 2));
        };

        byId("llmr-capture-assistant").onclick = () => captureLatest("assistant").catch(err => setResult(`queue assistant error: ${err}`));
        byId("llmr-capture-user").onclick = () => captureLatest("user").catch(err => setResult(`queue user error: ${err}`));
        byId("llmr-insert").onclick = () => insertNext().catch(err => setResult(`insert next from group error: ${err}`));
        byId("llmr-queue").onclick = () => toggleQueue().catch(err => setResult(`queue error: ${err}`));
        byId("llmr-group").onclick = () => toggleGroupPanel().catch(err => setResult(`group error: ${err}`));
        const queueSourceSelect = byId("llmr-queue-source-mode");
        if (queueSourceSelect) {
            queueSourceSelect.value = queueSourceMode();
            queueSourceSelect.onchange = () => {
                LLMR.__overlayState.queueSourceMode = queueSourceSelect.value;
                invalidateNextDraftCache();
                loadQueue({silent: false}).catch(err => setResult(`queue mode error: ${err}`));
            };
        }
        loadDispatchProviders({force: true}).then(() => renderRoutePanel()).catch(() => renderRoutePanel());
    }

    refreshOverlayState("script-load").catch((err) => {
        console.warn("[local_llm_router] initial overlay refresh failed", err);
    });

    if (LLMR.__overlayRouteWatcherVersion !== OVERLAY_VERSION) {
        if (Array.isArray(LLMR.__routeWatchers)) {
            LLMR.__routeWatchers = LLMR.__routeWatchers.filter(
                watcher => !watcher.__llmrOverlayRouteWatcher
            );
        }

        LLMR.__overlayRouteWatcherVersion = OVERLAY_VERSION;

        const overlayRouteWatcher = async () => {
            const refresh = LLMR.__overlayRefreshState || refreshOverlayState;
            await refresh("route-change");
        };
        overlayRouteWatcher.__llmrOverlayRouteWatcher = true;

        LLMR.onRouteChange(overlayRouteWatcher);
    }

    if (LLMR.__overlayRefreshIntervalId) {
        clearInterval(LLMR.__overlayRefreshIntervalId);
    }

    LLMR.__overlayRefreshIntervalId = setInterval(async () => {
        if (byId("llmr-queue-panel")?.style.display !== "none") {
            try {
                await loadQueue();
            } catch (_) {
            }
        }
        await updateSessionBadge({refreshGroup: false}).catch(() => {
        });
        await refreshKnownProviderSessions({force: true}).catch(() => []);
        await requestLiveChatGptSessions({force: true}).catch(() => []);
        await loadDispatchProviders({force: true}).catch(() => []);
        await loadPromptWrappers({force: true}).catch(() => []);
        await loadPromptWrapperSelections().catch(() => ({}));
        renderRoutePanelIfSafe("interval");

        if (byId("llmr-queue-panel")?.style.display === "none") {
            prefetchNextDraft("interval");
        }
    }, 4500);

    if (LLMR.__overlayMessageListener) {
        try {
            chrome.runtime.onMessage.removeListener(LLMR.__overlayMessageListener);
        } catch (err) {
            console.warn("[local_llm_router] old overlay listener removal failed", err);
        }
    }

    LLMR.__overlayMessageListener = (request, sender, sendResponse) => {
        if (request?.type === "LLMR_REFRESH_OVERLAY_STATE") {
            refreshOverlayState(request.reason || "message").then(sendResponse).catch((err) => {
                sendResponse({ok: false, error: String(err)});
            });
            return true;
        }

        if (request?.type === "LLMR_STATUS") {
            (async () => {
                const session = currentSession();
                const disconnected = await LLMR.isSessionDisconnected(session.source_session_id);
                const group = await currentQueueGroup();
                if (!disconnected) await updateSessionBadge();
                const status = LLMR.ChatGPTAdapter.detailedStatus
                    ? LLMR.ChatGPTAdapter.detailedStatus()
                    : LLMR.ChatGPTAdapter.status({includeLatest: true});
                sendResponse({...status, disconnected, queue_group: group});
            })();
            return true;
        }

        if (request?.type === "LLMR_RESET_OVERLAY") {
            resetOverlay().then(sendResponse);
            return true;
        }

        if (request?.type === "LLMR_DISCONNECT_SESSION") {
            disconnectCurrentSession().then(sendResponse);
            return true;
        }

        if (request?.type === "LLMR_RECONNECT_SESSION") {
            reconnectCurrentSession().then(sendResponse);
            return true;
        }

        if (request?.type === "LLMR_EXPORT_ROUTE_SOURCE") {
            try {
                const sourceKind = request.source_kind || "latest_user";
                const role = sourceKind === "latest_assistant" ? "assistant" : "user";
                const payload = getLatestPayloadForRole(role);
                if (!payload) {
                    sendResponse({ok: false, error: `no latest ${role} message found`, role});
                    return true;
                }
                sendResponse({ok: true, role, payload, session: currentSession()});
            } catch (err) {
                sendResponse({ok: false, error: String(err)});
            }
            return true;
        }

        if (request?.type === "LLMR_INSERT_CAPTURE_PAYLOAD") {
            try {
                const payload = request.payload || {};
                const inserted = payload.format_capture
                    ? LLMR.ChatGPTAdapter.insertFormatCapture(payload.format_capture)
                    : LLMR.ChatGPTAdapter.insertDraft(payload.text || "");
                sendResponse({
                    ok: Boolean(inserted?.ok),
                    inserted,
                    session: currentSession(),
                    source_role: payload.role || null,
                    message: inserted?.ok ? "inserted into ChatGPT composer; review and send manually" : inserted?.reason || "insert failed"
                });
            } catch (err) {
                sendResponse({ok: false, error: String(err)});
            }
            return true;
        }

        if (request?.type === "LLMR_SET_SESSION_LABEL") {
            (async () => {
                try {
                    const session = currentSession();
                    const response = await LLMR.setSessionLabel({
                        sourceSessionId: session.source_session_id,
                        provider: session.provider,
                        label: request.label || LLMR.ChatGPTAdapter.getSessionLabel(),
                        labelSource: "user_saved"
                    });
                    await updateSessionBadge({refreshGroup: true});
                    sendResponse(response);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_CAPTURE_LATEST") {
            (async () => {
                try {
                    if (await currentDisconnected()) {
                        sendResponse({ok: false, error: "this session is disconnected"});
                        return;
                    }
                    const safeRole = captureRoleLabel(request.role || "assistant");
                    const payload = getLatestPayloadForRole(safeRole);
                    if (!payload) {
                        sendResponse({ok: false, error: `no latest ${safeRole} message found`, role: safeRole});
                        return;
                    }
                    sendResponse({
                        ok: true,
                        role: safeRole,
                        response: await LLMR.postCapture({
                            ...payload,
                            metadata: {...(payload.metadata || {}), ...promptWrapperOptions({source: "overlay_capture_button"})}
                        })
                    });
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_INSERT_NEXT") {
            (async () => {
                try {
                    sendResponse(await insertPreparedNextDraft({setOverlayResult: true}));
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_INSERT_SELECTED") {
            (async () => {
                try {
                    if (!request.draft) {
                        sendResponse({ok: false, error: "missing draft payload"});
                        return;
                    }
                    const draft = await draftWithPromptWrapperForInsert(request.draft, request.options || {});
                    sendResponse(await insertDraftItem(draft));
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_CANCEL_DRAFT") {
            (async () => {
                try {
                    const response = await LLMR.cancelDraft(request.delivery_id, {reason: "cancelled from popup"});
                    invalidateNextDraftCache();
                    sendResponse(response);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_DISPATCH_DRAFT") {
            (async () => {
                try {
                    await loadDispatchProviders({force: true});
                    const provider = (LLMR.__overlayState.dispatchProviders || [])
                        .find(item => item.provider_id === request.provider_id) || selectedDispatchProvider();
                    if (!provider) {
                        sendResponse({ok: false, error: "no dispatch-capable provider"});
                        return;
                    }
                    const response = await LLMR.dispatchToProvider(provider.provider_id, {
                        deliveryId: request.delivery_id,
                        queueGroupId: request.queue_group_id || null,
                        manualConfirmed: Boolean(request.manual_confirmed),
                        options: request.options || {}
                    });
                    invalidateNextDraftCache();
                    sendResponse({ok: response.ok, response, provider});
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_ROUTE_ACTION") {
            (async () => {
                try {
                    if (request.source_kind) LLMR.__overlayState.routeSourceKind = request.source_kind;
                    if (request.target_kind) setRouteTargetKind(request.target_kind);
                    if (request.queue_source_mode) LLMR.__overlayState.queueSourceMode = request.queue_source_mode;
                    if (request.options?.prompt_wrapper_id) {
                        await loadPromptWrappers({force: true});
                        await loadPromptWrapperSelections();
                        await savePromptWrapperSelection({enabled: true, wrapperId: request.options.prompt_wrapper_id});
                    }
                    sendResponse(await executeRouteAction());
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_CLEAR_QUEUE") {
            (async () => {
                try {
                    const group = await currentQueueGroup();
                    const response = await LLMR.clearQueuedDrafts({
                        queueGroupId: group.queue_group_id,
                        provider: providerFilterForSourceMode(request.source_mode || queueSourceMode()),
                        reason: `cleared from popup (${queueSourceModeLabel(request.source_mode || queueSourceMode())})`
                    });
                    invalidateNextDraftCache();
                    sendResponse(response);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_QUEUE_STATUS") {
            (async () => {
                try {
                    const session = currentSession();
                    const group = await currentQueueGroup();
                    const sourceMode = request.source_mode || queueSourceMode();
                    LLMR.__overlayState.queueSourceMode = sourceMode;
                    const drafts = filterDraftsForSourceMode(filterUsableDrafts(await LLMR.getQueuedDrafts({
                        excludeSourceSessionId: session.source_session_id,
                        provider: providerFilterForSourceMode(sourceMode),
                        queueGroupId: group.queue_group_id
                    })), sourceMode);

                    const next = drafts.length
                        ? {found: true, draft: drafts[0]}
                        : {found: false, draft: null, reason: "no queued draft matched request"};
                    cacheNextDraft(session.source_session_id, group.queue_group_id, next);

                    sendResponse({ok: true, session, queue_group: group, drafts});
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_QUEUE_GROUP_STATUS") {
            (async () => {
                try {
                    sendResponse({
                        ok: true,
                        session: currentSession(),
                        queue_group: await currentQueueGroup(),
                        queue_groups: (await LLMR.listQueueGroups()).queue_groups || []
                    });
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_SET_QUEUE_GROUP") {
            (async () => {
                try {
                    const session = currentSession();
                    const response = await LLMR.setSessionQueueGroup({
                        sourceSessionId: session.source_session_id,
                        queueGroupId: request.queue_group_id,
                        provider: session.provider,
                        label: currentSessionLabel()
                    });

                    if (response?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, response.queue_group);
                    } else {
                        invalidateQueueGroupCache(session.source_session_id);
                    }

                    invalidateNextDraftCache(session.source_session_id);
                    await updateSessionBadge({refreshGroup: false});
                    prefetchNextDraft("popup-set-queue-group", {force: true});

                    sendResponse(response);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_CREATE_QUEUE_GROUP") {
            (async () => {
                try {
                    const created = await LLMR.createQueueGroup(request.name || "New queue");
                    const session = currentSession();
                    const assigned = await LLMR.setSessionQueueGroup({
                        sourceSessionId: session.source_session_id,
                        queueGroupId: created.queue_group_id,
                        provider: session.provider,
                        label: currentSessionLabel()
                    });

                    if (assigned?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, assigned.queue_group);
                    } else if (created?.queue_group) {
                        setCachedQueueGroup(session.source_session_id, created.queue_group);
                    } else {
                        invalidateQueueGroupCache(session.source_session_id);
                    }

                    invalidateNextDraftCache(session.source_session_id);
                    await updateSessionBadge({refreshGroup: false});
                    prefetchNextDraft("popup-create-queue-group", {force: true});

                    sendResponse(created);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        if (request?.type === "LLMR_DELETE_QUEUE_GROUP") {
            (async () => {
                try {
                    const session = currentSession();
                    const response = await LLMR.deleteQueueGroup(request.queue_group_id, {
                        cancelQueued: true,
                        reason: "deleted from popup"
                    });

                    invalidateQueueGroupCache(session.source_session_id);
                    invalidateNextDraftCache(session.source_session_id);
                    await currentQueueGroup({force: true});
                    await updateSessionBadge({refreshGroup: false});
                    prefetchNextDraft("popup-delete-queue-group", {force: true});

                    sendResponse(response);
                } catch (err) {
                    sendResponse({ok: false, error: String(err)});
                }
            })();
            return true;
        }

        return false;
    };

    chrome.runtime.onMessage.addListener(LLMR.__overlayMessageListener);
})();