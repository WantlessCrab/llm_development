# Routing commands

## Purpose

The router uses one operator model for moving messages between supported sources and targets:

```text
source → target → Route
```

Route execution is direct. The UI shows compact post-action confirmation. The router does not auto-send browser messages
and does not auto-dispatch provider calls.

## Sources

```text
Last user message
Last assistant response
Selected queued item
Generated provider response through selected queued item/provider-response mode
```

## Targets

```text
Local draft inbox
Configured local HTTP provider
ChatGPT active composer
Specific live ChatGPT session/tab
```

Browser-owned targets are executed by the extension content script because only the content script can access the
ChatGPT composer DOM.

## Session identity and names

Routing identity is stable and never depends on the displayed name.

```text
Stable identity:
  source_session_id
  provider
  conversation_id
  gizmo_id
  live Chrome tab_id when targeting a browser tab

Mutable display metadata:
  manual alias
  inferred label
  label source
  label updated timestamp
```

Manual aliases are authoritative. Inferred labels may fill empty names, but inferred labels must never overwrite a
user-saved alias. Group assignment, queued drafts, deliveries, and target identity stay attached to stable IDs when a
session is renamed.

## Inherited ChatGPT names

ChatGPT session labels are inferred in this order:

```text
1. filtered sidebar/current conversation title
2. document.title with project prefix stripped
3. full document.title
4. short session ID fallback
```

The sidebar selector rejects navigation/accessibility noise such as `Skip to content` and links containing `#main`.

## Prompt wrappers

Overlay and popup can optionally apply a configured prompt wrapper before delivery. Prompt wrappers are loaded from:

```text
~/.config/local-llm-router/prompt_wrappers.yaml
```

Prompt wrapper selection is stateful per `source_session_id::queue_group_id`. The wrapper changes only the outbound
routed payload. Original captures, selected queued drafts, FormatCapture source data, queue group assignment, and stable
routing IDs remain unchanged.

Prompt wrappers are separate from internal route wrappers such as `source_attribution_default`. Internal route wrappers
provide audit/source envelopes. Prompt wrappers provide user-facing workflow framing.

## Queue groups

Every operation is scoped by the active queue group. Queue groups remain the collaboration boundary for routing,
dispatch, and insertion.

The popup and overlay can create groups, assign the current session to a group, and rename non-default groups. Group
operations use `queue_group_id`, never display names.

## Queue source modes

```text
all_insertable:
  FIFO across all queued drafts in the active queue group.

chatgpt_captures:
  only ChatGPT-origin queued captures.

provider_responses:
  generated local-provider responses.
```

All-insertable FIFO can return an older ChatGPT capture before a newer generated provider response. Provider-response
mode is the explicit local-response return lane.

## Duplicate intent

Repeated routing of the same message is allowed. Duplicate route attempts are user intent, not an error. Delivery/action
metadata preserves duplicate intent and operator action identity when available.

## Race control

Frontend controls lock the specific source/target/group action while it is in flight. Live-session refresh merges by
`source_session_id`, not label, and cannot overwrite a newer manual alias.

## Manual-review boundary

```text
Provider dispatch: manual action
Browser insertion: manual action
Browser send: user-only action
```