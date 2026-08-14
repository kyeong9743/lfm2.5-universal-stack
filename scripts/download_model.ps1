# ---------------------------------------------------------------------
#  LFM2.5-2.6B GGUF 가중치 다운로드 + 무결성 검증 (Windows)
#  Invoke-WebRequest 는 대용량에서 매우 느리므로 Windows 내장 curl.exe 를 쓴다.
# ---------------------------------------------------------------------
$ErrorActionPreference = 'Stop'

$Root      = Split-Path -Parent $PSScriptRoot
$ModelDir  = Join-Path $Root 'models'
$HfRepo    = 'LiquidAI/LFM2.5-2.6B-GGUF'
$RemoteFile = 'LFM2.5-2.6B-Q4_K_M.gguf'

# .env 의 MODEL_FILE 을 로컬 저장명으로 사용
$ModelFile = $RemoteFile
$EnvPath = Join-Path $Root '.env'
if (Test-Path $EnvPath) {
    $line = Get-Content $EnvPath | Where-Object { $_ -match '^\s*MODEL_FILE\s*=' } | Select-Object -Last 1
    if ($line) { $ModelFile = ($line -split '=', 2)[1].Trim() }
}

$Url    = "https://huggingface.co/$HfRepo/resolve/main/$RemoteFile"
$ApiUrl = "https://huggingface.co/api/models/$HfRepo/tree/main"
$Target = Join-Path $ModelDir $ModelFile

# API 조회 실패 시 폴백 (2026-08-14 확인값)
$ExpectedSize   = 1674454848
$ExpectedSha256 = '79fdf00351b46cf26f020aead28d01889886be87c55fa0eb907e6f9b00bfee14'

if (-not (Test-Path $ModelDir)) { New-Item -ItemType Directory -Path $ModelDir | Out-Null }

# --- 1. 기대 크기/해시 조회 ------------------------------------------
try {
    $tree = curl.exe -sL --max-time 20 $ApiUrl | ConvertFrom-Json
    $entry = $tree | Where-Object { $_.path -eq $RemoteFile }
    if ($entry) {
        $ExpectedSize   = [int64]$entry.size
        $ExpectedSha256 = $entry.lfs.oid
    }
} catch {
    Write-Host "[WARN] HF API 조회 실패 - 폴백 값을 사용합니다."
}

Write-Host "[INFO] repo   : $HfRepo"
Write-Host "[INFO] target : $Target"
Write-Host "[INFO] expect : $ExpectedSize bytes / sha256 $ExpectedSha256"

function Test-Model {
    if (-not (Test-Path $Target)) { return $false }
    $size = (Get-Item $Target).Length
    if ($size -ne $ExpectedSize) {
        Write-Host "[WARN] 크기 불일치: $size != $ExpectedSize"
        return $false
    }
    Write-Host "[INFO] sha256 계산 중... (1.6GB, 수십 초 소요)"
    $hash = (Get-FileHash -Path $Target -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $ExpectedSha256.ToLower()) {
        Write-Host "[WARN] sha256 불일치: $hash"
        return $false
    }
    return $true
}

# --- 2. 이미 있으면 검증만 -------------------------------------------
if (Test-Path $Target) {
    Write-Host "[INFO] 기존 파일 발견. 무결성 검증 중..."
    if (Test-Model) {
        Write-Host "[SUCCESS] 검증 통과. 다운로드를 건너뜁니다."
        exit 0
    }
    Write-Host "[INFO] 검증 실패 -> 이어받기를 시도합니다."
}

# --- 3. 다운로드 (이어받기) ------------------------------------------
Write-Host "[INFO] 다운로드 시작: $Url"
curl.exe -L --fail --retry 5 --retry-delay 3 -C - --progress-bar -o $Target $Url
if ($LASTEXITCODE -ne 0) { throw "다운로드 실패 (curl exit $LASTEXITCODE)" }

# --- 4. 최종 검증 -----------------------------------------------------
Write-Host "[INFO] 다운로드 완료. 무결성 검증 중..."
if (Test-Model) {
    $gb = [math]::Round((Get-Item $Target).Length / 1GB, 2)
    Write-Host "[SUCCESS] $Target ($gb GB)"
} else {
    throw "무결성 검증 실패. 파일을 삭제하고 다시 실행하세요."
}
