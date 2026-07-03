# Prompt wrappers

Prompt wrappers are user-facing route-time text transforms. They are selected from the overlay or popup and apply only
to the outbound routed payload. They do not rewrite the original captured message, FormatCapture source record, session
identity, queue group, or delivery ownership.

## Active config

```text
~/.config/local-llm-router/prompt_wrappers.yaml
```

`./scripts/install.sh` creates the active file from `prompt_wrappers.example.yaml` if missing. Existing active wrapper
config is preserved and the latest source example is written as `prompt_wrappers.example.yaml.new`.

## Schema

```yaml
version: 1

prompt_wrappers:
  basic_fence:
    label: "Basic fenced block"
    description: "Wrap routed text in a fenced block."
    transform: "none"
    before: |
      ```text
    after: |
      ```
```

Supported transforms:

```text
none
strip
rstrip
lstrip
```

Optional `line_prefix` prefixes every routed line after the transform and before `before`/`after` are applied.

## Route flow

```text
source text
→ optional prompt wrapper
→ existing route target handling
→ manual review/send boundary
```

## CLI/API checks

```bash
local-llm-router prompt-wrappers
local-llm-router prompt-wrappers --apply basic_fence --text 'hello'
curl -fsS http://127.0.0.1:8015/api/v1/prompt-wrappers | python3 -m json.tool
```