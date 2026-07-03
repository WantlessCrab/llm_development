// extension/geacron_viewport/service_worker.js
"use strict";

const NATIVE_HOST = "com.wantless.geacron_panel";

function callNative(payload) {
    return new Promise((resolve) => {
        chrome.runtime.sendNativeMessage(NATIVE_HOST, payload, (response) => {
            const lastError = chrome.runtime.lastError;
            if (lastError) {
                resolve({
                    ok: false,
                    error: lastError.message || String(lastError),
                    native_host: NATIVE_HOST
                });
                return;
            }

            resolve(response || {
                ok: false,
                error: "native host returned an empty response",
                native_host: NATIVE_HOST
            });
        });
    });
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || message.target !== "geacron-panel-native") {
        return false;
    }

    const action = String(message.action || "");
    if (action !== "opacity-get" && action !== "opacity-set") {
        sendResponse({
            ok: false,
            error: `unsupported action: ${action}`
        });
        return false;
    }

    callNative(message)
        .then(sendResponse)
        .catch((error) => {
            sendResponse({
                ok: false,
                error: String((error && error.stack) || error)
            });
        });

    return true;
});