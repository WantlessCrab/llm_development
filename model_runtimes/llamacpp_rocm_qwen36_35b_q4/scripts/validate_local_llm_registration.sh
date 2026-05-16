#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
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

select_local_llm_cmd() {
  local python_bin="$1"

  if command -v local-llm >/dev/null 2>&1; then
    printf '%s\n' "local-llm"
    return 0
  fi

  printf '%s\n' "${python_bin} -m local_llm.cli"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${HOME}/.config/local-llm/config.yaml}"
REGISTRATION_PATCH="${REGISTRATION_PATCH:-${RUNTIME_ROOT}/config/local_llm_registration.yaml}"

EXPECTED_MODEL_PROFILE="${EXPECTED_MODEL_PROFILE:-local_qwen36_35b_q4_llamacpp}"
EXPECTED_WORKFLOW="${EXPECTED_WORKFLOW:-qwen36_35b_q4_llamacpp_rag_answer}"
EXPECTED_PROVIDER="${EXPECTED_PROVIDER:-openai_compatible}"
EXPECTED_BASE_URL="${EXPECTED_BASE_URL:-http://127.0.0.1:8023/v1}"
EXPECTED_API_KEY="${EXPECTED_API_KEY:-not-needed}"
EXPECTED_MODEL="${EXPECTED_MODEL:-local-qwen36-35b-q4-llamacpp}"
EXPECTED_CONTEXT_WINDOW="${EXPECTED_CONTEXT_WINDOW:-4096}"
EXPECTED_TEMPERATURE="${EXPECTED_TEMPERATURE:-0.2}"
EXPECTED_MAX_TOKENS="${EXPECTED_MAX_TOKENS:-384}"
EXPECTED_WORKFLOW_KIND="${EXPECTED_WORKFLOW_KIND:-rag_answer}"
EXPECTED_RAG_PROFILE="${EXPECTED_RAG_PROFILE:-project_basic}"
EXPECTED_PROMPT_PROFILE="${EXPECTED_PROMPT_PROFILE:-source_grounded_answer}"

CHECK_ENDPOINT="${CHECK_ENDPOINT:-0}"
ENDPOINT_TIMEOUT_SECONDS="${ENDPOINT_TIMEOUT_SECONDS:-30}"
RUN_SKIP_PROVIDER_DOCTOR="${RUN_SKIP_PROVIDER_DOCTOR:-1}"

PYTHON_SELECTED="$(select_python)"
LOCAL_LLM_CMD_TEXT="$(select_local_llm_cmd "${PYTHON_SELECTED}")"

export CONFIG_PATH
export REGISTRATION_PATCH
export EXPECTED_MODEL_PROFILE
export EXPECTED_WORKFLOW
export EXPECTED_PROVIDER
export EXPECTED_BASE_URL
export EXPECTED_API_KEY
export EXPECTED_MODEL
export EXPECTED_CONTEXT_WINDOW
export EXPECTED_TEMPERATURE
export EXPECTED_MAX_TOKENS
export EXPECTED_WORKFLOW_KIND
export EXPECTED_RAG_PROFILE
export EXPECTED_PROMPT_PROFILE
export CHECK_ENDPOINT
export ENDPOINT_TIMEOUT_SECONDS

echo "===== local_llm registration validation ====="
echo "CONFIG_PATH=${CONFIG_PATH}"
echo "REGISTRATION_PATCH=${REGISTRATION_PATCH}"
echo "PYTHON_SELECTED=${PYTHON_SELECTED}"
echo "LOCAL_LLM_CMD=${LOCAL_LLM_CMD_TEXT}"
echo "EXPECTED_MODEL_PROFILE=${EXPECTED_MODEL_PROFILE}"
echo "EXPECTED_WORKFLOW=${EXPECTED_WORKFLOW}"
echo "EXPECTED_BASE_URL=${EXPECTED_BASE_URL}"
echo "EXPECTED_MODEL=${EXPECTED_MODEL}"
echo "CHECK_ENDPOINT=${CHECK_ENDPOINT}"
echo "RUN_SKIP_PROVIDER_DOCTOR=${RUN_SKIP_PROVIDER_DOCTOR}"

[[ -f "${CONFIG_PATH}" ]] || fail "local_llm config not found: ${CONFIG_PATH}"
[[ -f "${REGISTRATION_PATCH}" ]] || fail "registration patch not found: ${REGISTRATION_PATCH}"

"${PYTHON_SELECTED}" - <<'PY'
from __future__ import annotations

import math
import os
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ModuleNotFoundError as exc:
    raise SystemExit(
        "PyYAML is required for config validation. "
        "Run through the installed local_llm Python environment or install PyYAML."
    ) from exc


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle)

    if data is None:
        return {}

    if not isinstance(data, dict):
        raise SystemExit(f"YAML root must be a mapping: {path}")

    return data


def expect_equal(actual: Any, expected: Any, label: str, failures: list[str]) -> None:
    if actual != expected:
        failures.append(f"{label}: expected {expected!r}, got {actual!r}")
    else:
        print(f"OK   {label} == {expected!r}")


