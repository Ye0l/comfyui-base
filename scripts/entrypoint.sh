#!/usr/bin/env bash
set -euo pipefail

ORIGINAL_START="/start.sh"
PATCHED_START="/tmp/start.patched.sh"
TORCH_GUARD="/tmp/ensure-torch.sh"
CUSTOM_HOOK=""

cat > "$TORCH_GUARD" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

PHASE="${1:-startup}"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/runpod-slim/ComfyUI}"
VENV_DIR="$COMFYUI_DIR/.venv-cu128"
PYTHON_EXE="$VENV_DIR/bin/python"

if [ ! -x "$PYTHON_EXE" ]; then
  PYTHON_EXE="python"
fi

detect_driver_cuda() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo ""
    return 0
  fi

  nvidia-smi 2>/dev/null \
    | sed -n 's/.*CUDA Version: \([0-9][0-9.]*\).*/\1/p' \
    | head -n 1
}

select_torch_target() {
  local driver_cuda="${1:-}"
  local major="${driver_cuda%%.*}"

  if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 13 ]; then
    echo "cu130"
  else
    echo "cu128"
  fi
}

smoke_test() {
  "$PYTHON_EXE" - <<'PY'
import sys
try:
    import torch
    print(f"[torch-guard] torch: {torch.__version__}")
    print(f"[torch-guard] torch CUDA: {torch.version.cuda}")
    print(f"[torch-guard] CUDA available: {torch.cuda.is_available()}")
    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() returned False")
    value = torch.zeros(1, device="cuda")
    print(f"[torch-guard] GPU: {torch.cuda.get_device_name(0)}")
    print(f"[torch-guard] smoke test passed: {value.device}")
except Exception as exc:
    print(f"[torch-guard] smoke test failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
}

repair_torch() {
  local target="$1"
  local fix_script="/tmp/fix_torch.sh"

  case "$target" in
    cu128|cu130) ;;
    *)
      echo "[torch-guard] ERROR: unsupported target: $target" >&2
      return 1
      ;;
  esac

  if [ -z "${FIX_TORCH_SCRIPT_URL:-}" ]; then
    echo "[torch-guard] ERROR: FIX_TORCH_SCRIPT_URL is not set" >&2
    return 1
  fi

  echo "[torch-guard] repairing torch with $target"
  curl -fsSL "$FIX_TORCH_SCRIPT_URL" -o "$fix_script"
  chmod +x "$fix_script"
  bash "$fix_script" --fix "$target"
}

echo "[torch-guard] checking torch during $PHASE"
DRIVER_CUDA="$(detect_driver_cuda)"
TARGET="$(select_torch_target "$DRIVER_CUDA")"
echo "[torch-guard] driver CUDA capability: ${DRIVER_CUDA:-unknown}"
echo "[torch-guard] selected target: $TARGET"

if smoke_test; then
  echo "[torch-guard] torch CUDA is already working"
  exit 0
fi

repair_torch "$TARGET"
smoke_test
echo "[torch-guard] torch repair completed"
SH
chmod +x "$TORCH_GUARD"

if [ -n "${CUSTOM_SCRIPT_URL:-}" ]; then
  echo "[entrypoint] fetching custom hook from $CUSTOM_SCRIPT_URL"
  CUSTOM_HOOK="/tmp/custom-hook.sh"
  if curl -sSL "$CUSTOM_SCRIPT_URL" -o "$CUSTOM_HOOK"; then
    chmod +x "$CUSTOM_HOOK"
  else
    echo "[entrypoint] ERROR: failed to fetch custom hook from $CUSTOM_SCRIPT_URL" >&2
    exit 1
  fi
elif [ -x "/custom-before-comfyui.sh" ]; then
  echo "[entrypoint] using local custom hook: /custom-before-comfyui.sh"
  CUSTOM_HOOK="/custom-before-comfyui.sh"
else
  echo "[entrypoint] no custom hook found (URL not set and local script missing)"
fi

if [ ! -f "$ORIGINAL_START" ]; then
  echo "[entrypoint] ERROR: $ORIGINAL_START not found" >&2
  exit 1
fi

if [ -n "$CUSTOM_HOOK" ] && [ -x "$CUSTOM_HOOK" ]; then
  echo "[entrypoint] patching /start.sh with hook: $CUSTOM_HOOK"
  awk -v hook="$CUSTOM_HOOK" -v guard="$TORCH_GUARD" '
  BEGIN {
    inserted = 0
  }

  {
    if (!inserted && $0 ~ /^[[:space:]]*python[[:space:]]+main\.py[[:space:]]+\$FIXED_ARGS/) {
      print "echo \"[entrypoint] checking torch before custom hook\""
      print guard " pre-hook"
      print "echo \"[entrypoint] running custom hook before ComfyUI\""
      print "FIX_TORCH_SCRIPT_URL=\"\" " hook
      print "echo \"[entrypoint] custom hook finished\""
      print "echo \"[entrypoint] checking torch after custom hook\""
      print guard " post-hook"
      inserted = 1
    }

    print
  }

  END {
    if (!inserted) {
      print "[entrypoint] ERROR: could not find ComfyUI launch line in /start.sh" > "/dev/stderr"
      exit 42
    }
  }
  ' "$ORIGINAL_START" > "$PATCHED_START"

  chmod +x "$PATCHED_START"
  echo "[entrypoint] patched start.sh ready"
  exec "$PATCHED_START"
else
  echo "[entrypoint] starting without custom hook"
  exec "$ORIGINAL_START"
fi
