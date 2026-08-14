# LFM2.5-2.6B Universal Edge Agent Server

Liquid AI **LFM2.5-2.6B** 를 `llama.cpp` 서버로 구동하는 범용 Docker 스택.
`.env` 프로파일 하나만 바꿔 **x86_64 PC / 라즈베리파이 5 / Oracle Cloud A1** 어디서나 동일하게 뜬다.
OpenAI 호환 REST API 와 내장 Web UI 를 함께 제공한다.

## 빠른 시작

```bash
git clone <repo> && cd lfm2.5-universal-stack
cp .env.example .env            # 하드웨어 프로파일 선택
./scripts/download_model.sh     # 가중치 1.67GB + sha256 검증
docker compose up -d
./scripts/test_api.sh
```

Windows(PowerShell):

```powershell
Copy-Item .env.example .env
.\scripts\download_model.ps1
docker compose up -d
.\scripts\test_api.ps1
```

- Web UI: <http://localhost:8080>
- API: `POST http://localhost:8080/v1/chat/completions`

## 스펙

| 항목 | 값 |
|---|---|
| 모델 | LiquidAI/LFM2.5-2.6B (2.69B) |
| 아키텍처 | 30 layers = 22 double-gated short-conv + 8 GQA |
| 양자화 | Q4_K_M GGUF, 1,674,454,848 bytes (약 1.56 GiB) |
| native 컨텍스트 | 128K (본 스택은 메모리 절약을 위해 4096으로 절삭) |
| 상주 메모리 | 약 2.5GB 이하 |
| 엔진 | `ghcr.io/ggml-org/llama.cpp:server-b10423` (amd64 / arm64 / s390x) |
| 언어 | 한국어 포함 16개 |

## 반드시 알아야 할 것: 이 모델은 "순수 추론 모델"이다

LFM2.5-2.6B 는 **답변 전에 항상 `<think>` 블록을 생성한다.** 끌 수 없다.
따라서 두 가지가 일반 모델과 다르다.

1. **응답 파싱** — 본 스택은 `LLAMA_ARG_THINK=deepseek` 으로 사고 과정을
   `message.reasoning_content` 로 분리하고, `message.content` 에는 최종 답변만 남긴다.
   기존 OpenAI 클라이언트를 그대로 붙여도 `<think>` 가 섞여 나오지 않는다.

2. **체감 지연** — tok/s 가 같아도 첫 답변까지 시간은 사고 토큰 수만큼 늘어난다.
   저사양 노드에서는 `.env` 의 `THINK_BUDGET` 으로 사고 길이를 제한한다.

   ```
   THINK_BUDGET=-1     무제한 (기본, 고사양 노드)
   THINK_BUDGET=256    256 토큰에서 사고 강제 종료 (RPi5 / A1 권장)
   THINK_BUDGET=0      사고 즉시 종료 (품질 저하 큼, 비권장)
   ```

### ⚠️ `max_tokens` 함정 — content 가 빈 문자열로 돌아온다

`max_tokens` 는 **사고 토큰까지 포함해서** 센다. 값이 작으면 사고만 하다가 예산이 끝나
`content` 가 빈 채로 `finish_reason: "length"` 가 돌아온다. 한국어 프롬프트로 실측한 결과:

| 요청 `max_tokens` | `finish_reason` | reasoning | **content** |
|---|---|---|---|
| 400 | `length` | 1083자 | **0자 (빈 응답)** |
| 1024 | `stop` | 1389자 | 182자 |
| 2048 | `stop` | 1721자 | 90자 |

**주의: 1024 는 안전한 하한이 아니다.** 프롬프트에 따라 사고량이 크게 달라진다.
`"라즈베리파이5 주의점 2가지만 짧게"` 라는 짧은 한국어 질문에서 사고가 1005 토큰을 넘겨
`max_tokens=1024` 로도 답변 델타가 **0개**였다. 같은 질문이 2048 에서는 정상 완결됐다.
질문이 짧다고 사고가 짧은 게 아니다.

해결책은 둘 중 하나다.

- **클라이언트**: `max_tokens` 를 **2048 이상**으로 주거나 아예 생략한다.
- **서버**: `THINK_BUDGET=256` 으로 사고를 잘라낸다. `max_tokens=400` 으로
  요청해도 `finish_reason: "stop"` 에 216자 답변이 정상적으로 나온다.
  (`THINK_BUDGET=384` 는 아직 부족해서 답변이 35자에서 잘렸다.)