def expect_int(actual: Any, expected: int, label: str, failures: list[str]) -> None:
    try:
        value = int(actual)
    except (TypeError, ValueError) as exc:
        failures.append(f"{label}: expected integer-compatible {expected!r}, got {actual!r}: {exc}")
        return

    if value != expected:
        failures.append(f"{label}: expected {expected}, got {value}")
    else:
        print(f"OK   {label} == {expected}")


def expect_float(actual: Any, expected: float, label: str, failures: list[str]) -> None:
    try:
        value = float(actual)
    except (TypeError, ValueError) as exc:
        failures.append(f"{label}: expected float-compatible {expected!r}, got {actual!r}: {exc}")
        return

    if not math.isclose(value, expected, rel_tol=0.0, abs_tol=1e-9):
        failures.append(f"{label}: expected {expected}, got {value}")
    else:
        print(f"OK   {label} == {expected}")


def validate_profile_values(
    *,
    source: dict[str, Any],
    source_label: str,
    expected_model_profile: str,
    expected_workflow: str,
    expected_provider: str,
    expected_base_url: str,
    expected_api_key: str,
    expected_model: str,
    expected_context_window: int,
    expected_temperature: float,
    expected_max_tokens: int,
    expected_workflow_kind: str,
    expected_rag_profile: str,
    expected_prompt_profile: str,
    failures: list[str],
) -> None:
    model_profiles = source.get("model_profiles")
    if not isinstance(model_profiles, dict):
        failures.append(f"{source_label}.model_profiles missing or not a mapping")
        model_profile: dict[str, Any] = {}
    else:
        candidate = model_profiles.get(expected_model_profile)
        if not isinstance(candidate, dict):
            failures.append(f"{source_label}.model_profiles.{expected_model_profile} missing or not a mapping")
            model_profile = {}
        else:
            model_profile = candidate
            print(f"OK   {source_label} includes model profile {expected_model_profile!r}")

    workflows = source.get("workflows")
    if not isinstance(workflows, dict):
        failures.append(f"{source_label}.workflows missing or not a mapping")
        workflow: dict[str, Any] = {}
    else:
        candidate = workflows.get(expected_workflow)
        if not isinstance(candidate, dict):
            failures.append(f"{source_label}.workflows.{expected_workflow} missing or not a mapping")
            workflow = {}
        else:
            workflow = candidate
            print(f"OK   {source_label} includes workflow {expected_workflow!r}")

    if model_profile:
        expect_equal(model_profile.get("provider"), expected_provider, f"{source_label}.model_profiles.{expected_model_profile}.provider", failures)
        expect_equal(str(model_profile.get("base_url", "")).rstrip("/"), expected_base_url, f"{source_label}.model_profiles.{expected_model_profile}.base_url", failures)
        expect_equal(model_profile.get("api_key"), expected_api_key, f"{source_label}.model_profiles.{expected_model_profile}.api_key", failures)
        expect_equal(model_profile.get("model"), expected_model, f"{source_label}.model_profiles.{expected_model_profile}.model", failures)
        expect_int(model_profile.get("context_window"), expected_context_window, f"{source_label}.model_profiles.{expected_model_profile}.context_window", failures)

        defaults = model_profile.get("defaults")
        if not isinstance(defaults, dict):
            failures.append(f"{source_label}.model_profiles.{expected_model_profile}.defaults missing or not a mapping")
        else:
            expect_float(defaults.get("temperature"), expected_temperature, f"{source_label}.model_profiles.{expected_model_profile}.defaults.temperature", failures)
            expect_int(defaults.get("max_tokens"), expected_max_tokens, f"{source_label}.model_profiles.{expected_model_profile}.defaults.max_tokens", failures)

    if workflow:
        expect_equal(workflow.get("kind"), expected_workflow_kind, f"{source_label}.workflows.{expected_workflow}.kind", failures)
        expect_equal(workflow.get("model_profile"), expected_model_profile, f"{source_label}.workflows.{expected_workflow}.model_profile", failures)
        expect_equal(workflow.get("rag_profile"), expected_rag_profile, f"{source_label}.workflows.{expected_workflow}.rag_profile", failures)
        expect_equal(workflow.get("prompt_profile"), expected_prompt_profile, f"{source_label}.workflows.{expected_workflow}.prompt_profile", failures)


config_path = Path(os.environ["CONFIG_PATH"]).expanduser()
registration_patch = Path(os.environ["REGISTRATION_PATCH"]).expanduser()

expected_model_profile = os.environ["EXPECTED_MODEL_PROFILE"]
expected_workflow = os.environ["EXPECTED_WORKFLOW"]
expected_provider = os.environ["EXPECTED_PROVIDER"]
expected_base_url = os.environ["EXPECTED_BASE_URL"].rstrip("/")
expected_api_key = os.environ["EXPECTED_API_KEY"]
expected_model = os.environ["EXPECTED_MODEL"]
expected_context_window = int(os.environ["EXPECTED_CONTEXT_WINDOW"])
expected_temperature = float(os.environ["EXPECTED_TEMPERATURE"])
expected_max_tokens = int(os.environ["EXPECTED_MAX_TOKENS"])
expected_workflow_kind = os.environ["EXPECTED_WORKFLOW_KIND"]
expected_rag_profile = os.environ["EXPECTED_RAG_PROFILE"]
expected_prompt_profile = os.environ["EXPECTED_PROMPT_PROFILE"]

