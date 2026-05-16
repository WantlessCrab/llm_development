#!/usr/bin/env bash
set -euo pipefail

PURGE_CONFIG=0

for arg in "$@"; do
  case "$arg" in
    --purge-config) PURGE_CONFIG=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./uninstall.sh [--purge-config]" >&2
      exit 2
      ;;
  esac
done

systemctl --user disable --now localhotkey.service 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

rm -f "$HOME/.local/bin/localhotkey"
rm -rf "$HOME/.local/share/localhotkey"
rm -f "$HOME/.config/systemd/user/localhotkey.service"
rm -f "$HOME/.config/autostart/localhotkey.desktop"
rm -f "$HOME/.config/autostart/localhotkey.desktop.example"
rm -rf "$HOME/.local/share/cinnamon/applets/localhotkey@wantless"

if [[ "$PURGE_CONFIG" == "1" ]]; then
  rm -rf "$HOME/.config/localhotkey"
  echo "Removed app and config."
else
  rm -f "$HOME/.config/localhotkey/generated.sxhkdrc"
  echo "Removed app runtime/applelet/service. Preserved config at: $HOME/.config/localhotkey/config.yaml"
fi
