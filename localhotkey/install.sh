#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SHARE="$HOME/.local/share/localhotkey"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/localhotkey"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"
CINNAMON_APPLET_DIR="$HOME/.local/share/cinnamon/applets/localhotkey@wantless"

ENABLE_SERVICE=0
ENABLE_AUTOSTART=0
INSTALL_APPLET=0

for arg in "$@"; do
  case "$arg" in
    --enable-service) ENABLE_SERVICE=1 ;;
    --enable-autostart) ENABLE_AUTOSTART=1 ;;
    --install-applet) INSTALL_APPLET=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./install.sh [--enable-service|--enable-autostart] [--install-applet]" >&2
      exit 2
      ;;
  esac
done

if [[ "$ENABLE_SERVICE" == "1" && "$ENABLE_AUTOSTART" == "1" ]]; then
  echo "Choose only one startup method: --enable-service or --enable-autostart" >&2
  exit 2
fi

mkdir -p "$APP_SHARE" "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR" "$AUTOSTART_DIR"

rsync -a --delete \
  --exclude '.git' \
  --exclude '.venv' \
  "$PROJECT_ROOT/" "$APP_SHARE/"

install -m 0755 "$PROJECT_ROOT/bin/localhotkey" "$BIN_DIR/localhotkey"

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  install -m 0644 "$PROJECT_ROOT/config.example.yaml" "$CONFIG_DIR/config.yaml"
  echo "Created active config: $CONFIG_DIR/config.yaml"
else
  install -m 0644 "$PROJECT_ROOT/config.example.yaml" "$CONFIG_DIR/config.example.yaml.new"
  echo "Preserved existing config: $CONFIG_DIR/config.yaml"
  echo "Wrote latest example config: $CONFIG_DIR/config.example.yaml.new"
fi

install -m 0644 "$PROJECT_ROOT/systemd/localhotkey.service.example" "$SYSTEMD_USER_DIR/localhotkey.service"

cat > "$AUTOSTART_DIR/localhotkey.desktop.example" <<EOF
[Desktop Entry]
Type=Application
Name=localhotkey
Comment=Start localhotkey sxhkd hotkey backend
Exec=sxhkd -c $CONFIG_DIR/generated.sxhkdrc
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

"$BIN_DIR/localhotkey" render

systemctl --user daemon-reload || true

if [[ "$INSTALL_APPLET" == "1" ]]; then
  mkdir -p "$CINNAMON_APPLET_DIR"
  rsync -a --delete "$PROJECT_ROOT/cinnamon/localhotkey@wantless/" "$CINNAMON_APPLET_DIR/"
  echo "Installed Cinnamon applet files: $CINNAMON_APPLET_DIR"
  echo "Add it via: Right-click panel → Applets → Manage → localhotkey → Add"
fi

if [[ "$ENABLE_SERVICE" == "1" ]]; then
  systemctl --user enable --now localhotkey.service
  echo "Enabled and started systemd user service: localhotkey.service"
elif [[ "$ENABLE_AUTOSTART" == "1" ]]; then
  cp "$AUTOSTART_DIR/localhotkey.desktop.example" "$AUTOSTART_DIR/localhotkey.desktop"
  echo "Enabled Cinnamon autostart: $AUTOSTART_DIR/localhotkey.desktop"
  echo "Autostart applies on next login. For immediate foreground test, run:"
  echo "  sxhkd -c \"$CONFIG_DIR/generated.sxhkdrc\""
else
  echo "Installed service and autostart templates, but did not enable startup."
  echo "Enable one later with:"
  echo "  ./install.sh --enable-service"
  echo "or:"
  echo "  ./install.sh --enable-autostart"
fi

echo ""
echo "Run diagnostics:"
echo "  localhotkey doctor"
echo "  localhotkey status"
