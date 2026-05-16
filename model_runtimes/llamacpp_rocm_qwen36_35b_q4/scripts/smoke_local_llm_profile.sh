#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

ok() {
  echo "OK   $*"
}

truthy() {
  case "${1,,}" in
    1|true|yes|y|on|enabled) return 0 ;;
    *) return 1 ;;
  esac
}

select_python() {
  if [[ -n "${PYTHON_BIN:-}" && -x "${PYTHON_BIN}" ]]; then
    printf '%s\n' "${PYTHON_BIN}"
    return 0
  fi

  if [[ -x "${HOME}/.local/share/local-llm/app/.venv/bin/python" ]]; then
    printf '%s\n' "${HOME}/.local/share/local-llm/app/.venv/bin/python"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  fail "python3 not found"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VALIDATE_SCRIPT="${VALIDATE_SCRIPT:-${SCRIPT_DIR}/validate_local_llm_registration.sh}"
PROMPT_FILE="${PROMPT_FILE:-${RUNTIME_ROOT}/eval_inputs/first_optimization.md}"
LOG_DIR="${LOG_DIR:-${RUNTIME_ROOT}/logs}"

WORKFLOW_ID="${WORKFLOW_ID:-qwen36_35b_q4_llamacpp_rag_answer}"
EXPECTED_MODEL_PROFILE="${EXPECTED_MODEL_PROFILE:-local_qwen36_35b_q4_llamacpp}"
EXPECTED_RAG_PROFILE="${EXPECTED_RAG_PROFILE:-project_basic}"
EXPECTED_PROMPT_PROFILE="${EXPECTED_PROMPT_PROFILE:-source_grounded_answer}"

CHECK_ENDPOINT="${CHECK_ENDPOINT:-1}"
REQUIRE_FULL_DOCTOR="${REQUIRE_FULL_DOCTOR:-0}"
RESPOND_TIMEOUT_SECONDS="${RESPOND_TIMEOUT_SECONDS:-900}"
REQUIRE_RETRIEVALS="${REQUIRE_RETRIEVALS:-1}"
REQUIRE_RUN_ARTIFACTS="${REQUIRE_RUN_ARTIFACTS:-1}"
PROMPT_STRIP_FIRST_MARKDOWN_HEADING="${PROMPT_STRIP_FIRST_MARKDOWN_HEADING:-1}"

PYTHON_SELECTED="$(select_python)"
LOCAL_LLM_CMD=()
if command -v local-llm >/dev/null 2>&1; then
  LOCAL_LLM_CMD=(local-llm)
else
  LOCAL_LLM_CMD=("${PYTHON_SELECTED}" -m local_llm.cli)
fi

export WORKFLOW_ID
export EXPECTED_MODEL_PROFILE
export EXPECTED_RAG_PROFILE
export EXPECTED_PROMPT_PROFILE
export CHECK_ENDPOINT
export RESPOND_TIMEOUT_SECONDS
export REQUIRE_RETRIEVALS
export REQUIRE_RUN_ARTIFACTS

echo "===== local_llm profile smoke ====="
echo "RUNTIME_ROOT=${RUNTIME_ROOT}"
echo "VALIDATE_SCRIPT=${VALIDATE_SCRIPT}"
echo "PROMPT_FILE=${PROMPT_FILE}"
echo "LOG_DIR=${LOG_DIR}"
echo "WORKFLOW_ID=${WORKFLOW_ID}"
echo "EXPECTED_MODEL_PROFILE=${EXPECTED_MODEL_PROFILE}"
echo "EXPECTED_RAG_PROFILE=${EXPECTED_RAG_PROFILE}"
echo "EXPECTED_PROMPT_PROFILE=${EXPECTED_PROMPT_PROFILE}"
echo "CHECK_ENDPOINT=${CHECK_ENDPOINT}"
echo "REQUIRE_FULL_DOCTOR=${REQUIRE_FULL_DOCTOR}"
echo "RESPOND_TIMEOUT_SECONDS=${RESPOND_TIMEOUT_SECONDS}"
echo "REQUIRE_RETRIEVALS=${REQUIRE_RETRIEVALS}"
echo "REQUIRE_RUN_ARTIFACTS=${REQUIRE_RUN_ARTIFACTS}"
echo "PROMPT_STRIP_FIRST_MARKDOWN_HEADING=${PROMPT_STRIP_FIRST_MARKDOWN_HEADING}"
echo "PYTHON_SELECTED=${PYTHON_SELECTED}"
echo "LOCAL_LLM_CMD=${LOCAL_LLM_CMD[*]}"

[[ -x "${VALIDATE_SCRIPT}" ]] || fail "validation script is missing or not executable: ${VALIDATE_SCRIPT}"
[[ -f "${PROMPT_FILE}" ]] || fail "prompt file not found: ${PROMPT_FILE}"

mkdir -p "${LOG_DIR}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
response_json="${LOG_DIR}/smoke_local_llm_profile_${timestamp}.json"
doctor_log="${LOG_DIR}/smoke_local_llm_doctor_${timestamp}.log"

echo
echo "===== Exact config registration validation ====="
CHECK_ENDPOINT="${CHECK_ENDPOINT}" RUN_SKIP_PROVIDER_DOCTOR=1 "${VALIDATE_SCRIPT}"

echo
echo "===== local-llm doctor ====="
set +e
"${LOCAL_LLM_CMD[@]}" doctor 2>&1 | tee "${doctor_log}"
doctor_status="${PIPESTATUS[0]}"
set -e

if [[ "${doctor_status}" -eq 0 ]]; then
  ok "local-llm doctor passed"
else
  if truthy "${REQUIRE_FULL_DOCTOR}"; then
    fail "local-llm doctor failed; see ${doctor_log}"
  fi
  warn "local-llm doctor failed. Continuing because REQUIRE_FULL_DOCTOR=${REQUIRE_FULL_DOCTOR}."
  warn "Workflow-specific respond remains authoritative for this profile smoke."
fi

if truthy "${PROMPT_STRIP_FIRST_MARKDOWN_HEADING}"; then
  prompt="$(sed '1s/^# *//' "${PROMPT_FILE}")"
else
  prompt="$(cat "${PROMPT_FILE}")"
fi

[[ -n "${prompt//[[:space:]]/}" ]] || fail "prompt file is empty after whitespace trimming: ${PROMPT_FILE}"

echo
echo "===== local-llm respond ====="
echo "workflow=${WORKFLOW_ID}"
echo "prompt_file=${PROMPT_FILE}"
echo "response_json=${response_json}"

if command -v timeout >/dev/null 2>&1; then
  timeout "${RESPOND_TIMEOUT_SECONDS}" "${LOCAL_LLM_CMD[@]}" respond "${WORKFLOW_ID}" "${prompt}" > "${response_json}"
else
  "${LOCAL_LLM_CMD[@]}" respond "${WORKFLOW_ID}" "${prompt}" > "${response_json}"
fi

"${PYTHON_SELECTED}" - "${response_json}" <<'PY'
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

path = Path(sys.argv[1])
expected_workflow = os.environ["WORKFLOW_ID"]
expected_model_profile = os.environ["EXPECTED_MODEL_PROFILE"]
expected_rag_profile = os.environ["EXPECTED_RAG_PROFILE"]
expected_prompt_profile = os.environ["EXPECTED_PROMPT_PROFILE"]
require_retrievals = os.environ["REQUIRE_RETRIEVALS"].lower() in {"1", "true", "yes", "y", "on", "enabled"}

try:
    data: dict[str, Any] = json.loads(path.read_text(encoding="utf-8"))
except json.JSONDecodeError as exc:
    print(path.read_text(encoding="utf-8"), file=sys.stderr)
    raise SystemExit(f"ERROR: local-llm respond output was not JSON: {exc}") from exc

failures: list[str] = []

if data.get("ok") is not True:
    failures.append(f"response.ok expected True, got {data.get('ok')!r}")

if data.get("workflow_id") != expected_workflow:
    failures.append(f"workflow_id expected {expected_workflow!r}, got {data.get('workflow_id')!r}")

if data.get("model_profile") != expected_model_profile:
    failures.append(f"model_profile expected {expected_model_profile!r}, got {data.get('model_profile')!r}")

if data.get("rag_profile") != expected_rag_profile:
    failures.append(f"rag_profile expected {expected_rag_profile!r}, got {data.get('rag_profile')!r}")

if data.get("prompt_profile") != expected_prompt_profile:
    failures.append(f"prompt_profile expected {expected_prompt_profile!r}, got {data.get('prompt_profile')!r}")

run_id = data.get("run_id")
if not isinstance(run_id, str) or not run_id.strip():
    failures.append("run_id missing or empty")

response_text = data.get("response_text")
if not isinstance(response_text, str) or not response_text.strip():
    failures.append("response_text missing or empty")

latency_ms = data.get("latency_ms")
if not isinstance(latency_ms, int) or latency_ms < 0:
    failures.append(f"latency_ms expected nonnegative integer, got {latency_ms!r}")

support = data.get("support")
if not isinstance(support, dict):
    failures.append("support missing or not a mapping")
else:
    if require_retrievals and support.get("retrieval_used") is not True:
        failures.append(f"support.retrieval_used expected True, got {support.get('retrieval_used')!r}")

    chunk_count = support.get("chunk_count")
    if require_retrievals and (not isinstance(chunk_count, int) or chunk_count <= 0):
        failures.append(f"support.chunk_count expected positive integer, got {chunk_count!r}")

retrievals = data.get("retrievals")
if not isinstance(retrievals, list):
    failures.append("retrievals missing or not a list")
elif require_retrievals and not retrievals:
    failures.append("retrievals expected non-empty list")

warnings = data.get("warnings")
if not isinstance(warnings, list):
    failures.append("warnings missing or not a list")

if failures:
    print("===== local_llm profile smoke failures =====", file=sys.stderr)
    for item in failures:
        print(f"FAIL {item}", file=sys.stderr)
    raise SystemExit(1)

preview = " ".join(response_text.split())[:500]

print("OK   local-llm respond returned ok=true")
print(f"OK   run_id={run_id}")
print(f"OK   workflow_id={data.get('workflow_id')}")
print(f"OK   model_profile={data.get('model_profile')}")
print(f"OK   rag_profile={data.get('rag_profile')}")
print(f"OK   prompt_profile={data.get('prompt_profile')}")
print(f"OK   latency_ms={latency_ms}")
print(f"OK   retrieval_count={len(retrievals)}")
print(f"OK   warning_count={len(warnings)}")
print()
print("===== response preview =====")
print(preview)
PY

run_id="$("${PYTHON_SELECTED}" - "${response_json}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(data.get("run_id", ""))
PY
)"

