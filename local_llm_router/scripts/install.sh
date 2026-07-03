#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SHARE="$HOME/.local/share/local-llm-router/app"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/local-llm-router"

for arg in "$@"; do
  case "$arg" in
    --enable-service)
      cat >&2 <<'EOF'
ERROR: --enable-service is disabled.

Host-local daemon lifecycle authority is Supervisor via code-svc.
Do not enable or start local-llm-router.service from this installer.

Use after install:
  code-svc restart code-host:local-llm-router
  code-svc status code-host:local-llm-router
  curl -fsS http://127.0.0.1:8015/health; echo
EOF
      exit 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./scripts/install.sh

Installs/updates local_llm_router code, CLI wrapper, and example config.
Runtime lifecycle is Supervisor-owned and must be managed with code-svc.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: ./scripts/install.sh" >&2
      exit 2
      ;;
  esac
done

mkdir -p   "$APP_SHARE"   "$BIN_DIR"   "$CONFIG_DIR"   "$HOME/.local/share/local-llm-router"   "$HOME/.cache/local-llm-router"

rsync -a --delete   --exclude '.git'   --exclude '.venv'   --exclude '__pycache__'   --exclude '*.pyc'   --exclude '*.backup*'   --exclude '*.bak'   "$PROJECT_ROOT/" "$APP_SHARE/"

cat > "$BIN_DIR/local-llm-router" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_SHARE="$HOME/.local/share/local-llm-router/app"
if [[ -x "$APP_SHARE/.venv/bin/python" ]]; then
  exec "$APP_SHARE/.venv/bin/python" -m local_llm_router.cli "$@"
fi
exec python3 -m local_llm_router.cli "$@"
EOF
chmod +x "$BIN_DIR/local-llm-router"

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

if [[ ! -f "$CONFIG_DIR/prompt_wrappers.yaml" ]]; then
  install -m 0644 "$PROJECT_ROOT/prompt_wrappers.example.yaml" "$CONFIG_DIR/prompt_wrappers.yaml"
  echo "Created prompt wrappers: $CONFIG_DIR/prompt_wrappers.yaml"
else
  install -m 0644 "$PROJECT_ROOT/prompt_wrappers.example.yaml" "$CONFIG_DIR/prompt_wrappers.example.yaml.new"
  echo "Preserved prompt wrappers: $CONFIG_DIR/prompt_wrappers.yaml"
  echo "Wrote latest prompt wrapper example: $CONFIG_DIR/prompt_wrappers.example.yaml.new"
fi

cat <<'EOF'
Installed local_llm_router.

Supervisor-owned runtime restart:
  code-svc restart code-host:local-llm-router
  code-svc status code-host:local-llm-router
  curl -fsS http://127.0.0.1:8015/health; echo

Validation:
  local-llm-router doctor
  local-llm-router config-check
EOF