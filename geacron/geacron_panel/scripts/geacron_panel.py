#!/usr/bin/env python3
# scripts/geacron_panel.py
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import signal
import re
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError as exc:
    print("ERROR: Python 3.11+ is required because this tool uses tomllib.", file=sys.stderr)
    raise SystemExit(2) from exc

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "config" / "config.toml"
RUNTIME_DIR = ROOT / "runtime"
PROFILE_DIR = RUNTIME_DIR / "profile"
LOG_DIR = RUNTIME_DIR / "logs"
LOG_FILE = LOG_DIR / "panel.log"
EXTENSION_DIR = ROOT / "extension" / "geacron_viewport"
NATIVE_HOST_NAME = "com.wantless.geacron_panel"
NATIVE_HOST_SCRIPT = ROOT / "scripts" / "geacron_native_host.sh"
GEACRON_EXTENSION_ID = "djoehloiemmkoopmcechgnbnmcgbjdop"
NATIVE_HOST_CONFIG_ROOTS = {
    "google-chrome": Path.home() / ".config" / "google-chrome",
    "chromium": Path.home() / ".config" / "chromium",
}

REQUIRED_BY_COMMAND: dict[str, list[str]] = {
    "doctor": ["xrandr", "wmctrl"],
    "launch": ["xrandr", "wmctrl"],
    "status": ["wmctrl"],
    "close": ["wmctrl"],
    "suggest-monitor": ["xrandr"],
    "set-monitor": ["xrandr"],
}

DEPENDENCY_HINTS = {
    "xrandr": "Install package: x11-xserver-utils",
    "wmctrl": "Install package: wmctrl",
    "xprop": "Install package: x11-utils; required for X11 window opacity and work-area strut detection",
    "xdotool": "Install package: xdotool; optional fallback only for forced window close",
}

VALID_MODES = {"window", "desktop"}
VALID_DESKTOP_LAYERS = {"below", "normal"}
MIN_WINDOW_OPACITY = 0.25
MAX_WINDOW_OPACITY = 1.0

CDP_IFRAME_SHELL_SCRIPT = r"""
(() => {
  const STATE_KEY = "__GEACRON_PANEL_CDP_INJECTION_STATE__";
  const RUN_KEY = "__GEACRON_PANEL_CDP_IFRAME_SHELL_RUNNING__";

  const MENU_ID = "geacron-panel-control-menu";
  const MENU_OWNER = "cdp";

  const OPACITY_REQUEST_KEY = "__GEACRON_PANEL_OPACITY_REQUEST__";
  const OPACITY_STATE_KEY = "__GEACRON_PANEL_OPACITY_STATE__";

  const REDIRECT_REQUEST_KEY = "__GEACRON_PANEL_REDIRECT_REQUEST__";
  const REDIRECT_STATE_KEY = "__GEACRON_PANEL_REDIRECT_STATE__";

  const PANEL_SYNC_TIMER_KEY = "__GEACRON_PANEL_CONTROL_MENU_SYNC_TIMER__";

  const OPACITY_MIN = 0.25;
  const OPACITY_MAX = 1.0;
  const OPACITY_STEP = 0.05;
  let opacityRequestSequence = 0;
  let redirectRequestSequence = 0;

  const state = window[STATE_KEY] || {
    applied: false,
    startedAt: new Date().toISOString(),
    lastReason: "starting",
    source: "cdp_shell_script"
  };
  window[STATE_KEY] = state;

  const update = (reason, extra = {}) => {
    Object.assign(state, extra, {
      source: state.source || "cdp_shell_script",
      lastReason: reason,
      updatedAt: new Date().toISOString()
    });
    try {
      document.documentElement.setAttribute("data-geacron-panel-cdp-injection", reason);
    } catch (_) {}
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
    document.querySelector('#geacron-iframe-only-shell iframe[src*="/map/atlas/mapal.html"]') ||
    document.querySelector("#geacron-iframe-only-shell iframe#m0id") ||
    document.querySelector('iframe[src*="/map/atlas/mapal.html"]') ||
    document.querySelector("iframe#m0id") ||
    document.querySelector("iframe.m0");

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

  const currentOpacityState = () => {
    const value = window[OPACITY_STATE_KEY];
    return value && typeof value === "object" ? value : null;
  };

  const fallbackRedirectState = () => ({
    ok: true,
    status: "ready",
    requestId: null,
    enabled: true,
    mode: "google",
    openTarget: "_blank",
    profiles: {
      google: {
        label: "Google",
        url_template: "https://www.google.com/search?q={coArea}+{date}"
      },
      wikipedia: {
        label: "Wiki",
        url_template: "https://en.wikipedia.org/wiki/Special:Search?search={coArea}"
      },
      britannica: {
        label: "Britannica",
        url_template: "https://www.britannica.com/search?query={coArea}+{date}"
      },
      jstor: {
        label: "JSTOR",
        url_template: "https://www.jstor.org/action/doBasicSearch?Query={coArea}+{date}&so=rel"
      }
    }
  });

  const currentRedirectState = () => {
    const value = window[REDIRECT_STATE_KEY];
    return value && typeof value === "object" ? value : fallbackRedirectState();
  };

  const normalizeRedirectMode = (backend) => {
    if (!backend || backend.enabled === false) return "off";
    const mode = String(backend.mode || "google").trim() || "google";
    return mode === "off" ? "off" : mode;
  };

  const populateRedirectOptions = (menu, backend) => {
    const select = menu.querySelector("[data-geacron-redirect-select]");
    if (!select) return;

    const profiles = backend && typeof backend.profiles === "object" ? backend.profiles : {};
    const serialized = JSON.stringify(profiles);
    if (select.dataset.profileSignature === serialized) return;

    select.dataset.profileSignature = serialized;
    select.textContent = "";

    const off = document.createElement("option");
    off.value = "off";
    off.textContent = "Off";
    select.appendChild(off);

    for (const [profileId, profile] of Object.entries(profiles)) {
      const option = document.createElement("option");
      option.value = profileId;
      option.textContent = String(profile?.label || profileId);
      select.appendChild(option);
    }
  };

  const setMenuRedirectValue = (menu, mode) => {
    const select = menu.querySelector("[data-geacron-redirect-select]");
    if (!select) return;
    const value = String(mode || "off");
    if (Array.from(select.options).some((option) => option.value === value)) {
      select.value = value;
    } else {
      select.value = "off";
    }
  };

  const applyRedirectStateToMapIframe = (backend) => {
    const iframe = findMapIframe();
    const frameWindow = iframe?.contentWindow;
    if (!frameWindow || !backend) return;

    try {
      const state = frameWindow.__GEACRON_PANEL_LOCATION_REDIRECT_STATE__;
      if (state && typeof state.setConfig === "function") {
        state.setConfig(backend);
      }
    } catch (_) {}
  };

  const syncRedirectFromBackendState = (menu) => {
    const backend = currentRedirectState();
    populateRedirectOptions(menu, backend);

    const pendingRequestId = menu.dataset.pendingRedirectRequestId || "";
    if (pendingRequestId) {
      if (!backend || backend.requestId !== pendingRequestId) {
        setMenuRedirectValue(menu, menu.dataset.pendingRedirectMode || normalizeRedirectMode(backend));
        setMenuStatus(menu, "Applying…", "neutral");
        applyRedirectStateToMapIframe(backend);
        return;
      }

      delete menu.dataset.pendingRedirectRequestId;
      delete menu.dataset.pendingRedirectMode;
    }

    setMenuRedirectValue(menu, normalizeRedirectMode(backend));
    applyRedirectStateToMapIframe(backend);
  };

  const syncOpacityFromBackendState = (menu) => {
    const backend = currentOpacityState();
    const pendingRequestId = menu.dataset.pendingOpacityRequestId || "";
    const userEditing = menu.dataset.userEditingOpacity === "1";

    if (pendingRequestId) {
      if (!backend || backend.requestId !== pendingRequestId) {
        if (Number.isFinite(Number(menu.dataset.pendingOpacityValue))) {
          setMenuOpacityValue(menu, Number(menu.dataset.pendingOpacityValue));
        }
        setMenuStatus(menu, "Applying…", "neutral");
        return;
      }

      delete menu.dataset.pendingOpacityRequestId;
      delete menu.dataset.pendingOpacityValue;
    }

    if (userEditing) {
      setMenuStatus(menu, "Release to apply", "neutral");
      return;
    }

    if (backend && Number.isFinite(Number(backend.observedOpacity))) {
      setMenuOpacityValue(menu, Number(backend.observedOpacity));
    } else if (backend && Number.isFinite(Number(backend.configuredOpacity))) {
      setMenuOpacityValue(menu, Number(backend.configuredOpacity));
    }

    if (!backend) {
      setMenuStatus(menu, "Syncing…", "neutral");
      return;
    }

    if (backend.ok === false) {
      setMenuStatus(menu, backend.error || "Opacity failed", "error");
      return;
    }

    if (backend.status === "applying") {
      setMenuStatus(menu, "Applying…", "neutral");
      return;
    }

    if (backend.status === "saved") {
      setMenuStatus(menu, "Saved", "ok");
      return;
    }

    setMenuStatus(menu, "Ready", "neutral");
  };

  const syncMenuFromBackendState = (menu) => {
    syncOpacityFromBackendState(menu);
    syncRedirectFromBackendState(menu);
  };

  const requestOpacity = (menu, opacity) => {
    const clamped = clampOpacity(opacity);
    opacityRequestSequence += 1;

    const request = {
      id: `${Date.now()}-${opacityRequestSequence}`,
      opacity: clamped,
      requestedAt: new Date().toISOString()
    };

    window[OPACITY_REQUEST_KEY] = request;

    menu.dataset.pendingOpacityRequestId = request.id;
    menu.dataset.pendingOpacityValue = String(clamped);
    delete menu.dataset.userEditingOpacity;

    setMenuOpacityValue(menu, clamped);
    setMenuStatus(menu, "Applying…", "neutral");
  };

  const requestRedirectMode = (menu, mode) => {
    const value = String(mode || "off").trim() || "off";
    redirectRequestSequence += 1;

    const request = {
      id: `${Date.now()}-${redirectRequestSequence}`,
      mode: value,
      requestedAt: new Date().toISOString()
    };

    window[REDIRECT_REQUEST_KEY] = request;
    menu.dataset.pendingRedirectRequestId = request.id;
    menu.dataset.pendingRedirectMode = value;
    setMenuRedirectValue(menu, value);
    setMenuStatus(menu, "Applying…", "neutral");
  };

  const ensureOpacityMenu = () => {
    if (window.top !== window.self || !document.body) return null;

    const mount = document.querySelector("#geacron-iframe-only-shell") || document.body;

    let existing = document.getElementById(MENU_ID);
    if (existing && existing.dataset.geacronPanelOwner !== MENU_OWNER) {
      existing.remove();
      existing = null;
    }

    if (existing) {
      if (mount && existing.parentElement !== mount) {
        mount.appendChild(existing);
      }
      syncMenuFromBackendState(existing);
      return existing;
    }

    const menu = document.createElement("section");
    menu.id = MENU_ID;
    menu.dataset.geacronPanelOwner = MENU_OWNER;
    menu.setAttribute("aria-label", "GeaCron panel controls");

    menu.innerHTML = `
      <style>
        #${MENU_ID} {
          position: fixed;
          top: 4px;
          left: 28px;
          z-index: 2147483647;
          pointer-events: auto;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          color: rgba(80, 54, 74, 0.96);
        }

        #${MENU_ID} .geacron-panel-card {
          min-width: 0;
          width: auto;
          border: 1px solid rgba(219, 151, 183, 0.42);
          border-radius: 14px;
          background:
            linear-gradient(135deg, rgba(255, 251, 246, 0.88), rgba(252, 236, 246, 0.84));
          box-shadow:
            0 10px 22px rgba(72, 43, 67, 0.12),
            inset 0 1px 0 rgba(255, 255, 255, 0.72);
          backdrop-filter: blur(10px);
          -webkit-backdrop-filter: blur(10px);
          padding: 6px 8px;
        }

        #${MENU_ID} .geacron-panel-row {
          display: flex;
          align-items: center;
          gap: 5px;
        }

        #${MENU_ID} .geacron-panel-status {
          display: none;
        }

        #${MENU_ID} .geacron-panel-button {
          flex: 0 0 auto;
          width: 22px;
          height: 22px;
          border-radius: 999px;
          border: 1px solid rgba(201, 133, 170, 0.44);
          background: rgba(255, 255, 255, 0.74);
          color: rgba(121, 73, 103, 0.96);
          font-size: 14px;
          font-weight: 800;
          line-height: 18px;
          padding: 0;
          cursor: pointer;
        }

        #${MENU_ID} .geacron-panel-button:hover {
          background: rgba(255, 245, 250, 0.94);
          border-color: rgba(191, 108, 153, 0.62);
        }

        #${MENU_ID} .geacron-panel-slider {
          flex: 0 0 96px;
          width: 96px;
          min-width: 96px;
          accent-color: rgb(204, 128, 168);
          cursor: pointer;
        }

        #${MENU_ID} .geacron-panel-value {
          flex: 0 0 33px;
          width: 33px;
          text-align: right;
          font-size: 12px;
          font-weight: 800;
          color: rgba(91, 64, 84, 0.92);
          margin-left: -2px;
        }

        #${MENU_ID} .geacron-panel-redirect-select {
          flex: 0 0 96px;
          width: 96px;
          max-width: 96px;
          min-width: 96px;
          border-radius: 999px;
          border: 1px solid rgba(201, 133, 170, 0.44);
          background: rgba(255, 255, 255, 0.78);
          color: rgba(91, 64, 84, 0.96);
          font-size: 12px;
          font-weight: 750;
          line-height: 20px;
          padding: 1px 20px 1px 8px;
          cursor: pointer;
        }
      </style>
      <div class="geacron-panel-card">
        <div class="geacron-panel-row geacron-panel-control-row">
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
          <select class="geacron-panel-redirect-select" data-geacron-redirect-select aria-label="Location link redirect"></select>
          <span class="geacron-panel-status" data-geacron-panel-status data-tone="neutral">Ready</span>
        </div>
      </div>
    `;

    mount.appendChild(menu);

    const slider = menu.querySelector("[data-geacron-opacity-slider]");
    const minus = menu.querySelector("[data-geacron-opacity-minus]");
    const plus = menu.querySelector("[data-geacron-opacity-plus]");
    const redirectSelect = menu.querySelector("[data-geacron-redirect-select]");

    if (slider) {
      const sliderKeys = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End"]);

      const markSliderEditing = (event) => {
        if (event && typeof event.stopPropagation === "function") {
          event.stopPropagation();
        }
        menu.dataset.userEditingOpacity = "1";
      };

      const applySliderValue = (event) => {
        if (event && typeof event.stopPropagation === "function") {
          event.stopPropagation();
        }
        requestOpacity(menu, opacityFromPercent(slider.value));
      };

      slider.addEventListener("pointerdown", markSliderEditing);
      slider.addEventListener("input", (event) => {
        markSliderEditing(event);
        setMenuOpacityValue(menu, opacityFromPercent(slider.value));
        setMenuStatus(menu, "Release to apply", "neutral");
      });
      slider.addEventListener("change", applySliderValue);
      slider.addEventListener("pointerup", applySliderValue);
      slider.addEventListener("keydown", (event) => {
        if (sliderKeys.has(event.key)) {
          markSliderEditing(event);
        }
      });
      slider.addEventListener("keyup", (event) => {
        if (sliderKeys.has(event.key)) {
          applySliderValue(event);
        }
      });
      slider.addEventListener("blur", () => {
        if (menu.dataset.userEditingOpacity === "1" && !menu.dataset.pendingOpacityRequestId) {
          requestOpacity(menu, opacityFromPercent(slider.value));
        }
      });
    }

    if (minus) {
      minus.addEventListener("click", (event) => {
        event.stopPropagation();
        const current = opacityFromPercent(slider ? slider.value : 100);
        requestOpacity(menu, current - OPACITY_STEP);
      });
    }

    if (plus) {
      plus.addEventListener("click", (event) => {
        event.stopPropagation();
        const current = opacityFromPercent(slider ? slider.value : 100);
        requestOpacity(menu, current + OPACITY_STEP);
      });
    }

    if (redirectSelect) {
      redirectSelect.addEventListener("pointerdown", (event) => event.stopPropagation());
      redirectSelect.addEventListener("click", (event) => event.stopPropagation());
      redirectSelect.addEventListener("change", (event) => {
        event.stopPropagation();
        requestRedirectMode(menu, redirectSelect.value);
      });
    }

    if (!window[PANEL_SYNC_TIMER_KEY]) {
      window[PANEL_SYNC_TIMER_KEY] = window.setInterval(() => {
        const current = document.getElementById(MENU_ID);
        if (current) syncMenuFromBackendState(current);
      }, 500);
    }

    syncMenuFromBackendState(menu);
    return menu;
  };

  const apply = () => {
    const iframe = findMapIframe();

    if (!iframe) {
      ensureOpacityMenu();
      return update("map_iframe_not_found", {
        ok: false,
        applied: false,
        iframeCount: document.querySelectorAll("iframe").length,
        iframeSources: Array.from(document.querySelectorAll("iframe")).map((f) => f.src || f.getAttribute("src") || "")
      });
    }

    if (document.querySelector("#geacron-iframe-only-shell")) {
      ensureOpacityMenu();
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
      const menu = document.querySelector(`#${MENU_ID}[data-geacron-panel-owner="${MENU_OWNER}"]`);

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
      update("restored", {ok: true, applied: false});
      return "Restored. Reload also restores.";
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
    ensureOpacityMenu();

    try {
      iframe.contentWindow.dispatchEvent(new Event("resize"));
    } catch (_) {}

    return update("iframe_only_shell_applied", {
      ok: true,
      applied: true,
      selector: iframe.id ? `#${iframe.id}` : 'iframe[src*="/map/atlas/mapal.html"]',
      src: iframe.src || iframe.getAttribute("src") || ""
    });
  };

  if (window.top !== window.self) {
    return update("subframe_noop", {ok: true, applied: false});
  }

  if (!document.body) {
    update("waiting_for_body", {ok: false, applied: false});
  } else {
    const first = apply();
    ensureOpacityMenu();
    if (first && first.ok && first.applied) return first;
  }

  if (window[RUN_KEY]) {
    ensureOpacityMenu();
    return update("poller_already_running", {ok: true, applied: false});
  }
  window[RUN_KEY] = true;

  const started = Date.now();
  const timer = window.setInterval(() => {
    try {
      if (document.body) {
        const result = apply();
        ensureOpacityMenu();
        if (result && result.ok && result.applied) {
          window.clearInterval(timer);
          window[RUN_KEY] = false;
        }
      }
      if (Date.now() - started > 16000) {
        window.clearInterval(timer);
        window[RUN_KEY] = false;
        update("timed_out_waiting_for_iframe", {ok: false, applied: false});
      }
    } catch (error) {
      window.clearInterval(timer);
      window[RUN_KEY] = false;
      update("exception", {ok: false, applied: false, error: String(error && error.stack || error)});
    }
  }, 250);

  ensureOpacityMenu();
  return update("polling_for_iframe", {ok: true, applied: false});
})();
"""