echo
echo "===== Run artifact inspection ====="
if truthy "${REQUIRE_RUN_ARTIFACTS}"; then
  [[ -n "${run_id}" ]] || fail "run_id is empty; cannot inspect run artifacts"

  artifact_log="${LOG_DIR}/smoke_local_llm_artifacts_${timestamp}.log"
  set +e
  "${LOCAL_LLM_CMD[@]}" run artifacts "${run_id}" 2>&1 | tee "${artifact_log}"
  artifact_status="${PIPESTATUS[0]}"
  set -e

  [[ "${artifact_status}" -eq 0 ]] || fail "local-llm run artifacts failed; see ${artifact_log}"

  for command_name in show prompt retrievals context; do
    log_path="${LOG_DIR}/smoke_local_llm_run_${command_name}_${timestamp}.log"
    set +e
    "${LOCAL_LLM_CMD[@]}" run "${command_name}" "${run_id}" > "${log_path}" 2>&1
    command_status="${?}"
    set -e

    if [[ "${command_status}" -ne 0 ]]; then
      cat "${log_path}" >&2 || true
      fail "local-llm run ${command_name} ${run_id} failed; see ${log_path}"
    fi

    ok "local-llm run ${command_name} ${run_id} passed"
  done
else
  warn "REQUIRE_RUN_ARTIFACTS=${REQUIRE_RUN_ARTIFACTS}; skipping run artifact inspection"
fi

echo
echo "===== Optional run inspection commands ====="
if [[ -n "${run_id}" ]]; then
  echo "${LOCAL_LLM_CMD[*]} run show ${run_id}"
  echo "${LOCAL_LLM_CMD[*]} run prompt ${run_id}"
  echo "${LOCAL_LLM_CMD[*]} run retrievals ${run_id}"
  echo "${LOCAL_LLM_CMD[*]} run context ${run_id}"
  echo "${LOCAL_LLM_CMD[*]} run artifacts ${run_id}"
fi

echo
echo "OK   local_llm profile smoke passed"
echo "response_json=${response_json}"
echo "doctor_log=${doctor_log}"