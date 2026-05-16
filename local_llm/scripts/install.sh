#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SHARE="$HOME/.local/share/local-llm/app"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

ENABLE_SERVICE=0
for arg in "$@"; do
  case "$arg" in
    --enable-service) ENABLE_SERVICE=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./scripts/install.sh [--enable-service]" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$APP_SHARE" "$BIN_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR" "$HOME/.local/share/local-llm" "$HOME/.cache/local-llm"

rsync -a --delete \
  --exclude '.git' \
  --exclude '.venv' \
  "$PROJECT_ROOT/" "$APP_SHARE/"

cat > "$BIN_DIR/local-llm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_SHARE="$HOME/.local/share/local-llm/app"
if [[ -x "$APP_SHARE/.venv/bin/python" ]]; then
  exec "$APP_SHARE/.venv/bin/python" -m local_llm.cli "$@"
fi
exec /usr/bin/python3 -m local_llm.cli "$@"
EOF
chmod +x "$BIN_DIR/local-llm"

if [[ ! -d "$APP_SHARE/.venv" ]]; then
  /usr/bin/python3 -m venv "$APP_SHARE/.venv"
fi

"$APP_SHARE/.venv/bin/python" -m pip install --upgrade pip >/dev/null
"$APP_SHARE/.venv/bin/python" -m pip install -e "$APP_SHARE" >/dev/null

if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  install -m 0644 "$PROJECT_ROOT/config.example.yaml" "$CONFIG_DIR/config.yaml"
  echo "Created config: $CONFIG_DIR/config.yaml"
else
  install -m 0644 "$PROJECT_ROOT/config.example.yaml" "$CONFIG_DIR/config.example.yaml.new"
  echo "Preserved config: $CONFIG_DIR/config.yaml"
  echo "Wrote latest example: $CONFIG_DIR/config.example.yaml.new"
fi

install -m 0644 "$PROJECT_ROOT/systemd/local-llm.service.example" "$SYSTEMD_USER_DIR/local-llm.service"
systemctl --user daemon-reload || true

if [[ "$ENABLE_SERVICE" == "1" ]]; then
  systemctl --user enable --now local-llm.service
  echo "Enabled and started local-llm.service"
fi

echo "Installed local_llm."
echo "Run:"
echo "  local-llm doctor --skip-provider"
echo "  local-llm serve"
