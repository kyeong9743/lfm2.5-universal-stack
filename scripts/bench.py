#!/usr/bin/env python3
"""
LFM2.5 속도 측정 스크립트.

노드끼리 같은 조건으로 비교하기 위해 사고 과정 길이에 영향을 받지 않는
/completion 엔드포인트를 쓰고, 출력 토큰 수를 고정한다(ignore_eos).
워밍업 1회 뒤 N회 측정해 평균을 낸다. 표준 라이브러리만 사용한다.

    python scripts/bench.py
    python scripts/bench.py --runs 5 --n-predict 512 --label <   >
"""
import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 프롬프트 처리 속도도 같이 보기 위해 적당한 길이의 고정 문장을 쓴다
PROMPT = (
    "Edge computing moves computation and data storage closer to the sources of data. "
    "This reduces latency, saves bandwidth, and keeps sensitive data on local devices. "
    "Small language models make it possible to run AI assistants on laptops, single board "
    "computers, and phones without sending every request to a remote server. "
    "Write a detailed explanation of the trade-offs of running language models on edge devices."
)


def load_env():
    conf = {}
    path = os.path.join(ROOT, ".env")
    if os.path.exists(path):
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                m = re.match(r"^\s*([A-Z_]+)\s*=\s*(.*?)\s*$", line)
                if m:
                    conf[m.group(1)] = m.group(2)
    return conf


def request(url, payload, api_key=None, timeout=600):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("Authorization", "Bearer " + api_key)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def docker_mem():
    try:
        out = subprocess.run(
            ["docker", "stats", "lfm-api", "--no-stream", "--format", "{{.MemUsage}}"],
            capture_output=True, text=True, timeout=30,
        )
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def docker_env(name):
    try:
        out = subprocess.run(
            ["docker", "exec", "lfm-api", "sh", "-c", "echo $" + name],
            capture_output=True, text=True, timeout=30,
        )
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3, help="측정 횟수 (워밍업 제외)")
    ap.add_argument("--n-predict", type=int, default=256, help="고정 출력 토큰 수")
    ap.add_argument("--label", default="", help="결과 파일 이름에 붙일 노드 이름")
    ap.add_argument("--no-save", action="store_true", help="benchmarks/ 에 저장하지 않는다")
    ap.add_argument("--wait", type=int, default=300, help="서버 준비를 기다릴 최대 시간(초)")
    args = ap.parse_args()

    conf = load_env()
    port = conf.get("PORT") or "8080"
    api_key = conf.get("API_KEY") or None
    base = "http://localhost:%s" % port

    # 컨테이너를 막 띄운 직후면 모델 로딩 중이라 연결이 끊긴다. 준비될 때까지 기다린다.
    print("서버 준비 대기 (최대 %ds)..." % args.wait)
    deadline = time.time() + args.wait
    last = "응답 없음"
    while True:
        try:
            with urllib.request.urlopen(base + "/health", timeout=10) as r:
                if json.load(r).get("status") == "ok":
                    break
        except Exception as e:  # URLError, RemoteDisconnected, 로딩 중 503 등
            last = e
        if time.time() > deadline:
            print("health 실패: %s" % last)
            print("컨테이너 상태 확인: docker compose ps / docker compose logs")
            return 1
        time.sleep(3)

    payload = {
        "prompt": PROMPT,
        "n_predict": args.n_predict,
        "ignore_eos": True,
        "cache_prompt": False,
        "temperature": 0.1,
    }

    threads = docker_env("LLAMA_ARG_THREADS")
    ngl = docker_env("LLAMA_ARG_N_GPU_LAYERS")
    print("서버      : %s" % base)
    print("THREADS   : %s" % (threads or "알 수 없음"))
    print("GPU 레이어: %s" % (ngl or "0 (CPU)"))
    print("출력 고정 : %d tokens / 측정 %d회 (워밍업 1회 제외)" % (args.n_predict, args.runs))

    print("\n워밍업...")
    request(base + "/completion", payload, api_key)

    results = []
    for i in range(args.runs):
        t0 = time.time()
        body = request(base + "/completion", payload, api_key)
        wall = time.time() - t0
        t = body.get("timings", {})
        row = {
            "prompt_n": t.get("prompt_n"),
            "prompt_tps": t.get("prompt_per_second"),
            "decode_n": t.get("predicted_n"),
            "decode_tps": t.get("predicted_per_second"),
            "wall_s": wall,
        }
        results.append(row)
        print("  %d회차  prompt %8.2f tok/s  decode %7.2f tok/s  (%.2fs)"
              % (i + 1, row["prompt_tps"], row["decode_tps"], wall))

    p = statistics.mean(r["prompt_tps"] for r in results)
    d = statistics.mean(r["decode_tps"] for r in results)
    d_sd = statistics.pstdev(r["decode_tps"] for r in results)
    mem = docker_mem()

    print("\n===== 평균 =====")
    print("prompt : %8.2f tok/s" % p)
    print("decode : %8.2f tok/s  (편차 %.2f)" % (d, d_sd))
    print("memory : %s" % (mem or "조회 실패"))

    if not args.no_save:
        os.makedirs(os.path.join(ROOT, "benchmarks"), exist_ok=True)
        name = "bench_%s%s.json" % (
            time.strftime("%Y%m%d_%H%M%S"), ("_" + args.label) if args.label else "")
        out = {
            "label": args.label,
            "host": platform.node(),
            "machine": platform.machine(),
            "threads": threads,
            "gpu_layers": ngl,
            "n_predict": args.n_predict,
            "runs": results,
            "avg_prompt_tps": p,
            "avg_decode_tps": d,
            "decode_stdev": d_sd,
            "memory": mem,
        }
        path = os.path.join(ROOT, "benchmarks", name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        print("저장    : %s" % os.path.relpath(path, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
