# llamacpp_rocm_qwen36_35b_q4

Containerized llama.cpp ROCm runtime for the first full-size local specialist model endpoint.

## Runtime identity

```text
runtime_id:
  qwen36_35b_q4_llamacpp

engine:
  llama.cpp server

compute backend:
  ROCm/HIP

GPU target:
  gfx1100

expected GPU:
  Radeon RX 7900 XTX

served model name:
  local-qwen36-35b-q4-llamacpp

OpenAI-compatible API:
  http://127.0.0.1:8023/v1

health endpoint:
  http://127.0.0.1:8023/health
```

## Directory authority

```text
runtime directory:
  /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4

compose file:
  docker-compose.llamacpp_rocm.yml

dockerfile:
  dockerfile.llamacpp_rocm

runtime manifest:
  runtime_manifest.yaml

model directory:
  ./models

runtime logs:
  ./logs

runtime cache:
  ./cache
```

## Current implementation state

Implemented container files define:

```text
compose GPU contract
loopback host port 8023
mounted model/cache/log directories
pinned llama.cpp source build
ROCm/HIP build target
llama-server, llama-cli, llama-bench runtime binaries
entrypoint runtime validation
device inspection script
model inspection script
OpenAI-compatible API smoke script
```

Current runtime status must be determined from actual validation output. Do not treat build, endpoint, local_llm
registration, or UI chat as passed until observed.

## GPU container contract

Compose exposes only the AMD runtime device path required for this model runtime:

```text
/dev/kfd
/dev/dri/renderD129
```

Intel render node is not part of this runtime contract.

```text
groups:
  video
  render

capability:
  SYS_PTRACE

security:
  seccomp:unconfined

ipc:
  host

shared memory:
  16g

ROCm visibility:
  ROCR_VISIBLE_DEVICES=0
  HIP_VISIBLE_DEVICES=0
```

## Model artifact

Expected first GGUF:

```text
Qwen3.6-35B-A3B-UD-Q4_K_S.gguf
```

Expected host path:

```text
/home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4/models/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf
```

Expected container path:

```text
/workspace/models/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf
```

Expected runtime env:

```text
LLAMA_ARG_MODEL=/workspace/models/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf
```

Checksum authority:

```text
models/MANIFEST.sha256
```

Generate the checksum manifest only after the final model file is placed.

## First-boot environment

Create `.env` from `.env.example`:

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
cp .env.example .env
```

Baseline first-boot settings:

```text
LLAMA_ARG_CTX_SIZE=4096
LLAMA_ARG_N_GPU_LAYERS=auto
LLAMA_ARG_CPU_MOE=false
LLAMA_ARG_N_CPU_MOE=0
LLAMA_ARG_CACHE_TYPE_K=q4_0
LLAMA_ARG_CACHE_TYPE_V=q4_0
LLAMA_ARG_FLASH_ATTN=auto
LLAMA_ARG_BATCH_SIZE=512
LLAMA_ARG_UBATCH_SIZE=256
LLAMA_ARG_THREADS=8
LLAMA_ARG_THREADS_BATCH=16
LLAMA_ARG_N_PARALLEL=1
```

`LLAMA_ARG_FLASH_ATTN=auto` means first boot does not force flash attention.

Do not add fit controls, larger context, nonzero MoE CPU offload, or throughput tuning variables before baseline
endpoint proof.

## Model inspection

Run before build/start when the model file is placed:

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
./scripts/inspect_model_files.sh
```

Expected result:

```text
model directory exists
model file exists
model file is readable
model file is non-empty
model file size is plausible
GGUF magic header is present
checksum manifest passes when present
```

## Build

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
docker compose -f docker-compose.llamacpp_rocm.yml --env-file .env build
```

Dockerfile builds from the pinned llama.cpp source ref and validates required server flags during image build.

## Device inspection

Run before full server launch:

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
docker compose -f docker-compose.llamacpp_rocm.yml --env-file .env run --rm --entrypoint /app/scripts/inspect_devices.sh llamacpp-rocm-qwen36-35b-q4
```

Expected result:

```text
/dev/kfd exists and is accessible
/dev/dri/renderD129 exists and is accessible
ROCm user-space is present
llama.cpp binaries are present
required llama-server flags are present
```

## Start runtime

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
docker compose -f docker-compose.llamacpp_rocm.yml --env-file .env up
```

Compose intentionally omits `restart: unless-stopped` until endpoint proof passes.

## API smoke

Run from another terminal after the runtime starts:

```bash
cd /home/wantless/PycharmProjects/automation/model_runtimes/llamacpp_rocm_qwen36_35b_q4
./scripts/smoke_openai_api.sh
```

Expected checks:

```text
/health is reachable
/v1/models returns JSON
/v1/models includes local-qwen36-35b-q4-llamacpp
/v1/chat/completions returns non-empty assistant content
```

## local_llm registration

Target config:

```text
/home/wantless/.config/local-llm/config.yaml
```

Registration patch:

```text
config/local_llm_registration.yaml
```

Merge the model profile and workflow into the existing config without removing existing entries.

Required model profile:

```text
local_qwen36_35b_q4_llamacpp
```

Required workflow:

```text
qwen36_35b_q4_llamacpp_rag_answer
```

Required model id:

```text
local-qwen36-35b-q4-llamacpp
```

Run doctor after applying config:

```bash
local-llm doctor
```

`local_llm` provider health requires `/v1/models` to include the configured model id.

## First full functionality chat test

Use the local_llm UI after API smoke and config registration pass.

```text
backend:
  http://127.0.0.1:8020

model runtime:
  http://127.0.0.1:8023/v1

workflow:
  qwen36_35b_q4_llamacpp_rag_answer
```

Suggested first prompt:

```text
Using retrieved project sources, explain how local_llm chooses and calls the configured model provider.
```

The same prompt is stored in:

```text
eval_inputs/first_optimization.md
```

Inspect the run after the UI response:

```bash
local-llm run show <run_id>
local-llm run prompt <run_id>
local-llm run retrievals <run_id>
local-llm run context <run_id>
local-llm run artifacts <run_id>
```

## Port map

```text
8020  local_llm backend/UI
8021  vLLM local-small control runtime
8023  llama.cpp qwen36_35b_q4 runtime
```

## Runtime boundaries

Promoted for first proof:

```text
manual endpoint launch
OpenAI-compatible API smoke
local_llm doctor
local_llm UI chat
source-grounded codebase question
```

Not promoted before proof:

```text
restart policy
unattended service operation
automatic agent loops
larger context settings
fit/reserve controls
nonzero MoE CPU offload
throughput tuning variables
```

## File update policy

Update `runtime_manifest.yaml` only from observed results.

Do not claim:

```text
model hash
successful build
healthy endpoint
served model alias proof
local_llm doctor proof
UI chat proof
```

until the corresponding command output proves it.