CDP_INNER_MAP_FILL_SCRIPT = r"""
(() => {
  const STATE_KEY = "__GEACRON_PANEL_INNER_MAP_FILL_STATE__";

  const state = window[STATE_KEY] || {
    applied: false,
    startedAt: new Date().toISOString(),
    lastReason: "starting"
  };
  window[STATE_KEY] = state;

  const update = (reason, extra = {}) => {
    Object.assign(state, extra, {
      lastReason: reason,
      updatedAt: new Date().toISOString()
    });
    try {
      document.documentElement.setAttribute("data-geacron-inner-map-fill", reason);
    } catch (_) {}
    return state;
  };

  const iframe =
    document.querySelector("#geacron-iframe-only-shell iframe[src*='/map/atlas/mapal.html']") ||
    document.querySelector("#geacron-iframe-only-shell iframe#m0id") ||
    document.querySelector('iframe[src*="/map/atlas/mapal.html"]') ||
    document.querySelector("iframe#m0id") ||
    document.querySelector("iframe.m0");

  if (!iframe) {
    return update("map_iframe_not_found", {ok: false, applied: false});
  }

  const frameWindow = iframe.contentWindow;
  const frameDocument = iframe.contentDocument;

  if (!frameWindow || !frameDocument || !frameDocument.body) {
    return update("iframe_document_not_ready", {ok: false, applied: false});
  }

  const frameHeight =
    frameDocument.documentElement.clientHeight ||
    frameWindow.innerHeight ||
    iframe.getBoundingClientRect().height;

  const frameWidth =
    frameDocument.documentElement.clientWidth ||
    frameWindow.innerWidth ||
    iframe.getBoundingClientRect().width;

  const visibleRect = (element) => {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return null;
    const style = frameWindow.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden") return null;
    const rect = element.getBoundingClientRect();
    if (!Number.isFinite(rect.width) || !Number.isFinite(rect.height)) return null;
    if (rect.width < 200 || rect.height < 100) return null;
    return rect;
  };

  const labelFor = (element) => {
    const cls =
      typeof element.className === "string"
        ? element.className
        : element.className?.baseVal || "";
    return [
      element.tagName,
      element.id || "",
      cls,
      element.getAttribute("name") || "",
      element.getAttribute("role") || "",
      element.getAttribute("style") || ""
    ]
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
  };

  const scoreCandidate = (element) => {
    const rect = visibleRect(element);
    if (!rect) return null;

    const label = labelFor(element).toLowerCase();
    const hasMapSignal =
      /(^|[\s_-])(map|mapa|olmap|openlayers|viewport)([\s_-]|$)/i.test(label) ||
      element.querySelector?.(".olMap, .olMapViewport, .olLayerDiv, .olControlPanZoomBar") ||
      element.querySelector?.("[id*='map'], [class*='map'], [class*='OpenLayers'], [class*='ol']");

    const belowControls = rect.top >= 40;
    const wideEnough = rect.width >= frameWidth * 0.65;
    const mapHeightish = rect.height >= 300;

    let score = rect.width * rect.height;

    if (hasMapSignal) score += 20000000;
    if (belowControls) score += 5000000;
    if (wideEnough) score += 3000000;
    if (mapHeightish) score += 3000000;

    if (element === frameDocument.body || element === frameDocument.documentElement) {
      score -= 100000000;
    }

    if (rect.top < 20) {
      score -= 4000000;
    }

    return {element, rect, label: labelFor(element), score};
  };

  const preferredSelectors = [
    ".olMap",
    ".olMapViewport",
    "[class*='olMap']",
    "[class*='OpenLayers']",
    "#map",
    "#mapa",
    "[id*='map']",
    "[class*='map']",
    "div",
    "table",
    "td"
  ];

  const elements = [];
  for (const selector of preferredSelectors) {
    try {
      elements.push(...frameDocument.querySelectorAll(selector));
    } catch (_) {}
  }

  const candidates = Array.from(new Set(elements))
    .map(scoreCandidate)
    .filter(Boolean)
    .sort((a, b) => b.score - a.score);

  const selected = candidates.find((candidate) => {
    const rect = candidate.rect;
    return rect.top >= 40 && rect.width >= frameWidth * 0.65 && rect.height >= 300;
  }) || candidates[0];

  if (!selected) {
    return update("no_map_root_candidate_found", {
      ok: false,
      applied: false,
      frame: {width: Math.round(frameWidth), height: Math.round(frameHeight)}
    });
  }

  const mapRoot = selected.element;
  const before = mapRoot.getBoundingClientRect();
  const top = Math.max(0, Math.round(before.top));
  const targetHeight = Math.max(300, Math.floor(frameHeight - top));

  window.__GEACRON_INNER_MAP_FILL_RESTORE__ = () => {
    try {
      const overscroll = frameWindow.__GEACRON_PANEL_VISUAL_OVERSCROLL_STATE__;
      if (overscroll && typeof overscroll.restore === "function") {
        overscroll.restore();
      }
    } catch (_) {}

    try {
      const labelNoSelect = frameWindow.__GEACRON_PANEL_LABEL_NO_SELECT_STATE__;
      if (labelNoSelect && typeof labelNoSelect.restore === "function") {
        labelNoSelect.restore();
      }
    } catch (_) {}

    try {
      const redirect = frameWindow.__GEACRON_PANEL_LOCATION_REDIRECT_STATE__;
      if (redirect && typeof redirect.restore === "function") {
        redirect.restore();
      }
    } catch (_) {}

    frameDocument.documentElement.style.height = "";
    frameDocument.documentElement.style.overflow = "";
    frameDocument.body.style.height = "";
    frameDocument.body.style.margin = "";
    frameDocument.body.style.overflow = "";
    mapRoot.removeAttribute("data-geacron-inner-map-fill");
    update("inner_map_fill_restored", {ok: true, applied: false});
    return "Reload is the clean restore. Basic style reset applied.";
  };

  frameDocument.documentElement.style.height = "100%";
  frameDocument.documentElement.style.overflow = "hidden";
  frameDocument.body.style.height = "100%";
  frameDocument.body.style.margin = "0";
  frameDocument.body.style.overflow = "hidden";

  mapRoot.setAttribute("data-geacron-inner-map-fill", "active");
  mapRoot.style.width = "100vw";
  mapRoot.style.maxWidth = "none";
  mapRoot.style.height = `${targetHeight}px`;
  mapRoot.style.minHeight = `${targetHeight}px`;
  mapRoot.style.maxHeight = "none";
  mapRoot.style.overflow = "hidden";

  const resizePass = () => {
    try {
      frameWindow.dispatchEvent(new Event("resize"));
    } catch (_) {}

    for (const key of Object.keys(frameWindow)) {
      try {
        const value = frameWindow[key];
        if (value && typeof value.updateSize === "function") {
          value.updateSize();
        }
      } catch (_) {}
    }
  };

  const installVisualOverscrollBridge = () => {
    const KEY = "__GEACRON_PANEL_VISUAL_OVERSCROLL_STATE__";
    const CAPTURE_ID = "geacron-panel-visual-overscroll-capture";

    const oldKeys = [
      "__GEACRON_PANEL_ANCHORED_VISUAL_OVERSCROLL_V3__",
      "__GEACRON_PANEL_ANCHORED_VISUAL_OVERSCROLL_V21__",
      "__GEACRON_PANEL_ANCHORED_VISUAL_OVERSCROLL_V2__",
      "__GEACRON_PANEL_ANCHORED_VISUAL_OVERSCROLL_TEST__",
      "__GEACRON_PANEL_VISUAL_OVERSCROLL_TEST__",
      "__GEACRON_PANEL_OVERZOOM_TEST__",
      "__GEACRON_PANEL_DEEP_ZOOM_TEST__",
      "__GEACRON_PANEL_OVERLAY_RANGE_TEST__",
      "__GEACRON_PANEL_STICKY_LABEL_TEST__",
      "__GEACRON_PANEL_DOM_STICKY_LABEL_TEST__",
      KEY
    ];

    for (const oldKey of oldKeys) {
      try {
        const value = frameWindow[oldKey];
        if (value && typeof value.restore === "function") value.restore();
      } catch (_) {}
      try {
        const value = frameWindow[oldKey];
        if (value && typeof value.remove === "function") value.remove();
      } catch (_) {}
    }

    const map = frameWindow.map;
    if (!map) {
      return {
        ok: false,
        reason: "frameWindow.map not found"
      };
    }

    const viewport =
      map.viewPortDiv ||
      frameDocument.querySelector("#map .olMapViewport") ||
      mapRoot;

    const layerContainer =
      map.layerContainerDiv ||
      frameDocument.querySelector("#map .olMapViewport > div") ||
      viewport;

    if (!layerContainer) {
      return {
        ok: false,
        reason: "OpenLayers layer container not found"
      };
    }

    const nativeMaxZoom = (() => {
      try {
        const n = typeof map.getNumZoomLevels === "function"
          ? Number(map.getNumZoomLevels())
          : Number(map.numZoomLevels);
        return Number.isFinite(n) ? n - 1 : 5;
      } catch (_) {
        return 5;
      }
    })();

    const MAX_EXTRA_LEVELS = 2;
    const SCALE_PER_LEVEL = 2;

    const original = {
      layerTransform: layerContainer.style.transform || "",
      layerTransformOrigin: layerContainer.style.transformOrigin || "",
      layerWillChange: layerContainer.style.willChange || "",
      layerTransition: layerContainer.style.transition || "",
      layerBackfaceVisibility: layerContainer.style.backfaceVisibility || "",
      viewportOverflow: viewport.style.overflow || "",
      mapRootOverflow: mapRoot.style.overflow || "",
      mapRootCursor: mapRoot.style.cursor || "",
      mapRootPosition: mapRoot.style.position || "",
      mapRootTouchAction: mapRoot.style.touchAction || "",
      mapRootUserSelect: mapRoot.style.userSelect || "",
      bodyUserSelect: frameDocument.body?.style?.userSelect || ""
    };

    if (frameWindow.getComputedStyle(mapRoot).position === "static") {
      mapRoot.style.position = "relative";
    }

    const previousCapture = frameDocument.getElementById(CAPTURE_ID);
    if (previousCapture) previousCapture.remove();

    const captureLayer = frameDocument.createElement("div");
    captureLayer.id = CAPTURE_ID;
    captureLayer.style.position = "absolute";
    captureLayer.style.left = "0";
    captureLayer.style.top = "0";
    captureLayer.style.width = "100%";
    captureLayer.style.height = "100%";
    captureLayer.style.zIndex = "2147483645";
    captureLayer.style.pointerEvents = "none";
    captureLayer.style.background = "transparent";
    captureLayer.style.touchAction = "none";
    captureLayer.style.userSelect = "none";
    captureLayer.setAttribute("data-geacron-panel-visual-overscroll-capture", "active");
    mapRoot.appendChild(captureLayer);

    let virtualLevel = 0;
    let scale = 1;
    let offsetX = 0;
    let offsetY = 0;

    let dragging = false;
    let dragStart = null;
    let dragOffsetStart = null;
    let lastPointer = null;
    let lastWheelAt = 0;
    let rafPending = false;

    const listeners = [];

    const readZoom = () => {
      let zoom = null;
      let resolution = null;
      let numZoomLevels = null;

      try {
        zoom = typeof map.getZoom === "function" ? Number(map.getZoom()) : Number(map.zoom);
      } catch (_) {}

      try {
        resolution = typeof map.getResolution === "function"
          ? Number(map.getResolution())
          : Number(map.resolution);
      } catch (_) {}

      try {
        numZoomLevels = typeof map.getNumZoomLevels === "function"
          ? Number(map.getNumZoomLevels())
          : Number(map.numZoomLevels);
      } catch (_) {}

      return {
        zoom: Number.isFinite(zoom) ? zoom : null,
        resolution: Number.isFinite(resolution) ? resolution : null,
        numZoomLevels: Number.isFinite(numZoomLevels) ? numZoomLevels : null
      };
    };

    const labelStats = () => {
      const text = String(layerContainer.innerText || layerContainer.textContent || "")
        .replace(/\s+/g, " ")
        .trim();

      return {
        textLength: text.length,
        sample: text.slice(0, 180),
        imageCount: layerContainer.querySelectorAll?.("img").length ?? null,
        childCount: layerContainer.children?.length ?? null
      };
    };

    const scaleForLevel = (level) => Math.pow(SCALE_PER_LEVEL, level);

    const pointFromEvent = (event) => {
      const rect = mapRoot.getBoundingClientRect();
      const source = event.touches?.[0] || event.changedTouches?.[0] || event;

      return {
        x: source.clientX - rect.left,
        y: source.clientY - rect.top,
        clientX: source.clientX,
        clientY: source.clientY
      };
    };

    const shouldIgnoreTarget = (target) => {
      if (!target) return false;
      if (target.closest?.("#geacron-panel-control-menu")) return true;
      if (target.closest?.("input, textarea, select, button")) return true;
      return false;
    };

    const bounds = () => {
      const rect = mapRoot.getBoundingClientRect();

      if (virtualLevel <= 0) {
        return {
          minX: 0,
          maxX: 0,
          minY: 0,
          maxY: 0,
          width: rect.width,
          height: rect.height
        };
      }

      const currentScale = scaleForLevel(virtualLevel);
      return {
        minX: Math.min(0, rect.width - rect.width * currentScale),
        maxX: 0,
        minY: Math.min(0, rect.height - rect.height * currentScale),
        maxY: 0,
        width: rect.width,
        height: rect.height
      };
    };

    const clampOffsets = () => {
      const b = bounds();

      offsetX = Math.max(b.minX, Math.min(b.maxX, offsetX));
      offsetY = Math.max(b.minY, Math.min(b.maxY, offsetY));
    };

    const applyNow = () => {
      rafPending = false;

      scale = scaleForLevel(virtualLevel);
      clampOffsets();

      viewport.style.overflow = "hidden";
      mapRoot.style.overflow = "hidden";

      mapRoot.style.touchAction = virtualLevel > 0 ? "none" : original.mapRootTouchAction;
      mapRoot.style.userSelect = virtualLevel > 0 ? "none" : original.mapRootUserSelect;
      if (frameDocument.body) {
        frameDocument.body.style.userSelect = virtualLevel > 0 ? "none" : original.bodyUserSelect;
      }

      captureLayer.style.pointerEvents = virtualLevel > 0 ? "auto" : "none";
      captureLayer.style.cursor = virtualLevel > 0 ? (dragging ? "grabbing" : "grab") : "default";

      layerContainer.style.transformOrigin = "0 0";
      layerContainer.style.transition = "";
      layerContainer.style.backfaceVisibility = "hidden";
      layerContainer.style.willChange = virtualLevel > 0 ? "transform" : original.layerWillChange;

      if (virtualLevel > 0) {
        layerContainer.style.transform = `translate3d(${offsetX}px, ${offsetY}px, 0) scale(${scale})`;
        mapRoot.style.cursor = dragging ? "grabbing" : "grab";
      } else {
        layerContainer.style.transform = original.layerTransform;
        mapRoot.style.cursor = original.mapRootCursor;
      }
    };

    const scheduleApply = () => {
      if (rafPending) return;
      rafPending = true;
      frameWindow.requestAnimationFrame(applyNow);
    };

    const snapshotState = () => ({
      ok: true,
      virtualLevel,
      scale,
      offsetX,
      offsetY,
      dragging,
      bounds: bounds(),
      nativeZoom: readZoom(),
      labelStats: labelStats()
    });

    const nativeZoomTo = (targetZoom) => {
      const safe = Math.max(0, Math.min(nativeMaxZoom, Number(targetZoom)));

      try {
        if (typeof map.zoomTo === "function") {
          map.zoomTo(safe);
        } else {
          const current = readZoom();
          if (safe > current.zoom && typeof map.zoomIn === "function") map.zoomIn();
          if (safe < current.zoom && typeof map.zoomOut === "function") map.zoomOut();
        }
      } catch (_) {}

      try {
        if (typeof map.updateSize === "function") map.updateSize();
        frameWindow.dispatchEvent(new Event("resize"));
      } catch (_) {}

      scheduleApply();
      return readZoom();
    };

    const setVirtualLevelAnchored = (nextLevel, anchorPoint = null) => {
      const oldScale = scale;
      const oldLevel = virtualLevel;
      const newLevel = Math.max(0, Math.min(MAX_EXTRA_LEVELS, Number(nextLevel)));
      const newScale = scaleForLevel(newLevel);

      const rect = mapRoot.getBoundingClientRect();
      const anchor = anchorPoint || lastPointer || {
        x: rect.width / 2,
        y: rect.height / 2
      };

      if (newLevel === 0) {
        virtualLevel = 0;
        scale = 1;
        offsetX = 0;
        offsetY = 0;
        scheduleApply();
        return snapshotState();
      }

      if (oldLevel === 0) {
        offsetX = anchor.x - anchor.x * newScale;
        offsetY = anchor.y - anchor.y * newScale;
      } else {
        const contentX = (anchor.x - offsetX) / oldScale;
        const contentY = (anchor.y - offsetY) / oldScale;
        offsetX = anchor.x - contentX * newScale;
        offsetY = anchor.y - contentY * newScale;
      }

      virtualLevel = newLevel;
      scale = newScale;

      scheduleApply();
      return snapshotState();
    };

    const zoomIn = (anchorPoint = null) => {
      const current = readZoom();

      if (Number(current.zoom) < nativeMaxZoom && virtualLevel === 0) {
        nativeZoomTo(Number(current.zoom) + 1);
        return snapshotState();
      }

      return setVirtualLevelAnchored(virtualLevel + 1, anchorPoint);
    };

    const zoomOut = (anchorPoint = null) => {
      if (virtualLevel > 0) {
        return setVirtualLevelAnchored(virtualLevel - 1, anchorPoint);
      }

      const current = readZoom();
      nativeZoomTo(Number(current.zoom || 0) - 1);
      return snapshotState();
    };

    const consume = (event) => {
      event.preventDefault?.();
      event.stopPropagation?.();
      event.stopImmediatePropagation?.();
    };

    const onWheel = (event) => {
      if (shouldIgnoreTarget(event.target)) return;

      consume(event);

      const now = Date.now();
      if (now - lastWheelAt < 100) return;
      lastWheelAt = now;

      lastPointer = pointFromEvent(event);

      const result = event.deltaY < 0 ? zoomIn(lastPointer) : zoomOut(lastPointer);

      if (frameWindow[KEY]) frameWindow[KEY].lastWheelResult = result;
    };

    const beginDrag = (event) => {
      if (virtualLevel <= 0) return;
      if (shouldIgnoreTarget(event.target)) return;
      if (event.button !== undefined && event.button !== 0) return;

      consume(event);

      const point = pointFromEvent(event);

      dragging = true;
      lastPointer = point;
      dragStart = {clientX: point.clientX, clientY: point.clientY};
      dragOffsetStart = {x: offsetX, y: offsetY};

      try { captureLayer.setPointerCapture?.(event.pointerId); } catch (_) {}
      scheduleApply();
    };

    const moveDrag = (event) => {
      if (!dragging || virtualLevel <= 0 || !dragStart || !dragOffsetStart) return;

      consume(event);

      const point = pointFromEvent(event);

      offsetX = dragOffsetStart.x + (point.clientX - dragStart.clientX);
      offsetY = dragOffsetStart.y + (point.clientY - dragStart.clientY);
      lastPointer = point;

      clampOffsets();
      scheduleApply();

      if (frameWindow[KEY]) frameWindow[KEY].lastDragResult = snapshotState();
    };

    const endDrag = (event) => {
      if (!dragging) return;

      consume(event);

      dragging = false;
      dragStart = null;
      dragOffsetStart = null;

      try { captureLayer.releasePointerCapture?.(event.pointerId); } catch (_) {}
      scheduleApply();
    };

    const blockNativeDuringVirtual = (event) => {
      if (virtualLevel <= 0) return;
      if (shouldIgnoreTarget(event.target)) return;
      consume(event);
    };

    const addListener = (target, type, handler, options, label) => {
      if (!target || typeof target.addEventListener !== "function") return;
      target.addEventListener(type, handler, options);
      listeners.push({target, type, handler, options, label});
    };

    const capturePassiveFalse = {capture: true, passive: false};
    const captureOnly = {capture: true};

    addListener(mapRoot, "wheel", onWheel, capturePassiveFalse, "mapRoot wheel");
    addListener(frameDocument, "wheel", onWheel, capturePassiveFalse, "document wheel");
    addListener(frameWindow, "wheel", onWheel, capturePassiveFalse, "window wheel");
    addListener(captureLayer, "wheel", onWheel, capturePassiveFalse, "capture wheel");

    addListener(captureLayer, "pointerdown", beginDrag, capturePassiveFalse, "capture pointerdown");
    addListener(frameDocument, "pointermove", moveDrag, capturePassiveFalse, "document pointermove");
    addListener(frameWindow, "pointermove", moveDrag, capturePassiveFalse, "window pointermove");
    addListener(frameDocument, "pointerup", endDrag, capturePassiveFalse, "document pointerup");
    addListener(frameWindow, "pointerup", endDrag, capturePassiveFalse, "window pointerup");
    addListener(frameWindow, "pointercancel", endDrag, capturePassiveFalse, "window pointercancel");

    addListener(captureLayer, "mousedown", beginDrag, capturePassiveFalse, "capture mousedown");
    addListener(frameDocument, "mousemove", moveDrag, capturePassiveFalse, "document mousemove");
    addListener(frameWindow, "mousemove", moveDrag, capturePassiveFalse, "window mousemove");
    addListener(frameDocument, "mouseup", endDrag, capturePassiveFalse, "document mouseup");
    addListener(frameWindow, "mouseup", endDrag, capturePassiveFalse, "window mouseup");

    addListener(captureLayer, "touchstart", beginDrag, capturePassiveFalse, "capture touchstart");
    addListener(frameDocument, "touchmove", moveDrag, capturePassiveFalse, "document touchmove");
    addListener(frameWindow, "touchmove", moveDrag, capturePassiveFalse, "window touchmove");
    addListener(frameDocument, "touchend", endDrag, capturePassiveFalse, "document touchend");
    addListener(frameWindow, "touchend", endDrag, capturePassiveFalse, "window touchend");
    addListener(frameWindow, "touchcancel", endDrag, capturePassiveFalse, "window touchcancel");

    addListener(captureLayer, "dragstart", blockNativeDuringVirtual, capturePassiveFalse, "capture dragstart");
    addListener(captureLayer, "click", blockNativeDuringVirtual, captureOnly, "capture click");
    addListener(captureLayer, "dblclick", blockNativeDuringVirtual, captureOnly, "capture dblclick");
    addListener(captureLayer, "contextmenu", blockNativeDuringVirtual, captureOnly, "capture contextmenu");

    const restore = () => {
      for (const item of listeners) {
        try { item.target.removeEventListener(item.type, item.handler, item.options); } catch (_) {}
      }

      captureLayer.remove();

      layerContainer.style.transform = original.layerTransform;
      layerContainer.style.transformOrigin = original.layerTransformOrigin;
      layerContainer.style.willChange = original.layerWillChange;
      layerContainer.style.transition = original.layerTransition;
      layerContainer.style.backfaceVisibility = original.layerBackfaceVisibility;
      viewport.style.overflow = original.viewportOverflow;
      mapRoot.style.overflow = original.mapRootOverflow;
      mapRoot.style.cursor = original.mapRootCursor;
      mapRoot.style.position = original.mapRootPosition;
      mapRoot.style.touchAction = original.mapRootTouchAction;
      mapRoot.style.userSelect = original.mapRootUserSelect;
      if (frameDocument.body) frameDocument.body.style.userSelect = original.bodyUserSelect;

      delete frameWindow[KEY];

      return {ok: true, restored: true};
    };

    frameWindow[KEY] = {
      ok: true,
      installedAt: new Date().toISOString(),
      mode: "visual_overscroll_v21_virtual_only_capture_layer",
      nativeMaxZoom,
      maxExtraLevels: MAX_EXTRA_LEVELS,
      scalePerLevel: SCALE_PER_LEVEL,
      mapRoot: [mapRoot.tagName, mapRoot.id || "", mapRoot.className || ""].join(" ").trim(),
      viewport: [viewport.tagName, viewport.id || "", viewport.className || ""].join(" ").trim(),
      layerContainer: [layerContainer.tagName, layerContainer.id || "", layerContainer.className || ""].join(" ").trim(),
      zoomNow: readZoom,
      labelStats,
      state: snapshotState,
      setVirtualLevel: (level) => setVirtualLevelAnchored(level, lastPointer),
      zoomIn: () => zoomIn(lastPointer),
      zoomOut: () => zoomOut(lastPointer),
      panBy: (dx, dy) => {
        offsetX += Number(dx || 0);
        offsetY += Number(dy || 0);
        clampOffsets();
        scheduleApply();
        return snapshotState();
      },
      restore,
      lastWheelResult: null,
      lastDragResult: null
    };

    scheduleApply();

    return {
      ok: true,
      mode: "visual_overscroll_v21_virtual_only_capture_layer",
      nativeMaxZoom,
      maxExtraLevels: MAX_EXTRA_LEVELS,
      scalePerLevel: SCALE_PER_LEVEL,
      listenerCount: listeners.length,
      targets: {
        mapRoot: frameWindow[KEY].mapRoot,
        viewport: frameWindow[KEY].viewport,
        layerContainer: frameWindow[KEY].layerContainer
      },
      initial: snapshotState()
    };
  };


  const installLabelNoSelectCssOnly = () => {
    const KEY = "__GEACRON_PANEL_LABEL_NO_SELECT_STATE__";
    const STYLE_ID = "geacron-panel-label-no-select-css-only";

    try {
      frameWindow[KEY]?.restore?.();
    } catch (_) {}

    const oldStyle = frameDocument.getElementById(STYLE_ID);
    if (oldStyle) oldStyle.remove();

    const style = frameDocument.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      [data-geacron-inner-map-fill="active"],
      [data-geacron-inner-map-fill="active"] *,
      #map,
      #map * {
        user-select: none !important;
        -webkit-user-select: none !important;
        -webkit-user-drag: none !important;
      }
    `;
    frameDocument.head?.appendChild(style);

    frameWindow[KEY] = {
      ok: true,
      mode: "css_only_no_select",
      mapRoot: [mapRoot.tagName, mapRoot.id || "", mapRoot.className || ""].join(" ").trim(),
      restore: () => {
        try { style.remove(); } catch (_) {}
        delete frameWindow[KEY];
        return {ok: true, restored: true};
      }
    };

    return {
      ok: true,
      mode: "css_only_no_select",
      mapRoot: frameWindow[KEY].mapRoot
    };
  };

  const installLocationWindowOpenRedirect = () => {
    const KEY = "__GEACRON_PANEL_LOCATION_REDIRECT_STATE__";

    try {
      frameWindow[KEY]?.restore?.();
    } catch (_) {}

    const originalOpen = frameWindow.open;
    const originalOpenBound = typeof originalOpen === "function" ? originalOpen.bind(frameWindow) : null;

    let config = {
      ok: true,
      enabled: true,
      mode: "google",
      openTarget: "_blank",
      profiles: {
        google: {
          label: "Google",
          url_template: "https://www.google.com/search?q={coArea}+{date}"
        },
        wikipedia: {
          label: "Wiki",
          url_template: "https://en.wikipedia.org/wiki/Special:Search?search={coArea}"
        },
        britannica: {
          label: "Britannica",
          url_template: "https://www.britannica.com/search?query={coArea}+{date}"
        },
        jstor: {
          label: "JSTOR",
          url_template: "https://www.jstor.org/action/doBasicSearch?Query={coArea}+{date}&so=rel"
        }
      }
    };

    const parentRedirectState = (() => {
      try {
        const parentState = window.__GEACRON_PANEL_REDIRECT_STATE__;
        return parentState && typeof parentState === "object" ? parentState : null;
      } catch (_) {
        return null;
      }
    })();

    if (parentRedirectState) {
      config = Object.assign({}, config, parentRedirectState);
    }

    const focusSafeHandle = (handle, fallbackUrl) => {
      if (handle && typeof handle.focus === "function") return handle;
      return {
        closed: false,
        location: {href: fallbackUrl || "about:blank"},
        focus: () => null,
        close: () => null
      };
    };

    const parseLinksdoc = (urlValue) => {
      let url;
      try {
        url = new URL(String(urlValue), frameWindow.location.href);
      } catch (_) {
        return null;
      }

      const params = Object.fromEntries(url.searchParams.entries());
      return {
        href: url.href,
        isLinksdoc: /\/linksdoc/i.test(url.pathname) || /linksdoc/i.test(url.href),
        idArea: String(params.idArea || ""),
        coArea: String(params.coArea || ""),
        lng: String(params.lng || ""),
        date: String(params.date || ""),
        layer: String(params.layer || "")
      };
    };

    const renderTemplate = (template, record) => {
      const replacements = {
        "{originalUrl}": record.href,
        "{idArea}": encodeURIComponent(record.idArea || ""),
        "{coArea}": encodeURIComponent(record.coArea || ""),
        "{lng}": encodeURIComponent(record.lng || ""),
        "{date}": encodeURIComponent(record.date || ""),
        "{layer}": encodeURIComponent(record.layer || "")
      };

      let rendered = String(template || "");
      for (const [token, value] of Object.entries(replacements)) {
        rendered = rendered.split(token).join(value);
      }
      return rendered;
    };

    const buildRedirect = (record) => {
      if (!record?.isLinksdoc) return record?.href || null;
      if (!config.enabled || config.mode === "off") return record.href;

      const profile = config.profiles?.[config.mode] || config.profiles?.google;
      const template = profile?.url_template || profile?.urlTemplate || "{originalUrl}";
      return renderTemplate(template, record);
    };

    frameWindow.open = function patchedOpen(url, target, features) {
      const parsed = parseLinksdoc(url);
      const redirectUrl = parsed?.isLinksdoc ? buildRedirect(parsed) : String(url || "");

      if (parsed?.isLinksdoc && (!config.enabled || config.mode === "off")) {
        if (originalOpenBound) {
          const handle = originalOpenBound(url, target, features);
          return focusSafeHandle(handle, String(url || ""));
        }
        return focusSafeHandle(null, String(url || ""));
      }

      if (parsed?.isLinksdoc && redirectUrl && originalOpenBound) {
        const finalTarget = config.openTarget || "_blank";
        const handle = originalOpenBound(redirectUrl, finalTarget, "noopener,noreferrer");
        return focusSafeHandle(handle, redirectUrl);
      }

      if (originalOpenBound) {
        const handle = originalOpenBound(url, target, features);
        return focusSafeHandle(handle, String(url || ""));
      }

      return focusSafeHandle(null, redirectUrl);
    };

    frameWindow[KEY] = {
      ok: true,
      mode: "location_window_open_redirect",
      setConfig: (nextConfig) => {
        if (nextConfig && typeof nextConfig === "object") {
          config = Object.assign({}, config, nextConfig);
        }
        return frameWindow[KEY].state();
      },
      state: () => ({
        ok: true,
        enabled: config.enabled,
        selectedMode: config.mode,
        openTarget: config.openTarget,
        profileIds: Object.keys(config.profiles || {})
      }),
      restore: () => {
        try { frameWindow.open = originalOpen; } catch (_) {}
        delete frameWindow[KEY];
        return {ok: true, restored: true};
      }
    };

    return frameWindow[KEY].state();
  };

  resizePass();
  setTimeout(resizePass, 100);
  setTimeout(resizePass, 350);
  setTimeout(resizePass, 800);

  const visualOverscroll = installVisualOverscrollBridge();
  const labelNoSelect = installLabelNoSelectCssOnly();
  const locationRedirect = installLocationWindowOpenRedirect();

  const after = mapRoot.getBoundingClientRect();

  return update("inner_map_fill_applied", {
    ok: true,
    applied: true,
    selected: selected.label,
    frame: {
      width: Math.round(frameWidth),
      height: Math.round(frameHeight)
    },
    before: {
      top: Math.round(before.top),
      width: Math.round(before.width),
      height: Math.round(before.height),
      bottom: Math.round(before.bottom)
    },
    after: {
      top: Math.round(after.top),
      width: Math.round(after.width),
      height: Math.round(after.height),
      bottom: Math.round(after.bottom)
    },
    targetHeight,
    visualOverscroll,
    labelNoSelect,
    locationRedirect
  });
})();
"""

