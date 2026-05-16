#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

is_true() {
  case "${1,,}" in
    1|true|yes|y|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

is_false() {
  case "${1,,}" in
    0|false|no|n|off|disabled) return 0 ;;
    *) return 1 ;;
  esac
}

is_nonnegative_integer() {
  [[ "${1}" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
  [[ "${1}" =~ ^[1-9][0-9]*$ ]]
}

require_nonempty() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "${value}" ]] || fail "${name} is required"
}

prepare_help_cache() {
  if ! llama-server --help > /tmp/llama-server-help.txt 2>&1; then
    cat /tmp/llama-server-help.txt >&2 || true
    fail "llama-server --help failed"
  fi
}

supports_help_flag() {
  local flag="$1"
  grep -q -- "${flag}" /tmp/llama-server-help.txt
}

help_line_for_flag() {
  local flag="$1"
  grep -m 1 -- "${flag}" /tmp/llama-server-help.txt || true
}

flash_attn_accepts_value() {
  local line
  line="$(help_line_for_flag "--flash-attn")"
  [[ "${line}" =~ (on|off|auto|true|false) ]]
}

validate_reasoning_policy() {
  case "${1,,}" in
    on|off|auto) return 0 ;;
    *) return 1 ;;
  esac
}

add_required_flag_value() {
  local flag="$1"
  local value="$2"

  [[ -n "${value}" ]] || fail "${flag} requires a non-empty value"
  supports_help_flag "${flag}" || fail "llama-server does not support required flag ${flag}"
  LLAMA_CMD+=("${flag}" "${value}")
}

: "${RUNTIME_ID:=qwen36_35b_q4_llamacpp}"
: "${LLAMA_ARG_ALIAS:=local-qwen36-35b-q4-llamacpp}"
: "${LLAMA_ARG_MODEL:=/workspace/models/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf}"
: "${LLAMA_ARG_HOST:=0.0.0.0}"
: "${LLAMA_ARG_PORT:=8000}"
: "${LLAMA_ARG_DEVICE:=ROCm0}"
: "${LLAMA_ARG_CTX_SIZE:=4096}"
: "${LLAMA_ARG_N_GPU_LAYERS:=auto}"
: "${LLAMA_ARG_CPU_MOE:=false}"
: "${LLAMA_ARG_N_CPU_MOE:=0}"
: "${LLAMA_ARG_CACHE_TYPE_K:=q4_0}"
: "${LLAMA_ARG_CACHE_TYPE_V:=q4_0}"
: "${LLAMA_ARG_FLASH_ATTN:=auto}"
: "${LLAMA_ARG_REASONING:=off}"
: "${LLAMA_ARG_BATCH_SIZE:=512}"
: "${LLAMA_ARG_UBATCH_SIZE:=256}"
: "${LLAMA_ARG_THREADS:=8}"
: "${LLAMA_ARG_THREADS_BATCH:=16}"
: "${LLAMA_ARG_N_PARALLEL:=1}"

require_nonempty RUNTIME_ID
require_nonempty LLAMA_ARG_ALIAS
require_nonempty LLAMA_ARG_MODEL
require_nonempty LLAMA_ARG_HOST
require_nonempty LLAMA_ARG_PORT
require_nonempty LLAMA_ARG_DEVICE
require_nonempty LLAMA_ARG_CTX_SIZE
require_nonempty LLAMA_ARG_N_GPU_LAYERS
require_nonempty LLAMA_ARG_CPU_MOE
require_nonempty LLAMA_ARG_N_CPU_MOE
require_nonempty LLAMA_ARG_CACHE_TYPE_K
require_nonempty LLAMA_ARG_CACHE_TYPE_V
require_nonempty LLAMA_ARG_FLASH_ATTN
require_nonempty LLAMA_ARG_REASONING
require_nonempty LLAMA_ARG_BATCH_SIZE
require_nonempty LLAMA_ARG_UBATCH_SIZE
require_nonempty LLAMA_ARG_THREADS
require_nonempty LLAMA_ARG_THREADS_BATCH
require_nonempty LLAMA_ARG_N_PARALLEL

command -v llama-server >/dev/null 2>&1 || fail "llama-server is not available on PATH; PATH=${PATH}"

prepare_help_cache

required_flags=(
  "--model"
  "--alias"
  "--host"
  "--port"
  "--device"
  "--ctx-size"
  "--n-gpu-layers"
  "--cache-type-k"
  "--cache-type-v"
  "--batch-size"
  "--ubatch-size"
  "--threads"
  "--threads-batch"
  "--parallel"
  "--cpu-moe"
  "--n-cpu-moe"
  "--flash-attn"
  "--reasoning"
)

for flag in "${required_flags[@]}"; do
  supports_help_flag "${flag}" || fail "missing required llama-server flag: ${flag}"
done

