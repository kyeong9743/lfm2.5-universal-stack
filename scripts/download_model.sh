#!/usr/bin/env bash
# ---------------------------------------------------------------------
# LFM2.5-2.6B GGUF 가중치 다운로드 + 무결성 검증
# Linux 노드용 (RPi5 / Oracle A1 / WSL2)
# ---------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="$ROOT_DIR/models"

HF_REPO="LiquidAI/LFM2.5-2.6B-GGUF"
# .env 의 MODEL_FILE 을 따르되, 없으면 HF 원본 파일명을 쓴다.
MODEL_FILE="${MODEL_FILE:-LFM2.5-2.6B-Q4_K_M.gguf}"
if [ -z "${MODEL_FILE_OVERRIDE:-}" ] && [ -f "$ROOT_DIR/.env" ]; then
    MODEL_FILE="$(grep -E '^MODEL_FILE=' "$ROOT_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || true)"
    MODEL_FILE="${MODEL_FILE:-LFM2.5-2.6B-Q4_K_M.gguf}"
fi

# HF 저장소상의 실제 파일명(대문자). MODEL_FILE 은 로컬 저장명일 뿐이다.
REMOTE_FILE="LFM2.5-2.6B-Q4_K_M.gguf"
DOWNLOAD_URL="https://huggingface.co/${HF_REPO}/resolve/main/${REMOTE_FILE}"
API_URL="https://huggingface.co/api/models/${HF_REPO}/tree/main"

# API 조회 실패 시 사용할 폴백 (2026-09-30 확인값, HF 파일 2026-09-22 갱신본)
FALLBACK_SIZE=1674455040
FALLBACK_SHA256=02a8b7e17487d326e46d68ce0ba24211e1b80a14c4cd0597fa73c1cd697f52ed

TARGET="$MODEL_DIR/$MODEL_FILE"
mkdir -p "$MODEL_DIR"

# --- 1. 기대 크기/해시 조회 ------------------------------------------
EXPECTED_SIZE=""
EXPECTED_SHA256=""
if command -v python3 >/dev/null 2>&1; then
    read -r EXPECTED_SIZE EXPECTED_SHA256 < <(
        curl -fsSL "$API_URL" 2>/dev/null | python3 -c '
import json,sys
try:
    for e in json.load(sys.stdin):
        if e.get("path") == "'"$REMOTE_FILE"'":
            print(e.get("size",""), (e.get("lfs") or {}).get("oid",""))
            break
except Exception:
    pass
' || true
    )
fi
EXPECTED_SIZE="${EXPECTED_SIZE:-$FALLBACK_SIZE}"
EXPECTED_SHA256="${EXPECTED_SHA256:-$FALLBACK_SHA256}"

echo "[INFO] repo   : $HF_REPO"
echo "[INFO] target : $TARGET"
echo "[INFO] expect : ${EXPECTED_SIZE} bytes / sha256 ${EXPECTED_SHA256}"

verify() {
    [ -f "$TARGET" ] || return 1
    local actual_size
    actual_size=$(stat -c%s "$TARGET" 2>/dev/null || stat -f%z "$TARGET")
    if [ "$actual_size" != "$EXPECTED_SIZE" ]; then
        echo "[WARN] 크기 불일치: ${actual_size} != ${EXPECTED_SIZE}"
        return 1
    fi
    echo "[INFO] sha256 계산 중... (1.6GB, 수십 초 소요)"
    local actual_sha
    actual_sha=$(sha256sum "$TARGET" | cut -d' ' -f1)
    if [ "$actual_sha" != "$EXPECTED_SHA256" ]; then
        echo "[WARN] sha256 불일치: $actual_sha"
        return 1
    fi
    return 0
}

# --- 2. 이미 있으면 검증만 -------------------------------------------
if [ -f "$TARGET" ]; then
    echo "[INFO] 기존 파일 발견. 무결성 검증 중..."
    if verify; then
        echo "[SUCCESS] 검증 통과. 다운로드를 건너뜁니다."
        exit 0
    fi
    echo "[INFO] 검증 실패 → 이어받기를 시도합니다."
fi

# --- 3. 다운로드 (이어받기) ------------------------------------------
# 주의: wget 의 이어받기는 소문자 -c 다. -C 는 캐시 옵션이며 동작하지 않는다.
echo "[INFO] 다운로드 시작: $DOWNLOAD_URL"
if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 5 --retry-delay 3 -C - -o "$TARGET" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -c "$DOWNLOAD_URL" -O "$TARGET"
else
    echo "[ERROR] curl 또는 wget 이 필요합니다." >&2
    exit 1
fi

# --- 4. 최종 검증 -----------------------------------------------------
echo "[INFO] 다운로드 완료. 무결성 검증 중..."
if verify; then
    echo "[SUCCESS] $TARGET ($(du -h "$TARGET" | cut -f1))"
else
    echo "[ERROR] 무결성 검증 실패. 파일을 삭제하고 다시 실행하세요." >&2
    exit 1
fi