CDP_VIEWPORT_STATUS_SCRIPT = r"""
(() => {
  const iframe =
    document.querySelector("#geacron-iframe-only-shell iframe[src*='/map/atlas/mapal.html']") ||
    document.querySelector("#geacron-iframe-only-shell iframe#m0id") ||
    document.querySelector('iframe[src*="/map/atlas/mapal.html"], iframe#m0id, iframe.m0');

  let innerMapFill = false;
  let innerMapFillRect = null;
  try {
    const mapRoot = iframe?.contentDocument?.querySelector("[data-geacron-inner-map-fill='active']");
    innerMapFill = Boolean(mapRoot);
    if (mapRoot) {
      const rect = mapRoot.getBoundingClientRect();
      innerMapFillRect = {
        top: Math.round(rect.top),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        bottom: Math.round(rect.bottom)
      };
    }
  } catch (_) {}

  return {
    url: location.href,
    topFrame: window.top === window.self,
    shell: Boolean(document.querySelector("#geacron-iframe-only-shell")),
    shellIframe: Boolean(iframe),
    oldShell: Boolean(document.querySelector("#geacron-exact-shell")),
    htmlDataset: {...document.documentElement.dataset},
    iframe: Boolean(document.querySelector('iframe[src*="/map/atlas/mapal.html"], iframe#m0id, iframe.m0')),
    iframeSrc: document.querySelector('iframe[src*="/map/atlas/mapal.html"], iframe#m0id, iframe.m0')?.src || null,
    innerMapFill,
    innerMapFillRect,
    cdpState: window.__GEACRON_PANEL_CDP_INJECTION_STATE__ || null,
    innerMapFillState: window.__GEACRON_PANEL_INNER_MAP_FILL_STATE__ || null
  };
})();
"""

CDP_OPACITY_REQUEST_SCRIPT = r"""
(() => {
  const request = window.__GEACRON_PANEL_OPACITY_REQUEST__ || null;
  if (!request || typeof request !== "object") return null;

  return {
    id: String(request.id || ""),
    opacity: Number(request.opacity),
    requestedAt: String(request.requestedAt || "")
  };
})();
"""

CDP_REDIRECT_REQUEST_SCRIPT = r"""
(() => {
  const request = window.__GEACRON_PANEL_REDIRECT_REQUEST__ || null;
  if (!request || typeof request !== "object") return null;

  return {
    id: String(request.id || ""),
    mode: String(request.mode || ""),
    requestedAt: String(request.requestedAt || "")
  };
})();
"""


@dataclass
class Settings:
    raw: dict[str, Any]

    @property
    def general(self) -> dict[str, Any]:
        return self.raw["general"]

    @property
    def window(self) -> dict[str, Any]:
        return self.raw["window"]

    @property
    def monitor_contract(self) -> dict[str, Any]:
        return self.raw.get("monitor_contract", {})

    @property
    def safety(self) -> dict[str, Any]:
        return self.raw.get("safety", {})

    @property
    def viewport(self) -> dict[str, Any]:
        return self.raw.get("viewport", {})

    @property
    def map_labels(self) -> dict[str, Any]:
        return self.raw.get("map_labels", {})

    @property
    def location_redirect(self) -> dict[str, Any]:
        return self.raw.get("location_redirect", {})


