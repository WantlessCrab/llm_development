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
ENV_FILE="$HOME/.config/local-llm/local-llm.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

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

ENV_FILE="$CONFIG_DIR/local-llm.env"
ENV_EXAMPLE_FILE="$CONFIG_DIR/local-llm.env.example"

cat > "$ENV_EXAMPLE_FILE" <<'EOF'
# local_llm host-side runtime secrets.
#
# The database URL in config.yaml intentionally remains passwordless.
# local_llm reads the database password from storage.database_password_env,
# which defaults to LOCAL_LLM_POSTGRES_PASSWORD.
#
# Match this value to POSTGRES_PASSWORD in:
#   /home/wantless/PycharmProjects/automation/data_stack/.env
LOCAL_LLM_POSTGRES_PASSWORD=CHANGE_ME_LOCAL_ONLY
EOF
chmod 0600 "$ENV_EXAMPLE_FILE"

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0600 "$ENV_EXAMPLE_FILE" "$ENV_FILE"
  echo "Created runtime env template: $ENV_FILE"
  echo "Edit LOCAL_LLM_POSTGRES_PASSWORD in that file before PostgreSQL-backed runs."
else
  chmod 0600 "$ENV_FILE"
  echo "Preserved runtime env: $ENV_FILE"
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