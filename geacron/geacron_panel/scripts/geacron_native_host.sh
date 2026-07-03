#!/usr/bin/env bash
# scripts/geacron_native_host.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec python3 "$ROOT/scripts/geacron_panel.py" native-host