#!/usr/bin/env bash
set -euo pipefail

status=0

mark_ok() {
  echo "OK   $*"
}

mark_fail() {
  echo "FAIL $*" >&2
  status=1
}

mark_warn() {
  echo "WARN $*"
}

check_path_exists() {
  local path="$1"

  if [[ -e "${path}" ]]; then
    mark_ok "${path} exists"
    ls -l "${path}"
  else
    mark_fail "${path} missing"
    return 0
  fi

  if [[ -r "${path}" ]]; then
    mark_ok "${path} readable"
  else
    mark_fail "${path} not readable"
  fi

  if [[ -w "${path}" ]]; then
    mark_ok "${path} writable"
  else
    mark_fail "${path} not writable"
  fi
}

echo "===== Runtime identity ====="
echo "hostname=$(hostname)"
echo "whoami=$(whoami)"
echo "id=$(id)"
echo "pwd=$(pwd)"

echo
echo "===== ROCm visibility env ====="
echo "ROCR_VISIBLE_DEVICES=${ROCR_VISIBLE_DEVICES:-unset}"
echo "HIP_VISIBLE_DEVICES=${HIP_VISIBLE_DEVICES:-unset}"
echo "AMDGPU_TARGETS=${AMDGPU_TARGETS:-unset}"
echo "HSA_OVERRIDE_GFX_VERSION=${HSA_OVERRIDE_GFX_VERSION:-unset}"
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-unset}"
echo "PATH=${PATH}"

echo
echo "===== Required device nodes ====="
check_path_exists /dev/kfd
check_path_exists /dev/dri/renderD129

echo
echo "===== /dev/dri inventory ====="
if [[ -d /dev/dri ]]; then
  ls -l /dev/dri
else
  mark_fail "/dev/dri missing"
fi

echo
echo "===== ROCm user-space ====="
if [[ -d /opt/rocm ]]; then
  mark_ok "/opt/rocm exists"
else
  mark_fail "/opt/rocm missing"
fi

if [[ -f /opt/rocm/.info/version ]]; then
  echo "ROCm version file:"
  cat /opt/rocm/.info/version
else
  mark_warn "/opt/rocm/.info/version missing"
fi

for tool in hipcc rocminfo rocm-smi amd-smi; do
  if command -v "${tool}" >/dev/null 2>&1; then
    mark_ok "${tool} found at $(command -v "${tool}")"
  else
    mark_warn "${tool} not found on PATH"
  fi
done

echo
echo "===== ROCm library inventory ====="
find /opt/rocm -maxdepth 4 -type f \( \
  -name "libamdhip64.so*" -o \
  -name "librocblas.so*" -o \
  -name "libhipblas.so*" -o \
  -name "libamd_smi.so*" \
\) -print 2>/dev/null | sort | sed -n '1,160p' || true

echo
echo "===== rocminfo selected output ====="
if command -v rocminfo >/dev/null 2>&1; then
  rocminfo 2>/dev/null | grep -E "Agent [0-9]+|Name:|Marketing Name:|Vendor Name:|Device Type:|gfx" | sed -n '1,160p' || true
else
  mark_warn "rocminfo unavailable"
fi

echo
echo "===== llama.cpp binaries ====="
for binary in llama-server llama-cli llama-bench; do
  if command -v "${binary}" >/dev/null 2>&1; then
    mark_ok "${binary} found at $(command -v "${binary}")"
    "${binary}" --version 2>&1 | sed -n '1,5p' || true
  else
    mark_fail "${binary} missing"
  fi
done

echo
echo "===== llama-server device listing ====="
if command -v llama-server >/dev/null 2>&1; then
  if ! llama-server --help > /tmp/llama-server-help.txt 2>&1; then
    mark_fail "llama-server --help failed"
  elif grep -q -- "--list-devices" /tmp/llama-server-help.txt; then
    llama-server --list-devices || mark_fail "llama-server --list-devices failed"
  else
    mark_warn "llama-server does not expose --list-devices"
  fi
fi

echo
echo "===== Required server flag surface ====="
required_flags=(
  "--model"
  "--alias"
  "--host"
  "--port"
  "--device"
  "--ctx-size"
  "--n-gpu-layers"
  "--cpu-moe"
  "--n-cpu-moe"
  "--cache-type-k"
  "--cache-type-v"
  "--flash-attn"
  "--batch-size"
  "--ubatch-size"
  "--threads"
  "--threads-batch"
  "--parallel"
  "--reasoning"
)

if command -v llama-server >/dev/null 2>&1 && [[ -f /tmp/llama-server-help.txt ]]; then
  for flag in "${required_flags[@]}"; do
    if grep -q -- "${flag}" /tmp/llama-server-help.txt; then
      mark_ok "llama-server supports ${flag}"
    else
      mark_fail "llama-server missing ${flag}"
    fi
  done
fi

echo
echo "===== Inspection result ====="
if [[ "${status}" -eq 0 ]]; then
  mark_ok "device inspection passed"
else
  mark_fail "device inspection failed"
fi

exit "${status}"