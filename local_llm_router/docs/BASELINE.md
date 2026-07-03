# local_llm_router validated baseline

## Runtime decision

```text
No Docker for the router daemon and browser extension path.
Use host-local daemon + SQLite + unpacked browser extension.
Use port 8015.
Host-local lifecycle authority is Supervisor/code-svc.
```

## Validated operational state

```text
assistant capture to local draft: operational
user capture to local draft: operational
intentional duplicate capture/requeue: operational
manual local provider dispatch guard: operational
confirmed local provider dispatch: operational
generated provider response to local draft: operational
provider-response return lane visibility: operational
manual browser insertion: operational through content script
Supervisor-backed local service status: operational
```

## Multi-session UX baseline

```text
live ChatGPT tab discovery: implemented through service worker
session inherited label: implemented in ChatGPT adapter
manual session alias: daemon-backed and user-authoritative
specific live ChatGPT target: implemented through tab_id bridge
session group assignment: implemented through existing queue-group API
popup collapsible sections: implemented
overlay current-session naming/group controls: implemented
prompt wrapper route-time transform: implemented
```

## ChatGPT adapter facts

```text
provider_detection: PASS
  location.hostname === "chatgpt.com"

conversation_identity: PASS
  conversation_id from /c/{conversation_id}
  gizmo_id from /g/{gizmo_id} when present

conversation_label_inference: PASS
  filtered sidebar title when available
  cleaned document.title fallback
  short session ID fallback

composer_detection: PASS
  selector: #prompt-textarea
  element: div
  role: textbox
  contenteditable: true

draft_insertion: PASS
  synthetic text/plain paste, verified execCommand insertText, range fallback

message_role_boundary: PASS
  [data-message-author-role="assistant"]
  [data-message-author-role="user"]
```

## Deferred or explicit non-targets

```text
auto-send: deferred
generation-state detection: deferred
Docker deployment for router: deferred
Docker runtime lifecycle control: explicitly non-target
Playwright-controlled browser provider: deferred
```