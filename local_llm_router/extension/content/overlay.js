globalThis.LLMR = globalThis.LLMR || {};

(function initOverlay() {
    if (!LLMR.ChatGPTAdapter?.detect()) return;

    const OVERLAY_VERSION = "formatcapture-v0.4.1-insert-fastpath";
    const OVERLAY_POSITION_KEY = "llmr.overlay.position.v1";
    const DEFAULT_OFFSET = {right: 12, bottom: 84};
    const QUEUE_GROUP_CACHE_TTL_MS = 15000;
    const NEXT_DRAFT_CACHE_TTL_MS = 7000;
    const POST_INSERT_QUEUE_REFRESH_DELAY_MS = 250;

    LLMR.__overlayState = LLMR.__overlayState || {
        queueGroupBySession: {},
        nextDraftBySessionGroup: {},
        nextDraftInFlightByKey: {},
        pendingInsertedDeliveryIds: {},
        postInsertRefreshTimer: null
    };

    LLMR.__overlayState.queueGroupBySession = LLMR.__overlayState.queueGroupBySession || {};
    LLMR.__overlayState.nextDraftBySessionGroup = LLMR.__overlayState.nextDraftBySessionGroup || {};
    LLMR.__overlayState.nextDraftInFlightByKey = LLMR.__overlayState.nextDraftInFlightByKey || {};
    LLMR.__overlayState.pendingInsertedDeliveryIds = LLMR.__overlayState.pendingInsertedDeliveryIds || {};
    LLMR.__overlayState.postInsertRefreshTimer = LLMR.__overlayState.postInsertRefreshTimer || null;

    function byId(id) {
        return document.getElementById(id);
    }

    function setResult(text) {
        const result = byId("llmr-result");
        if (result) result.textContent = text;
    }

    function currentSession() {
        return LLMR.ChatGPTAdapter.getSessionIdentity();
    }

    function currentSessionLabel() {
        const session = currentSession();
        return session.conversation_title || session.conversation_id || session.source_session_id;
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

    function nextDraftCacheKey(sessionId, groupId) {
        return `${sessionId || "unknown"}::${groupId || "default"}`;
    }

    function invalidateNextDraftCache(sessionId = null, groupId = null) {
        if (!sessionId) {
            LLMR.__overlayState.nextDraftBySessionGroup = {};
            return;
        }

        if (groupId) {
            delete LLMR.__overlayState.nextDraftBySessionGroup[nextDraftCacheKey(sessionId, groupId)];
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

        groupBadge.textContent = `queue: ${group.name}`;
        groupBadge.title = group.queue_group_id;
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
            groupBadge.textContent = "queue: refreshing…";
            groupBadge.title = session.source_session_id;
        }

        fetchQueueGroup(session)
            .then(group => applyQueueGroupBadge(session.source_session_id, group))
            .catch(err => {
                const current = currentSession();
                if (current.source_session_id !== session.source_session_id) return;
                const badge = byId("llmr-queue-group");
                if (badge) {
                    badge.textContent = "queue: unavailable";
                    badge.title = String(err);
                }
            });
    }

    async function updateSessionBadge({refreshGroup = false} = {}) {
        const badge = byId("llmr-session");
        if (!badge) return;

        try {
            const session = currentSession();
            badge.textContent = `session: ${LLMR.ChatGPTAdapter.getSessionLabel()}`;
            badge.title = session.source_session_id;

            refreshQueueGroupBadge({force: refreshGroup});
        } catch (err) {
            badge.textContent = "session: unavailable";
            badge.title = String(err);
            const groupBadge = byId("llmr-queue-group");
            if (groupBadge) groupBadge.textContent = "queue: unavailable";
        }
    }

    function cacheNextDraft(sessionId, groupId, next) {
        const key = nextDraftCacheKey(sessionId, groupId);

        if (!next?.found || !next?.draft || isPendingInserted(next.draft.delivery_id)) {
            delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            return;
        }

        LLMR.__overlayState.nextDraftBySessionGroup[key] = {
            next,
            cachedAt: nowMs()
        };
    }

    function cachedNextDraft(sessionId, groupId) {
        const key = nextDraftCacheKey(sessionId, groupId);
        const entry = LLMR.__overlayState.nextDraftBySessionGroup[key];
        if (!entry) return null;
        if (nowMs() - entry.cachedAt > NEXT_DRAFT_CACHE_TTL_MS) {
            delete LLMR.__overlayState.nextDraftBySessionGroup[key];
            return null;
        }
        return entry.next;
    }

    async function fetchNextDraftForSessionGroup(session, group, {force = false} = {}) {
        const key = nextDraftCacheKey(session.source_session_id, group.queue_group_id);

        if (!force) {
            const cached = cachedNextDraft(session.source_session_id, group.queue_group_id);
            if (cached) return cached;
        }

        if (LLMR.__overlayState.nextDraftInFlightByKey[key]) {
            return LLMR.__overlayState.nextDraftInFlightByKey[key];
        }

        const promise = LLMR.getNextDraft({
            excludeSourceSessionId: session.source_session_id,
            provider: "chatgpt",
            queueGroupId: group.queue_group_id
        }).then(async next => {
            if (next?.found && next?.draft && isPendingInserted(next.draft.delivery_id)) {
                const drafts = filterUsableDrafts(await LLMR.getQueuedDrafts({
                    excludeSourceSessionId: session.source_session_id,
                    provider: "chatgpt",
                    queueGroupId: group.queue_group_id
                }));

                next = drafts.length
                    ? {found: true, draft: drafts[0]}
                    : {found: false, draft: null, reason: "no usable queued draft after local pending-insert filter"};
            }

            cacheNextDraft(session.source_session_id, group.queue_group_id, next);
            return next;
        }).finally(() => {
            delete LLMR.__overlayState.nextDraftInFlightByKey[key];
        });

        LLMR.__overlayState.nextDraftInFlightByKey[key] = promise;
        return promise;
    }

    function prefetchNextDraft(reason = "background", {force = false} = {}) {
        const session = currentSession();

        currentQueueGroup()
            .then(group => fetchNextDraftForSessionGroup(session, group, {force}))
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

    async function refreshOverlayState(reason = "manual") {
        const session = currentSession();
        const previousSessionId = LLMR.__overlayLastSessionId || null;
        const sessionChanged = Boolean(previousSessionId && previousSessionId !== session.source_session_id);

        LLMR.__overlayLastSessionId = session.source_session_id;

        await ensureOverlay(false);
        await updateSessionBadge({refreshGroup: sessionChanged});

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

    async function saveCurrentPosition(box) {
        const rect = box.getBoundingClientRect();
        await LLMR.storageSet(OVERLAY_POSITION_KEY, {
            left: Math.round(rect.left),
            top: Math.round(rect.top)
        });
    }

    async function resetPosition(box) {
        await LLMR.storageSet(OVERLAY_POSITION_KEY, null);
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
        await LLMR.storageSet(LLMR.OVERLAY_COLLAPSED_KEY, Boolean(collapsed));
        applyCollapsed(Boolean(collapsed));
    }

    function applyCollapsed(collapsed) {
        const body = byId("llmr-body");
        const toggle = byId("llmr-mini");
        const box = byId("llmr-overlay");

        if (!body || !toggle || !box) return;

        body.style.display = collapsed ? "none" : "block";
        toggle.textContent = collapsed ? "Expand" : "Mini";
        box.style.minWidth = collapsed ? "190px" : "250px";
    }

    function draftLabel(draft) {
        const title = draft.conversation_title || "Untitled";
        const turn = draft.turn_testid || "no-turn";
        return `${title} · ${LLMR.shortId(draft.conversation_id || "", 8, 5)} · ${turn}`;
    }

    function draftMeta(draft) {
        return `${draft.body_length} chars · ${LLMR.shortId(draft.source_session_id, 12, 7)} · ${draft.body_hash}`;
    }

    async function captureLatest() {
        if (await currentDisconnected()) {
            setResult("This session is disconnected. Reconnect from the extension popup to use LLMR here.");
            return;
        }

        await updateSessionBadge();
        setResult("capturing…");

        const payload = LLMR.ChatGPTAdapter.getLatestAssistantMessage();
        if (!payload) {
            setResult("No latest assistant message found.");
            return;
        }

        const response = await LLMR.postCapture(payload);

        if (response.deduped) {
            const deliveries = response.delivery_ids || [];
            setResult(
                `already captured\n` +
                `${deliveries.length ? "requeued duplicate delivery" : "no new delivery"}\n` +
                `message: ${LLMR.shortId(response.message_id)}\n` +
                `route: ${response.route_decision}\n` +
                `deliveries: ${deliveries.map(id => LLMR.shortId(id)).join(", ")}`
            );
        } else {
            setResult(
                `queued\n` +
                `route: ${response.route_decision}\n` +
                `message: ${LLMR.shortId(response.message_id)}\n` +
                `deliveries: ${response.delivery_ids.map(id => LLMR.shortId(id)).join(", ")}`
            );
        }

        invalidateNextDraftCache();
        if (byId("llmr-queue-panel")?.style.display !== "none") {
            await loadQueue();
        } else {
            prefetchNextDraft("capture-latest", {force: true});
        }
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
        const next = await fetchNextDraftForSessionGroup(session, group);

        if (!next.found || !next.draft) {
            prefetchNextDraft("insert-prepared-empty");
            return {
                ok: false,
                error: next.reason || "no queued draft found",
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
            provider: "chatgpt",
            reason: "cleared from overlay"
        });
        invalidateNextDraftCache();
        await loadQueue();
        setResult(`cleared queue: ${group.name}\ncancelled: ${response.cancelled_count}`);
    }

    function renderQueue(drafts) {
        const list = byId("llmr-queue-list");
        if (!list) return;

        list.innerHTML = "";

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
            meta.textContent = draftMeta(draft);

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

            const cancel = document.createElement("button");
            cancel.type = "button";
            cancel.textContent = "Delete from queue";
            cancel.style.cssText = "margin-top:5px;padding:5px 8px;border-radius:999px;border:1px solid #e68a9c;background:#241828;color:#f7eef8;width:100%;";
            cancel.onclick = () => cancelDraft(draft.delivery_id).catch(err => setResult(`delete error: ${err}`));

            row.append(title, meta, insert, cancel);
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
        const drafts = filterUsableDrafts(await LLMR.getQueuedDrafts({
            excludeSourceSessionId: session.source_session_id,
            provider: "chatgpt",
            queueGroupId: group.queue_group_id
        }));

        renderQueue(drafts);

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
        const current = await currentQueueGroup();
        const groups = (await LLMR.listQueueGroups()).queue_groups || [];

        panel.innerHTML = "";

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
            await loadQueue();
            setResult("session queue group updated");
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
            await loadQueue();
            setResult(`created queue group: ${created.queue_group?.name || name}`);
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

        panel.append(select, assign, input, create, del);
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
        if (!existing.querySelector("#llmr-capture")) return false;
        if (!existing.querySelector("#llmr-insert")) return false;
        if (!existing.querySelector("#llmr-queue")) return false;
        if (!existing.querySelector("#llmr-group")) return false;
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
        box.style.cssText = "position:fixed;z-index:2147483647;right:12px;bottom:84px;background:#171018;color:#f7eef8;border:1px solid #5a3c5e;border-radius:14px;padding:0;font:12px system-ui,sans-serif;box-shadow:0 12px 34px rgba(0,0,0,.38);min-width:250px;max-width:340px";

        box.innerHTML = `
          <div id="llmr-handle" title="Drag to move. Double-click to reset." style="cursor:move;padding:9px 9px 0;">
            <div style="display:flex;gap:8px;align-items:center;justify-content:space-between;">
              <div style="font-weight:800;color:#f0c9dd;">LLMR ChatGPT</div>
              <button id="llmr-mini" title="Collapse or expand" style="padding:3px 7px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;font-size:10.5px;cursor:pointer;">Mini</button>
            </div>
            <div id="llmr-session" style="margin-top:3px;color:#c9adca;font-family:ui-monospace,monospace;font-size:10.5px;max-width:305px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">session: detecting…</div>
            <div id="llmr-queue-group" style="margin-top:2px;margin-bottom:7px;color:#c9adca;font-family:ui-monospace,monospace;font-size:10.5px;max-width:305px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">queue: detecting…</div>
          </div>
          <div id="llmr-body" style="padding:0 9px 9px;">
            <div style="display:flex;gap:5px;flex-wrap:wrap;">
              <button id="llmr-capture" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Capture latest</button>
              <button id="llmr-insert" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Insert next</button>
              <button id="llmr-queue" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Queue</button>
              <button id="llmr-group" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Group</button>
              <button id="llmr-status" style="padding:6px 8px;border-radius:999px;border:1px solid #6a4c70;background:#241828;color:#f7eef8;">Status</button>
            </div>
            <div id="llmr-queue-panel" style="display:none;margin-top:7px;max-height:320px;overflow:auto;border-top:1px solid #3b293f;padding-top:6px;">
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
        await updateSessionBadge();

        const collapsed = await LLMR.storageGet(LLMR.OVERLAY_COLLAPSED_KEY);
        applyCollapsed(Boolean(collapsed));

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
                latest: status.latestAssistant
            }, null, 2));
        };

        byId("llmr-capture").onclick = () => captureLatest().catch(err => setResult(`capture error: ${err}`));
        byId("llmr-insert").onclick = () => insertNext().catch(err => setResult(`insert error: ${err}`));
        byId("llmr-queue").onclick = () => toggleQueue().catch(err => setResult(`queue error: ${err}`));
        byId("llmr-group").onclick = () => toggleGroupPanel().catch(err => setResult(`group error: ${err}`));
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

        if (byId("llmr-queue-panel")?.style.display === "none") {
            prefetchNextDraft("interval");
        }
    }, 5000);

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
                sendResponse({...LLMR.ChatGPTAdapter.status(), disconnected, queue_group: group});
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

        if (request?.type === "LLMR_CAPTURE_LATEST") {
            (async () => {
                try {
                    if (await currentDisconnected()) {
                        sendResponse({ok: false, error: "this session is disconnected"});
                        return;
                    }
                    const payload = LLMR.ChatGPTAdapter.getLatestAssistantMessage();
                    if (!payload) {
                        sendResponse({ok: false, error: "no latest assistant message found"});
                        return;
                    }
                    sendResponse({ok: true, response: await LLMR.postCapture(payload)});
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
                    sendResponse(await insertDraftItem(request.draft));
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

        if (request?.type === "LLMR_CLEAR_QUEUE") {
            (async () => {
                try {
                    const group = await currentQueueGroup();
                    const response = await LLMR.clearQueuedDrafts({
                        queueGroupId: group.queue_group_id,
                        provider: "chatgpt",
                        reason: "cleared from popup"
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
                    const drafts = filterUsableDrafts(await LLMR.getQueuedDrafts({
                        excludeSourceSessionId: session.source_session_id,
                        provider: "chatgpt",
                        queueGroupId: group.queue_group_id
                    }));

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