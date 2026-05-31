#!/usr/bin/env bash
#
# fix-torch.sh
#   1) Diagnose the torch / cuda version and install path of the active python
#   2) Optionally force-reinstall the specified CUDA build
#
# Usage:
#   ./fix-torch.sh                      # diagnose only (changes nothing)
#   ./fix-torch.sh --fix                # reinstall with default cu128
#   ./fix-torch.sh --fix cu124          # reinstall with cu124
#   ./fix-torch.sh --fix cu121          # reinstall with cu121
#   ./fix-torch.sh --fix cu128 2.10.0   # cu128 + explicit torch version
#   CU=cu124 TORCH=2.6.0 ./fix-torch.sh --fix   # also configurable via env vars
#
set -euo pipefail

# -- config -------------------------------------------
VENV="/workspace/runpod-slim/ComfyUI/.venv-cu128"

# CUDA tag: 2nd arg > env CU > default cu128
CU="${2:-${CU:-cu128}}"
# torch version: 3rd arg > env TORCH > empty (=latest)
TORCH_VER="${3:-${TORCH:-}}"
# -----------------------------------------------------

INDEX_URL="https://download.pytorch.org/whl/${CU}"

# Use venv python if present, otherwise current python3
if [[ -x "${VENV}/bin/python" ]]; then
    PY="${VENV}/bin/python"
else
    PY="$(command -v python3)"
fi

echo "==================== DIAGNOSE ===================="
echo "Interpreter in use: ${PY}"
echo

echo "[active python3]"
python3 -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  path  :', torch.__file__)" 2>/dev/null \
    || echo "  torch not found / import failed"
echo

echo "[venv python: ${PY}]"
"${PY}" -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  path  :', torch.__file__)" 2>/dev/null \
    || echo "  torch not found / import failed"
echo

echo "[driver (nvidia-smi)]"
nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null \
    || echo "  nvidia-smi unavailable"
echo "=================================================="
echo

# Without the --fix flag, diagnose only and exit
if [[ "${1:-}" != "--fix" ]]; then
    echo "Diagnose only. To reinstall:  $0 --fix [cu_tag] [torch_version]"
    echo "  e.g.: $0 --fix cu124"
    exit 0
fi

# Build package spec depending on whether a torch version was given
if [[ -n "${TORCH_VER}" ]]; then
    # User supplied a torch version -> pin with +cu tag
    TORCH_SPEC="torch==${TORCH_VER}+${CU}"
    TV_SPEC="torchvision"
    TA_SPEC="torchaudio"
else
    # No version -> latest from the index
    TORCH_SPEC="torch"
    TV_SPEC="torchvision"
    TA_SPEC="torchaudio"
fi

echo
echo "==================== REINSTALL ===================="
echo "target : ${PY}"
echo "CUDA   : ${CU}"
echo "torch  : ${TORCH_SPEC}"
echo "index  : ${INDEX_URL}"
echo

"${PY}" -m pip uninstall -y torch torchvision torchaudio || true

"${PY}" -m pip install \
    "${TORCH_SPEC}" "${TV_SPEC}" "${TA_SPEC}" \
    --index-url "${INDEX_URL}" \
    --ignore-installed

echo
echo "[after reinstall]"
"${PY}" -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  cuda_available:', torch.cuda.is_available())"
echo "=================================================="
