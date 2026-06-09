#!/usr/bin/env bash
set -euo pipefail

echo "[custom] custom-before-comfyui.sh started"

: "${HF_BUCKET_MODELS_URI:?HF_BUCKET_MODELS_URI is required}"

# Optional.
# If set, this script is downloaded and executed when system CUDA and torch CUDA mismatch.
FIX_TORCH_SCRIPT_URL="${FIX_TORCH_SCRIPT_URL:-}"

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

echo "[custom] checking CUDA / torch CUDA compatibility"

if [ -x "$VENV_DIR/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  PYTHON_EXE="python"
  echo "[custom] venv activated: $VENV_DIR"
else
  echo "[custom] WARNING: venv activate not found at $VENV_DIR/bin/activate"
  echo "[custom] WARNING: using current python executable: $PYTHON_EXE"
fi

SYSTEM_CUDA_VERSION=""

if command -v nvidia-smi >/dev/null 2>&1; then
  SYSTEM_CUDA_VERSION="$(
    nvidia-smi 2>/dev/null \
      | sed -n 's/.*CUDA Version: \([0-9][0-9.]*\).*/\1/p' \
      | head -n 1
  )"
else
  echo "[custom] WARNING: nvidia-smi not found"
fi

TORCH_CUDA_VERSION="$(
  "$PYTHON_EXE" - <<'PY'
try:
    import torch
    print(torch.version.cuda or "")
except Exception:
    print("")
PY
)"

normalize_cuda_minor() {
  local version="${1:-}"
  if [ -z "$version" ]; then
    echo ""
    return 0
  fi

  # 12.8.1 -> 12.8
  # 12.8   -> 12.8
  echo "$version" | awk -F. '{ if (NF >= 2) print $1 "." $2; else print $1 }'
}

SYSTEM_CUDA_MINOR="$(normalize_cuda_minor "$SYSTEM_CUDA_VERSION")"
TORCH_CUDA_MINOR="$(normalize_cuda_minor "$TORCH_CUDA_VERSION")"

echo "[custom] system CUDA: ${SYSTEM_CUDA_VERSION:-unknown}"
echo "[custom] torch CUDA:  ${TORCH_CUDA_VERSION:-unknown}"

if [ -z "$SYSTEM_CUDA_MINOR" ]; then
  echo "[custom] WARNING: system CUDA version could not be detected; skipping torch fix"
elif [ -z "$TORCH_CUDA_MINOR" ]; then
  echo "[custom] WARNING: torch CUDA version could not be detected"

  if [ -n "$FIX_TORCH_SCRIPT_URL" ]; then
    echo "[custom] running FIX_TORCH_SCRIPT because torch CUDA is missing"
    FIX_TORCH_SCRIPT="/tmp/fix-torch.sh"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$FIX_TORCH_SCRIPT_URL" -o "$FIX_TORCH_SCRIPT"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$FIX_TORCH_SCRIPT" "$FIX_TORCH_SCRIPT_URL"
    else
      echo "[custom] ERROR: neither curl nor wget found; cannot download FIX_TORCH_SCRIPT_URL" >&2
      exit 1
    fi

    chmod +x "$FIX_TORCH_SCRIPT"
    bash "$FIX_TORCH_SCRIPT"
  else
    echo "[custom] WARNING: FIX_TORCH_SCRIPT_URL is not set; skipping torch fix"
  fi
elif [ "$SYSTEM_CUDA_MINOR" != "$TORCH_CUDA_MINOR" ]; then
  echo "[custom] WARNING: CUDA mismatch detected: system=$SYSTEM_CUDA_MINOR torch=$TORCH_CUDA_MINOR"

  if [ -n "$FIX_TORCH_SCRIPT_URL" ]; then
    echo "[custom] running FIX_TORCH_SCRIPT"
    echo "[custom] from: $FIX_TORCH_SCRIPT_URL"

    FIX_TORCH_SCRIPT="/tmp/fix-torch.sh"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$FIX_TORCH_SCRIPT_URL" -o "$FIX_TORCH_SCRIPT"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$FIX_TORCH_SCRIPT" "$FIX_TORCH_SCRIPT_URL"
    else
      echo "[custom] ERROR: neither curl nor wget found; cannot download FIX_TORCH_SCRIPT_URL" >&2
      exit 1
    fi

    chmod +x "$FIX_TORCH_SCRIPT"
    bash "$FIX_TORCH_SCRIPT"
  else
    echo "[custom] WARNING: FIX_TORCH_SCRIPT_URL is not set; skipping torch fix"
  fi
else
  echo "[custom] CUDA versions look compatible: $SYSTEM_CUDA_MINOR"
fi

echo "[custom] done"
