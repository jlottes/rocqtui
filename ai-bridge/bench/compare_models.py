"""Compare model variants on the bridge scenario corpus.

For each `--model LABEL:PATH[:DRAFT_PATH]` argument, this script:

  1. Starts an isolated `llama-server` with that model (and optional
     speculative-decoding draft).
  2. Starts an `ai-bridge` instance pointed at it.
  3. Runs every scenario in `scenarios/` through the bridge, capturing
     latency and pass/fail.
  4. Tears the stack down.

After all models are processed, prints a comparison table.

Usage:
    python -m bench.compare_models \\
        --model 1.5B:~/src/models/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf \\
        --model 3B:~/src/models/qwen2.5-coder-3b-instruct-q4_k_m.gguf \\
        --model 7B:~/src/models/qwen2.5-coder-7b-instruct-q4_k_m.gguf \\
        --model 7B+1.5B-draft:~/src/models/qwen2.5-coder-7b-instruct-q4_k_m.gguf:~/src/models/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf \\
        --llama-server ~/src/llama.cpp/build/bin/llama-server
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import shutil
import socket as sk
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

from ai_bridge_cli.main import _check_scenario, _send_recv


ROOT = Path(__file__).resolve().parent.parent


@dataclass
class ModelSpec:
    label: str
    model_path: str
    draft_path: str | None = None

    @classmethod
    def parse(cls, s: str) -> ModelSpec:
        parts = s.split(":", 2)
        if len(parts) < 2:
            raise ValueError(f"--model must be LABEL:PATH[:DRAFT]: {s!r}")
        label, model = parts[0], os.path.expanduser(parts[1])
        draft = os.path.expanduser(parts[2]) if len(parts) == 3 else None
        if not os.path.exists(model):
            raise ValueError(f"model not found: {model}")
        if draft and not os.path.exists(draft):
            raise ValueError(f"draft model not found: {draft}")
        return cls(label=label, model_path=model, draft_path=draft)


def _wait_for_http(url: str, deadline: float) -> bool:
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def _wait_for_socket(path: str, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if os.path.exists(path):
            try:
                s = sk.socket(sk.AF_UNIX, sk.SOCK_STREAM)
                s.connect(path)
                s.close()
                return True
            except OSError:
                pass
        time.sleep(0.1)
    return False


def _run_scenarios(socket_path: str) -> list[dict]:
    """Run every scenario through the bridge at `socket_path`. Returns
    a list of result dicts."""
    scenarios = sorted(ROOT.glob("scenarios/**/*.json"))
    results = []
    for s_path in scenarios:
        with open(s_path) as f:
            scenario = json.load(f)
        req = dict(scenario["request"])
        req.setdefault("req_id", f"bench-{s_path.stem}")
        t0 = time.perf_counter()
        try:
            responses = asyncio.run(_send_recv(socket_path, req))
            err = None
        except Exception as e:
            responses = []
            err = str(e)
        elapsed_ms = int((time.perf_counter() - t0) * 1000)
        ok, reasons = _check_scenario(scenario, responses)
        first_useful_ms = None
        # Approximation: we don't have inter-line timestamps from a
        # batched _send_recv, so report end-to-end only. A future
        # version could subscribe per-line for first-token latency.
        results.append({
            "id": scenario.get("id", s_path.stem),
            "pass": ok and not err,
            "elapsed_ms": elapsed_ms,
            "reasons": reasons + ([err] if err else []),
            "n_responses": len(responses),
        })
    return results


def _start_llama_server(llama_bin: str, spec: ModelSpec, port: int):
    args = [llama_bin, "-m", spec.model_path,
            "-ngl", "99", "--host", "127.0.0.1", "--port", str(port),
            "-c", "8192"]
    if spec.draft_path:
        args += ["--spec-draft-model", spec.draft_path]
    log = open(f"/tmp/bench-llama-{spec.label}.log", "w")
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    return proc, log


def _start_bridge(socket_path: str, llama_url: str):
    log = open("/tmp/bench-bridge.log", "w")
    proc = subprocess.Popen(
        [sys.executable, "-m", "ai_bridge",
         "--socket", socket_path, "--llama-url", llama_url,
         "--log-level", "WARNING"],
        stdout=log, stderr=subprocess.STDOUT,
    )
    return proc, log


def _kill(proc, log):
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    log.close()


def run_bench(specs: list[ModelSpec], llama_bin: str, port: int, sock: str) -> dict:
    all_results: dict[str, list[dict]] = {}
    for spec in specs:
        print(f"\n=== {spec.label} ===", flush=True)
        if os.path.exists(sock):
            os.unlink(sock)
        llama_proc, llama_log = _start_llama_server(llama_bin, spec, port)
        try:
            ready = _wait_for_http(f"http://127.0.0.1:{port}/health",
                                   time.monotonic() + 90)
            if not ready:
                print(f"  llama-server did not become healthy")
                continue
            bridge_proc, bridge_log = _start_bridge(sock, f"http://127.0.0.1:{port}")
            try:
                if not _wait_for_socket(sock, time.monotonic() + 10):
                    print(f"  bridge did not open socket")
                    continue
                print(f"  stack ready, running scenarios...", flush=True)
                results = _run_scenarios(sock)
                all_results[spec.label] = results
                pass_n = sum(1 for r in results if r["pass"])
                print(f"  {pass_n}/{len(results)} pass")
            finally:
                _kill(bridge_proc, bridge_log)
        finally:
            _kill(llama_proc, llama_log)
            if os.path.exists(sock):
                os.unlink(sock)
    return all_results


def print_table(all_results: dict[str, list[dict]]) -> None:
    if not all_results:
        return
    labels = list(all_results.keys())
    scenarios = [r["id"] for r in next(iter(all_results.values()))]
    width = max(len(s) for s in scenarios) + 2
    col = 16
    header = f"{'scenario':<{width}}" + "".join(f"{l:>{col}}" for l in labels)
    print(f"\n{header}")
    print("-" * len(header))
    for sid in scenarios:
        cells = []
        for l in labels:
            r = next(x for x in all_results[l] if x["id"] == sid)
            badge = "✓" if r["pass"] else "✗"
            cells.append(f"{badge} {r['elapsed_ms']:>5}ms".rjust(col))
        print(f"{sid:<{width}}" + "".join(cells))
    print()
    for l in labels:
        rs = all_results[l]
        passn = sum(r["pass"] for r in rs)
        med = sorted(r["elapsed_ms"] for r in rs)[len(rs)//2]
        print(f"  {l:>20}: {passn}/{len(rs)} pass | median {med}ms")


def main() -> int:
    ap = argparse.ArgumentParser(prog="bench.compare_models")
    ap.add_argument("--model", action="append", required=True,
                    type=ModelSpec.parse,
                    help="LABEL:PATH[:DRAFT_PATH]; repeatable")
    ap.add_argument("--llama-server", default=shutil.which("llama-server") or "",
                    help="path to llama-server binary")
    ap.add_argument("--port", type=int, default=18080,
                    help="TCP port for llama-server (use a free one)")
    ap.add_argument("--socket", default="/tmp/ai-bridge-bench.sock",
                    help="Unix socket path for bridge")
    ap.add_argument("--json", help="optional path to write raw results JSON")
    args = ap.parse_args()

    if not args.llama_server or not os.path.exists(args.llama_server):
        print(f"llama-server binary not found: {args.llama_server!r}", file=sys.stderr)
        return 2

    results = run_bench(args.model, args.llama_server, args.port, args.socket)
    print_table(results)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
