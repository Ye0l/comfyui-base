#!/usr/bin/env bash
set -euo pipefail

echo "[custom] custom-before-comfyui.sh started"

: "${HF_BUCKET_MODELS_URI:?HF_BUCKET_MODELS_URI is required}"
: "${HF_BUCKET_MODELS_FILTER:?HF_BUCKET_MODELS_FILTER is required}"
HF_BUCKET_MODELS_URI="${HF_BUCKET_MODELS_URI%/}"

# Optional.
# If set, this script is downloaded and executed when system CUDA and torch CUDA mismatch.
# Example:
#   FIX_TORCH_SCRIPT_URL="https://example.com/fix_torch.sh"
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
DOWNLOADED_FILTERS_DIR="$DOWNLOADED_MODELS_DIR/filters"
DOWNLOADED_FILTER_FILE="$DOWNLOADED_FILTERS_DIR/$HF_BUCKET_MODELS_FILTER"

COMFYUI_MODELS_DIR="$COMFYUI_DIR/models"
COMFYUI_WORKFLOWS_DIR="$COMFYUI_DIR/user/default/workflows"

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$output" "$url"
  else
    echo "[custom] ERROR: neither curl nor wget found; cannot download: $url" >&2
    exit 1
  fi
}

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

cuda_version_to_torch_tag() {
  local version="${1:-}"

  if [ -z "$version" ]; then
    echo ""
    return 0
  fi

  # 12.4, 12.4.1 -> cu124
  # 12.8, 12.8.1 -> cu128
  echo "$version" | awk -F. '{ if (NF >= 2) print "cu" $1 $2; else print "" }'
}

run_fix_torch_script() {
  local target_cuda_version="${1:-}"
  local target_torch_tag
  local fix_torch_script

  target_torch_tag="$(cuda_version_to_torch_tag "$target_cuda_version")"

  if [ -z "$FIX_TORCH_SCRIPT_URL" ]; then
    echo "[custom] WARNING: FIX_TORCH_SCRIPT_URL is not set; skipping torch fix"
    return 0
  fi

  if [ -z "$target_torch_tag" ]; then
    echo "[custom] WARNING: target torch CUDA tag could not be determined from: $target_cuda_version"
    echo "[custom] WARNING: skipping torch fix"
    return 0
  fi

  echo "[custom] running FIX_TORCH_SCRIPT"
  echo "[custom] from:   $FIX_TORCH_SCRIPT_URL"
  echo "[custom] target: $target_torch_tag"

  fix_torch_script="/tmp/fix_torch.sh"

  download_file "$FIX_TORCH_SCRIPT_URL" "$fix_torch_script"

  chmod +x "$fix_torch_script"

  bash "$fix_torch_script" --fix "$target_torch_tag"
}

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
echo "[custom] filter: filters/$HF_BUCKET_MODELS_FILTER"

mkdir -p "$DOWNLOADED_FILTERS_DIR"

hf buckets cp "$HF_BUCKET_MODELS_URI/filters/$HF_BUCKET_MODELS_FILTER" "$DOWNLOADED_FILTER_FILE"

hf buckets sync "$HF_BUCKET_MODELS_URI" "$DOWNLOADED_MODELS_DIR" \
  --filter-from "$DOWNLOADED_FILTER_FILE"

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

echo "[custom] installing comfy-cli"
"$PYTHON_EXE" -m pip install -U comfy-cli

echo "[custom] installing workflow dependencies"

if [ -d "$DOWNLOADED_WORKFLOWS_DIR" ]; then
  # comfy-cli가 ComfyUI를 인식하도록 cwd를 ComfyUI 디렉토리로 (--here)
  while IFS= read -r wf; do
    echo "[custom] comfy node install-deps --workflow=$wf"
    (
      cd "$COMFYUI_DIR" && \
      comfy --here node install-deps --workflow="$wf" < /dev/null
    ) || echo "[custom] WARNING: failed to install deps for $wf"
  done < <(find "$DOWNLOADED_WORKFLOWS_DIR" -type f -name "*.json" | sort)

  # 레지스트리에 없는 custom node는 git clone으로 수동 설치
  KNOWN_CUSTOM_NODE_REPOS="${KNOWN_CUSTOM_NODE_REPOS:-https://github.com/An1X3R/Anima-Artist-Mixer}"
  CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
  mkdir -p "$CUSTOM_NODES_DIR"
  while IFS= read -r repo_url; do
    [ -z "$repo_url" ] && continue
    repo_name=$(basename "$repo_url" .git)
    target="$CUSTOM_NODES_DIR/$repo_name"
    if [ -d "$target" ]; then
      echo "[custom] $repo_name already installed"
      continue
    fi
    echo "[custom] git clone $repo_url -> $target"
    git clone --depth 1 "$repo_url" "$target" || {
      echo "[custom] WARNING: failed to clone $repo_url"
      continue
    }
    if [ -f "$target/requirements.txt" ]; then
      echo "[custom] pip install -r $target/requirements.txt"
      "$PYTHON_EXE" -m pip install -r "$target/requirements.txt" || \
        echo "[custom] WARNING: pip install failed for $repo_name"
    fi
  done <<< "$KNOWN_CUSTOM_NODE_REPOS"

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

if [ -f "$VENV_DIR/bin/activate" ]; then
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

SYSTEM_CUDA_MINOR="$(normalize_cuda_minor "$SYSTEM_CUDA_VERSION")"
TORCH_CUDA_MINOR="$(normalize_cuda_minor "$TORCH_CUDA_VERSION")"

echo "[custom] system CUDA: ${SYSTEM_CUDA_VERSION:-unknown}"
echo "[custom] torch CUDA:  ${TORCH_CUDA_VERSION:-unknown}"

if [ -z "$SYSTEM_CUDA_MINOR" ]; then
  echo "[custom] WARNING: system CUDA version could not be detected; skipping torch fix"
elif [ -z "$TORCH_CUDA_MINOR" ]; then
  echo "[custom] WARNING: torch CUDA version could not be detected"
  run_fix_torch_script "$SYSTEM_CUDA_MINOR"
elif [ "$SYSTEM_CUDA_MINOR" != "$TORCH_CUDA_MINOR" ]; then
  echo "[custom] WARNING: CUDA mismatch detected: system=$SYSTEM_CUDA_MINOR torch=$TORCH_CUDA_MINOR"
  run_fix_torch_script "$SYSTEM_CUDA_MINOR"
else
  echo "[custom] CUDA versions look compatible: $SYSTEM_CUDA_MINOR"
fi

echo "[custom] done"
