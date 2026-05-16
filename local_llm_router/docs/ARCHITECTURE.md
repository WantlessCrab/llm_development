# Architecture

## Components

```text
Browser content adapter
  Detects provider/session.
  Extracts latest assistant message.
  Inserts draft text when later enabled.
  Shows local overlay controls.

Browser extension popup
  Lightweight operator UI.
  Sends commands to active tab.
  Does not own durable state.

Daemon
  FastAPI app on 127.0.0.1:8015.
  Owns config, route decisions, validation, storage, draft inbox.

SQLite store
  Durable authority for sessions, messages, routes/deliveries, audit events.

Local draft inbox
  Browser-accessible local target.
  Displays routed drafts.
  Supports copy and mark-handled.
```

## Separation of concerns

```text
Provider adapters:
  DOM-specific observation and insertion only.

Daemon router:
  route decisions, wrappers, dedupe, delivery creation.

Store:
  persistence only.

Draft inbox:
  user-facing target view/control only.

Extension popup/overlay:
  command surface only.
```

## First enabled mode

```text
manual_draft_bridge:
  source: browser_session/chatgpt assistant message
  target: local_draft/default
  delivery: queued draft
  user action: copy / mark handled
```
