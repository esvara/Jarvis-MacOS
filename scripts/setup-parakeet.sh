#!/bin/zsh
# Creates the Python venv for the local Parakeet STT server and installs
# parakeet-mlx (requires Python >= 3.10; uses uv to fetch a managed Python
# when the system one is too old). The server script is copied INTO the venv
# directory because launchd processes cannot read from ~/Desktop (TCC).
#
# After running this once, load the LaunchAgent:
#   launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.jarvis.parakeet.plist

set -euo pipefail

SCRIPT_DIR="${0:a:h}"
VENV_DIR="${JARVIS_STT_VENV:-$HOME/.local/jarvis-stt}"

python_ok() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null
}

if [[ ! -x "$VENV_DIR/bin/python3" ]] || ! python_ok "$VENV_DIR/bin/python3"; then
  if python_ok "$(command -v python3 || echo /usr/bin/python3)"; then
    echo "Creating venv at $VENV_DIR with system python3"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
    "$VENV_DIR/bin/pip" install parakeet-mlx
  else
    UV="$HOME/.local/bin/uv"
    if [[ ! -x "$UV" ]]; then
      echo "System python3 is older than 3.10 — installing uv to manage Python"
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$HOME/.local/bin" sh
    fi
    echo "Creating venv at $VENV_DIR with uv-managed Python 3.12"
    rm -rf "$VENV_DIR"
    "$UV" venv "$VENV_DIR" --python 3.12
    "$UV" pip install --python "$VENV_DIR/bin/python3" parakeet-mlx
  fi
else
  "$VENV_DIR/bin/pip" install --upgrade parakeet-mlx 2>/dev/null ||
    "$HOME/.local/bin/uv" pip install --python "$VENV_DIR/bin/python3" --upgrade parakeet-mlx
fi

cp "$SCRIPT_DIR/parakeet-server.py" "$VENV_DIR/parakeet-server.py"

echo "Parakeet STT venv ready at $VENV_DIR"
echo "The model (~1.2 GB) downloads from Hugging Face on first server start."
