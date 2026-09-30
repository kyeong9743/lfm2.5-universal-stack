# ---------------------------------------------------------------------
#  LFM2.5 API 검증 스크립트 (Windows)
#   1) /health 대기        2) /v1/models
#   3) /v1/chat/completions → reasoning_content 분리 검증
#   4) timings 로 tok/s 실측  5) 컨테이너 메모리 실측
# ---------------------------------------------------------------------
param(
    [int]$Port = 0,
    [string]$ApiKey = $null,
    [int]$TimeoutSec = 300
)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot

# .env 에서 PORT / API_KEY 자동 로드
$EnvPath = Join-Path $Root '.env'
$conf = @{}
if (Test-Path $EnvPath) {
    Get-Content $EnvPath | Where-Object { $_ -match '^\s*[A-Z_]+\s*=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $conf[$kv[0].Trim()] = $kv[1].Trim()
    }
}
if ($Port -eq 0)   { $Port   = if ($conf['PORT']) { [int]$conf['PORT'] } else { 8080 } }
if (-not $ApiKey)  { $ApiKey = $conf['API_KEY'] }

$Base = "http://localhost:$Port"
$Headers = @{ 'Content-Type' = 'application/json' }
if ($ApiKey) { $Headers['Authorization'] = "Bearer $ApiKey" }

$pass = 0; $fail = 0
function Ok([string]$m)   { Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function Bad([string]$m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red;   $script:fail++ }
function Info([string]$m) { Write-Host "  $m" -ForegroundColor DarkGray }

# --- 1. /health 대기 --------------------------------------------------
Write-Host "`n[1/5] /health 대기 (최대 ${TimeoutSec}s, 모델 로딩 포함)" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$ready = $false
while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
        $h = Invoke-RestMethod -Uri "$Base/health" -TimeoutSec 5
        if ($h.status -eq 'ok') { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 3
}
if ($ready) { Ok "서버 기동 완료 ($([math]::Round($sw.Elapsed.TotalSeconds,1))s)" }
else { Bad "타임아웃 - 'docker compose logs' 를 확인하세요"; exit 1 }

# --- 2. /v1/models ----------------------------------------------------
Write-Host "`n[2/5] /v1/models" -ForegroundColor Cyan
try {
    $m = Invoke-RestMethod -Uri "$Base/v1/models" -Headers $Headers
    $id = $m.data[0].id
    Ok "모델 인식: $id"
} catch { Bad "실패: $($_.Exception.Message)" }

# --- 3. 추론 + reasoning_content 분리 검증 ----------------------------
Write-Host "`n[3/5] /v1/chat/completions - reasoning_content 분리 검증" -ForegroundColor Cyan
$body = @{
    model    = 'lfm2.5-2.6b'
    messages = @(
        @{ role = 'system'; content = 'You are a concise edge AI assistant.' },
        @{ role = 'user';   content = 'Explain edge computing in one sentence.' }
    )
    max_tokens = 2048
} | ConvertTo-Json -Depth 5

$t0 = [Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post -Headers $Headers -Body $body -TimeoutSec 600
$t0.Stop()

$msg = $resp.choices[0].message
$content = [string]$msg.content
$reasoning = [string]$msg.reasoning_content

Info "--- content ---"
Write-Host $content
if ($reasoning) {
    Info "--- reasoning_content (앞 200자) ---"
    Write-Host ($reasoning.Substring(0, [Math]::Min(200, $reasoning.Length)) + '...')
}

if ($content -match '<think>|</think>') {
    Bad "content 에 <think> 태그가 남아있음 - REASONING_FORMAT 설정 확인 필요"
} else {
    Ok "content 에 <think> 태그 없음"
}
if ($reasoning) { Ok "reasoning_content 필드 분리 확인 ($($reasoning.Length) chars)" }
else { Bad "reasoning_content 가 비어있음 - 파서가 LFM2.5 포맷을 인식하지 못함" }

# 추론 모델 특유의 함정: 사고가 max_tokens 를 다 먹으면 content 가 빈 채로 잘린다
$finish = $resp.choices[0].finish_reason
if ($finish -eq 'length') {
    Bad "finish_reason=length - 사고가 max_tokens 를 소진했습니다. THINK_BUDGET=256 또는 max_tokens>=2048"
} else {
    Ok "finish_reason=$finish"
}
if (-not $content) { Bad "content 가 빈 문자열입니다 (위 max_tokens 함정 참조)" }

# --- 4. 속도 실측 -----------------------------------------------------
Write-Host "`n[4/5] 속도 실측" -ForegroundColor Cyan
$tm = $resp.timings
if ($tm) {
    Info ("prompt  : {0,8:N2} tok/s  ({1} tokens)" -f $tm.prompt_per_second,    $tm.prompt_n)
    Info ("decode  : {0,8:N2} tok/s  ({1} tokens)" -f $tm.predicted_per_second, $tm.predicted_n)
    Info ("wall    : {0,8:N2} s" -f $t0.Elapsed.TotalSeconds)
    Ok ("디코드 {0:N1} tok/s" -f $tm.predicted_per_second)
} else {
    Info ("wall: {0:N2}s / completion_tokens: {1}" -f $t0.Elapsed.TotalSeconds, $resp.usage.completion_tokens)
}

# --- 5. 메모리 실측 ---------------------------------------------------
Write-Host "`n[5/5] 컨테이너 메모리 (주장: < 2.5GB)" -ForegroundColor Cyan
try {
    $stat = docker stats lfm-api --no-stream --format "{{.MemUsage}} / limit {{.MemPerc}}"
    Info $stat
    $used = [double](( $stat -split '/' )[0].Trim() -replace '[^0-9.]','')
    if ($stat -match 'GiB' -and $used -lt 2.5) { Ok "2.5GB 미만 확인" }
    elseif ($stat -match 'MiB') { Ok "2.5GB 미만 확인" }
    else { Bad "2.5GB 초과 - CTX_SIZE / PARALLEL_REQUESTS 조정 필요" }
} catch { Info "docker stats 조회 실패 (건너뜀)" }

Write-Host "`n===== 결과: PASS $pass / FAIL $fail =====" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
