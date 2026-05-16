#!/usr/bin/env bash
set -euo pipefail

DEFAULT_MODEL_FILENAME="Qwen3.6-35B-A3B-UD-Q4_K_S.gguf"
MIN_MODEL_BYTES="${MIN_MODEL_BYTES:-8589934592}"

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

human_bytes() {
  python3 - "$1" <<'PY'
import sys

value = int(sys.argv[1])
units = ["B", "KiB", "MiB", "GiB", "TiB"]
size = float(value)

for unit in units:
    if size < 1024 or unit == units[-1]:
        print(f"{size:.2f} {unit}")
        break
    size /= 1024
PY
}

default_model_dir() {
  if [[ -n "${MODEL_DIR:-}" ]]; then
    printf '%s\n' "${MODEL_DIR}"
  elif [[ -d ./models ]]; then
    printf '%s\n' "./models"
  elif [[ -d /workspace/models ]]; then
    printf '%s\n' "/workspace/models"
  else
    printf '%s\n' "./models"
  fi
}

resolve_model_path() {
  local model_dir="$1"
  local env_model="${LLAMA_ARG_MODEL:-}"
  local model_filename="${MODEL_FILENAME:-}"

  if [[ -n "${MODEL_PATH:-}" ]]; then
    printf '%s\n' "${MODEL_PATH}"
    return 0
  fi

  if [[ -n "${env_model}" && -f "${env_model}" ]]; then
    printf '%s\n' "${env_model}"
    return 0
  fi

  if [[ -z "${model_filename}" && -n "${env_model}" ]]; then
    model_filename="$(basename "${env_model}")"
  fi

  if [[ -z "${model_filename}" ]]; then
    model_filename="${DEFAULT_MODEL_FILENAME}"
  fi

  printf '%s/%s\n' "${model_dir%/}" "${model_filename}"
}

MODEL_DIR="$(default_model_dir)"
MODEL_PATH="$(resolve_model_path "${MODEL_DIR}")"
MODEL_BASENAME="$(basename "${MODEL_PATH}")"
MODEL_PARENT="$(dirname "${MODEL_PATH}")"
MANIFEST_PATH="${SHA256_MANIFEST:-${MODEL_PARENT}/MANIFEST.sha256}"

echo "===== Model file inspection ====="
echo "pwd=$(pwd)"
echo "MODEL_DIR=${MODEL_DIR}"
echo "MODEL_PATH=${MODEL_PATH}"
echo "MODEL_FILENAME=${MODEL_BASENAME}"
echo "LLAMA_ARG_MODEL=${LLAMA_ARG_MODEL:-unset}"
echo "MIN_MODEL_BYTES=${MIN_MODEL_BYTES} ($(human_bytes "${MIN_MODEL_BYTES}"))"
echo "SHA256_MANIFEST=${MANIFEST_PATH}"

echo
echo "===== Model directory ====="
if [[ -d "${MODEL_PARENT}" ]]; then
  mark_ok "model directory exists: ${MODEL_PARENT}"
else
  mark_fail "model directory missing: ${MODEL_PARENT}"
fi

if [[ ! -f "${MODEL_PATH}" ]]; then
  mark_fail "model file missing: ${MODEL_PATH}"
  echo
  echo "Available files in ${MODEL_PARENT}:"
  find "${MODEL_PARENT}" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort | sed -n '1,120p' || true
  exit "${status}"
fi

if [[ -r "${MODEL_PATH}" ]]; then
  mark_ok "model file is readable"
else
  mark_fail "model file is not readable: ${MODEL_PATH}"
fi

if [[ -s "${MODEL_PATH}" ]]; then
  mark_ok "model file is non-empty"
else
  mark_fail "model file is empty: ${MODEL_PATH}"
fi

MODEL_BYTES="$(stat -c '%s' "${MODEL_PATH}")"
echo "model_bytes=${MODEL_BYTES}"
echo "model_size=$(human_bytes "${MODEL_BYTES}")"

if (( MODEL_BYTES < MIN_MODEL_BYTES )); then
  mark_fail "model file is smaller than plausible threshold: $(human_bytes "${MODEL_BYTES}") < $(human_bytes "${MIN_MODEL_BYTES}")"
else
  mark_ok "model file size is plausible"
fi

echo
echo "===== GGUF header probe ====="
if python3 - "${MODEL_PATH}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
with path.open("rb") as handle:
    head = handle.read(16)

print("first_16_bytes_hex=" + head.hex())

if len(head) < 4:
    raise SystemExit("file too small to contain GGUF magic")

if head[:4] != b"GGUF":
    raise SystemExit(f"expected GGUF magic, got {head[:4]!r}")

print("OK   GGUF magic present")
PY
then
  mark_ok "GGUF header probe passed"
else
  mark_fail "GGUF header probe failed"
fi

echo
echo "===== SHA256 ====="
ACTUAL_SHA256="$(sha256sum "${MODEL_PATH}" | awk '{print $1}')"
echo "${ACTUAL_SHA256}  ${MODEL_BASENAME}"

if [[ -f "${MANIFEST_PATH}" ]]; then
  echo
  echo "===== MANIFEST.sha256 validation ====="
  echo "manifest=${MANIFEST_PATH}"

  MANIFEST_PARENT="$(dirname "${MANIFEST_PATH}")"
  MANIFEST_FILE="$(basename "${MANIFEST_PATH}")"

  if (cd "${MANIFEST_PARENT}" && sha256sum -c "${MANIFEST_FILE}"); then
    mark_ok "checksum manifest passed"
  else
    mark_fail "checksum manifest failed"
  fi
else
  mark_warn "checksum manifest not found: ${MANIFEST_PATH}"
  mark_warn "write after download with: cd ${MODEL_PARENT} && sha256sum ${MODEL_BASENAME} > MANIFEST.sha256"
fi

echo
echo "===== Model directory inventory ====="
find "${MODEL_PARENT}" -maxdepth 1 -type f -printf '%f\t%s bytes\n' 2>/dev/null | sort | sed -n '1,160p' || true

echo
echo "===== Model inspection result ====="
if [[ "${status}" -eq 0 ]]; then
  mark_ok "model inspection passed"
else
  mark_fail "model inspection failed"
fi

exit "${status}"