**클라이언트의 `max_tokens` 를 통제할 수 없다면 서버 쪽 `THINK_BUDGET` 이 유일하게
확실한 방법이다.** 프롬프트마다 필요한 값이 달라 클라이언트 규약으로는 막을 수 없다.

## 하드웨어 프로파일

`.env.example` 하단의 `[A]~[E]` 블록 중 하나를 골라 파일 맨 아래 "현재 적용값"에 반영한다.

| 노드 | THREADS | CPUSET | LOAD_MODE | BIND_ADDR | 디코드 |
|---|---|---|---|---|---|
| [A] 노트북 Core Ultra 7 258V | 6 | — | none | 127.0.0.1 | **25.1 tok/s (실측)** |
| [B] 메인 PC 9950X3D | 12 | — | none | 127.0.0.1 | 미측정 |
| [C] RPi5 8GB | 3 | `0-2` | none | 0.0.0.0 | 미측정 (코어 3은 NPM 몫) |
| [D] Oracle A1 2 OCPU | 2 | — | none | 0.0.0.0 | 미측정 |
| [E] i5-10400F | — | — | — | — | 배포 지양 |

### 실측 (Core Ultra 7 258V / Q4_K_M / ctx 4096, 워밍업 후 3회 평균)

스레드 수 — **6이 최적이고 8은 오히려 느리다.** Lunar Lake 는 P코어 4 + LP-E코어 4 구성이라
스레드를 전부 채우면 느린 LP-E 코어가 배리어를 잡아 편차까지 커진다.

| THREADS | 3 | 4 | 6 | 8 |
|---|---|---|---|---|
| decode tok/s | 21.4 | 23.9 | **25.1** | 18.8 (편차 큼) |

로딩 모드 — 정상 상태 처리량은 셋 다 비슷하고, **차이는 첫 요청 지연과 상주 메모리에서 난다.**

| LOAD_MODE | decode | 상주 메모리 | 비고 |
|---|---|---|---|
| `none` | 27.1 tok/s | 1.70 GiB | **권장.** 적재 시 전량 RAM |
| `auto` (mmap) | 26.3 tok/s | 1.28 GiB | 첫 요청이 페이지폴트로 3 tok/s 수준까지 떨어짐 |
| `mmap+mlock` | 25.3 tok/s | 2.82 GiB | "2.5GB 미만" 목표를 깬다 |

> 콜드스타트 주의: `auto` 로 띄운 직후 첫 요청만 재보면 3 tok/s 가 나온다. 엔진이나
> 마운트 문제가 아니라 mmap 페이지 폴트다. 벤치마크는 반드시 워밍업 후에 측정한다.

`CPUSET` 이 실제 코어 격리를 수행한다. 값을 비우면 격리가 걸리지 않으므로,
RPi5 처럼 다른 서비스와 공존하는 노드에서는 반드시 지정한다.

```bash
# 격리 확인
docker exec lfm-api cat /sys/fs/cgroup/cpuset.cpus.effective
```

## 외부 노출 (RPi5 + Nginx Proxy Manager)

기본값은 `BIND_ADDR=127.0.0.1` 로 **루프백 전용**이다. 외부에 열 때만 아래를 수행한다.

1. `.env` 에서 `BIND_ADDR=0.0.0.0`
2. `.env` 에 `API_KEY=<충분히 긴 랜덤 문자열>` 설정 — **비워두면 무인증 공개다**
3. `ENDPOINT_SLOTS=0` 으로 내부 상태 노출 차단
4. NPM 에서 `ai.example.com → http://<rpi5-ip>:8080` 프록시 + Let's Encrypt TLS
5. 호출 시 `Authorization: Bearer <API_KEY>` 헤더 부착

```bash
curl https://ai.example.com/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"lfm2.5-2.6b","messages":[{"role":"user","content":"안녕"}]}'
```

키 없이 호출했을 때 401 이 나오는지 반드시 확인한다.

## 운영 명령어

```bash
docker compose up -d              # 기동
docker compose ps                 # (healthy) 확인
docker compose logs -f            # 실시간 로그
docker compose down               # 정지 + 컨테이너 삭제 (모델·설정은 남음)
docker stats lfm-api --no-stream  # 메모리·CPU
```

### 설정을 바꿨을 때

```bash
docker compose up -d --force-recreate
```

