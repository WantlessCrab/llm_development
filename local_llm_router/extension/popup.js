const out = document.getElementById("out");
const queue = document.getElementById("queue");
const sessionState = document.getElementById("sessionState");
const queueGroupSelect = document.getElementById("queueGroupSelect");
const newQueueGroupName = document.getElementById("newQueueGroupName");

function shortId(value, left = 8, right = 4) {
    const s = String(value || "");
    if (s.length <= left + right + 3) return s;
    return `${s.slice(0, left)}…${s.slice(-right)}`;
}

function print(x) {
    out.textContent = typeof x === "string" ? x : JSON.stringify(x, null, 2);
}

function setSessionStateFromStatus(res) {
    if (!res?.ok || !res.session) {
        sessionState.textContent = "Session state unavailable.";
        return;
    }

    const label = res.session_label || shortId(res.session.source_session_id, 12, 7);
    const disconnected = Boolean(res.disconnected);
    const group = res.queue_group?.name || "unknown queue";

    sessionState.textContent =
        `${disconnected ? "DISCONNECTED" : "connected"}\n` +
        `${label}\n` +
        `queue: ${group}\n` +
        `${shortId(res.session.source_session_id, 18, 10)}`;

    sessionState.style.color = disconnected ? "var(--danger)" : "var(--muted)";
}

function send(message) {
    return new Promise(resolve => {
        chrome.runtime.sendMessage(message, (res) => {
            if (chrome.runtime.lastError) {
                const err = {ok: false, error: chrome.runtime.lastError.message};
                print(err);
                resolve(err);
                return;
            }
            resolve(res || {ok: false, error: "no response"});
        });
    });
}

function summarizeRefreshResponse(res) {
    if (!res) return {ok: false, error: "no response"};

    if (Array.isArray(res.results)) {
        return {
            ok: res.ok,
            result: "overlay refresh complete",
            reason: res.reason,
            matched_tabs: res.matched_tabs,
            refreshed: res.refreshed,
            failed: res.failed,
            failed_tabs: res.results
                .filter(item => !item.ok && !item.skipped)
                .map(item => ({
                    title: item.tab?.title,
                    url: item.tab?.url,
                    error: item.error || item.response?.error
                }))
        };
    }

    return res;
}

function summarizeResponse(res) {
    if (!res) return {ok: false, error: "no response"};

    if (res.ok && res.response?.deduped) {
        const deliveries = res.response.delivery_ids || [];
        return {
            ok: true,
            result: deliveries.length ? "already captured; duplicate requeued" : "already captured",
            message_id: shortId(res.response.message_id),
            deliveries: deliveries.map(id => shortId(id)),
            route_decision: res.response.route_decision
        };
    }

    if (res.ok && res.response?.delivery_ids) {
        return {
            ok: true,
            result: "queued",
            message_id: shortId(res.response.message_id),
            deliveries: res.response.delivery_ids.map(id => shortId(id)),
            route_decision: res.response.route_decision
        };
    }

    if (res.ok && res.draft && res.inserted) {
        return {
            ok: true,
            result: "draft inserted",
            status: res.draft.status || "draft_inserted",
            delivery_id: shortId(res.draft.delivery_id),
            from: shortId(res.draft.source_session_id, 12, 7),
            method: res.inserted.method,
            body_length: res.draft.body_length
        };
    }

    if (res.ok && res.session) {
        return {
            ok: true,
            provider: res.provider,
            detected: res.detected,
            disconnected: Boolean(res.disconnected),
            queue_group: res.queue_group,
            session_label: res.session_label,
            source_session_id: res.session.source_session_id,
            conversation_id: res.session.conversation_id,
            composer_found: res.composer?.found,
            latestAssistant: res.latestAssistant
        };
    }

    return res;
}

async function sendAndPrint(message) {
    const res = await send(message);
    if (res?.session) setSessionStateFromStatus(res);
    print(summarizeResponse(res));
    return res;
}

function draftTitle(draft) {
    return draft.conversation_title || "Untitled conversation";
}

function draftMeta(draft) {
    return [
        `${draft.body_length} chars`,
        draft.queue_group_name || draft.queue_group_id || "default",
        shortId(draft.source_session_id, 12, 7),
        draft.turn_testid || "no-turn",
        draft.body_hash
    ].join(" · ");
}

function renderQueue(drafts) {
    queue.innerHTML = "";

    if (!drafts.length) {
        const empty = document.createElement("div");
        empty.className = "queue-item";
        empty.textContent = "No queued drafts available for this active tab/queue group.";
        queue.appendChild(empty);
        return;
    }

    for (const draft of drafts) {
        const row = document.createElement("div");
        row.className = "queue-item";

        const title = document.createElement("div");
        title.className = "queue-title";
        title.textContent = draftTitle(draft);

        const meta = document.createElement("div");
        meta.className = "queue-meta";
        meta.textContent = draftMeta(draft);

        const insert = document.createElement("button");
        insert.textContent = "Insert this draft";
        insert.onclick = async () => {
            insert.disabled = true;
            insert.textContent = "Inserting…";

            const res = await send({
                type: "LLMR_INSERT_SELECTED_ACTIVE_TAB",
                draft
            });

            print(summarizeResponse(res));
            await loadQueue();

            insert.disabled = false;
            insert.textContent = "Insert this draft";
        };

        const del = document.createElement("button");
        del.textContent = "Delete from queue";
        del.className = "danger";
        del.onclick = async () => {
            del.disabled = true;
            const res = await send({
                type: "LLMR_CANCEL_DRAFT_ACTIVE_TAB",
                delivery_id: draft.delivery_id
            });
            print(res);
            await loadQueue();
        };

        row.append(title, meta, insert, del);
        queue.appendChild(row);
    }
}