[[ -e /dev/kfd ]] || fail "/dev/kfd is missing"
[[ -e /dev/dri/renderD129 ]] || fail "/dev/dri/renderD129 is missing; mounted AMD render node is required"
[[ -r /dev/kfd ]] || fail "/dev/kfd is not readable"
[[ -w /dev/kfd ]] || fail "/dev/kfd is not writable"
[[ -r /dev/dri/renderD129 ]] || fail "/dev/dri/renderD129 is not readable"
[[ -w /dev/dri/renderD129 ]] || fail "/dev/dri/renderD129 is not writable"

[[ -f "${LLAMA_ARG_MODEL}" ]] || fail "model file not found: ${LLAMA_ARG_MODEL}; expected compose mount ./models:/workspace/models"
[[ -r "${LLAMA_ARG_MODEL}" ]] || fail "model file is not readable: ${LLAMA_ARG_MODEL}"
[[ -s "${LLAMA_ARG_MODEL}" ]] || fail "model file is empty: ${LLAMA_ARG_MODEL}"

is_positive_integer "${LLAMA_ARG_PORT}" || fail "LLAMA_ARG_PORT must be a positive integer; got ${LLAMA_ARG_PORT}"
is_positive_integer "${LLAMA_ARG_CTX_SIZE}" || fail "LLAMA_ARG_CTX_SIZE must be a positive integer; got ${LLAMA_ARG_CTX_SIZE}"
is_positive_integer "${LLAMA_ARG_BATCH_SIZE}" || fail "LLAMA_ARG_BATCH_SIZE must be a positive integer; got ${LLAMA_ARG_BATCH_SIZE}"
is_positive_integer "${LLAMA_ARG_UBATCH_SIZE}" || fail "LLAMA_ARG_UBATCH_SIZE must be a positive integer; got ${LLAMA_ARG_UBATCH_SIZE}"
is_positive_integer "${LLAMA_ARG_THREADS}" || fail "LLAMA_ARG_THREADS must be a positive integer; got ${LLAMA_ARG_THREADS}"
is_positive_integer "${LLAMA_ARG_THREADS_BATCH}" || fail "LLAMA_ARG_THREADS_BATCH must be a positive integer; got ${LLAMA_ARG_THREADS_BATCH}"
is_positive_integer "${LLAMA_ARG_N_PARALLEL}" || fail "LLAMA_ARG_N_PARALLEL must be a positive integer; got ${LLAMA_ARG_N_PARALLEL}"
is_nonnegative_integer "${LLAMA_ARG_N_CPU_MOE}" || fail "LLAMA_ARG_N_CPU_MOE must be a nonnegative integer; got ${LLAMA_ARG_N_CPU_MOE}"

case "${LLAMA_ARG_N_GPU_LAYERS,,}" in
  auto|all) ;;
  *) is_nonnegative_integer "${LLAMA_ARG_N_GPU_LAYERS}" || fail "LLAMA_ARG_N_GPU_LAYERS must be auto, all, or a nonnegative integer; got ${LLAMA_ARG_N_GPU_LAYERS}" ;;
esac

echo "===== llama.cpp ROCm runtime ====="
echo "RUNTIME_ID=${RUNTIME_ID}"
echo "LLAMA_ARG_MODEL=${LLAMA_ARG_MODEL}"
echo "LLAMA_ARG_ALIAS=${LLAMA_ARG_ALIAS}"
echo "LLAMA_ARG_HOST=${LLAMA_ARG_HOST}"
echo "LLAMA_ARG_PORT=${LLAMA_ARG_PORT}"
echo "LLAMA_ARG_DEVICE=${LLAMA_ARG_DEVICE}"
echo "LLAMA_ARG_CTX_SIZE=${LLAMA_ARG_CTX_SIZE}"
echo "LLAMA_ARG_N_GPU_LAYERS=${LLAMA_ARG_N_GPU_LAYERS}"
echo "LLAMA_ARG_CPU_MOE=${LLAMA_ARG_CPU_MOE}"
echo "LLAMA_ARG_N_CPU_MOE=${LLAMA_ARG_N_CPU_MOE}"
echo "LLAMA_ARG_CACHE_TYPE_K=${LLAMA_ARG_CACHE_TYPE_K}"
echo "LLAMA_ARG_CACHE_TYPE_V=${LLAMA_ARG_CACHE_TYPE_V}"
echo "LLAMA_ARG_FLASH_ATTN=${LLAMA_ARG_FLASH_ATTN}"
echo "LLAMA_ARG_REASONING=${LLAMA_ARG_REASONING}"
echo "LLAMA_ARG_BATCH_SIZE=${LLAMA_ARG_BATCH_SIZE}"
echo "LLAMA_ARG_UBATCH_SIZE=${LLAMA_ARG_UBATCH_SIZE}"
echo "LLAMA_ARG_THREADS=${LLAMA_ARG_THREADS}"
echo "LLAMA_ARG_THREADS_BATCH=${LLAMA_ARG_THREADS_BATCH}"
echo "LLAMA_ARG_N_PARALLEL=${LLAMA_ARG_N_PARALLEL}"
echo "ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-unset}"
echo "HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-unset}"
echo "AMDGPU_TARGETS=${AMDGPU_TARGETS:-unset}"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}"