config = load_yaml(config_path)
patch = load_yaml(registration_patch)

failures: list[str] = []

allowed_patch_top_keys = {"model_profiles", "workflows"}
unexpected_patch_keys = sorted(set(patch) - allowed_patch_top_keys)
if unexpected_patch_keys:
    failures.append(f"registration patch contains non-config metadata keys: {unexpected_patch_keys}")
else:
    print("OK   registration patch contains only model_profiles/workflows")

validate_profile_values(
    source=patch,
    source_label="registration_patch",
    expected_model_profile=expected_model_profile,
    expected_workflow=expected_workflow,
    expected_provider=expected_provider,
    expected_base_url=expected_base_url,
    expected_api_key=expected_api_key,
    expected_model=expected_model,
    expected_context_window=expected_context_window,
    expected_temperature=expected_temperature,
    expected_max_tokens=expected_max_tokens,
    expected_workflow_kind=expected_workflow_kind,
    expected_rag_profile=expected_rag_profile,
    expected_prompt_profile=expected_prompt_profile,
    failures=failures,
)

try:
    from local_llm.config import AppConfig

    AppConfig.model_validate(config)
    print("OK   target config satisfies local_llm AppConfig schema")
except Exception as exc:
    failures.append(f"target config does not satisfy local_llm AppConfig schema: {exc}")

validate_profile_values(
    source=config,
    source_label="target_config",
    expected_model_profile=expected_model_profile,
    expected_workflow=expected_workflow,
    expected_provider=expected_provider,
    expected_base_url=expected_base_url,
    expected_api_key=expected_api_key,
    expected_model=expected_model,
    expected_context_window=expected_context_window,
    expected_temperature=expected_temperature,
    expected_max_tokens=expected_max_tokens,
    expected_workflow_kind=expected_workflow_kind,
    expected_rag_profile=expected_rag_profile,
    expected_prompt_profile=expected_prompt_profile,
    failures=failures,
)

rag_profiles = config.get("rag_profiles")
if not isinstance(rag_profiles, dict):
    failures.append("target_config.rag_profiles missing or not a mapping")
elif expected_rag_profile not in rag_profiles:
    failures.append(f"target_config.rag_profiles.{expected_rag_profile} missing")
else:
    print(f"OK   target_config referenced rag profile exists: {expected_rag_profile!r}")

prompt_profiles = config.get("prompt_profiles")
if not isinstance(prompt_profiles, dict):
    failures.append("target_config.prompt_profiles missing or not a mapping")
elif expected_prompt_profile not in prompt_profiles:
    failures.append(f"target_config.prompt_profiles.{expected_prompt_profile} missing")
else:
    print(f"OK   target_config referenced prompt profile exists: {expected_prompt_profile!r}")

if failures:
    print()
    print("===== local_llm registration validation failures =====", file=sys.stderr)
    for item in failures:
        print(f"FAIL {item}", file=sys.stderr)
    raise SystemExit(1)

print()
print("OK   local_llm registration exact-value validation passed")
PY

if truthy "${CHECK_ENDPOINT}"; then
  echo
  echo "===== /v1/models endpoint alias validation ====="

  "${PYTHON_SELECTED}" - <<'PY'
from __future__ import annotations

import json
import os
import urllib.request

base_url = os.environ["EXPECTED_BASE_URL"].rstrip("/")
api_key = os.environ["EXPECTED_API_KEY"]
expected_model = os.environ["EXPECTED_MODEL"]
timeout = float(os.environ["ENDPOINT_TIMEOUT_SECONDS"])

request = urllib.request.Request(
    base_url + "/models",
    headers={"Authorization": "Bearer " + api_key},
)

try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
except Exception as exc:
    raise SystemExit(f"ERROR: /v1/models endpoint check failed: {exc}") from exc

model_ids = [item.get("id") for item in payload.get("data", []) if isinstance(item, dict)]
print("models:", model_ids)

if expected_model not in model_ids:
    raise SystemExit(f"ERROR: expected served model {expected_model!r} not found in /v1/models")

print(f"OK   /v1/models includes {expected_model!r}")
PY
else
  echo
  warn "CHECK_ENDPOINT=${CHECK_ENDPOINT}; skipping /v1/models endpoint check"
fi

if truthy "${RUN_SKIP_PROVIDER_DOCTOR}"; then
  echo
  echo "===== local-llm doctor --skip-provider ====="

  if command -v local-llm >/dev/null 2>&1; then
    local-llm doctor --skip-provider
  else
    "${PYTHON_SELECTED}" -m local_llm.cli doctor --skip-provider
  fi
else
  echo
  warn "RUN_SKIP_PROVIDER_DOCTOR=${RUN_SKIP_PROVIDER_DOCTOR}; skipping local-llm doctor --skip-provider"
fi

echo
echo "OK   local_llm registration validation complete"