#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:8021/v1}"
API_KEY="${VLLM_API_KEY:-not-needed}"
MODEL="${VLLM_SERVED_MODEL_NAME:-local-small}"

echo "===== /health ====="
curl -fsS "${BASE_URL%/v1}/health"
echo

echo "===== /v1/models ====="
curl -fsS "${BASE_URL}/models" \
  -H "Authorization: Bearer ${API_KEY}" | python3 -m json.tool

echo
echo "===== /v1/models served model check ====="
python3 - <<PY
import json
import urllib.request

base_url = "${BASE_URL}"
api_key = "${API_KEY}"
expected = "${MODEL}"

req = urllib.request.Request(
    base_url + "/models",
    headers={"Authorization": "Bearer " + api_key},
)
with urllib.request.urlopen(req, timeout=10) as response:
    payload = json.loads(response.read().decode("utf-8"))

model_ids = [item.get("id") for item in payload.get("data", [])]
print("models:", model_ids)
if expected not in model_ids:
    raise SystemExit(f"expected served model {expected!r} not found in /v1/models")
print("✓ served model name present:", expected)
PY

echo
echo "===== /v1/chat/completions ====="
curl -fsS "${BASE_URL}/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"Reply with exactly: local model ready\"}
    ],
    \"temperature\": 0,
    \"max_tokens\": 20
  }" | python3 -m json.tool