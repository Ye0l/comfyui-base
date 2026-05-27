#!/usr/bin/env bash
set -euo pipefail

echo "[custom] custom-before-comfyui.sh started"

: "${HF_BUCKET_MODELS_URI:?HF_BUCKET_MODELS_URI is required}"

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
PYTHON_EXE="$VENV_DIR/bin/python"

if [ ! -x "$PYTHON_EXE" ]; then
  echo "[custom] WARNING: venv python not found at $PYTHON_EXE, falling back to system python"
  PYTHON_EXE="python"
fi

SYNC_ROOT="${SYNC_ROOT:-/workspace/hf-bucket-sync}"

DOWNLOADED_MODELS_DIR="$SYNC_ROOT/models"
DOWNLOADED_WORKFLOWS_DIR="$DOWNLOADED_MODELS_DIR/workflows"

COMFYUI_MODELS_DIR="$COMFYUI_DIR/models"
COMFYUI_WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"

echo "[custom] installing huggingface-hub"
"$PYTHON_EXE" -m pip install -U "huggingface-hub"

# Use the hf command from the venv if available
export PATH="$VENV_DIR/bin:$PATH"

command -v hf >/dev/null 2>&1 || {
  echo "[custom] ERROR: hf command not found" >&2
  exit 1
}

echo "[custom] syncing models"
echo "[custom] from: $HF_BUCKET_MODELS_URI"
echo "[custom] to:   $DOWNLOADED_MODELS_DIR"

mkdir -p "$SYNC_ROOT"

hf buckets sync "$HF_BUCKET_MODELS_URI" "$DOWNLOADED_MODELS_DIR"

if [ ! -d "$DOWNLOADED_MODELS_DIR" ]; then
  echo "[custom] ERROR: downloaded models dir not found: $DOWNLOADED_MODELS_DIR" >&2
  exit 1
fi

echo "[custom] replacing ComfyUI models with symlink"

rm -rf "$COMFYUI_MODELS_DIR"
ln -s "$DOWNLOADED_MODELS_DIR" "$COMFYUI_MODELS_DIR"

echo "[custom] linking workflows"

mkdir -p "$(dirname "$COMFYUI_WORKFLOWS_DIR")"

if [ -d "$DOWNLOADED_WORKFLOWS_DIR" ]; then
  rm -rf "$COMFYUI_WORKFLOWS_DIR"
  ln -s "$DOWNLOADED_WORKFLOWS_DIR" "$COMFYUI_WORKFLOWS_DIR"
else
  echo "[custom] WARNING: workflows dir not found: $DOWNLOADED_WORKFLOWS_DIR"
fi

echo "[custom] installing workflow dependencies"

if [ -d "$DOWNLOADED_WORKFLOWS_DIR" ]; then
  while IFS= read -r req; do
    echo "[custom] pip install -r $req"
    "$PYTHON_EXE" -m pip install -r "$req"
  done < <(find "$DOWNLOADED_WORKFLOWS_DIR" -type f -name "requirements.txt" | sort)

  while IFS= read -r script; do
    echo "[custom] running $script"
    chmod +x "$script"
    bash "$script"
  done < <(find "$DOWNLOADED_WORKFLOWS_DIR" -type f \( -name "install.sh" -o -name "setup.sh" \) | sort)
fi

echo "[custom] final links:"
echo "[custom] models    -> $(readlink -f "$COMFYUI_MODELS_DIR" || true)"

if [ -L "$COMFYUI_WORKFLOWS_DIR" ]; then
  echo "[custom] workflows -> $(readlink -f "$COMFYUI_WORKFLOWS_DIR" || true)"
fi

echo "[custom] done"