def default_settings() -> dict[str, Any]:
    return {
        "general": {
            "name": "GeaCron Live Map Panel",
            "url": "https://geacron.com/home-en/",
            "chrome_binary": "google-chrome",
            "chrome_extra_args": [],
            "window_title_hint": "GeaCron",
            "default_mode": "desktop",
            "log_level": "INFO",
        },
        "window": {
            "monitor": "DisplayPort-5",
            "x": 1586,
            "y": 0,
            "width": 1680,
            "height": 1050,
            "always_on_top": False,
            "sticky": False,
            "workspace": -1,
            "desktop_fill_monitor": True,
            "desktop_fullscreen": False,
            "desktop_layer": "below",
            "opacity": 1.0,
            "respect_work_area": True,
            "taskbar_bottom_margin_fallback": 40,
        },
        "monitor_contract": {
            "name": "DisplayPort-5",
            "label": "top / ONN 100027813",
            "expected_x": 1586,
            "expected_y": 0,
            "expected_width": 1680,
            "expected_height": 1050,
        },
        "viewport": {
            "enabled": True,
            "mode": "auto_map_shell",
            "extension_dir": "extension/geacron_viewport",
            "fallback_mode": "plain_page",
        },
        "map_labels": {
            "no_select": True,
        },
        "location_redirect": {
            "enabled": True,
            "mode": "google",
            "open_target": "_blank",
            "profiles": {
                "google": {
                    "label": "Google",
                    "url_template": "https://www.google.com/search?q={coArea}+{date}",
                },
                "wikipedia": {
                    "label": "Wiki",
                    "url_template": "https://en.wikipedia.org/wiki/Special:Search?search={coArea}",
                },
                "britannica": {
                    "label": "Britannica",
                    "url_template": "https://www.britannica.com/search?query={coArea}+{date}",
                },
                "jstor": {
                    "label": "JSTOR",
                    "url_template": "https://www.jstor.org/action/doBasicSearch?Query={coArea}+{date}&so=rel",
                },
            },
        },
        "safety": {
            "require_x11": True,
            "refuse_root_for_launch": True,
            "require_configured_monitor_for_desktop": True,
            "require_monitor_contract_match_for_desktop": True,
            "allow_xdotool_force_close": True,
        },
    }


