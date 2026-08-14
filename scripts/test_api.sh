#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  LFM2.5 API 검증 스크립트 (Linux / RPi5 / Oracle A1)
#   1) /health 대기  2) /v1/models
#   3) reasoning_content 분리 검증  4) tok/s 실측  5) 메모리 실측
# ---------------------------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# .env 로드 (PORT / API_KEY)
PORT=8080
API_KEY=""
if [ -f "$ROOT_DIR/.env" ]; then
    # shellcheck disable=SC2046
    PORT="$(grep -E '^PORT=' "$ROOT_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || echo 8080)"
    API_KEY="$(grep -E '^API_KEY=' "$ROOT_DIR/.env" | tail -n1 | cut -d= -f2- | tr -d '\r' || echo '')"
fi
PORT="${1:-${PORT:-8080}}"
BASE="http://localhost:$PORT"
TIMEOUT="${TIMEOUT:-300}"

AUTH=()
[ -n "$API_KEY" ] && AUTH=(-H "Authorization: Bearer $API_KEY")

PASS=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  $*"; }

command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq 가 필요합니다: sudo apt install -y jq"; exit 1; }

# --- 1. /health -------------------------------------------------------
echo
echo "[1/5] /health 대기 (최대 ${TIMEOUT}s, 모델 로딩 포함)"
START=$(date +%s)
READY=0
while [ $(( $(date +%s) - START )) -lt "$TIMEOUT" ]; do
    if curl -fsS --max-time 5 "$BASE/health" 2>/dev/null | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
        READY=1; break
    fi
    sleep 3
done
if [ "$READY" = "1" ]; then ok "서버 기동 완료 ($(( $(date +%s) - START ))s)"
else bad "타임아웃 - 'docker compose logs' 확인"; exit 1; fi

# --- 2. /v1/models ----------------------------------------------------
echo
echo "[2/5] /v1/models"
MODELS=$(curl -fsS "${AUTH[@]}" "$BASE/v1/models" 2>/dev/null)
if [ -n "$MODELS" ]; then ok "모델 인식: $(echo "$MODELS" | jq -r '.data[0].id')"
else bad "조회 실패"; fi

# --- 3. 추론 + reasoning_content --------------------------------------
echo
echo "[3/5] /v1/chat/completions - reasoning_content 분리 검증"
REQ='{
  "model": "lfm2.5-2.6b",
  "messages": [
    {"role": "system", "content": "You are a concise edge AI assistant."},
    {"role": "user",   "content": "Explain edge computing in one sentence."}
  ],
  "max_tokens": 512
}'
T0=$(date +%s.%N)
RESP=$(curl -fsS --max-time 600 -X POST "$BASE/v1/chat/completions" \
        -H "Content-Type: application/json" "${AUTH[@]}" -d "$REQ")
T1=$(date +%s.%N)

CONTENT=$(echo "$RESP"   | jq -r '.choices[0].message.content // ""')
REASONING=$(echo "$RESP" | jq -r '.choices[0].message.reasoning_content // ""')

echo "  --- content ---"
echo "$CONTENT"
if [ -n "$REASONING" ]; then
    echo "  --- reasoning_content (앞 200자) ---"
    echo "${REASONING:0:200}..."
fi

if echo "$CONTENT" | grep -q '<think>\|</think>'; then
    bad "content 에 <think> 태그가 남아있음 - REASONING_FORMAT 확인 필요"
else
    ok "content 에 <think> 태그 없음"
fi
if [ -n "$REASONING" ]; then ok "reasoning_content 분리 확인 (${#REASONING} chars)"
else bad "reasoning_content 가 비어있음 - 파서가 LFM2.5 포맷을 인식하지 못함"; fi

# 추론 모델 특유의 함정: 사고가 max_tokens 를 다 먹으면 content 가 빈 채로 잘린다
FINISH=$(echo "$RESP" | jq -r '.choices[0].finish_reason // ""')
if [ "$FINISH" = "length" ]; then
    bad "finish_reason=length - 사고가 max_tokens 를 소진. THINK_BUDGET=256 또는 max_tokens>=1024"
else
    ok "finish_reason=$FINISH"
fi
[ -n "$CONTENT" ] || bad "content 가 빈 문자열입니다 (위 max_tokens 함정 참조)"

# --- 4. 속도 실측 -----------------------------------------------------
echo
echo "[4/5] 속도 실측"
PPS=$(echo "$RESP" | jq -r '.timings.prompt_per_second // empty')
DPS=$(echo "$RESP" | jq -r '.timings.predicted_per_second // empty')
PN=$(echo  "$RESP" | jq -r '.timings.prompt_n // empty')
DN=$(echo  "$RESP" | jq -r '.timings.predicted_n // empty')
WALL=$(echo "$T1 - $T0" | bc 2>/dev/null || echo "n/a")
if [ -n "$DPS" ]; then
    info "$(printf 'prompt  : %8.2f tok/s  (%s tokens)' "$PPS" "$PN")"
    info "$(printf 'decode  : %8.2f tok/s  (%s tokens)' "$DPS" "$DN")"
    info "wall    : ${WALL}s"
    ok "$(printf '디코드 %.1f tok/s' "$DPS")"
else
    info "timings 없음 / wall ${WALL}s"
fi

# --- 5. 메모리 실측 ---------------------------------------------------
echo
echo "[5/5] 컨테이너 메모리 (주장: < 2.5GB)"
if command -v docker >/dev/null 2>&1; then
    STAT=$(docker stats lfm-api --no-stream --format '{{.MemUsage}} ({{.MemPerc}})' 2>/dev/null || echo "")
    if [ -n "$STAT" ]; then info "$STAT"; ok "측정 완료"; else info "조회 실패 (건너뜀)"; fi
fi

echo
echo "===== 결과: PASS $PASS / FAIL $FAIL ====="
[ "$FAIL" -eq 0 ] || exit 1