`.env` 값은 컨테이너 **생성 시점**에 구워지므로 기존 컨테이너에는 반영되지 않는다.
실측으로 확인한 동작:

| 명령 | `.env` 반영 | 실측 |
|---|---|---|
| `docker compose restart` | **안 됨** | `.env`를 `THREADS=2`로 바꿔도 컨테이너는 6 유지 |
| `docker compose stop`→`start` | **안 됨** | 위와 동일 |
| `docker compose up -d` | 됨 | 설정 변경을 감지해 자동 재생성 |
| **`up -d --force-recreate`** | **항상 됨** | 헷갈리면 이걸 쓴다 |

```bash
docker compose config                                  # .env 보간 결과 사전 확인
docker exec lfm-api sh -c 'echo $LLAMA_ARG_THREADS'    # 실제 주입값 확인
docker exec lfm-api cat /sys/fs/cgroup/cpuset.cpus.effective   # 코어 격리 확인
```

### 엔진 업그레이드

```bash
docker manifest inspect ghcr.io/ggml-org/llama.cpp:server-b<새빌드>
# .env 의 IMAGE_TAG 수정 후
docker compose pull && docker compose up -d --force-recreate
./scripts/test_api.sh
```

## 주의사항

- **이미지 네임스페이스**: `ghcr.io/ggerganov/llama.cpp` 는 더 이상 존재하지 않는다
  (`manifest unknown`). `ggml-org` 를 쓴다.
- **빌드 하한**: LFM2.5 GGUF 는 llama.cpp `b10262` 로 양자화되었다. 그보다 낮은 빌드는
  `unknown model architecture` 로 기동 실패한다. `IMAGE_TAG` 를 함부로 내리지 않는다.
- **`TEMP` 변수명 금지**: Docker Compose 는 셸 환경변수를 `.env` 보다 우선한다.
  Windows 의 `%TEMP%` 가 값을 덮어쓰므로 샘플링 변수는 `SAMPLING_` 접두사를 유지한다.
- **`--mlock` / `--mmap` 은 deprecated**. b10423 기준 `--load-mode` 로 통합되었다.
- 모델 파일은 `.gitignore` 로 제외되어 있다. 커밋하지 않는다.

## 디렉토리

```
lfm2.5-universal-stack/
├── docker-compose.yml       # 노드 무관 공통 정의. 수정하지 않는다
├── .env.example             # 하드웨어 프로파일 프리셋
├── models/                  # GGUF 마운트 대상 (read-only 로 컨테이너에 연결)
└── scripts/
    ├── download_model.sh / .ps1   # 다운로드 + size/sha256 검증
    ├── test_api.sh / .ps1         # health → 추론 → reasoning 분리 → tok/s → 메모리
    └── test_api.py                # 파이썬 클라이언트 예제 겸 검증 (표준 라이브러리만)
```

`test_api.py` 는 `openai` / `requests` 없이 동작한다. 연동 문제가 SDK 쪽인지 서버 쪽인지
가를 때 먼저 돌려본다.

```bash
python scripts/test_api.py                     # 단발 요청
python scripts/test_api.py --stream            # SSE 스트리밍
python scripts/test_api.py --max-tokens 2048 --prompt "질문"
```

## 트러블슈팅

| 증상 | 원인 / 조치 |
|---|---|
| `manifest unknown` | 이미지 네임스페이스가 `ggerganov` 로 되어 있음 → `ggml-org` |
| `unknown model architecture: lfm2` | `IMAGE_TAG` 가 b10262 미만 |
| 컨테이너가 계속 `starting` | 모델 로딩 중. `HEALTH_START_PERIOD` 를 늘린다 |
| `content` 에 `<think>` 가 섞임 | `REASONING_FORMAT=deepseek` 확인 |
| 첫 응답이 지나치게 느림 | 사고 토큰 때문. `THINK_BUDGET` 을 384 등으로 제한 |
| OOM / 컨테이너 재시작 반복 | `CTX_SIZE` 를 2048로, `PARALLEL_REQUESTS` 를 1로 |
| mlock 실패 로그 | `LOAD_MODE=none` 으로 되돌린다 (성능 손해 없음) |
| 첫 요청만 유난히 느림 | `LOAD_MODE=auto` 의 mmap 페이지폴트. `none` 으로 변경 |
| 스레드를 늘렸는데 느려짐 | P/E 코어 혼재 CPU 의 정상 현상. 위 실측표대로 낮춰서 재측정 |