def deep_merge(base: dict[str, Any], overlay: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def die(message: str, code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(code)


def run(cmd: list[str], *, check: bool = False, timeout: float | None = 20.0) -> \
        subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, check=check, text=True, capture_output=True, timeout=timeout)


def load_settings() -> Settings:
    if not CONFIG_PATH.exists():
        die(f"missing config file: {CONFIG_PATH}", 2)
    try:
        with CONFIG_PATH.open("rb") as handle:
            loaded = tomllib.load(handle)
    except tomllib.TOMLDecodeError as exc:
        die(f"invalid TOML in {CONFIG_PATH}: {exc}", 2)
    except OSError as exc:
        die(f"failed to read {CONFIG_PATH}: {exc}", 2)

    settings = Settings(deep_merge(default_settings(), loaded))
    validate_settings(settings)
    return settings


def validate_settings(settings: Settings) -> None:
    general = settings.general
    window = settings.window

    if str(general.get("default_mode")) not in VALID_MODES:
        die("general.default_mode must be 'window' or 'desktop'", 2)
    if not str(general.get("url", "")).strip():
        die("general.url is required", 2)
    if not str(general.get("chrome_binary", "")).strip():
        die("general.chrome_binary is required", 2)
    if not isinstance(general.get("chrome_extra_args", []), list):
        die("general.chrome_extra_args must be an array", 2)

    for key in ("x", "y", "width", "height", "workspace"):
        try:
            window[key] = int(window[key])
        except (KeyError, TypeError, ValueError) as exc:
            die(f"window.{key} must be an integer", 2)

    if window["width"] < 100 or window["height"] < 100:
        die("window.width and window.height must be at least 100", 2)
    if not str(window.get("monitor", "")).strip():
        die("window.monitor is required", 2)

    desktop_layer = str(window.get("desktop_layer", "below")).strip().lower()
    if desktop_layer not in VALID_DESKTOP_LAYERS:
        die(
            "window.desktop_layer must be one of: " + ", ".join(sorted(VALID_DESKTOP_LAYERS)),
            2,
        )
    window["desktop_layer"] = desktop_layer

    try:
        opacity = float(window.get("opacity", 1.0))
    except (TypeError, ValueError) as exc:
        die("window.opacity must be a decimal number", 2)
    if opacity < MIN_WINDOW_OPACITY or opacity > MAX_WINDOW_OPACITY:
        die(
            f"window.opacity must be between {MIN_WINDOW_OPACITY:.2f} and {MAX_WINDOW_OPACITY:.1f}",
            2,
        )
    window["opacity"] = opacity

    for key in ("taskbar_bottom_margin_fallback",):
        if key not in window:
            window[key] = 0
        try:
            window[key] = int(window[key])
        except (TypeError, ValueError) as exc:
            die(f"window.{key} must be an integer", 2)
        if window[key] < 0:
            die(f"window.{key} must be zero or greater", 2)

    if "respect_work_area" not in window:
        window["respect_work_area"] = True

    viewport = settings.viewport
    if "enabled" not in viewport:
        viewport["enabled"] = True
    if str(viewport.get("mode", "auto_map_shell")) not in {"auto_map_shell", "off"}:
        die("viewport.mode must be 'auto_map_shell' or 'off'", 2)

    map_labels = settings.map_labels
    if "no_select" not in map_labels:
        map_labels["no_select"] = True
    map_labels["no_select"] = bool(map_labels.get("no_select", True))

    location_redirect = settings.location_redirect
    if "enabled" not in location_redirect:
        location_redirect["enabled"] = True
    location_redirect["enabled"] = bool(location_redirect.get("enabled", True))
    open_target = str(location_redirect.get("open_target", "_blank")).strip() or "_blank"
    if not re.match(r"^[_A-Za-z][A-Za-z0-9_-]{0,31}$", open_target):
        die("location_redirect.open_target must be _blank, _self, or a simple window target name",
            2)
    location_redirect["open_target"] = open_target

    profiles = location_redirect.get("profiles", {})
    if not isinstance(profiles, dict) or not profiles:
        die("location_redirect.profiles must be a non-empty table", 2)

    for profile_id, profile in profiles.items():
        profile_id_string = str(profile_id)
        if not re.match(r"^[a-z0-9_-]+$", profile_id_string):
            die("location_redirect profile ids must use lowercase letters, numbers, underscores, or hyphens",
                2)
        if not isinstance(profile, dict):
            die(f"location_redirect.profiles.{profile_id_string} must be a table", 2)
        label = str(profile.get("label", profile_id_string)).strip() or profile_id_string
        url_template = str(profile.get("url_template", "")).strip()
        if not url_template:
            die(f"location_redirect.profiles.{profile_id_string}.url_template is required", 2)
        lower_template = url_template.lower().strip()
        if lower_template.startswith(("javascript:", "data:", "file:")):
            die(f"location_redirect.profiles.{profile_id_string}.url_template uses a disallowed scheme",
                2)
        if "{originalUrl}" not in url_template and not lower_template.startswith(
                ("https://", "http://")):
            die(
                f"location_redirect.profiles.{profile_id_string}.url_template must be http(s) or {{originalUrl}}",
                2,
            )
        profile["label"] = label
        profile["url_template"] = url_template

    mode = str(location_redirect.get("mode", "google")).strip().lower() or "google"
    if mode != "off" and mode not in profiles:
        die("location_redirect.mode must be 'off' or one configured profile id", 2)
    location_redirect["mode"] = mode
    if viewport.get("extension_dir") is not None and not str(viewport.get("extension_dir")).strip():
        die("viewport.extension_dir cannot be blank", 2)

    for key in ("expected_x", "expected_y", "expected_width", "expected_height"):
        if key in settings.monitor_contract:
            try:
                settings.monitor_contract[key] = int(settings.monitor_contract[key])
            except (TypeError, ValueError) as exc:
                die(f"monitor_contract.{key} must be an integer", 2)


def ensure_runtime() -> None:
    PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


def cmd_exists(name: str) -> bool:
    return shutil.which(name) is not None


def dependency_report(commands: list[str]) -> list[dict[str, str]]:
    return [
        {"command": command,
         "hint": DEPENDENCY_HINTS.get(command, "Install this command or put it in PATH")}
        for command in commands
        if not cmd_exists(command)
    ]


def missing_for_command(settings: Settings, command: str) -> list[str]:
    required = list(REQUIRED_BY_COMMAND.get(command, []))
    if command in {"doctor", "launch"}:
        required.append(str(settings.general["chrome_binary"]))
    return [item for item in required if not cmd_exists(item)]


def current_session() -> dict[str, Any]:
    return {
        "display": os.environ.get("DISPLAY", ""),
        "xdg_current_desktop": os.environ.get("XDG_CURRENT_DESKTOP", ""),
        "desktop_session": os.environ.get("DESKTOP_SESSION", ""),
        "xdg_session_type": os.environ.get("XDG_SESSION_TYPE", ""),
        "wayland_display": os.environ.get("WAYLAND_DISPLAY", ""),
        "user": os.environ.get("USER", ""),
        "euid": os.geteuid() if hasattr(os, "geteuid") else None,
    }


def session_problems(settings: Settings, command: str) -> list[str]:
    session = current_session()
    problems: list[str] = []
    if settings.safety.get("require_x11", True):
        if session["xdg_session_type"].lower() and session["xdg_session_type"].lower() != "x11":
            problems.append(
                f"desktop placement requires X11; XDG_SESSION_TYPE={session['xdg_session_type']!r}")
        if session["wayland_display"]:
            problems.append(
                f"Wayland display is set; desktop hints may not be honored: WAYLAND_DISPLAY={session['wayland_display']!r}")
    if command == "launch" and settings.safety.get("refuse_root_for_launch", True) and session[
        "euid"] == 0:
        problems.append("launch should be run as the normal desktop user, not root")
    if command in {"doctor", "launch", "status", "close"} and not session["display"]:
        problems.append("DISPLAY is empty; X11 window discovery/placement cannot work")
    return problems


def detect_monitors() -> list[dict[str, Any]]:
    if not cmd_exists("xrandr"):
        return []
    result = run(["xrandr", "--query"], timeout=10.0)
    monitors: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        if " connected" not in line:
            continue
        parts = line.split()
        geometry = next((part for part in parts if "+" in part and "x" in part), None)
        if not geometry:
            continue
        try:
            size, px, py = geometry.split("+", maxsplit=2)
            width, height = size.split("x", maxsplit=1)
            monitors.append(
                {
                    "name": parts[0],
                    "width": int(width),
                    "height": int(height),
                    "x": int(px),
                    "y": int(py),
                    "raw": line.strip(),
                    "primary": "primary" in parts,
                }
            )
        except ValueError:
            continue
    return monitors


def format_monitor(monitor: dict[str, Any]) -> str:
    primary = " primary" if monitor.get("primary") else ""
    return f"{monitor['name']}: {monitor['width']}x{monitor['height']}+{monitor['x']}+{monitor['y']}{primary}"


def monitor_center_x(monitor: dict[str, Any]) -> float:
    return float(monitor["x"]) + float(monitor["width"]) / 2.0


def suggest_monitor(monitors: list[dict[str, Any]], position: str) -> dict[str, Any] | None:
    if not monitors:
        return None
    if position == "primary":
        primary = [monitor for monitor in monitors if monitor.get("primary")]
        return primary[0] if primary else sorted(monitors, key=lambda item: (item["x"], item["y"]))[
            0]
    if position == "top-middle":
        top_y = min(monitor["y"] for monitor in monitors)
        top_row = [monitor for monitor in monitors if monitor["y"] == top_y]
        return sorted(top_row, key=monitor_center_x)[len(top_row) // 2]
    raise ValueError(f"Unsupported monitor position: {position}")


def find_monitor(name: str) -> dict[str, Any] | None:
    for monitor in detect_monitors():
        if monitor["name"] == name:
            return monitor
    return None


def monitor_contract_result(settings: Settings, monitor: dict[str, Any] | None) -> dict[str, Any]:
    contract = settings.monitor_contract
    expected_name = str(contract.get("name") or settings.window.get("monitor"))
    checks: list[dict[str, Any]] = []

    def add(name: str, expected: Any, actual: Any) -> None:
        checks.append(
            {"name": name, "expected": expected, "actual": actual, "ok": expected == actual})

    add("name", expected_name, monitor.get("name") if monitor else None)
    if monitor:
        add("x", contract.get("expected_x"), monitor.get("x"))
        add("y", contract.get("expected_y"), monitor.get("y"))
        add("width", contract.get("expected_width"), monitor.get("width"))
        add("height", contract.get("expected_height"), monitor.get("height"))
    return {
        "label": contract.get("label", ""),
        "checks": checks,
        "ok": bool(checks) and all(item["ok"] for item in checks),
    }


def viewport_adapter_enabled(settings: Settings) -> bool:
    viewport = settings.viewport
    return bool(viewport.get("enabled", True)) and str(
        viewport.get("mode", "auto_map_shell")) != "off"


def configured_extension_dir(settings: Settings) -> Path:
    raw = str(settings.viewport.get("extension_dir", "extension/geacron_viewport"))
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = ROOT / path
    return path


def viewport_adapter_report(settings: Settings) -> dict[str, Any]:
    enabled = viewport_adapter_enabled(settings)
    extension_dir = configured_extension_dir(settings)
    manifest = extension_dir / "manifest.json"
    content = extension_dir / "content.js"
    stops: list[str] = []
    warnings: list[str] = []
    if enabled:
        if not extension_dir.is_dir():
            stops.append(f"viewport adapter directory is missing: {extension_dir}")
        if not manifest.is_file():
            stops.append(f"viewport adapter manifest is missing: {manifest}")
        if not content.is_file():
            stops.append(f"viewport adapter content script is missing: {content}")
    return {
        "enabled": enabled,
        "mode": str(settings.viewport.get("mode", "auto_map_shell")),
        "extension_dir": str(extension_dir),
        "manifest": str(manifest),
        "content_script": str(content),
        "stops": stops,
        "warnings": warnings,
    }


def screen_size_from_xrandr() -> dict[str, int] | None:
    if not cmd_exists("xrandr"):
        return None
    result = run(["xrandr", "--query"], timeout=10.0)
    match = re.search(r"current\s+(\d+)\s+x\s+(\d+)", result.stdout)
    if not match:
        return None
    return {"width": int(match.group(1)), "height": int(match.group(2))}


def parse_xprop_window_ids(value: str) -> list[str]:
    return re.findall(r"0x[0-9a-fA-F]+", value)


def parse_strut_partial(stdout: str) -> dict[str, int] | None:
    match = re.search(r"_NET_WM_STRUT_PARTIAL\([^)]*\)\s*=\s*([^\n]+)", stdout)
    if not match:
        return None
    nums = [int(value) for value in re.findall(r"\d+", match.group(1))]
    if len(nums) < 12:
        return None
    keys = [
        "left",
        "right",
        "top",
        "bottom",
        "left_start_y",
        "left_end_y",
        "right_start_y",
        "right_end_y",
        "top_start_x",
        "top_end_x",
        "bottom_start_x",
        "bottom_end_x",
    ]
    return dict(zip(keys, nums))


def ranges_overlap(a_start: int, a_end: int, b_start: int, b_end: int) -> bool:
    return max(a_start, b_start) < min(a_end, b_end)


def detect_strut_margins_for_monitor(monitor: dict[str, Any]) -> dict[str, Any]:
    margins = {"left": 0, "right": 0, "top": 0, "bottom": 0}
    details: list[dict[str, Any]] = []
    screen = screen_size_from_xrandr()
    if not screen:
        return {"available": False, "margins": margins, "details": details,
                "reason": "screen size unavailable"}
    if not cmd_exists("xprop"):
        return {"available": False, "margins": margins, "details": details,
                "reason": "xprop not found"}

    root = run(["xprop", "-root", "_NET_CLIENT_LIST", "_NET_CLIENT_LIST_STACKING"], timeout=10.0)
    ids = parse_xprop_window_ids(root.stdout)
    seen: set[str] = set()
    monitor_left = int(monitor["x"])
    monitor_top = int(monitor["y"])
    monitor_right = monitor_left + int(monitor["width"])
    monitor_bottom = monitor_top + int(monitor["height"])

    for window_id in ids:
        if window_id in seen:
            continue
        seen.add(window_id)
        result = run(["xprop", "-id", window_id, "_NET_WM_STRUT_PARTIAL", "WM_CLASS"], timeout=10.0)
        strut = parse_strut_partial(result.stdout)
        if not strut:
            continue
        wm_class_match = re.search(r"WM_CLASS\([^)]*\)\s*=\s*(.*)", result.stdout)
        wm_class = wm_class_match.group(1).strip() if wm_class_match else ""
        details.append({"window_id": window_id, "wm_class": wm_class, "strut": strut})

        if strut["bottom"] > 0:
            rect_top = int(screen["height"]) - strut["bottom"]
            rect_bottom = int(screen["height"])
            if ranges_overlap(strut["bottom_start_x"], strut["bottom_end_x"] + 1, monitor_left,
                              monitor_right) and ranges_overlap(rect_top, rect_bottom, monitor_top,
                                                                monitor_bottom):
                margins["bottom"] = max(margins["bottom"], monitor_bottom - rect_top)
        if strut["top"] > 0:
            rect_top = 0
            rect_bottom = strut["top"]
            if ranges_overlap(strut["top_start_x"], strut["top_end_x"] + 1, monitor_left,
                              monitor_right) and ranges_overlap(rect_top, rect_bottom, monitor_top,
                                                                monitor_bottom):
                margins["top"] = max(margins["top"], rect_bottom - monitor_top)
        if strut["left"] > 0:
            rect_left = 0
            rect_right = strut["left"]
            if ranges_overlap(strut["left_start_y"], strut["left_end_y"] + 1, monitor_top,
                              monitor_bottom) and ranges_overlap(rect_left, rect_right,
                                                                 monitor_left, monitor_right):
                margins["left"] = max(margins["left"], rect_right - monitor_left)
        if strut["right"] > 0:
            rect_left = int(screen["width"]) - strut["right"]
            rect_right = int(screen["width"])
            if ranges_overlap(strut["right_start_y"], strut["right_end_y"] + 1, monitor_top,
                              monitor_bottom) and ranges_overlap(rect_left, rect_right,
                                                                 monitor_left, monitor_right):
                margins["right"] = max(margins["right"], monitor_right - rect_left)

    return {"available": True, "margins": margins, "details": details, "reason": "ok"}


def visible_area_for_monitor(settings: Settings, monitor: dict[str, Any]) -> dict[str, Any]:
    monitor_area = {
        "x": int(monitor["x"]),
        "y": int(monitor["y"]),
        "width": int(monitor["width"]),
        "height": int(monitor["height"]),
    }
    work_area = {
        "source": "monitor_geometry",
        "monitor_area": dict(monitor_area),
        "visible_area": dict(monitor_area),
        "struts": None,
        "fallback_bottom_margin": 0,
        "warnings": [],
    }
    if not bool(settings.window.get("respect_work_area", True)):
        return work_area

    struts = detect_strut_margins_for_monitor(monitor)
    work_area["struts"] = struts
    margins = dict(struts.get("margins") or {})
    used_strut = any(int(value) > 0 for value in margins.values())
    if used_strut:
        work_area["source"] = "x11_struts"
    else:
        fallback = int(settings.window.get("taskbar_bottom_margin_fallback", 0))
        margins = {"left": 0, "right": 0, "top": 0, "bottom": fallback}
        work_area["source"] = "configured_fallback_margin"
        work_area["fallback_bottom_margin"] = fallback
        # Fallback margin is an intentional configured behavior for panels/taskbars
        # that do not expose a target-monitor EWMH strut. The selected source is
        # still reported in the placement plan, but it is not a warning.

    x = monitor_area["x"] + int(margins.get("left", 0))
    y = monitor_area["y"] + int(margins.get("top", 0))
    width = monitor_area["width"] - int(margins.get("left", 0)) - int(margins.get("right", 0))
    height = monitor_area["height"] - int(margins.get("top", 0)) - int(margins.get("bottom", 0))
    if width < 100 or height < 100:
        work_area["warnings"].append(
            "computed visible work area was too small; falling back to full monitor geometry")
        work_area["visible_area"] = dict(monitor_area)
    else:
        work_area["visible_area"] = {"x": x, "y": y, "width": width, "height": height}
    return work_area


def placement_plan(settings: Settings, mode: str, monitor_name: str | None = None) -> dict[
    str, Any]:
    if mode not in VALID_MODES:
        die(f"unsupported mode: {mode}", 2)

    configured_monitor = str(monitor_name or settings.window["monitor"])
    monitor = find_monitor(configured_monitor)
    target = {
        "mode": mode,
        "source": "fallback_geometry",
        "monitor": configured_monitor,
        "x": int(settings.window["x"]),
        "y": int(settings.window["y"]),
        "width": int(settings.window["width"]),
        "height": int(settings.window["height"]),
        "monitor_area": None,
        "visible_area": None,
        "work_area": None,
        "viewport_adapter": viewport_adapter_report(settings),
        "warnings": [],
        "stops": [],
        "monitor_contract": None,
    }

    if mode == "desktop" and settings.window.get("desktop_fill_monitor", True):
        if monitor:
            contract_result = monitor_contract_result(settings, monitor)
            target["monitor_contract"] = contract_result
            if (
                    settings.safety.get("require_monitor_contract_match_for_desktop", True)
                    and not contract_result["ok"]
            ):
                target["stops"].append(
                    "active xrandr geometry does not match monitor_contract; run doctor and fix monitor layout before desktop launch"
                )
            if not target["stops"]:
                work_area = visible_area_for_monitor(settings, monitor)
                visible = work_area["visible_area"]
                target.update(
                    {
                        "source": f"active_xrandr_monitor_geometry+{work_area['source']}",
                        "monitor": monitor["name"],
                        "x": int(visible["x"]),
                        "y": int(visible["y"]),
                        "width": int(visible["width"]),
                        "height": int(visible["height"]),
                        "monitor_area": work_area["monitor_area"],
                        "visible_area": visible,
                        "work_area": work_area,
                    }
                )
                target["warnings"].extend(work_area.get("warnings", []))
        elif settings.safety.get("require_configured_monitor_for_desktop", True):
            target["stops"].append(
                f"configured desktop monitor {configured_monitor!r} was not detected by xrandr"
            )
        else:
            target["warnings"].append(
                f"configured monitor {configured_monitor!r} was not detected; using fallback geometry"
            )
    return target


def read_proc_cmdline(pid: int) -> list[str]:
    try:
        data = (Path("/proc") / str(pid) / "cmdline").read_bytes()
    except (FileNotFoundError, PermissionError, ProcessLookupError, OSError):
        return []
    return [part.decode("utf-8", errors="replace") for part in data.split(b"\0") if part]


def normalize_path_for_compare(value: str) -> str:
    try:
        return str(Path(value).expanduser().resolve())
    except (OSError, RuntimeError):
        return str(Path(value).expanduser())


def extract_arg_value(argv: list[str], name: str) -> str | None:
    prefix = f"{name}="
    for index, arg in enumerate(argv):
        if arg.startswith(prefix):
            return arg.split("=", 1)[1]
        if arg == name and index + 1 < len(argv):
            return argv[index + 1]
    return None


def parse_remote_debugging_port(argv: list[str]) -> int | None:
    value = extract_arg_value(argv, "--remote-debugging-port")
    if value and value.isdigit():
        return int(value)
    return None


def process_uses_profile(argv: list[str], profile_dir: Path = PROFILE_DIR) -> bool:
    value = extract_arg_value(argv, "--user-data-dir")
    if not value:
        return False
    return normalize_path_for_compare(value) == normalize_path_for_compare(str(profile_dir))


def profile_chrome_processes(profile_dir: Path = PROFILE_DIR) -> list[dict[str, Any]]:
    processes: list[dict[str, Any]] = []
    proc_root = Path("/proc")
    for entry in proc_root.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        if pid == os.getpid():
            continue
        argv = read_proc_cmdline(pid)
        if not argv or not process_uses_profile(argv, profile_dir):
            continue
        processes.append({
            "pid": pid,
            "remote_debugging_port": parse_remote_debugging_port(argv),
            "argv": argv,
            "cmdline": shlex.join(argv),
        })
    processes.sort(key=lambda item: int(item["pid"]))
    return processes


def terminate_profile_chrome_processes(timeout_seconds: float = 2.0) -> dict[str, Any]:
    before = profile_chrome_processes(PROFILE_DIR)
    pids = [int(item["pid"]) for item in before]
    terminated: list[int] = []
    killed: list[int] = []
    errors: list[str] = []

    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
            terminated.append(pid)
        except ProcessLookupError:
            pass
        except PermissionError as exc:
            errors.append(f"SIGTERM denied for pid {pid}: {exc}")
        except OSError as exc:
            errors.append(f"SIGTERM failed for pid {pid}: {exc}")

    deadline = time.time() + max(0.0, timeout_seconds)
    while time.time() < deadline:
        if not profile_chrome_processes(PROFILE_DIR):
            break
        time.sleep(0.1)

    remaining_after_term = profile_chrome_processes(PROFILE_DIR)
    for item in remaining_after_term:
        pid = int(item["pid"])
        try:
            os.kill(pid, signal.SIGKILL)
            killed.append(pid)
        except ProcessLookupError:
            pass
        except PermissionError as exc:
            errors.append(f"SIGKILL denied for pid {pid}: {exc}")
        except OSError as exc:
            errors.append(f"SIGKILL failed for pid {pid}: {exc}")

    if killed:
        deadline = time.time() + 1.0
        while time.time() < deadline:
            if not profile_chrome_processes(PROFILE_DIR):
                break
            time.sleep(0.1)

    after = profile_chrome_processes(PROFILE_DIR)
    return {
        "profile_dir": str(PROFILE_DIR),
        "before": before,
        "terminated_pids": terminated,
        "killed_pids": killed,
        "after": after,
        "ok": not after and not errors,
        "errors": errors,
    }


def window_pid(window_id: str) -> int | None:
    if not cmd_exists("wmctrl"):
        return None
    result = run(["wmctrl", "-lp"], timeout=10.0)
    normalized = window_id.lower()
    for line in result.stdout.splitlines():
        parts = line.split(maxsplit=4)
        if len(parts) >= 3 and parts[0].lower() == normalized and parts[2].isdigit():
            pid = int(parts[2])
            return pid if pid > 0 else None
    return None


def devtools_active_port() -> int | None:
    path = PROFILE_DIR / "DevToolsActivePort"
    try:
        first_line = path.read_text(encoding="utf-8", errors="replace").splitlines()[0].strip()
    except (FileNotFoundError, IndexError, OSError):
        return None
    return int(first_line) if first_line.isdigit() else None


def cdp_port_reachable(port: int | None) -> bool:
    if port is None:
        return False
    try:
        fetch_json(f"http://127.0.0.1:{port}/json/version", timeout=0.8)
        return True
    except (OSError, urllib.error.URLError, json.JSONDecodeError):
        return False


def resolve_cdp_port_for_window(window_id: str, requested_port: int | None) -> dict[str, Any]:
    pid = window_pid(window_id)
    argv = read_proc_cmdline(pid) if pid is not None else []
    window_cmdline_port = parse_remote_debugging_port(argv)
    active_file_port = devtools_active_port()

    candidates: list[int] = []
    for item in (window_cmdline_port, active_file_port, requested_port):
        if item is not None and item not in candidates:
            candidates.append(item)

    reachable: list[int] = [port for port in candidates if cdp_port_reachable(port)]
    selected = reachable[0] if reachable else (candidates[0] if candidates else None)

    return {
        "requested_port": requested_port,
        "window_pid": pid,
        "window_cmdline_port": window_cmdline_port,
        "devtools_active_port": active_file_port,
        "candidates": candidates,
        "reachable": reachable,
        "selected_port": selected,
        "selected_port_reachable": selected in reachable if selected is not None else False,
        "window_profile_matches": process_uses_profile(argv, PROFILE_DIR) if argv else None,
    }


def allocate_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def viewport_cdp_enabled(settings: Settings) -> bool:
    viewport = settings.viewport
    if not viewport_adapter_enabled(settings):
        return False
    mode = str(viewport.get("mode", "auto_map_shell"))
    return mode in {"auto_map_shell", "cdp_iframe_shell", "iframe_shell"}


def fetch_json(url: str, timeout: float = 1.5) -> Any:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def canonical_cdp_url(value: str) -> str:
    parsed = urllib.parse.urlparse(str(value or ""))
    scheme = parsed.scheme.lower()
    netloc = parsed.netloc.lower()
    path = parsed.path or "/"
    if path != "/" and path.endswith("/"):
        path = path[:-1]
    query = f"?{parsed.query}" if parsed.query else ""
    return f"{scheme}://{netloc}{path}{query}"


def cdp_target_score(target: dict[str, Any], desired_url: str) -> int:
    if target.get("type") != "page":
        return -1

    raw_url = str(target.get("url") or "")
    if not raw_url:
        return -1

    parsed = urllib.parse.urlparse(raw_url)
    if parsed.scheme not in {"http", "https"}:
        return -1
    if parsed.hostname not in {"geacron.com", "www.geacron.com"}:
        return -1

    target_url = canonical_cdp_url(raw_url)
    desired = canonical_cdp_url(desired_url)

    if target_url == desired:
        return 100
    if parsed.path.rstrip("/") == "/home-en":
        return 90
    if parsed.hostname in {"geacron.com", "www.geacron.com"}:
        return 50
    return -1


def describe_cdp_targets(targets: list[dict[str, Any]]) -> list[dict[str, str]]:
    described: list[dict[str, str]] = []
    for target in targets:
        described.append({
            "type": str(target.get("type") or ""),
            "url": str(target.get("url") or ""),
            "title": str(target.get("title") or ""),
            "id": str(target.get("id") or ""),
        })
    return described


def choose_cdp_target(targets: list[dict[str, Any]], desired_url: str) -> dict[str, Any] | None:
    scored: list[tuple[int, dict[str, Any]]] = []
    for target in targets:
        score = cdp_target_score(target, desired_url)
        if score >= 0 and target.get("webSocketDebuggerUrl"):
            scored.append((score, target))
    if not scored:
        return None
    scored.sort(key=lambda item: item[0], reverse=True)
    return scored[0][1]


def wait_for_cdp_target(port: int, desired_url: str, timeout_seconds: float = 12.0) -> dict[
    str, Any]:
    deadline = time.time() + timeout_seconds
    last_error: str | None = None
    last_targets: list[dict[str, str]] = []
    while time.time() < deadline:
        try:
            targets = fetch_json(f"http://127.0.0.1:{port}/json/list")
            if isinstance(targets, list):
                last_targets = describe_cdp_targets(targets)
                target = choose_cdp_target(targets, desired_url)
                if target and target.get("webSocketDebuggerUrl"):
                    return target
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = str(exc)
        time.sleep(0.25)
    target_summary = json.dumps(last_targets, ensure_ascii=False)[:1200]
    raise RuntimeError(
        f"CDP GeaCron page target unavailable on port {port}: "
        f"{last_error or 'no matching geacron page target'}; observed_targets={target_summary}"
    )


def websocket_handshake(ws_url: str, timeout: float = 3.0) -> socket.socket:
    parsed = urllib.parse.urlparse(ws_url)
    if parsed.scheme != "ws":
        raise RuntimeError(f"unsupported CDP websocket URL scheme: {parsed.scheme}")
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or 80
    path = parsed.path or "/"
    if parsed.query:
        path += f"?{parsed.query}"

    key = base64.b64encode(os.urandom(16)).decode("ascii")
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode("ascii")

    sock = socket.create_connection((host, port), timeout=timeout)
    sock.sendall(request)
    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            sock.close()
            raise RuntimeError("CDP websocket handshake closed before headers")
        response += chunk
        if len(response) > 65536:
            sock.close()
            raise RuntimeError("CDP websocket handshake response too large")
    header = response.split(b"\r\n\r\n", 1)[0].decode("iso-8859-1", errors="replace")
    if " 101 " not in header.split("\r\n", 1)[0]:
        sock.close()
        raise RuntimeError(
            f"CDP websocket handshake failed: {header.splitlines()[0] if header else 'no status'}")

    accept_expected = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
    ).decode("ascii")
    if accept_expected not in header:
        sock.close()
        raise RuntimeError("CDP websocket handshake accept key mismatch")
    return sock


def websocket_send_text(sock: socket.socket, text: str) -> None:
    payload = text.encode("utf-8")
    frame = bytearray([0x81])
    length = len(payload)
    if length < 126:
        frame.append(0x80 | length)
    elif length <= 0xFFFF:
        frame.append(0x80 | 126)
        frame.extend(struct.pack("!H", length))
    else:
        frame.append(0x80 | 127)
        frame.extend(struct.pack("!Q", length))
    mask = os.urandom(4)
    frame.extend(mask)
    frame.extend(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    sock.sendall(frame)


def websocket_recv_exact(sock: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("CDP websocket closed while reading frame")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def websocket_recv_text(sock: socket.socket) -> str:
    while True:
        first, second = websocket_recv_exact(sock, 2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", websocket_recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", websocket_recv_exact(sock, 8))[0]
        mask = websocket_recv_exact(sock, 4) if masked else b""
        payload = websocket_recv_exact(sock, length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x1:
            return payload.decode("utf-8")
        if opcode == 0x8:
            raise RuntimeError("CDP websocket closed")
        # Ignore ping/pong/binary/continuation frames for this small CDP usage.


def cdp_command(sock: socket.socket, request_id: int, method: str,
                params: dict[str, Any] | None = None) -> dict[str, Any]:
    websocket_send_text(sock,
                        json.dumps({"id": request_id, "method": method, "params": params or {}}))
    while True:
        message = json.loads(websocket_recv_text(sock))
        if message.get("id") == request_id:
            if "error" in message:
                raise RuntimeError(f"CDP {method} failed: {message['error']}")
            return message


def cdp_evaluate(sock: socket.socket, request_id: int, expression: str) -> Any:
    response = cdp_command(sock, request_id, "Runtime.evaluate", {
        "expression": expression,
        "awaitPromise": True,
        "returnByValue": True,
        "userGesture": True,
    })
    result = response.get("result", {})
    if result.get("exceptionDetails"):
        raise RuntimeError(f"CDP evaluation exception: {result['exceptionDetails']}")
    remote = result.get("result", {})
    if "value" in remote:
        return remote["value"]
    return remote.get("description")


def inject_viewport_shell_via_cdp(
        port: int,
        desired_url: str,
        *,
        settings: Settings | None = None,
        window_id: str | None = None,
        timeout_seconds: float = 18.0,
) -> dict[str, Any]:
    target = wait_for_cdp_target(port, desired_url, timeout_seconds=12.0)
    ws_url = str(target["webSocketDebuggerUrl"])
    sock = websocket_handshake(ws_url)
    try:
        cdp_command(sock, 1, "Runtime.enable")
        deadline = time.time() + timeout_seconds
        last_status: Any = None
        last_initial: Any = None
        last_inner_fill: Any = None
        last_menu_state: Any = None
        request_id = 2

        while time.time() < deadline:
            # Phase 1: re-run the iframe shell during the wait window. This
            # prevents a too-early injection from being lost if Chrome navigates
            # the app target after the websocket is already attached.
            last_initial = cdp_evaluate(sock, request_id, CDP_IFRAME_SHELL_SCRIPT)
            request_id += 1

            # Phase 2: only after the outer shell exists, stretch the inner
            # map surface inside GeaCron's own iframe. This leaves the top
            # GeaCron controls alone and only fills the former bottom whitespace.
            shell_status = cdp_evaluate(sock, request_id, CDP_VIEWPORT_STATUS_SCRIPT)
            request_id += 1
            last_status = shell_status

            if isinstance(shell_status, dict) and shell_status.get("shell") and shell_status.get(
                    "shellIframe"):
                last_inner_fill = cdp_evaluate(sock, request_id, CDP_INNER_MAP_FILL_SCRIPT)
                request_id += 1

                if settings is not None and window_id:
                    menu_payload = opacity_menu_state_payload(settings, window_id, status="ready")
                    last_menu_state = cdp_evaluate(
                        sock,
                        request_id,
                        cdp_set_opacity_menu_state_expression(menu_payload),
                    )
                    request_id += 1

                    redirect_payload = location_redirect_payload(settings, status="ready")
                    cdp_evaluate(
                        sock,
                        request_id,
                        cdp_set_location_redirect_state_expression(redirect_payload),
                    )
                    request_id += 1

                status = cdp_evaluate(sock, request_id, CDP_VIEWPORT_STATUS_SCRIPT)
                request_id += 1
                last_status = status

                if isinstance(status, dict) and status.get("shell") and status.get(
                        "shellIframe") and status.get("innerMapFill"):
                    return {
                        "ok": True,
                        "target_url": target.get("url"),
                        "target_title": target.get("title"),
                        "target_id": target.get("id"),
                        "initial": last_initial,
                        "inner_fill": last_inner_fill,
                        "menu_state": last_menu_state,
                        "status": status,
                    }

            time.sleep(0.35)

        return {
            "ok": False,
            "target_url": target.get("url"),
            "target_title": target.get("title"),
            "target_id": target.get("id"),
            "initial": last_initial,
            "inner_fill": last_inner_fill,
            "menu_state": last_menu_state,
            "status": last_status,
            "error": "iframe shell or inner map fill did not appear before timeout in the selected GeaCron target",
        }
    finally:
        try:
            sock.close()
        except Exception:
            pass


def build_chrome_cmd(settings: Settings, url: str, plan: dict[str, Any],
                     cdp_port: int | None = None) -> list[str]:
    cmd = [
        str(settings.general["chrome_binary"]),
        "--new-window",
        f"--app={url}",
        f"--user-data-dir={PROFILE_DIR}",
        "--class=geacron-panel",
        f"--window-position={plan['x']},{plan['y']}",
        f"--window-size={plan['width']},{plan['height']}",
        "--force-device-scale-factor=1",
        "--disable-session-crashed-bubble",
        "--disable-background-mode",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-features=Translate",
    ]
    if cdp_port is not None:
        cmd.extend([
            "--remote-debugging-address=127.0.0.1",
            f"--remote-debugging-port={cdp_port}",
        ])
    if viewport_adapter_enabled(settings):
        extension_dir = configured_extension_dir(settings)
        cmd.extend([
            f"--disable-extensions-except={extension_dir}",
            f"--load-extension={extension_dir}",
        ])
    cmd.extend(str(arg) for arg in settings.general.get("chrome_extra_args", []))
    return cmd


def find_panel_window(settings: Settings, retries: int = 1) -> str | None:
    """Find only windows launched by this tool's dedicated X11 class.

    A normal browser tab titled "GeaCron" is not a managed panel. Status,
    close, and reuse must not target unrelated Vivaldi/Chrome browser windows.
    """
    if not cmd_exists("wmctrl"):
        return None
    for attempt in range(max(1, retries)):
        result = run(["wmctrl", "-lx"], timeout=10.0)
        for line in result.stdout.splitlines():
            parts = line.split(maxsplit=4)
            if len(parts) < 3:
                continue
            window_id = parts[0]
            wm_class = parts[2].lower()
            if "geacron-panel" in wm_class:
                return window_id
        if attempt < retries - 1:
            time.sleep(0.5)
    return None


def get_window_info(window_id: str) -> dict[str, Any] | None:
    if not cmd_exists("wmctrl"):
        return None
    result = run(["wmctrl", "-lGx"], timeout=10.0)
    for line in result.stdout.splitlines():
        parts = line.split(maxsplit=8)
        if len(parts) < 7 or parts[0] != window_id:
            continue
        title = parts[8] if len(parts) > 8 else (parts[7] if len(parts) > 7 else "")
        return {
            "window_id": parts[0],
            "desktop": parts[1],
            "x": int(parts[2]),
            "y": int(parts[3]),
            "width": int(parts[4]),
            "height": int(parts[5]),
            "wm_class": parts[6],
            "title": title,
            "raw": line,
        }
    return None


def wmctrl_set_geometry(window_id: str, plan: dict[str, Any]) -> None:
    run(
        ["wmctrl", "-ir", window_id, "-e",
         f"0,{plan['x']},{plan['y']},{plan['width']},{plan['height']}"],
        timeout=10.0,
    )


def wmctrl_add_state(window_id: str, states: list[str]) -> None:
    if states:
        run(["wmctrl", "-ir", window_id, "-b", "add," + ",".join(states)], timeout=10.0)


def wmctrl_remove_state(window_id: str, states: list[str]) -> None:
    if states:
        run(["wmctrl", "-ir", window_id, "-b", "remove," + ",".join(states)], timeout=10.0)


def lower_window_if_available(window_id: str) -> dict[str, Any]:
    """Lower the managed X11 window after BELOW hints are applied.

    This is intentionally optional because wmctrl BELOW is the primary EWMH
    state. xdotool windowlower is the extra Muffin/Cinnamon nudge proven live
    to keep normal windows above the interactive GeaCron panel.
    """
    if not cmd_exists("xdotool"):
        return {
            "ok": True,
            "available": False,
            "applied": False,
            "reason": "xdotool_not_found",
        }

    result = run(["xdotool", "windowlower", window_id], timeout=10.0)
    return {
        "ok": result.returncode == 0,
        "available": True,
        "applied": result.returncode == 0,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def desktop_hints_for_layer(layer: str) -> list[str]:
    if layer == "below":
        return ["below", "skip_taskbar", "skip_pager", "sticky"]
    if layer == "normal":
        return ["skip_taskbar", "skip_pager", "sticky"]
    raise ValueError(f"unsupported desktop layer: {layer}")


def window_opacity_cardinal(opacity: float) -> int:
    return max(0, min(0xFFFFFFFF, round(float(opacity) * 0xFFFFFFFF)))


def apply_window_opacity(window_id: str, opacity: float) -> dict[str, Any]:
    requested = float(opacity)
    if requested >= 0.999:
        if not cmd_exists("xprop"):
            return {
                "ok": True,
                "requested": requested,
                "applied": False,
                "property_removed": False,
                "reason": "opaque_default_does_not_require_xprop",
            }
        result = run(["xprop", "-id", window_id, "-remove", "_NET_WM_WINDOW_OPACITY"], timeout=10.0)
        return {
            "ok": result.returncode == 0,
            "requested": 1.0,
            "applied": result.returncode == 0,
            "property_removed": result.returncode == 0,
            "stdout": result.stdout.strip(),
            "stderr": result.stderr.strip(),
        }

    if not cmd_exists("xprop"):
        return {
            "ok": False,
            "requested": requested,
            "applied": False,
            "error": "xprop is required when window.opacity is less than 1.0",
        }

    cardinal = window_opacity_cardinal(requested)
    cardinal_hex = f"0x{cardinal:08x}"
    result = run([
        "xprop",
        "-id",
        window_id,
        "-f",
        "_NET_WM_WINDOW_OPACITY",
        "32c",
        "-set",
        "_NET_WM_WINDOW_OPACITY",
        cardinal_hex,
    ], timeout=10.0)
    return {
        "ok": result.returncode == 0,
        "requested": requested,
        "applied": result.returncode == 0,
        "x11_cardinal": cardinal,
        "x11_cardinal_hex": cardinal_hex,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def read_window_opacity(window_id: str) -> dict[str, Any]:
    if not cmd_exists("xprop"):
        return {"available": False, "opacity": None, "reason": "xprop_not_found"}

    result = run(["xprop", "-id", window_id, "_NET_WM_WINDOW_OPACITY"], timeout=10.0)
    stdout = result.stdout.strip()
    if result.returncode != 0:
        return {
            "available": True,
            "ok": False,
            "opacity": None,
            "stdout": stdout,
            "stderr": result.stderr.strip(),
        }
    if "not found" in stdout.lower():
        return {
            "available": True,
            "ok": True,
            "opacity": 1.0,
            "property_present": False,
            "raw": stdout,
        }

    match = re.search(r"=\s*(0x[0-9a-fA-F]+|[0-9]+)", stdout)
    if not match:
        return {
            "available": True,
            "ok": False,
            "opacity": None,
            "property_present": True,
            "raw": stdout,
            "error": "could_not_parse_opacity_property",
        }

    raw_value = match.group(1)
    cardinal = int(raw_value, 0)
    return {
        "available": True,
        "ok": True,
        "opacity": round(cardinal / 0xFFFFFFFF, 4),
        "property_present": True,
        "x11_cardinal": cardinal,
        "x11_cardinal_hex": f"0x{cardinal:08x}",
        "raw": stdout,
    }


def presentation_stops(settings: Settings) -> list[str]:
    opacity = float(settings.window.get("opacity", 1.0))
    if opacity < 0.999 and not cmd_exists("xprop"):
        return ["window.opacity is below 1.0 but xprop is missing"]
    return []


def presentation_report(settings: Settings) -> dict[str, Any]:
    return {
        "desktop_layer": str(settings.window.get("desktop_layer", "below")),
        "opacity": float(settings.window.get("opacity", 1.0)),
        "opacity_backend": "xprop",
        "stops": presentation_stops(settings),
    }


def place_window(settings: Settings, window_id: str, mode: str, monitor_name: str | None = None) -> \
        dict[str, Any]:
    plan = placement_plan(settings, mode, monitor_name=monitor_name)
    if plan["stops"]:
        return {"ok": False, "target": plan, "requested_hints": [],
                "actual": get_window_info(window_id)}

    wmctrl_remove_state(window_id,
                        ["above", "below", "fullscreen", "skip_taskbar", "skip_pager", "sticky"])
    wmctrl_set_geometry(window_id, plan)

    requested_hints: list[str] = []
    if mode == "desktop":
        desktop_layer = str(settings.window.get("desktop_layer", "below"))
        requested_hints = desktop_hints_for_layer(desktop_layer)
        if settings.window.get("desktop_fullscreen", False):
            requested_hints.append("fullscreen")
    else:
        if settings.window.get("always_on_top", False):
            requested_hints.append("above")
        if settings.window.get("sticky", False):
            requested_hints.append("sticky")
        workspace = int(settings.window.get("workspace", -1))
        if workspace >= 0:
            run(["wmctrl", "-ir", window_id, "-t", str(workspace)], timeout=10.0)

    wmctrl_add_state(window_id, requested_hints)
    time.sleep(0.2)

    # Reapply geometry after state changes because Muffin/Chrome can adjust
    # decorations and managed-window extents after _NET_WM_STATE changes.
    wmctrl_set_geometry(window_id, plan)

    # Reassert the exact successful live-tested presentation state after final
    # geometry. This keeps normal windows above the map while preserving map
    # interaction when the map is exposed.
    if mode == "desktop":
        wmctrl_remove_state(window_id, ["above", "fullscreen"])
        wmctrl_add_state(window_id, requested_hints)

    opacity_result = apply_window_opacity(window_id, float(settings.window.get("opacity", 1.0)))

    lower_result = {
        "ok": True,
        "available": False,
        "applied": False,
        "reason": "not_desktop_mode",
    }
    if mode == "desktop" and "below" in requested_hints:
        lower_result = lower_window_if_available(window_id)

    return {
        "ok": bool(opacity_result.get("ok", False)) and bool(lower_result.get("ok", False)),
        "target": plan,
        "requested_hints": requested_hints,
        "opacity": opacity_result,
        "layer_lower": lower_result,
        "actual": get_window_info(window_id),
    }


def human_monitor_summary(settings: Settings) -> str:
    monitors = detect_monitors()
    suggestion = suggest_monitor(monitors, "top-middle")
    lines = ["Monitor candidates:"]
    if not monitors:
        return "Monitor candidates:\n  none detected"
    for index, monitor in enumerate(monitors):
        suffix = "  <-- suggested top-middle" if suggestion and monitor["name"] == suggestion[
            "name"] else ""
        configured = "  <-- configured" if monitor["name"] == settings.window.get("monitor") else ""
        lines.append(f"  [{index}] {format_monitor(monitor)}{suffix}{configured}")
    return "\n".join(lines)


def print_dependency_guidance(missing: list[str]) -> None:
    if not missing:
        return
    print("\nMissing dependency guidance:")
    for item in dependency_report(missing):
        print(f"  - {item['command']}: {item['hint']}")


def command_common_report(settings: Settings, command: str) -> dict[str, Any]:
    monitors = detect_monitors()
    configured_monitor = find_monitor(str(settings.window.get("monitor", "")))
    return {
        "project_root": str(ROOT),
        "config_path": str(CONFIG_PATH),
        "runtime_dir": str(RUNTIME_DIR),
        "profile_dir": str(PROFILE_DIR),
        "log_file": str(LOG_FILE),
        "session": current_session(),
        "session_problems": session_problems(settings, command),
        "missing_dependencies": missing_for_command(settings, command),
        "dependency_hints": dependency_report(missing_for_command(settings, command)),
        "monitors": monitors,
        "suggested_top_middle_monitor": suggest_monitor(monitors, "top-middle"),
        "configured_monitor": configured_monitor,
        "monitor_contract": monitor_contract_result(settings, configured_monitor),
        "viewport_adapter": viewport_adapter_report(settings),
        "presentation": presentation_report(settings),
        "settings": settings.raw,
    }


def cmd_doctor(settings: Settings, as_json: bool = False) -> int:
    report = command_common_report(settings, "doctor")
    report["detected_panel_window"] = find_panel_window(settings, retries=1)
    report["default_desktop_plan"] = placement_plan(settings, str(settings.general["default_mode"]))
    ok = not report["missing_dependencies"] and not report["session_problems"]
    if report["viewport_adapter"]["stops"]:
        ok = False
    if str(settings.general["default_mode"]) == "desktop" and report["default_desktop_plan"][
        "stops"]:
        ok = False
    if report["presentation"]["stops"]:
        ok = False
    report["ok"] = ok

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron panel doctor")
        print(f"  project: {ROOT}")
        print(f"  config:  {CONFIG_PATH}")
        print(f"  mode:    {settings.general['default_mode']}")
        print(f"  url:     {settings.general['url']}")
        print()
        print(human_monitor_summary(settings))
        print()
        if report["session_problems"]:
            print("Session problems:")
            for problem in report["session_problems"]:
                print(f"  STOP {problem}")
        if report["missing_dependencies"]:
            print("Missing dependencies:")
            for command in report["missing_dependencies"]:
                print(f"  STOP {command}")
            print_dependency_guidance(report["missing_dependencies"])
        viewport = report["viewport_adapter"]
        print("Viewport adapter:")
        print(f"  enabled: {viewport['enabled']}")
        print(f"  mode:    {viewport['mode']}")
        print(f"  dir:     {viewport['extension_dir']}")
        for warning in viewport["warnings"]:
            print(f"  WARN {warning}")
        for stop in viewport["stops"]:
            print(f"  STOP {stop}")
        presentation = report["presentation"]
        print("Window presentation:")
        print(f"  desktop_layer: {presentation['desktop_layer']}")
        print(f"  opacity:       {presentation['opacity']:.3f}")
        for stop in presentation["stops"]:
            print(f"  STOP {stop}")
        contract = report["monitor_contract"]
        print("Monitor contract:")
        print(
            f"  target: {settings.monitor_contract.get('name')} ({settings.monitor_contract.get('label')})")
        for check in contract["checks"]:
            mark = "OK" if check["ok"] else "STOP"
            print(
                f"  {mark:4} {check['name']}: expected={check['expected']} actual={check['actual']}")
        plan = report["default_desktop_plan"]
        print("Default placement plan:")
        print(f"  source: {plan['source']}")
        print(
            f"  target: {plan['width']}x{plan['height']}+{plan['x']}+{plan['y']} on {plan['monitor']}")
        if plan.get("visible_area"):
            visible = plan["visible_area"]
            print(
                f"  visible: {visible['width']}x{visible['height']}+{visible['x']}+{visible['y']}")
        for warning in plan["warnings"]:
            print(f"  WARN {warning}")
        for stop in plan["stops"]:
            print(f"  STOP {stop}")
        print(f"\nResult: {'OK' if ok else 'STOP'}")
    return 0 if ok else 1


def cmd_suggest_monitor(settings: Settings, position: str, as_json: bool = False) -> int:
    monitors = detect_monitors()
    monitor = suggest_monitor(monitors, position)
    report = {"position": position, "monitors": monitors, "suggested_monitor": monitor}
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print(human_monitor_summary(settings))
        if monitor:
            print(f"\nSuggested {position}: {monitor['name']} ({format_monitor(monitor)})")
    return 0 if monitor else 1


def toml_quote(value: str) -> str:
    return json.dumps(value)


def write_config(settings: Settings) -> None:
    general = settings.general
    window = settings.window
    contract = settings.monitor_contract
    safety = settings.safety
    map_labels = settings.map_labels
    location_redirect = settings.location_redirect
    redirect_profiles = location_redirect.get("profiles", {})
    redirect_profile_text = ""
    for profile_id, profile in redirect_profiles.items():
        redirect_profile_text += f"\n[location_redirect.profiles.{profile_id}]\n"
        redirect_profile_text += f"label = {toml_quote(str(profile.get('label', profile_id)))}\n"
        redirect_profile_text += f"url_template = {toml_quote(str(profile.get('url_template', '{originalUrl}')))}\n"
    chrome_args = ", ".join(toml_quote(str(arg)) for arg in general.get("chrome_extra_args", []))
    text = f'''# config/config.toml

[general]
name = {toml_quote(str(general.get("name", "GeaCron Live Map Panel")))}
url = {toml_quote(str(general["url"]))}
chrome_binary = {toml_quote(str(general["chrome_binary"]))}
chrome_extra_args = [{chrome_args}]
window_title_hint = {toml_quote(str(general.get("window_title_hint", "GeaCron")))}
default_mode = {toml_quote(str(general.get("default_mode", "desktop")))}
log_level = {toml_quote(str(general.get("log_level", "INFO")))}

[window]
monitor = {toml_quote(str(window.get("monitor", "DisplayPort-5")))}
x = {int(window["x"])}
y = {int(window["y"])}
width = {int(window["width"])}
height = {int(window["height"])}
always_on_top = {str(bool(window.get("always_on_top", False))).lower()}
sticky = {str(bool(window.get("sticky", False))).lower()}
workspace = {int(window.get("workspace", -1))}
desktop_fill_monitor = {str(bool(window.get("desktop_fill_monitor", True))).lower()}
desktop_fullscreen = {str(bool(window.get("desktop_fullscreen", False))).lower()}
desktop_layer = {toml_quote(str(window.get("desktop_layer", "below")))}
opacity = {float(window.get("opacity", 1.0)):.3f}
respect_work_area = {str(bool(window.get("respect_work_area", True))).lower()}
taskbar_bottom_margin_fallback = {int(window.get("taskbar_bottom_margin_fallback", 40))}

[viewport]
enabled = {str(bool(settings.viewport.get("enabled", True))).lower()}
mode = {toml_quote(str(settings.viewport.get("mode", "auto_map_shell")))}
extension_dir = {toml_quote(str(settings.viewport.get("extension_dir", "extension/geacron_viewport")))}
fallback_mode = {toml_quote(str(settings.viewport.get("fallback_mode", "plain_page")))}

[map_labels]
no_select = {str(bool(map_labels.get("no_select", True))).lower()}

[location_redirect]
enabled = {str(bool(location_redirect.get("enabled", True))).lower()}
mode = {toml_quote(str(location_redirect.get("mode", "google")))}
open_target = {toml_quote(str(location_redirect.get("open_target", "_blank")))}
{redirect_profile_text}
[monitor_contract]
name = {toml_quote(str(contract.get("name", window.get("monitor", "DisplayPort-5"))))}
label = {toml_quote(str(contract.get("label", "top / ONN 100027813")))}
expected_x = {int(contract.get("expected_x", window["x"]))}
expected_y = {int(contract.get("expected_y", window["y"]))}
expected_width = {int(contract.get("expected_width", window["width"]))}
expected_height = {int(contract.get("expected_height", window["height"]))}

[safety]
require_x11 = {str(bool(safety.get("require_x11", True))).lower()}
refuse_root_for_launch = {str(bool(safety.get("refuse_root_for_launch", True))).lower()}
require_configured_monitor_for_desktop = {str(bool(safety.get("require_configured_monitor_for_desktop", True))).lower()}
require_monitor_contract_match_for_desktop = {str(bool(safety.get("require_monitor_contract_match_for_desktop", True))).lower()}
allow_xdotool_force_close = {str(bool(safety.get("allow_xdotool_force_close", True))).lower()}
'''
    CONFIG_PATH.write_text(text, encoding="utf-8")


def cmd_set_monitor(settings: Settings, monitor_name: str, desktop_default: bool,
                    as_json: bool = False) -> int:
    known = {monitor["name"]: monitor for monitor in detect_monitors()}
    if known and monitor_name not in known:
        print(
            f"WARNING: monitor {monitor_name!r} was not detected. Known monitors: {', '.join(sorted(known))}",
            file=sys.stderr,
        )
    settings.window["monitor"] = monitor_name
    settings.window["desktop_fill_monitor"] = True
    settings.monitor_contract["name"] = monitor_name
    if monitor_name in known:
        monitor = known[monitor_name]
        settings.window["x"] = monitor["x"]
        settings.window["y"] = monitor["y"]
        settings.window["width"] = monitor["width"]
        settings.window["height"] = monitor["height"]
        settings.monitor_contract["expected_x"] = monitor["x"]
        settings.monitor_contract["expected_y"] = monitor["y"]
        settings.monitor_contract["expected_width"] = monitor["width"]
        settings.monitor_contract["expected_height"] = monitor["height"]
    if desktop_default:
        settings.general["default_mode"] = "desktop"
    write_config(settings)
    report = {"configured_monitor": monitor_name, "desktop_default": desktop_default,
              "config_path": str(CONFIG_PATH)}
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Configured window.monitor = {monitor_name!r}.")
        if desktop_default:
            print("Configured general.default_mode = 'desktop'.")
        print(f"Updated {CONFIG_PATH}.")
    return 0


def parse_requested_opacity(value: Any) -> float:
    try:
        opacity = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError("opacity must be a decimal number") from exc

    if opacity < MIN_WINDOW_OPACITY or opacity > MAX_WINDOW_OPACITY:
        raise ValueError(
            f"opacity must be between {MIN_WINDOW_OPACITY:.2f} and {MAX_WINDOW_OPACITY:.1f}"
        )
    return round(opacity, 3)


def opacity_snapshot(settings: Settings) -> dict[str, Any]:
    window_id = find_panel_window(settings, retries=1)
    observed = read_window_opacity(window_id) if window_id else None
    return {
        "ok": True,
        "running": bool(window_id),
        "window_id": window_id,
        "configured_opacity": float(settings.window.get("opacity", 1.0)),
        "observed": observed,
        "config_path": str(CONFIG_PATH),
    }


def set_panel_opacity(settings: Settings, opacity_value: Any, *, persist: bool = True) -> dict[
    str, Any]:
    try:
        opacity = parse_requested_opacity(opacity_value)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}

    window_id = find_panel_window(settings, retries=1)

    settings.window["opacity"] = opacity
    config_written = False
    if persist:
        write_config(settings)
        config_written = True

    applied: dict[str, Any] | None = None
    observed: dict[str, Any] | None = None
    if window_id:
        applied = apply_window_opacity(window_id, opacity)
        observed = read_window_opacity(window_id)

    return {
        "ok": bool(window_id) and bool(applied and applied.get("ok")),
        "running": bool(window_id),
        "window_id": window_id,
        "requested_opacity": opacity,
        "configured_opacity": float(settings.window.get("opacity", opacity)),
        "config_written": config_written,
        "config_path": str(CONFIG_PATH),
        "applied": applied,
        "observed": observed,
        "error": None if window_id else "GeaCron panel window is not running",
    }


def cmd_opacity_get(settings: Settings, as_json: bool) -> int:
    report = opacity_snapshot(settings)
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron panel opacity")
        print(f"  configured: {report['configured_opacity']:.3f}")
        print(f"  running:    {'yes' if report['running'] else 'no'}")
        if report.get("observed") and report["observed"].get("opacity") is not None:
            print(f"  observed:   {float(report['observed']['opacity']):.3f}")
    return 0 if report["ok"] else 1


def cmd_opacity_set(settings: Settings, opacity: str, as_json: bool) -> int:
    report = set_panel_opacity(settings, opacity, persist=True)
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron panel opacity set")
        print(f"  requested: {float(report.get('requested_opacity') or 0):.3f}")
        print(f"  running:   {'yes' if report.get('running') else 'no'}")
        print(f"  config:    {'written' if report.get('config_written') else 'not written'}")
        if report.get("observed") and report["observed"].get("opacity") is not None:
            print(f"  observed:  {float(report['observed']['opacity']):.3f}")
        if report.get("error"):
            print(f"  WARN {report['error']}")
    return 0 if report.get("ok") else 1


def native_read_message() -> dict[str, Any] | None:
    raw_length = sys.stdin.buffer.read(4)
    if not raw_length:
        return None
    if len(raw_length) != 4:
        raise RuntimeError("native message length header was incomplete")

    length = struct.unpack("<I", raw_length)[0]
    if length > 1024 * 1024:
        raise RuntimeError(f"native message too large: {length} bytes")

    payload = sys.stdin.buffer.read(length)
    if len(payload) != length:
        raise RuntimeError("native message payload was incomplete")

    value = json.loads(payload.decode("utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError("native message must be a JSON object")
    return value


def native_write_message(payload: dict[str, Any]) -> None:
    data = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def handle_native_message(settings: Settings, message: dict[str, Any]) -> dict[str, Any]:
    action = str(message.get("action") or message.get("type") or "")
    if action == "opacity-get":
        return opacity_snapshot(settings)
    if action == "opacity-set":
        return set_panel_opacity(settings, message.get("opacity"), persist=True)
    return {
        "ok": False,
        "error": f"unsupported native action: {action}",
    }


def cmd_native_host(settings: Settings) -> int:
    try:
        while True:
            message = native_read_message()
            if message is None:
                return 0
            native_write_message(handle_native_message(settings, message))
    except Exception as exc:
        try:
            native_write_message({
                "ok": False,
                "error": str(exc),
            })
        except Exception:
            pass
        return 1


def native_host_manifest_path(browser: str) -> Path:
    root = NATIVE_HOST_CONFIG_ROOTS[browser]
    return root / "NativeMessagingHosts" / f"{NATIVE_HOST_NAME}.json"


def native_host_manifest_payload() -> dict[str, Any]:
    return {
        "name": NATIVE_HOST_NAME,
        "description": "GeaCron Panel native opacity bridge",
        "path": str(NATIVE_HOST_SCRIPT),
        "type": "stdio",
        "allowed_origins": [
            f"chrome-extension://{GEACRON_EXTENSION_ID}/"
        ],
    }


def cmd_install_native_host(browser: str, as_json: bool) -> int:
    browsers = sorted(NATIVE_HOST_CONFIG_ROOTS) if browser == "both" else [browser]
    payload = native_host_manifest_payload()
    written: list[str] = []

    if not NATIVE_HOST_SCRIPT.exists():
        print(f"ERROR: native host script is missing: {NATIVE_HOST_SCRIPT}", file=sys.stderr)
        return 1

    NATIVE_HOST_SCRIPT.chmod(0o755)

    for item in browsers:
        path = native_host_manifest_path(item)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        written.append(str(path))

    report = {
        "ok": True,
        "native_host": NATIVE_HOST_NAME,
        "extension_id": GEACRON_EXTENSION_ID,
        "host_script": str(NATIVE_HOST_SCRIPT),
        "written": written,
    }

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron native host installed.")
        print(f"  native host: {NATIVE_HOST_NAME}")
        print(f"  extension:   {GEACRON_EXTENSION_ID}")
        print(f"  script:      {NATIVE_HOST_SCRIPT}")
        for path in written:
            print(f"  manifest:    {path}")
    return 0


def cmd_remove_native_host(browser: str, as_json: bool) -> int:
    browsers = sorted(NATIVE_HOST_CONFIG_ROOTS) if browser == "both" else [browser]
    removed: list[str] = []
    missing: list[str] = []

    for item in browsers:
        path = native_host_manifest_path(item)
        if path.exists():
            path.unlink()
            removed.append(str(path))
        else:
            missing.append(str(path))

    report = {
        "ok": True,
        "native_host": NATIVE_HOST_NAME,
        "removed": removed,
        "missing": missing,
    }

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron native host removal complete.")
        for path in removed:
            print(f"  removed: {path}")
        for path in missing:
            print(f"  missing: {path}")
    return 0


def opacity_menu_state_payload(
        settings: Settings,
        window_id: str | None,
        *,
        request_id: str | None = None,
        status: str = "ready",
        ok: bool = True,
        error: str | None = None,
) -> dict[str, Any]:
    observed = read_window_opacity(window_id) if window_id else None
    observed_opacity = None
    if isinstance(observed, dict) and observed.get("opacity") is not None:
        observed_opacity = float(observed["opacity"])

    configured_opacity = float(settings.window.get("opacity", 1.0))
    return {
        "ok": ok,
        "status": status,
        "requestId": request_id,
        "configuredOpacity": configured_opacity,
        "observedOpacity": observed_opacity if observed_opacity is not None else configured_opacity,
        "backend": "xprop",
        "windowId": window_id,
        "error": error,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


def cdp_set_opacity_menu_state_expression(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, ensure_ascii=False)
    return f"""
(() => {{
  const payload = {encoded};
  window.__GEACRON_PANEL_OPACITY_STATE__ = payload;
  try {{
    document.dispatchEvent(new CustomEvent("geacron-panel-opacity-state", {{ detail: payload }}));
  }} catch (_) {{}}
  return payload;
}})();
"""


def location_redirect_payload(
        settings: Settings,
        *,
        request_id: str | None = None,
        status: str = "ready",
        ok: bool = True,
        error: str | None = None,
) -> dict[str, Any]:
    redirect = settings.location_redirect
    profiles = redirect.get("profiles", {})
    return {
        "ok": ok,
        "status": status,
        "requestId": request_id,
        "enabled": bool(redirect.get("enabled", True)),
        "mode": str(redirect.get("mode", "google")),
        "openTarget": str(redirect.get("open_target", "_blank")),
        "profiles": profiles,
        "error": error,
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    }


def cdp_set_location_redirect_state_expression(payload: dict[str, Any]) -> str:
    encoded = json.dumps(payload, ensure_ascii=False)
    return f"""
(() => {{
  const payload = {encoded};
  window.__GEACRON_PANEL_REDIRECT_STATE__ = payload;
  try {{
    const iframe =
      document.querySelector("#geacron-iframe-only-shell iframe[src*='/map/atlas/mapal.html']") ||
      document.querySelector("#geacron-iframe-only-shell iframe#m0id") ||
      document.querySelector('iframe[src*="/map/atlas/mapal.html"]') ||
      document.querySelector("iframe#m0id") ||
      document.querySelector("iframe.m0");
    const target = iframe && iframe.contentWindow && iframe.contentWindow.__GEACRON_PANEL_LOCATION_REDIRECT_STATE__;
    if (target && typeof target.setConfig === "function") {{
      target.setConfig(payload);
    }}
  }} catch (_) {{}}
  try {{
    document.dispatchEvent(new CustomEvent("geacron-panel-redirect-state", {{ detail: payload }}));
  }} catch (_) {{}}
  return payload;
}})();
"""


def parse_requested_redirect_mode(value: Any, settings: Settings) -> str:
    mode = str(value or "").strip().lower()
    if not mode:
        raise ValueError("empty location redirect mode")
    profiles = settings.location_redirect.get("profiles", {})
    if mode != "off" and mode not in profiles:
        raise ValueError(f"unknown location redirect mode: {mode}")
    return mode


def set_location_redirect_mode(settings: Settings, mode: str, *, persist: bool = True) -> dict[
    str, Any]:
    try:
        parsed_mode = parse_requested_redirect_mode(mode, settings)
    except ValueError as exc:
        return {"ok": False, "error": str(exc)}
    settings.location_redirect["mode"] = parsed_mode
    if persist:
        write_config(settings)
    return {"ok": True, "mode": parsed_mode}


def cdp_read_redirect_request(sock: socket.socket, request_id: int, settings: Settings) -> dict[
                                                                                               str, Any] | None:
    value = cdp_evaluate(sock, request_id, CDP_REDIRECT_REQUEST_SCRIPT)
    if not isinstance(value, dict):
        return None
    request_key = str(value.get("id") or "")
    if not request_key:
        return None
    try:
        mode = parse_requested_redirect_mode(value.get("mode"), settings)
    except ValueError as exc:
        return {
            "id": request_key,
            "mode": None,
            "error": str(exc),
            "requestedAt": str(value.get("requestedAt") or ""),
        }
    return {
        "id": request_key,
        "mode": mode,
        "error": None,
        "requestedAt": str(value.get("requestedAt") or ""),
    }


def cdp_read_opacity_request(sock: socket.socket, request_id: int) -> dict[str, Any] | None:
    value = cdp_evaluate(sock, request_id, CDP_OPACITY_REQUEST_SCRIPT)
    if not isinstance(value, dict):
        return None
    request_key = str(value.get("id") or "")
    if not request_key:
        return None
    try:
        opacity = parse_requested_opacity(value.get("opacity"))
    except ValueError:
        return {
            "id": request_key,
            "opacity": None,
            "error": "invalid opacity request from menu",
            "requestedAt": str(value.get("requestedAt") or ""),
        }
    return {
        "id": request_key,
        "opacity": opacity,
        "error": None,
        "requestedAt": str(value.get("requestedAt") or ""),
    }


def cmd_opacity_controller(settings: Settings, window_id: str, port: int, url: str) -> int:
    target = wait_for_cdp_target(port, url, timeout_seconds=8.0)
    ws_url = str(target["webSocketDebuggerUrl"])
    sock = websocket_handshake(ws_url)

    last_request_id: str | None = None
    request_id = 1

    try:
        cdp_command(sock, request_id, "Runtime.enable")
        request_id += 1

        initial = opacity_menu_state_payload(settings, window_id, status="ready")
        cdp_evaluate(sock, request_id, cdp_set_opacity_menu_state_expression(initial))
        request_id += 1

        initial_redirect = location_redirect_payload(settings, status="ready")
        cdp_evaluate(sock, request_id, cdp_set_location_redirect_state_expression(initial_redirect))
        request_id += 1

        last_redirect_request_id: str | None = None

        while True:
            current_window = find_panel_window(settings, retries=1)
            if current_window != window_id:
                return 0

            try:
                request = cdp_read_opacity_request(sock, request_id)
                request_id += 1
            except Exception as exc:
                print(f"[opacity-controller] CDP request read failed: {exc}", flush=True)
                return 1

            if request and request["id"] != last_request_id:
                last_request_id = request["id"]

                if request.get("error") or request.get("opacity") is None:
                    payload = opacity_menu_state_payload(
                        settings,
                        window_id,
                        request_id=last_request_id,
                        status="error",
                        ok=False,
                        error=str(request.get("error") or "invalid opacity request"),
                    )
                    cdp_evaluate(sock, request_id, cdp_set_opacity_menu_state_expression(payload))
                    request_id += 1
                    time.sleep(0.35)
                    continue

                result = set_panel_opacity(settings, request["opacity"], persist=True)
                payload = opacity_menu_state_payload(
                    settings,
                    window_id,
                    request_id=last_request_id,
                    status="saved" if result.get("ok") else "error",
                    ok=bool(result.get("ok")),
                    error=result.get("error"),
                )
                cdp_evaluate(sock, request_id, cdp_set_opacity_menu_state_expression(payload))
                request_id += 1

            try:
                redirect_request = cdp_read_redirect_request(sock, request_id, settings)
                request_id += 1
            except Exception as exc:
                print(f"[opacity-controller] CDP redirect request read failed: {exc}", flush=True)
                return 1

            if redirect_request and redirect_request["id"] != last_redirect_request_id:
                last_redirect_request_id = redirect_request["id"]

                if redirect_request.get("error") or redirect_request.get("mode") is None:
                    payload = location_redirect_payload(
                        settings,
                        request_id=last_redirect_request_id,
                        status="error",
                        ok=False,
                        error=str(redirect_request.get("error") or "invalid redirect request"),
                    )
                    cdp_evaluate(sock, request_id,
                                 cdp_set_location_redirect_state_expression(payload))
                    request_id += 1
                    time.sleep(0.35)
                    continue

                result = set_location_redirect_mode(settings, redirect_request["mode"],
                                                    persist=True)
                payload = location_redirect_payload(
                    settings,
                    request_id=last_redirect_request_id,
                    status="saved" if result.get("ok") else "error",
                    ok=bool(result.get("ok")),
                    error=result.get("error"),
                )
                cdp_evaluate(sock, request_id, cdp_set_location_redirect_state_expression(payload))
                request_id += 1

            time.sleep(0.35)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def start_opacity_controller_process(
        *,
        window_id: str,
        port: int,
        url: str,
) -> dict[str, Any]:
    cmd = [
        sys.executable,
        str(Path(__file__).resolve()),
        "opacity-controller",
        "--window-id",
        window_id,
        "--port",
        str(port),
        "--url",
        url,
    ]

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_handle = LOG_FILE.open("a", encoding="utf-8")
    try:
        process = subprocess.Popen(
            cmd,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
        )
    finally:
        log_handle.close()

    return {
        "ok": True,
        "pid": process.pid,
        "command": shlex.join(cmd),
    }


def cmd_launch(
        settings: Settings,
        mode: str | None,
        url: str | None,
        monitor_name: str | None,
        dry_run: bool,
        new: bool,
        as_json: bool,
) -> int:
    chosen_mode = mode or str(settings.general["default_mode"])
    chosen_url = url or str(settings.general["url"])
    plan = placement_plan(settings, chosen_mode, monitor_name=monitor_name)
    cdp_port = allocate_loopback_port() if viewport_cdp_enabled(settings) else None
    cmd = build_chrome_cmd(settings, chosen_url, plan, cdp_port=cdp_port)
    common = command_common_report(settings, "launch")
    viewport = viewport_adapter_report(settings)
    stops = (
            list(common["session_problems"])
            + list(common["missing_dependencies"])
            + list(common["presentation"]["stops"])
            + list(viewport["stops"])
            + list(plan["stops"])
    )
    report = {
        "ok": not stops,
        "dry_run": dry_run,
        "mode": chosen_mode,
        "url": chosen_url,
        "placement_plan": plan,
        "viewport_adapter": viewport,
        "cdp_injection": {"enabled": cdp_port is not None, "port": cdp_port},
        "chrome_command": cmd,
        "chrome_command_shell": shlex.join(cmd),
        "stops": stops,
        "warnings": plan["warnings"],
        "project_root": str(ROOT),
        "profile_dir": str(PROFILE_DIR),
        "log_file": str(LOG_FILE),
    }

    if dry_run:
        if as_json:
            print(json.dumps(report, indent=2))
        else:
            print("GeaCron panel launch dry-run")
            print(f"  mode: {chosen_mode}")
            print(f"  url:  {chosen_url}")
            print(
                f"  plan: {plan['width']}x{plan['height']}+{plan['x']}+{plan['y']} on {plan['monitor']} ({plan['source']})")
            if plan.get("visible_area"):
                visible = plan["visible_area"]
                print(
                    f"  visible: {visible['width']}x{visible['height']}+{visible['x']}+{visible['y']}")
            presentation = common["presentation"]
            print(f"  viewport adapter: {viewport['mode'] if viewport['enabled'] else 'disabled'}")
            print(f"  desktop layer: {presentation['desktop_layer']}")
            print(f"  opacity: {presentation['opacity']:.3f}")
            print("  command:")
            print(f"    {shlex.join(cmd)}")
            for warning in report["warnings"]:
                print(f"  WARN {warning}")
            for stop in stops:
                print(f"  STOP {stop}")
            print(f"\nResult: {'OK for launch' if not stops else 'STOP before launch'}")
        return 0 if not stops else 1

    if stops:
        if as_json:
            print(json.dumps(report, indent=2))
        else:
            print("Launch stopped before changing anything:", file=sys.stderr)
            for stop in stops:
                print(f"  - {stop}", file=sys.stderr)
            print("Run ./scripts/launch.sh --dry-run or ./scripts/doctor.sh for details.",
                  file=sys.stderr)
        return 1

    ensure_runtime()
    existing_window = find_panel_window(settings, retries=1)
    profile_cleanup: dict[str, Any] | None = None

    if existing_window and not new:
        placement = place_window(settings, existing_window, chosen_mode, monitor_name=monitor_name)
        report.update(
            {"existing_window_reused": True, "window_id": existing_window, "placement": placement})
        if as_json:
            print(json.dumps(report, indent=2))
        else:
            print(
                f"Existing GeaCron panel found and re-placed in {chosen_mode} mode: {existing_window}")
            print(
                f"Target: {placement['target']['width']}x{placement['target']['height']}+{placement['target']['x']}+{placement['target']['y']}")
        return 0 if placement.get("ok") else 1

    if cdp_port is not None:
        # Chrome can leave a profile-owned browser process alive after the app
        # window is closed. A fresh --remote-debugging-port is ignored when the
        # new launch is handed off to that existing profile process, so stop
        # only this dedicated profile before a fresh CDP-controlled launch.
        profile_cleanup = terminate_profile_chrome_processes()
        report["profile_process_cleanup"] = profile_cleanup
        if profile_cleanup.get("after") or profile_cleanup.get("errors"):
            report.update({
                "ok": False,
                "error": "could not stop existing GeaCron profile Chrome processes before launch",
            })
            if as_json:
                print(json.dumps(report, indent=2))
            else:
                print("Launch stopped before Chrome start:", file=sys.stderr)
                print("  STOP could not stop existing GeaCron profile Chrome processes",
                      file=sys.stderr)
                for error in profile_cleanup.get("errors", []):
                    print(f"  - {error}", file=sys.stderr)
            return 1
        existing_window = None

    with LOG_FILE.open("a", encoding="utf-8") as log:
        log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] Launch: {shlex.join(cmd)}\n")

    subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    window_id = find_panel_window(settings, retries=40)
    if not window_id:
        report.update(
            {"ok": False, "error": "could not find GeaCron panel window after Chrome launch"})
        if as_json:
            print(json.dumps(report, indent=2))
        else:
            print(
                "Could not find the GeaCron panel window after launch. Run doctor for diagnostics.",
                file=sys.stderr)
        return 2

    placement = place_window(settings, window_id, chosen_mode, monitor_name=monitor_name)
    injection: dict[str, Any] | None = None
    cdp_port_resolution: dict[str, Any] | None = None
    if cdp_port is not None:
        cdp_port_resolution = resolve_cdp_port_for_window(window_id, cdp_port)
        selected_port = cdp_port_resolution.get("selected_port")
        try:
            if selected_port is None:
                raise RuntimeError("no CDP port could be resolved for the launched panel window")
            injection = inject_viewport_shell_via_cdp(
                int(selected_port),
                chosen_url,
                settings=settings,
                window_id=window_id,
            )
            injection["port"] = selected_port
            injection["port_resolution"] = cdp_port_resolution
        except Exception as exc:
            injection = {
                "ok": False,
                "error": str(exc),
                "port": selected_port,
                "port_resolution": cdp_port_resolution,
            }
    opacity_controller: dict[str, Any] | None = None
    if injection is not None and injection.get("ok") and injection.get("port"):
        opacity_controller = start_opacity_controller_process(
            window_id=window_id,
            port=int(injection["port"]),
            url=chosen_url,
        )

    report.update({
        "window_id": window_id,
        "placement": placement,
        "viewport_injection": injection,
        "opacity_controller": opacity_controller,
    })
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Panel launched in {chosen_mode} mode and placed: {window_id}")
        print(
            f"Target: {placement['target']['width']}x{placement['target']['height']}+{placement['target']['x']}+{placement['target']['y']}")
        if placement.get("actual"):
            actual = placement["actual"]
            print(f"Actual: {actual['width']}x{actual['height']}+{actual['x']}+{actual['y']}")
        if profile_cleanup and profile_cleanup.get("before"):
            stopped = len(profile_cleanup.get("terminated_pids", [])) + len(
                profile_cleanup.get("killed_pids", []))
            print(f"Stopped stale GeaCron profile Chrome processes: {stopped}")
        if injection is not None:
            print(f"Viewport CDP injection: {'OK' if injection.get('ok') else 'FAILED'}")
            if injection.get("port"):
                print(f"Viewport CDP port: {injection.get('port')}")
            if injection.get("target_url"):
                print(f"Viewport CDP target: {injection.get('target_url')}")
            if not injection.get("ok") and injection.get("error"):
                print(f"Viewport CDP injection error: {injection['error']}", file=sys.stderr)
            if opacity_controller is not None:
                print(f"Opacity controller: OK pid={opacity_controller.get('pid')}")
    return 0 if placement.get("ok") and (injection is None or injection.get("ok")) else 1


def cmd_status(settings: Settings, id_only: bool, verbose: bool, as_json: bool) -> int:
    window_id = find_panel_window(settings, retries=1)
    if id_only:
        if window_id:
            print(window_id)
        return 0 if window_id else 1
    report: dict[str, Any] = {"running": bool(window_id), "window_id": window_id}
    if window_id:
        report["window"] = get_window_info(window_id)
        report["opacity"] = read_window_opacity(window_id)
    if verbose:
        report.update(command_common_report(settings, "status"))
        report["default_plan"] = placement_plan(settings, str(settings.general["default_mode"]))
    if as_json or verbose:
        print(json.dumps(report, indent=2))
    else:
        print("GeaCron panel status")
        print(f"  running: {'yes' if window_id else 'no'}")
        if window_id:
            window = get_window_info(window_id) or {}
            print(f"  window:  {window_id}")
            if window:
                print(
                    f"  actual:  {window.get('width')}x{window.get('height')}+{window.get('x')}+{window.get('y')}")
            opacity = read_window_opacity(window_id)
            if opacity.get("ok") and opacity.get("opacity") is not None:
                print(f"  opacity: {float(opacity['opacity']):.3f}")
        return 0 if window_id else 1


def cmd_close(settings: Settings, wait_seconds: int, as_json: bool) -> int:
    window_id = find_panel_window(settings, retries=1)
    report: dict[str, Any] = {"found": bool(window_id), "window_id": window_id, "closed": False,
                              "forced": False}

    if window_id:
        run(["wmctrl", "-ic", window_id], timeout=10.0)
        deadline = time.time() + max(0, wait_seconds)
        while time.time() < deadline:
            if not find_panel_window(settings, retries=1):
                report["closed"] = True
                break
            time.sleep(0.25)

        if not report["closed"] and settings.safety.get("allow_xdotool_force_close",
                                                        True) and cmd_exists("xdotool"):
            run(["xdotool", "windowkill", window_id], timeout=10.0)
            report["forced"] = True
            report["closed"] = not bool(find_panel_window(settings, retries=1))
    else:
        report["closed"] = True

    cleanup = terminate_profile_chrome_processes()
    report["profile_process_cleanup"] = cleanup
    if cleanup.get("after") or cleanup.get("errors"):
        report["closed"] = False

    if as_json:
        print(json.dumps(report, indent=2))
    else:
        if not window_id and not cleanup.get("before"):
            print("No GeaCron panel window or profile-owned Chrome process found.")
        elif report["closed"]:
            if window_id:
                print("Panel window closed.")
            if cleanup.get("before"):
                stopped = len(cleanup.get("terminated_pids", [])) + len(
                    cleanup.get("killed_pids", []))
                print(f"Stopped GeaCron profile Chrome processes: {stopped}")
        else:
            print("GeaCron panel/profile close did not finish cleanly.", file=sys.stderr)
            for error in cleanup.get("errors", []):
                print(f"  - {error}", file=sys.stderr)
    return 0 if report["closed"] else 1


def cmd_reset_profile(as_json: bool) -> int:
    cleanup = terminate_profile_chrome_processes()
    ensure_runtime()
    removed: list[str] = []
    for item in PROFILE_DIR.iterdir():
        removed.append(str(item))
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()
    report = {"profile_dir": str(PROFILE_DIR), "removed": removed,
              "profile_process_cleanup": cleanup}
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("Dedicated Chrome profile reset.")
        print(f"Profile: {PROFILE_DIR}")
    return 0


def desktop_entry_text(autostart: bool = False) -> str:
    return """[Desktop Entry]
Type=Application
Name=GeaCron Panel
Comment=Launch the live GeaCron map panel
Exec={exec_path}
Icon=applications-internet
Terminal=false
Categories=Utility;
X-GeaCron-Autostart={autostart}
""".format(exec_path=ROOT / "scripts" / "launch.sh", autostart=str(autostart).lower())


def cmd_install_desktop(autostart: bool, as_json: bool) -> int:
    app_dir = Path.home() / ".local/share/applications"
    app_dir.mkdir(parents=True, exist_ok=True)
    app_path = app_dir / "geacron-panel.desktop"
    app_path.write_text(desktop_entry_text(autostart=False), encoding="utf-8")
    written = [str(app_path)]
    if autostart:
        auto_dir = Path.home() / ".config/autostart"
        auto_dir.mkdir(parents=True, exist_ok=True)
        auto_path = auto_dir / "geacron-panel.desktop"
        auto_path.write_text(desktop_entry_text(autostart=True), encoding="utf-8")
        written.append(str(auto_path))
    report = {"written": written, "autostart": autostart}
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("Desktop launcher installed.")
        if autostart:
            print("Autostart pointer installed.")
        for path in written:
            print(f"  {path}")
    return 0


def cmd_remove_desktop(as_json: bool) -> int:
    paths = [
        Path.home() / ".local/share/applications/geacron-panel.desktop",
        Path.home() / ".config/autostart/geacron-panel.desktop",
    ]
    removed: list[str] = []
    for path in paths:
        if path.exists():
            path.unlink()
            removed.append(str(path))
    report = {"removed": removed}
    if as_json:
        print(json.dumps(report, indent=2))
    else:
        print("Desktop/autostart pointer cleanup complete.")
        for path in removed:
            print(f"  removed {path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="GeaCron live map panel for Linux Mint Cinnamon/X11")
    sub = parser.add_subparsers(dest="cmd", required=True)

    doctor = sub.add_parser("doctor",
                            help="Inspect dependencies, session, monitor contract, and placement plan")
    doctor.add_argument("--json", action="store_true")

    launch = sub.add_parser("launch", help="Launch or re-place the GeaCron panel")
    launch.add_argument("--mode", choices=sorted(VALID_MODES), default=None)
    launch.add_argument("--url", default=None,
                        help="Override the configured GeaCron URL or saved link")
    launch.add_argument("--monitor", default=None,
                        help="Override the configured monitor for this launch")
    launch.add_argument("--dry-run", action="store_true",
                        help="Print the launch plan without starting Chrome")
    launch.add_argument("--new", action="store_true",
                        help="Launch a new panel even if one is already running")
    launch.add_argument("--json", action="store_true")

    status = sub.add_parser("status", help="Report whether the panel is running")
    status.add_argument("--id-only", action="store_true")
    status.add_argument("--verbose", action="store_true")
    status.add_argument("--json", action="store_true")

    close = sub.add_parser("close", help="Close the GeaCron panel window")
    close.add_argument("--wait-seconds", type=int, default=5)
    close.add_argument("--json", action="store_true")

    suggest = sub.add_parser("suggest-monitor",
                             help="Suggest a monitor from active xrandr geometry")
    suggest.add_argument("--position", choices=["top-middle", "primary"], default="top-middle")
    suggest.add_argument("--json", action="store_true")

    set_monitor = sub.add_parser("set-monitor", help="Write config for a detected monitor")
    set_monitor.add_argument("monitor")
    set_monitor.add_argument("--desktop-default", action="store_true")
    set_monitor.add_argument("--json", action="store_true")

    reset_profile = sub.add_parser("reset-profile",
                                   help="Delete the dedicated Chrome profile contents")
    reset_profile.add_argument("--json", action="store_true")

    install_desktop = sub.add_parser("install-desktop",
                                     help="Install a local desktop launcher pointer")
    install_desktop.add_argument("--autostart", action="store_true",
                                 help="Also install an autostart pointer")
    install_desktop.add_argument("--json", action="store_true")

    remove_desktop = sub.add_parser("remove-desktop",
                                    help="Remove local desktop/autostart pointer files")
    remove_desktop.add_argument("--json", action="store_true")

    opacity_get = sub.add_parser("opacity-get",
                                 help="Report configured and observed window opacity")
    opacity_get.add_argument("--json", action="store_true")

    opacity_set = sub.add_parser("opacity-set", help="Set and persist GeaCron panel window opacity")
    opacity_set.add_argument("opacity")
    opacity_set.add_argument("--json", action="store_true")

    install_native = sub.add_parser("install-native-host",
                                    help="Install the Chrome native messaging host for panel controls")
    install_native.add_argument("--browser", choices=["google-chrome", "chromium", "both"],
                                default="google-chrome")
    install_native.add_argument("--json", action="store_true")

    remove_native = sub.add_parser("remove-native-host",
                                   help="Remove the Chrome native messaging host manifest")
    remove_native.add_argument("--browser", choices=["google-chrome", "chromium", "both"],
                               default="google-chrome")
    remove_native.add_argument("--json", action="store_true")

    controller = sub.add_parser("opacity-controller", help=argparse.SUPPRESS)
    controller.add_argument("--window-id", required=True)
    controller.add_argument("--port", type=int, required=True)
    controller.add_argument("--url", required=True)

    sub.add_parser("native-host", help=argparse.SUPPRESS)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    settings = load_settings()

    if args.cmd == "doctor":
        return cmd_doctor(settings, as_json=args.json)
    if args.cmd == "launch":
        return cmd_launch(settings, args.mode, args.url, args.monitor, args.dry_run, args.new,
                          args.json)
    if args.cmd == "status":
        return cmd_status(settings, args.id_only, args.verbose, args.json)
    if args.cmd == "close":
        return cmd_close(settings, args.wait_seconds, args.json)
    if args.cmd == "suggest-monitor":
        return cmd_suggest_monitor(settings, args.position, args.json)
    if args.cmd == "set-monitor":
        return cmd_set_monitor(settings, args.monitor, args.desktop_default, args.json)
    if args.cmd == "reset-profile":
        return cmd_reset_profile(args.json)
    if args.cmd == "install-desktop":
        return cmd_install_desktop(args.autostart, args.json)
    if args.cmd == "remove-desktop":
        return cmd_remove_desktop(args.json)
    if args.cmd == "opacity-get":
        return cmd_opacity_get(settings, args.json)
    if args.cmd == "opacity-set":
        return cmd_opacity_set(settings, args.opacity, args.json)
    if args.cmd == "install-native-host":
        return cmd_install_native_host(args.browser, args.json)
    if args.cmd == "remove-native-host":
        return cmd_remove_native_host(args.browser, args.json)
    if args.cmd == "opacity-controller":
        return cmd_opacity_controller(settings, args.window_id, args.port, args.url)
    if args.cmd == "native-host":
        return cmd_native_host(settings)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())