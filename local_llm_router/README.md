# local_llm_router

`local_llm_router` is a host-local LLM session routing app for Linux Mint Cinnamon/X11.

The first enabled route is intentionally narrow:

```text
ChatGPT active browser page
→ manual capture of latest assistant message
→ local daemon
→ SQLite store
→ configured wrapper
→ local draft inbox
→ user manually copies / sends / marks handled
```

The architecture is not temporary. The first route is simple because only one mode is enabled.

## Authority model

```text
Source/dev authority:
  /home/wantless/PycharmProjects/automation/local_llm_router

Runtime config:
  ~/.config/local-llm-router/config.yaml

Runtime database:
  ~/.local/share/local-llm-router/router.sqlite

Daemon:
  http://127.0.0.1:8015

Draft inbox:
  http://127.0.0.1:8015/draft-inbox

Browser adapter:
  Chrome/Chromium unpacked extension from ./extension
```

## Install

From the project root:

```bash
./scripts/install.sh
```

Run the daemon in the foreground first:

```bash
local-llm-router doctor
local-llm-router serve
```

Open:

```text
http://127.0.0.1:8015/draft-inbox
```

After foreground service works, install and start the user service:

```bash
./scripts/install.sh --enable-service
local-llm-router doctor
```

## Load extension

In Chrome/Chromium:

```text
chrome://extensions
→ Developer mode ON
→ Load unpacked
→ /home/wantless/PycharmProjects/automation/local_llm_router/extension
```

Then open ChatGPT. A small `LLMR` overlay should appear. Use `Capture latest` to send the latest assistant message to the local draft inbox.

## Core commands

```bash
local-llm-router doctor
local-llm-router status
local-llm-router serve
local-llm-router db-summary
local-llm-router open config
local-llm-router open inbox
local-llm-router service status
local-llm-router service restart
local-llm-router logs
```

## First-test success definition

```text
1. Daemon health endpoint returns ok.
2. Draft inbox loads.
3. Extension detects ChatGPT.
4. ChatGPT overlay appears.
5. Capture latest assistant message creates a message row.
6. Router creates a local draft delivery.
7. Draft inbox displays wrapped message.
8. Copy button copies wrapped draft.
9. Mark handled updates delivery status.
10. State survives daemon restart.
```
