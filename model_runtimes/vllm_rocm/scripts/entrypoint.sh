#!/usr/bin/env bash
set -euo pipefail

: "${VLLM_MODEL:?VLLM_MODEL is required}"
: "${VLLM_SERVED_MODEL_NAME:=local-small}"
: "${VLLM_API_HOST:=0.0.0.0}"
: "${VLLM_API_PORT:=8000}"
: "${VLLM_TARGET_DEVICE:=rocm}"
: "${VLLM_API_KEY:=not-needed}"
: "${VLLM_MAX_MODEL_LEN:=4096}"
: "${VLLM_GPU_MEMORY_UTILIZATION:=0.70}"
: "${VLLM_DTYPE:=auto}"

echo "===== vLLM ROCm runtime ====="
echo "VLLM_MODEL=${VLLM_MODEL}"
echo "VLLM_SERVED_MODEL_NAME=${VLLM_SERVED_MODEL_NAME}"
echo "VLLM_API_HOST=${VLLM_API_HOST}"
echo "VLLM_API_PORT=${VLLM_API_PORT}"
echo "VLLM_TARGET_DEVICE=${VLLM_TARGET_DEVICE}"
echo "VLLM_MAX_MODEL_LEN=${VLLM_MAX_MODEL_LEN}"
echo "VLLM_GPU_MEMORY_UTILIZATION=${VLLM_GPU_MEMORY_UTILIZATION}"
echo "VLLM_DTYPE=${VLLM_DTYPE}"
echo "PYTORCH_ROCM_ARCH=${PYTORCH_ROCM_ARCH:-unset}"

echo "===== Runtime ROCm/PyTorch/vLLM check ====="
if ! python3 - <<'PY'
import importlib.metadata as md
import torch
import vllm

print("startup torch:", torch.__version__)
print("startup hip:", getattr(torch.version, "hip", None))
try:
    print("startup amdsmi:", md.version("amdsmi"))
except md.PackageNotFoundError:
    print("startup amdsmi: not installed as a pip package")
print("startup cuda_available:", torch.cuda.is_available())
print("startup device_count:", torch.cuda.device_count())
print("startup device_name:", torch.cuda.get_device_name(0) if torch.cuda.is_available() and torch.cuda.device_count() else "")
print("startup vllm:", vllm.__version__)

assert getattr(torch.version, "hip", None), "ROCm-enabled PyTorch is not present at runtime."
assert torch.cuda.is_available(), "ROCm GPU is not visible at runtime."
assert torch.cuda.device_count() == 1, "Expected exactly one visible AMD GPU at runtime."
PY
then
  echo "ERROR: Runtime ROCm/PyTorch/vLLM check failed." >&2
  exit 1
fi

echo "===== Starting vLLM OpenAI-compatible server ====="
exec vllm serve "${VLLM_MODEL}" \
  --host "${VLLM_API_HOST}" \
  --port "${VLLM_API_PORT}" \
  --served-model-name "${VLLM_SERVED_MODEL_NAME}" \
  --api-key "${VLLM_API_KEY}" \
  --max-model-len "${VLLM_MAX_MODEL_LEN}" \
  --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTILIZATION}" \
  --dtype "${VLLM_DTYPE}"