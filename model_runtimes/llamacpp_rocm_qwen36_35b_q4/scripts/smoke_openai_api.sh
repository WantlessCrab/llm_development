#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8023/v1}"
BASE_URL="${BASE_URL%/}"
API_ROOT="${BASE_URL%/v1}"
API_KEY="${API_KEY:-not-needed}"
MODEL="${MODEL:-${LLAMA_ARG_ALIAS:-local-qwen36-35b-q4-llamacpp}}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
HEALTH_WAIT_SECONDS="${HEALTH_WAIT_SECONDS:-600}"
MAX_TOKENS="${MAX_TOKENS:-48}"

export BASE_URL API_ROOT API_KEY MODEL TIMEOUT_SECONDS MAX_TOKENS

health_url="${API_ROOT}/health"

echo "===== OpenAI-compatible API smoke ====="
echo "BASE_URL=${BASE_URL}"
echo "API_ROOT=${API_ROOT}"
echo "health_url=${health_url}"
echo "MODEL=${MODEL}"
echo "TIMEOUT_SECONDS=${TIMEOUT_SECONDS}"
echo "HEALTH_WAIT_SECONDS=${HEALTH_WAIT_SECONDS}"
echo "MAX_TOKENS=${MAX_TOKENS}"

echo
echo "===== Wait for /health ====="
deadline=$((SECONDS + HEALTH_WAIT_SECONDS))
last_error=""

while (( SECONDS < deadline )); do
  if output="$(curl -fsS --max-time 5 "${health_url}" 2>&1)"; then
    echo "${output}"
    echo
    echo "OK   health endpoint is reachable"
    break
  fi

  last_error="${output}"
  sleep 5
done

if (( SECONDS >= deadline )); then
  echo "ERROR: health endpoint did not become reachable within ${HEALTH_WAIT_SECONDS}s" >&2
  echo "Last curl error: ${last_error}" >&2
  exit 1
fi

echo
echo "===== /v1/models ====="
curl -fsS --max-time 30 "${BASE_URL}/models" \
  -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool

echo
echo "===== /v1/models served model check ====="
python3 - <<'PY'
import json
import os
import urllib.request

base_url = os.environ["BASE_URL"].rstrip("/")
api_key = os.environ["API_KEY"]
expected = os.environ["MODEL"]
timeout = float(os.environ["TIMEOUT_SECONDS"])

request = urllib.request.Request(
    base_url + "/models",
    headers={"Authorization": "Bearer " + api_key},
)

with urllib.request.urlopen(request, timeout=timeout) as response:
    payload = json.loads(response.read().decode("utf-8"))

model_ids = [item.get("id") for item in payload.get("data", []) if isinstance(item, dict)]
print("models:", model_ids)

if expected not in model_ids:
    raise SystemExit(f"expected served model {expected!r} not found in /v1/models")

print("OK   served model name present:", expected)
PY

echo
echo "===== /v1/chat/completions ====="
python3 - <<'PY'
import json
import os
import urllib.request

base_url = os.environ["BASE_URL"].rstrip("/")
api_key = os.environ["API_KEY"]
model = os.environ["MODEL"]
timeout = float(os.environ["TIMEOUT_SECONDS"])
max_tokens = int(os.environ["MAX_TOKENS"])

payload = {
    "model": model,
    "messages": [
        {
            "role": "user",
            "content": "Reply with exactly: local model ready",
        }
    ],
    "temperature": 0,
    "max_tokens": max_tokens,
    "stream": False,
}

body = json.dumps(payload).encode("utf-8")
request = urllib.request.Request(
    base_url + "/chat/completions",
    data=body,
    method="POST",
    headers={
        "Authorization": "Bearer " + api_key,
        "Content-Type": "application/json",
    },
)

try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
except Exception as exc:
    raise SystemExit(f"chat completion request failed: {exc}") from exc

try:
    result = json.loads(raw)
except json.JSONDecodeError as exc:
    print(raw)
    raise SystemExit(f"chat completion response was not JSON: {exc}") from exc

print(json.dumps(result, indent=2, ensure_ascii=False))

choices = result.get("choices", [])
if not choices:
    raise SystemExit("chat response contained no choices")

message = choices[0].get("message") or {}
content = message.get("content") or ""

if not content.strip():
    raise SystemExit("chat response contained empty assistant content")

print()
print("assistant_content:", content.strip())
print("OK   chat completion returned assistant content")
PY

echo
echo "===== API smoke result ====="
echo "OK   OpenAI-compatible API smoke passed"