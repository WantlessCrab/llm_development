#!/usr/bin/env bash
set -euo pipefail

PURGE_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --purge-config) PURGE_CONFIG=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

systemctl --user disable --now local-llm.service 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

rm -f "$HOME/.local/bin/local-llm"
rm -rf "$HOME/.local/share/local-llm/app"
rm -f "$HOME/.config/systemd/user/local-llm.service"

if [[ "$PURGE_CONFIG" == "1" ]]; then
  rm -rf "$HOME/.config/local-llm"
  rm -rf "$HOME/.local/share/local-llm"
  rm -rf "$HOME/.cache/local-llm"
  echo "Removed app, config, state, and cache."
else
  echo "Removed app runtime/service. Preserved config and state."
fi
