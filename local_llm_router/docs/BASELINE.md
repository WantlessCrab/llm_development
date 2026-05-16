# local_llm_router validated baseline

## Host/runtime decision

Validated first-pass decision:

```text
No Docker for first manual receive/send route.
Use host-local daemon + SQLite + unpacked browser extension.
Use port 8015.
```

Reason:

```text
The first route targets the user's real logged-in ChatGPT browser page.
Docker adds process/network/storage layers before the browser adapter contract is proven.
```

## Runtime paths

```text
source/dev:
  /home/wantless/PycharmProjects/automation/local_llm_router

config:
  ~/.config/local-llm-router/config.yaml

database:
  ~/.local/share/local-llm-router/router.sqlite

audit:
  ~/.local/share/local-llm-router/audit/

cache/logs:
  ~/.cache/local-llm-router/
```

## ChatGPT validated adapter facts

```text
provider_detection: PASS
  location.hostname === "chatgpt.com"

conversation_identity: PASS
  conversation_id from /c/{conversation_id}
  gizmo_id from /g/{gizmo_id} when present

composer_detection: PASS
  selector: #prompt-textarea
  element: div
  role: textbox
  contenteditable: true

draft_insertion: PASS
  method: document.execCommand("insertText", false, text)

message_role_boundary: PASS
  [data-message-author-role="assistant"]
  [data-message-author-role="user"]

latest_assistant_capture: PASS
  latest assistant root = last [data-message-author-role="assistant"]

preferred assistant body source: PASS
  latest assistant root → .markdown descendant → innerText
```

## Deferred / not validated

```text
auto-send: deferred
generation-state detection: deferred
bidirectional consult loop: deferred
local model inference: deferred
Docker deployment: deferred
Playwright-controlled browser: deferred
```
