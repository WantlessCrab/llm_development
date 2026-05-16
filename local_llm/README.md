# local_llm

`local_llm` is a standalone local LLM backend for source-grounded retrieval, model calls, run storage, and artifact-backed inspection.

## Permanent first operation

```text
configured local corpus
→ deterministic ingestion
→ source/document/chunk records
→ SQLite FTS retrieval
→ source-grounded prompt
→ configured OpenAI-compatible model endpoint
→ model response
→ stored run/retrieval/prompt artifacts
→ inspectable provenance
```

## Runtime authority

```text
source:
  /home/wantless/PycharmProjects/automation/local_llm

config:
  ~/.config/local-llm/config.yaml

database:
  ~/.local/share/local-llm/local_llm.sqlite

artifacts:
  ~/.local/share/local-llm/artifacts

server:
  http://127.0.0.1:8020
```

## Install

From the project root:

```bash
./scripts/install.sh
local-llm doctor
```

Run foreground first:

```bash
local-llm serve
```

## Core workflow

In a second terminal:

```bash
local-llm ingest primary_local_corpus
local-llm search project_basic "provider contract"
local-llm respond default_rag_answer "Explain the project structure and cite retrieved sources."
local-llm db-summary
```

Inspect a run:

```bash
local-llm run show <run_id>
local-llm run prompt <run_id>
local-llm run retrievals <run_id>
local-llm run context <run_id>
local-llm run artifacts <run_id>
```

## Model runtime

`local_llm` expects an OpenAI-compatible model endpoint defined by config:

```yaml
model_profiles:
  local_basic:
    provider: "openai_compatible"
    base_url: "http://127.0.0.1:8021/v1"
    api_key: "not-needed"
    model: "local-small"
```

The model runtime is external to this app. It can be vLLM, llama.cpp server, LM Studio, TGI, or another OpenAI-compatible local endpoint.
