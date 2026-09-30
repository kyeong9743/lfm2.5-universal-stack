#!/usr/bin/env python3
"""
LFM2.5 API 클라이언트 예제 겸 검증 스크립트.

표준 라이브러리만 사용한다(openai / requests 불필요). 어떤 파이썬 환경에서도
그대로 돌아가므로, 연동 문제가 SDK 쪽인지 서버 쪽인지 가르는 데 쓴다.

    python scripts/test_api.py
    python scripts/test_api.py --stream
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_env(path=None):
    """.env 에서 PORT / API_KEY 를 읽는다. 없으면 기본값."""
    conf = {}
    path = path or os.path.join(ROOT, ".env")
    if os.path.exists(path):
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                m = re.match(r"^\s*([A-Z_]+)\s*=\s*(.*?)\s*$", line)
                if m:
                    conf[m.group(1)] = m.group(2)
    return conf


def post(url, payload, api_key=None, stream=False, timeout=600):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("Authorization", "Bearer " + api_key)
    return urllib.request.urlopen(req, timeout=timeout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stream", action="store_true", help="SSE 스트리밍으로 받는다")
    ap.add_argument("--prompt", default="엣지 컴퓨팅을 한 문장으로 설명해줘.")
    # ★ 사고 토큰까지 max_tokens 에 포함되므로 작게 주면 content 가 빈다
    ap.add_argument("--max-tokens", type=int, default=2048)
    args = ap.parse_args()

    conf = load_env()
    port = conf.get("PORT") or "8080"
    api_key = conf.get("API_KEY") or None
    base = "http://localhost:%s" % port

    print("서버 : %s" % base)
    print("인증 : %s" % ("Bearer 사용" if api_key else "없음 (API_KEY 비어 있음)"))

    # --- health -------------------------------------------------------
    try:
        with urllib.request.urlopen(base + "/health", timeout=10) as r:
            print("health: %s" % json.load(r).get("status"))
    except urllib.error.URLError as e:
        print("health 실패: %s" % e)
        print("컨테이너가 떠 있는지 확인: docker compose ps")
        return 1

    payload = {
        "model": "lfm",
        "messages": [{"role": "user", "content": args.prompt}],
        "max_tokens": args.max_tokens,
        "stream": args.stream,
    }
    url = base + "/v1/chat/completions"
    t0 = time.time()

    try:
        resp = post(url, payload, api_key, stream=args.stream)
    except urllib.error.HTTPError as e:
        print("HTTP %s %s" % (e.code, e.reason))
        if e.code == 401:
            print(".env 의 API_KEY 와 요청 헤더가 일치하지 않는다.")
        return 1

    if args.stream:
        # 사고 델타가 전부 흐른 뒤 답변 델타가 온다
        n_reason = n_content = 0
        content = []
        for raw in resp:
            line = raw.decode("utf-8").strip()
            if not line.startswith("data: ") or "[DONE]" in line:
                continue
            delta = json.loads(line[6:])["choices"][0].get("delta", {})
            if delta.get("reasoning_content"):
                n_reason += 1
                if n_reason == 1:
                    print("\n[생각 중...]", end="", flush=True)
                elif n_reason % 50 == 0:
                    print(".", end="", flush=True)
            if delta.get("content"):
                if not n_content:
                    print("\n\n--- 답변 ---")
                n_content += 1
                content.append(delta["content"])
                print(delta["content"], end="", flush=True)
        print("\n\n사고 델타 %d개 / 답변 델타 %d개 / %.1fs"
              % (n_reason, n_content, time.time() - t0))
        return 0 if content else 1

    body = json.load(resp)
    choice = body["choices"][0]
    msg = choice["message"]
    content = msg.get("content") or ""
    reasoning = msg.get("reasoning_content") or ""
    timings = body.get("timings", {})

    print("\n--- content ---")
    print(content if content else "(빈 문자열)")
    print("\n--- reasoning_content (%d자) ---" % len(reasoning))
    print(reasoning[:200] + ("..." if len(reasoning) > 200 else ""))
    print("\nfinish_reason : %s" % choice.get("finish_reason"))
    print("decode        : %.2f tok/s" % timings.get("predicted_per_second", 0))
    print("wall          : %.2fs" % (time.time() - t0))

    ok = True
    if "<think>" in content:
        print("\n[FAIL] content 에 <think> 가 남아있다 → REASONING_FORMAT 확인")
        ok = False
    if not reasoning:
        print("\n[FAIL] reasoning_content 가 비어있다")
        ok = False
    if choice.get("finish_reason") == "length":
        print("\n[FAIL] 사고가 max_tokens 를 소진했다 → --max-tokens 를 올리거나 THINK_BUDGET=256")
        ok = False
    if not content:
        print("[FAIL] content 가 빈 문자열이다")
        ok = False
    print("\n===== %s =====" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