echo
echo "===== llama.cpp build/version ====="
llama-server --version

echo
echo "===== Runtime device nodes ====="
ls -l /dev/kfd /dev/dri/renderD129
[[ -d /dev/dri ]] && ls -l /dev/dri

echo
echo "===== ROCm user-space ====="
if [[ -f /opt/rocm/.info/version ]]; then
  cat /opt/rocm/.info/version
else
  warn "/opt/rocm/.info/version not found"
fi

if command -v rocminfo >/dev/null 2>&1; then
  rocminfo 2>/dev/null | grep -E "Agent [0-9]+|Name:|Marketing Name:|Vendor Name:|Device Type:|gfx" | sed -n '1,120p' || true
else
  warn "rocminfo not found"
fi

echo
echo "===== llama-server device list ====="
if supports_help_flag "--list-devices"; then
  llama-server --list-devices || warn "llama-server --list-devices failed; continuing to authoritative server launch"
else
  warn "llama-server does not expose --list-devices"
fi

LLAMA_CMD=(llama-server)

add_required_flag_value "--model" "${LLAMA_ARG_MODEL}"
add_required_flag_value "--alias" "${LLAMA_ARG_ALIAS}"
add_required_flag_value "--host" "${LLAMA_ARG_HOST}"
add_required_flag_value "--port" "${LLAMA_ARG_PORT}"
add_required_flag_value "--device" "${LLAMA_ARG_DEVICE}"
add_required_flag_value "--ctx-size" "${LLAMA_ARG_CTX_SIZE}"
add_required_flag_value "--n-gpu-layers" "${LLAMA_ARG_N_GPU_LAYERS}"
add_required_flag_value "--cache-type-k" "${LLAMA_ARG_CACHE_TYPE_K}"
add_required_flag_value "--cache-type-v" "${LLAMA_ARG_CACHE_TYPE_V}"
add_required_flag_value "--batch-size" "${LLAMA_ARG_BATCH_SIZE}"
add_required_flag_value "--ubatch-size" "${LLAMA_ARG_UBATCH_SIZE}"
add_required_flag_value "--threads" "${LLAMA_ARG_THREADS}"
add_required_flag_value "--threads-batch" "${LLAMA_ARG_THREADS_BATCH}"
add_required_flag_value "--parallel" "${LLAMA_ARG_N_PARALLEL}"

case "${LLAMA_ARG_FLASH_ATTN,,}" in
  auto|"")
    echo "LLAMA_ARG_FLASH_ATTN=auto; not forcing --flash-attn"
    ;;
  1|true|yes|y|on|enabled)
    if flash_attn_accepts_value; then
      LLAMA_CMD+=("--flash-attn" "on")
    else
      LLAMA_CMD+=("--flash-attn")
    fi
    ;;
  0|false|no|n|off|disabled)
    if flash_attn_accepts_value; then
      LLAMA_CMD+=("--flash-attn" "off")
    else
      echo "LLAMA_ARG_FLASH_ATTN=${LLAMA_ARG_FLASH_ATTN}; not passing boolean --flash-attn"
    fi
    ;;
  *)
    fail "LLAMA_ARG_FLASH_ATTN must be auto, on/true/1, or off/false/0; got ${LLAMA_ARG_FLASH_ATTN}"
    ;;
esac

validate_reasoning_policy "${LLAMA_ARG_REASONING}" || fail "LLAMA_ARG_REASONING must be on, off, or auto; got ${LLAMA_ARG_REASONING}"
add_required_flag_value "--reasoning" "${LLAMA_ARG_REASONING}"

if is_true "${LLAMA_ARG_CPU_MOE}"; then
  LLAMA_CMD+=("--cpu-moe")
elif is_false "${LLAMA_ARG_CPU_MOE}"; then
  :
else
  fail "LLAMA_ARG_CPU_MOE must be a true/false style value; got ${LLAMA_ARG_CPU_MOE}"
fi

if [[ "${LLAMA_ARG_N_CPU_MOE}" != "0" ]]; then
  LLAMA_CMD+=("--n-cpu-moe" "${LLAMA_ARG_N_CPU_MOE}")
fi

echo
echo "===== Starting llama.cpp OpenAI-compatible server ====="
printf 'Command:'
printf ' %q' "${LLAMA_CMD[@]}"
printf '\n'

exec "${LLAMA_CMD[@]}"