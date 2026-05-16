#!/usr/bin/env bash
set -euo pipefail

echo "===== Runtime GPU smoke from inside container ====="

if ! python3 - <<'PY'
import importlib.metadata as md
import torch

print("torch:", torch.__version__)
print("hip:", getattr(torch.version, "hip", None))
print("amdsmi:", md.version("amdsmi"))
print("cuda_available:", torch.cuda.is_available())
print("device_count:", torch.cuda.device_count())
print("device_name:", torch.cuda.get_device_name(0) if torch.cuda.is_available() and torch.cuda.device_count() else "")

assert getattr(torch.version, "hip", None), "ROCm-enabled PyTorch is not active."
assert torch.cuda.is_available(), "GPU is not visible to torch."
assert torch.cuda.device_count() == 1, "Expected exactly one visible AMD GPU."

x = torch.ones((2, 2), device="cuda")
y = x @ x
print("tensor:", y)
print("✓ ROCm tensor execution OK")
PY
then
  echo "ERROR: Runtime GPU smoke failed." >&2
  exit 1
fi

if ! python3 - <<'PY'
import vllm
print("vllm:", vllm.__version__)
print("✓ vLLM import OK")
PY
then
  echo "ERROR: vLLM import smoke failed." >&2
  exit 1
fi

(pip3 list | grep -Ei 'nvidia|cuda' && echo "ERROR: NVIDIA/CUDA packages found" && exit 1) || echo "✓ No NVIDIA/CUDA contamination"