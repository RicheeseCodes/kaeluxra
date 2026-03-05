#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"

if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
pip install -q -r "$ROOT_DIR/requirements.txt"

# Change these before distributing if your server URL is public.
export KEY_API_URL="${KEY_API_URL:-http://127.0.0.1:5000/api/client/validate-key}"
export KEY_SITE_A_URL="${KEY_SITE_A_URL:-http://127.0.0.1:5000/site-a}"

python3 "$SCRIPT_DIR/kaeluxra_roblox_launcher.py"