async function loadQueue() {
    print("Loading selectable queue…");
    const res = await send({type: "LLMR_QUEUE_ACTIVE_TAB"});

    if (!res?.ok) {
        queue.innerHTML = "";
        print(res || {ok: false, error: "queue request failed"});
        return;
    }

    renderQueue(res.drafts || []);
    print({
        ok: true,
        result: "queue loaded",
        count: (res.drafts || []).length,
        queue_group: res.queue_group,
        target_session_id: res.session?.source_session_id
    });
}

async function refreshQueueGroups() {
    const res = await send({type: "LLMR_QUEUE_GROUP_STATUS_ACTIVE_TAB"});
    if (!res?.ok) {
        print(res || {ok: false, error: "queue group request failed"});
        return;
    }

    queueGroupSelect.innerHTML = "";
    for (const group of res.queue_groups || []) {
        const opt = document.createElement("option");
        opt.value = group.queue_group_id;
        opt.textContent = `${group.name}${group.is_default ? " (default)" : ""}`;
        opt.selected = group.queue_group_id === res.queue_group?.queue_group_id;
        queueGroupSelect.appendChild(opt);
    }

    setSessionStateFromStatus({
        ok: true,
        session: res.session,
        session_label: res.session?.conversation_title || shortId(res.session?.source_session_id, 12, 7),
        disconnected: false,
        queue_group: res.queue_group
    });
}

document.getElementById("status").onclick = () => {
    sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"});
};

document.getElementById("capture").onclick = () => {
    sendAndPrint({type: "LLMR_CAPTURE_ACTIVE_TAB"});
};

document.getElementById("insertNext").onclick = () => {
    sendAndPrint({type: "LLMR_INSERT_NEXT_ACTIVE_TAB"});
};

document.getElementById("loadQueue").onclick = () => {
    loadQueue();
};

document.getElementById("clearQueue").onclick = async () => {
    const res = await send({type: "LLMR_CLEAR_QUEUE_ACTIVE_TAB"});
    print(res);
    await loadQueue();
};

document.getElementById("resetOverlay").onclick = async () => {
    const res = await send({type: "LLMR_RESET_OVERLAY_ACTIVE_TAB"});
    print(res);
};

document.getElementById("refreshActiveOverlay").onclick = async () => {
    const res = await send({
        type: "LLMR_REFRESH_ACTIVE_OVERLAY",
        reason: "popup-active"
    });
    print(summarizeRefreshResponse(res));
    await sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"});
};

document.getElementById("refreshAllOverlays").onclick = async () => {
    const res = await send({
        type: "LLMR_REFRESH_ALL_OVERLAYS",
        reason: "popup-all"
    });
    print(summarizeRefreshResponse(res));
    await sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"});
};

document.getElementById("assignQueueGroup").onclick = async () => {
    const res = await send({
        type: "LLMR_SET_QUEUE_GROUP_ACTIVE_TAB",
        queue_group_id: queueGroupSelect.value
    });
    print(res);
    await refreshQueueGroups();
    await loadQueue();
};

document.getElementById("createQueueGroup").onclick = async () => {
    const name = newQueueGroupName.value.trim();
    if (!name) {
        print({ok: false, error: "enter a queue group name"});
        return;
    }

    const res = await send({
        type: "LLMR_CREATE_QUEUE_GROUP_ACTIVE_TAB",
        name
    });
    print(res);
    newQueueGroupName.value = "";
    await refreshQueueGroups();
    await loadQueue();
};

document.getElementById("deleteQueueGroup").onclick = async () => {
    if (queueGroupSelect.value === "default") {
        print({ok: false, error: "default queue cannot be deleted"});
        return;
    }

    const res = await send({
        type: "LLMR_DELETE_QUEUE_GROUP_ACTIVE_TAB",
        queue_group_id: queueGroupSelect.value
    });
    print(res);
    await refreshQueueGroups();
    await loadQueue();
};

document.getElementById("disconnectSession").onclick = async () => {
    const res = await send({type: "LLMR_DISCONNECT_ACTIVE_SESSION"});
    queue.innerHTML = "";
    print(res);
    await sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"});
};

document.getElementById("reconnectSession").onclick = async () => {
    const res = await send({type: "LLMR_RECONNECT_ACTIVE_SESSION"});
    print(res);
    await sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"});
};

document.getElementById("inbox").onclick = () => {
    chrome.tabs.create({url: "http://127.0.0.1:8015/draft-inbox"});
};

sendAndPrint({type: "LLMR_STATUS_ACTIVE_TAB"}).then(refreshQueueGroups);