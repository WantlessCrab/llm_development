#!/usr/bin/env bash
set -euo pipefail

PURGE_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --purge-config) PURGE_CONFIG=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/uninstall.sh [--purge-config]

Removes local_llm_router installed app files and CLI wrapper.
Supervisor program configuration is external authority and is not removed here.
EOF
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done


rm -f "$HOME/.local/bin/local-llm-router"
rm -rf "$HOME/.local/share/local-llm-router/app"

if [[ "$PURGE_CONFIG" == "1" ]]; then
  rm -rf "$HOME/.config/local-llm-router" "$HOME/.local/share/local-llm-router" "$HOME/.cache/local-llm-router"
  echo "Removed app, config, state, and cache."
else
  echo "Removed app runtime and CLI wrapper. Preserved config and state."
fi

cat <<'EOF'

Supervisor ownership note:
  Host-local runtime authority lives outside this app under:
    ~/.config/code-services/supervisor/

This uninstall script does not remove Supervisor program configs.
Use code-svc / Supervisor config management for code-host:local-llm-router if needed.
EOF