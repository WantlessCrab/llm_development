#!/usr/bin/env bash
# scripts/doctor.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec python3 "$ROOT/scripts/geacron_panel.py" doctor "$@"