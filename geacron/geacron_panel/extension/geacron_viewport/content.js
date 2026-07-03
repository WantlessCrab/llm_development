// extension/geacron_viewport/content.js
(() => {
    "use strict";

    const STATE_KEY = "__GEACRON_PANEL_CDP_INJECTION_STATE__";
    const RUN_KEY = "__GEACRON_PANEL_CDP_IFRAME_SHELL_RUNNING__";
    const MENU_ID = "geacron-panel-control-menu";
    const STORAGE_KEY = "geacron.panel.opacity.v1";

    const OPACITY_MIN = 0.25;
    const OPACITY_MAX = 1.0;
    const OPACITY_STEP = 0.05;

    const state = window[STATE_KEY] || {
        applied: false,
        startedAt: new Date().toISOString(),
        lastReason: "starting",
        source: "extension_content_script"
    };
    window[STATE_KEY] = state;

    const update = (reason, extra = {}) => {
        Object.assign(state, extra, {
            source: state.source || "extension_content_script",
            lastReason: reason,
            updatedAt: new Date().toISOString()
        });

        try {
            document.documentElement.setAttribute("data-geacron-panel-cdp-injection", reason);
        } catch (_) {
        }

        return state;
    };

    const clampOpacity = (value) => {
        const n = Number(value);
        if (!Number.isFinite(n)) return 1.0;
        return Math.max(OPACITY_MIN, Math.min(OPACITY_MAX, Math.round(n * 100) / 100));
    };

    const percentFromOpacity = (opacity) => Math.round(clampOpacity(opacity) * 100);

    const opacityFromPercent = (percent) => clampOpacity(Number(percent) / 100);

    const findMapIframe = () =>
        document.querySelector('iframe[src*="/map/atlas/mapal.html"]') ||
        document.querySelector("iframe#m0id") ||
        document.querySelector("iframe.m0");

    const extensionRuntimeAvailable = () =>
        typeof chrome !== "undefined" &&
        chrome.runtime &&
        typeof chrome.runtime.sendMessage === "function";

    const storageAvailable = () =>
        typeof chrome !== "undefined" &&
        chrome.storage &&
        chrome.storage.local;

    const storageGetOpacity = () => new Promise((resolve) => {
        if (!storageAvailable()) {
            resolve(null);
            return;
        }

        chrome.storage.local.get([STORAGE_KEY], (items) => {
            const value = items ? items[STORAGE_KEY] : null;
            resolve(Number.isFinite(Number(value)) ? Number(value) : null);
        });
    });

    const storageSetOpacity = (opacity) => {
        if (!storageAvailable()) return;
        chrome.storage.local.set({[STORAGE_KEY]: clampOpacity(opacity)});
    };

    const nativeRequest = (payload) => new Promise((resolve) => {
        if (!extensionRuntimeAvailable()) {
            resolve({
                ok: false,
                error: "extension runtime is unavailable"
            });
            return;
        }

        chrome.runtime.sendMessage(
            Object.assign({target: "geacron-panel-native"}, payload),
            (response) => {
                const lastError = chrome.runtime.lastError;
                if (lastError) {
                    resolve({
                        ok: false,
                        error: lastError.message || String(lastError)
                    });
                    return;
                }

                resolve(response || {
                    ok: false,
                    error: "empty extension response"
                });
            }
        );
    });

    const setMenuStatus = (menu, message, tone = "neutral") => {
        const status = menu.querySelector("[data-geacron-panel-status]");
        if (!status) return;
        status.textContent = message;
        status.dataset.tone = tone;
    };

    const setMenuOpacityValue = (menu, opacity) => {
        const clamped = clampOpacity(opacity);
        const percent = percentFromOpacity(clamped);
        const slider = menu.querySelector("[data-geacron-opacity-slider]");
        const value = menu.querySelector("[data-geacron-opacity-value]");
        if (slider) slider.value = String(percent);
        if (value) value.textContent = `${percent}%`;
    };

    const commitOpacity = async (menu, opacity) => {
        const clamped = clampOpacity(opacity);
        setMenuOpacityValue(menu, clamped);
        setMenuStatus(menu, "Applying…", "neutral");

        const response = await nativeRequest({
            action: "opacity-set",
            opacity: clamped
        });

        if (response && response.ok) {
            const observed = response.observed && Number.isFinite(Number(response.observed.opacity))
                ? Number(response.observed.opacity)
                : clamped;
            setMenuOpacityValue(menu, observed);
            storageSetOpacity(observed);
            setMenuStatus(menu, "Saved", "ok");
            window.setTimeout(() => setMenuStatus(menu, "Ready", "neutral"), 1200);
            return;
        }

        const error = response && response.error ? response.error : "opacity update failed";
        setMenuStatus(menu, error, "error");
    };

    const hydrateMenu = async (menu) => {
        const stored = await storageGetOpacity();
        if (stored !== null) {
            setMenuOpacityValue(menu, stored);
        }

        const response = await nativeRequest({action: "opacity-get"});
        if (response && response.ok) {
            const observed = response.observed && Number.isFinite(Number(response.observed.opacity))
                ? Number(response.observed.opacity)
                : Number(response.configured_opacity);
            setMenuOpacityValue(menu, observed);
            storageSetOpacity(observed);
            setMenuStatus(menu, "Ready", "neutral");
            return;
        }

        if (stored !== null) {
            setMenuStatus(menu, "Host setup needed", "error");
        } else {
            setMenuOpacityValue(menu, 1.0);
            setMenuStatus(menu, "Host setup needed", "error");
        }
    };

    const ensureControlMenu = () => {
        if (window.top !== window.self || !document.body) return null;

        const mount = document.querySelector("#geacron-iframe-only-shell") || document.body;

        const existing = document.getElementById(MENU_ID);
        if (existing) {
            if (mount && existing.parentElement !== mount) {
                mount.appendChild(existing);
            }
            return existing;
        }
        const menu = document.createElement("section");
        menu.id = MENU_ID;
        menu.setAttribute("aria-label", "GeaCron panel controls");
        menu.innerHTML = `
            <div class="geacron-panel-card">
                <div class="geacron-panel-row geacron-panel-title-row">
                    <span class="geacron-panel-kicker">Panel</span>
                    <span class="geacron-panel-status" data-geacron-panel-status data-tone="neutral">Loading…</span>
                </div>
                <div class="geacron-panel-row geacron-panel-opacity-row">
                    <span class="geacron-panel-label">Opacity</span>
                    <button type="button" class="geacron-panel-button" data-geacron-opacity-minus aria-label="Decrease opacity">−</button>
                    <input
                        class="geacron-panel-slider"
                        data-geacron-opacity-slider
                        type="range"
                        min="25"
                        max="100"
                        step="5"
                        value="100"
                        aria-label="Window opacity"
                    />
                    <button type="button" class="geacron-panel-button" data-geacron-opacity-plus aria-label="Increase opacity">+</button>
                    <span class="geacron-panel-value" data-geacron-opacity-value>100%</span>
                </div>
            </div>
        `;

        const style = document.createElement("style");
        style.textContent = `
            #${MENU_ID} {
                position: fixed;
                top: 18px;
                left: 28px;
                z-index: 2147483647;
                pointer-events: auto;
                font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                color: rgba(80, 54, 74, 0.96);
            }

            #${MENU_ID} .geacron-panel-card {
                min-width: 268px;
                border: 1px solid rgba(219, 151, 183, 0.42);
                border-radius: 18px;
                background:
                    linear-gradient(135deg, rgba(255, 251, 246, 0.88), rgba(252, 236, 246, 0.84));
                box-shadow:
                    0 12px 28px rgba(72, 43, 67, 0.14),
                    inset 0 1px 0 rgba(255, 255, 255, 0.72);
                backdrop-filter: blur(10px);
                -webkit-backdrop-filter: blur(10px);
                padding: 9px 11px 10px;
            }

            #${MENU_ID} .geacron-panel-row {
                display: flex;
                align-items: center;
                gap: 8px;
            }

            #${MENU_ID} .geacron-panel-title-row {
                justify-content: space-between;
                margin-bottom: 7px;
                padding: 0 2px;
            }

            #${MENU_ID} .geacron-panel-kicker {
                font-size: 11px;
                line-height: 1;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: rgba(155, 83, 126, 0.86);
            }

            #${MENU_ID} .geacron-panel-status {
                font-size: 11px;
                line-height: 1;
                font-weight: 650;
                color: rgba(106, 78, 96, 0.76);
            }

            #${MENU_ID} .geacron-panel-status[data-tone="ok"] {
                color: rgba(91, 128, 96, 0.92);
            }

            #${MENU_ID} .geacron-panel-status[data-tone="error"] {
                color: rgba(158, 68, 91, 0.94);
            }

            #${MENU_ID} .geacron-panel-label {
                flex: 0 0 auto;
                min-width: 58px;
                font-size: 13px;
                font-weight: 750;
                color: rgba(87, 62, 80, 0.92);
            }

            #${MENU_ID} .geacron-panel-button {
                flex: 0 0 auto;
                width: 24px;
                height: 24px;
                border-radius: 999px;
                border: 1px solid rgba(201, 133, 170, 0.44);
                background: rgba(255, 255, 255, 0.74);
                color: rgba(121, 73, 103, 0.96);
                font-size: 15px;
                font-weight: 800;
                line-height: 20px;
                padding: 0;
                cursor: pointer;
            }

            #${MENU_ID} .geacron-panel-button:hover {
                background: rgba(255, 245, 250, 0.94);
                border-color: rgba(191, 108, 153, 0.62);
            }

            #${MENU_ID} .geacron-panel-slider {
                flex: 1 1 auto;
                min-width: 88px;
                accent-color: rgb(204, 128, 168);
                cursor: pointer;
            }

            #${MENU_ID} .geacron-panel-value {
                flex: 0 0 42px;
                text-align: right;
                font-size: 12px;
                font-weight: 800;
                color: rgba(91, 64, 84, 0.92);
            }
        `;

        menu.prepend(style);
        mount.appendChild(menu);

        const slider = menu.querySelector("[data-geacron-opacity-slider]");
        const minus = menu.querySelector("[data-geacron-opacity-minus]");
        const plus = menu.querySelector("[data-geacron-opacity-plus]");

        if (slider) {
            slider.addEventListener("input", () => {
                setMenuOpacityValue(menu, opacityFromPercent(slider.value));
                setMenuStatus(menu, "Release to apply", "neutral");
            });
            slider.addEventListener("change", () => {
                commitOpacity(menu, opacityFromPercent(slider.value));
            });
        }

        if (minus) {
            minus.addEventListener("click", () => {
                const current = opacityFromPercent(slider ? slider.value : 100);
                commitOpacity(menu, current - OPACITY_STEP);
            });
        }

        if (plus) {
            plus.addEventListener("click", () => {
                const current = opacityFromPercent(slider ? slider.value : 100);
                commitOpacity(menu, current + OPACITY_STEP);
            });
        }

        hydrateMenu(menu);
        return menu;
    };

    const apply = () => {
        const iframe = findMapIframe();

        if (!iframe) {
            return update("map_iframe_not_found", {
                ok: false,
                applied: false,
                iframeCount: document.querySelectorAll("iframe").length,
                iframeSources: Array.from(document.querySelectorAll("iframe")).map(
                    (frame) => frame.src || frame.getAttribute("src") || ""
                )
            });
        }

        if (document.querySelector("#geacron-iframe-only-shell")) {
            ensureControlMenu();
            return update("already_applied", {
                ok: true,
                applied: true,
                selector: iframe.id ? `#${iframe.id}` : 'iframe[src*="/map/atlas/mapal.html"]',
                src: iframe.src || iframe.getAttribute("src") || ""
            });
        }

        const originalParent = iframe.parentElement;
        const originalNext = iframe.nextSibling;
        const originalStyle = iframe.getAttribute("style");

        window.__GEACRON_IFRAME_ONLY_RESTORE__ = () => {
            const shell = document.querySelector("#geacron-iframe-only-shell");
            const menu = document.getElementById(MENU_ID);

            if (originalNext && originalParent) {
                originalParent.insertBefore(iframe, originalNext);
            } else if (originalParent) {
                originalParent.appendChild(iframe);
            }

            if (originalStyle === null) iframe.removeAttribute("style");
            else iframe.setAttribute("style", originalStyle);

            document.documentElement.style.overflow = "";
            document.body.style.overflow = "";
            document.body.style.margin = "";
            document.body.style.background = "";

            if (menu) menu.remove();
            if (shell) shell.remove();

            return update("restored", {
                ok: true,
                applied: false
            });
        };

        const shell = document.createElement("div");
        shell.id = "geacron-iframe-only-shell";
        shell.style.position = "fixed";
        shell.style.inset = "0";
        shell.style.width = "100vw";
        shell.style.height = "100vh";
        shell.style.margin = "0";
        shell.style.padding = "0";
        shell.style.overflow = "hidden";
        shell.style.background = "white";
        shell.style.zIndex = "2147483647";

        document.documentElement.style.overflow = "hidden";
        document.body.style.overflow = "hidden";
        document.body.style.margin = "0";
        document.body.style.background = "white";

        iframe.style.display = "block";
        iframe.style.position = "absolute";
        iframe.style.left = "0";
        iframe.style.top = "0";
        iframe.style.width = "100vw";
        iframe.style.height = "100vh";
        iframe.style.border = "0";
        iframe.style.margin = "0";
        iframe.style.padding = "0";
        iframe.style.maxWidth = "none";
        iframe.style.maxHeight = "none";

        shell.appendChild(iframe);
        document.body.appendChild(shell);
        ensureControlMenu();

        try {
            iframe.contentWindow.dispatchEvent(new Event("resize"));
        } catch (_) {
        }

        return update("iframe_only_shell_applied", {
            ok: true,
            applied: true,
            selector: iframe.id ? `#${iframe.id}` : 'iframe[src*="/map/atlas/mapal.html"]',
            src: iframe.src || iframe.getAttribute("src") || ""
        });
    };

    if (window.top !== window.self) {
        return update("subframe_noop", {
            ok: true,
            applied: false
        });
    }

    if (!document.body) {
        update("waiting_for_body", {
            ok: false,
            applied: false
        });
    } else {
        const first = apply();
        ensureControlMenu();
        if (first && first.ok && first.applied) return first;
    }

    if (window[RUN_KEY]) {
        ensureControlMenu();
        return update("poller_already_running", {
            ok: true,
            applied: false
        });
    }

    window[RUN_KEY] = true;

    const started = Date.now();
    const timer = window.setInterval(() => {
        try {
            if (document.body) {
                const result = apply();
                ensureControlMenu();

                if (result && result.ok && result.applied) {
                    window.clearInterval(timer);
                    window[RUN_KEY] = false;
                }
            }

            if (Date.now() - started > 16000) {
                window.clearInterval(timer);
                window[RUN_KEY] = false;

                update("timed_out_waiting_for_iframe", {
                    ok: false,
                    applied: false
                });
            }
        } catch (error) {
            window.clearInterval(timer);
            window[RUN_KEY] = false;

            update("exception", {
                ok: false,
                applied: false,
                error: String((error && error.stack) || error)
            });
        }
    }, 250);

    ensureControlMenu();

    return update("polling_for_iframe", {
        ok: true,
        applied: false
    });
})();