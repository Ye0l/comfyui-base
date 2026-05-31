#!/usr/bin/env bash
#
# fix-torch.sh
#   1) 현재 활성 python 의 torch / cuda 버전과 설치 경로를 진단
#   2) 원할 경우 지정한 CUDA 빌드로 강제 재설치
#
# 사용법:
#   ./fix-torch.sh                      # 진단만 (아무것도 바꾸지 않음)
#   ./fix-torch.sh --fix                # 기본 cu128 로 강제 재설치
#   ./fix-torch.sh --fix cu124          # cu124 로 재설치
#   ./fix-torch.sh --fix cu121          # cu121 로 재설치
#   ./fix-torch.sh --fix cu128 2.10.0   # cu128 + torch 버전 직접 지정
#   CU=cu124 TORCH=2.6.0 ./fix-torch.sh --fix   # 환경변수로도 지정 가능
#
set -euo pipefail

# ── 설정 ──────────────────────────────────────────────
VENV="/workspace/runpod-slim/ComfyUI/.venv-cu128"

# CUDA 태그: 2번째 인자 > 환경변수 CU > 기본 cu128
CU="${2:-${CU:-cu128}}"
# torch 버전: 3번째 인자 > 환경변수 TORCH > 빈 값(=최신)
TORCH_VER="${3:-${TORCH:-}}"
# ─────────────────────────────────────────────────────

INDEX_URL="https://download.pytorch.org/whl/${CU}"

# venv 가 있으면 그 python, 없으면 현재 python3
if [[ -x "${VENV}/bin/python" ]]; then
    PY="${VENV}/bin/python"
else
    PY="$(command -v python3)"
fi

echo "==================== 진단 ===================="
echo "사용 인터프리터: ${PY}"
echo

echo "[현재 활성 python3]"
python3 -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  path  :', torch.__file__)" 2>/dev/null \
    || echo "  torch 없음 / import 실패"
echo

echo "[venv python: ${PY}]"
"${PY}" -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  path  :', torch.__file__)" 2>/dev/null \
    || echo "  torch 없음 / import 실패"
echo

echo "[드라이버 (nvidia-smi)]"
nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>/dev/null \
    || echo "  nvidia-smi 사용 불가"
echo "=============================================="
echo

# --fix 플래그가 없으면 진단만 하고 종료
if [[ "${1:-}" != "--fix" ]]; then
    echo "진단만 수행했습니다. 재설치하려면:  $0 --fix [cu태그] [torch버전]"
    echo "  예: $0 --fix cu124"
    exit 0
fi

# torch 버전 지정 여부에 따라 패키지 스펙 구성
if [[ -n "${TORCH_VER}" ]]; then
    # 사용자가 torch 버전을 줬으면 +cu 태그 붙여 핀 고정
    TORCH_SPEC="torch==${TORCH_VER}+${CU}"
    TV_SPEC="torchvision"
    TA_SPEC="torchaudio"
else
    # 버전 미지정 → 해당 인덱스의 최신
    TORCH_SPEC="torch"
    TV_SPEC="torchvision"
    TA_SPEC="torchaudio"
fi

echo
echo "==================== 재설치 ===================="
echo "대상  : ${PY}"
echo "CUDA  : ${CU}"
echo "torch : ${TORCH_SPEC}"
echo "index : ${INDEX_URL}"
echo

"${PY}" -m pip uninstall -y torch torchvision torchaudio || true

"${PY}" -m pip install \
    "${TORCH_SPEC}" "${TV_SPEC}" "${TA_SPEC}" \
    --index-url "${INDEX_URL}" \
    --ignore-installed

echo
echo "[재설치 후 확인]"
"${PY}" -c "import torch; print('  torch :', torch.__version__); print('  cuda  :', torch.version.cuda); print('  cuda_available:', torch.cuda.is_available())"
echo "=============================================="
