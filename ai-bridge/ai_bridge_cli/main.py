"""Fake-rocqtui CLI: talks to the bridge over its Unix socket.

Subcommands:
    scenario PATH          read a scenario JSON, send request, check expected
    file PATH --line N --col N [--history PATH]    build request from a real file
    watch                  read NDJSON requests from stdin, print responses
"""
from __future__ import annotations
import argparse
import asyncio
import json
import os
import sys
import time
import uuid
from typing import Any


def _default_socket() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(runtime, "rocqtui-ai-bridge.sock")


async def _send_recv(socket_path: str, request: dict[str, Any]) -> list[dict[str, Any]]:
    """Send one request to the bridge, return the full list of response lines."""
    reader, writer = await asyncio.open_unix_connection(socket_path)
    line = (json.dumps(request) + "\n").encode("utf-8")
    writer.write(line)
    await writer.drain()
    writer.write_eof()
    responses: list[dict[str, Any]] = []
    while True:
        raw = await reader.readline()
        if not raw:
            break
        s = raw.decode("utf-8").strip()
        if not s:
            continue
        try:
            responses.append(json.loads(s))
        except json.JSONDecodeError:
            print(f"  ! non-JSON line: {s!r}", file=sys.stderr)
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    return responses


async def _stream(socket_path: str, request: dict[str, Any]) -> None:
    """Like _send_recv but prints responses as they arrive."""
    reader, writer = await asyncio.open_unix_connection(socket_path)
    line = (json.dumps(request) + "\n").encode("utf-8")
    writer.write(line)
    await writer.drain()
    writer.write_eof()
    while True:
        raw = await reader.readline()
        if not raw:
            break
        s = raw.decode("utf-8").rstrip("\n")
        if s:
            print(s, flush=True)
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass


# ---- scenario subcommand ----

def _check_scenario(scenario: dict, responses: list[dict]) -> tuple[bool, list[str]]:
    reasons: list[str] = []
    expected = scenario.get("expected", {})
    kinds = [r["type"] for r in responses if r["type"] != "done"]

    expected_kind = expected.get("kind")  # "fim" | "edits" | "none" | "error"
    if expected_kind == "fim":
        fims = [r for r in responses if r["type"] == "fim"]
        if not fims:
            reasons.append("no fim response")
        else:
            want = expected.get("contains")
            if want and want not in fims[0].get("insertion", ""):
                reasons.append(f"insertion {fims[0]['insertion']!r} missing {want!r}")
    elif expected_kind == "edits":
        edits = [r for r in responses if r["type"] == "edit"]
        min_n = expected.get("min_changes")
        max_n = expected.get("max_changes")
        if min_n is not None and len(edits) < min_n:
            reasons.append(f"got {len(edits)} edits, expected ≥ {min_n}")
        if max_n is not None and len(edits) > max_n:
            reasons.append(f"got {len(edits)} edits, expected ≤ {max_n}")
        for want in expected.get("must_contain_each", []):
            if not any(want in e["change"]["replacement"] for e in edits):
                reasons.append(f"no edit replacement contains {want!r}")
    elif expected_kind == "none":
        non_done = [k for k in kinds if k not in ("done",)]
        if non_done:
            reasons.append(f"expected no suggestion, got {non_done}")
    elif expected_kind == "error":
        if not any(r["type"] == "error" for r in responses):
            reasons.append("expected error, got none")
    return (not reasons), reasons


async def _cmd_scenario(args) -> int:
    with open(args.path) as f:
        scenario = json.load(f)
    req = dict(scenario["request"])
    req.setdefault("req_id", f"scenario-{uuid.uuid4().hex[:8]}")

    t0 = time.perf_counter()
    responses = await _send_recv(args.socket, req)
    elapsed = time.perf_counter() - t0

    ok, reasons = _check_scenario(scenario, responses)
    badge = "✓ PASS" if ok else "✗ FAIL"
    print(f"{badge}  {scenario.get('id', args.path)}  ({elapsed*1000:.0f} ms)")
    if args.verbose or not ok:
        for r in responses:
            print(f"  → {json.dumps(r)}")
    for reason in reasons:
        print(f"  ! {reason}")
    return 0 if ok else 1


# ---- file subcommand ----

async def _cmd_file(args) -> int:
    with open(args.path) as f:
        buf = f.read()
    history: list[dict] = []
    if args.history:
        with open(args.history) as f:
            history = json.load(f)
    req = {
        "req_id": f"file-{uuid.uuid4().hex[:8]}",
        "kind": "suggest",
        "buffer": buf,
        "cursor": {"line": args.line, "col": args.col},
        "language": "rocq",
        "recent_edits": history,
    }
    await _stream(args.socket, req)
    return 0


# ---- watch subcommand ----

async def _cmd_watch(args) -> int:
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            req = json.loads(raw)
        except json.JSONDecodeError as e:
            print(json.dumps({"type": "error", "message": f"bad JSON: {e}"}))
            continue
        req.setdefault("req_id", f"watch-{uuid.uuid4().hex[:8]}")
        await _stream(args.socket, req)
    return 0


# ---- entry ----

def main() -> int:
    ap = argparse.ArgumentParser(prog="ai-bridge-cli")
    ap.add_argument("--socket", default=os.environ.get("AI_BRIDGE_SOCKET", _default_socket()))
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("scenario", help="run a scenario file")
    sp.add_argument("path")
    sp.add_argument("-v", "--verbose", action="store_true")
    sp.set_defaults(func=_cmd_scenario)

    fp = sub.add_parser("file", help="send a request built from a real .v file")
    fp.add_argument("path")
    fp.add_argument("--line", type=int, default=0)
    fp.add_argument("--col", type=int, default=0)
    fp.add_argument("--history", default=None)
    fp.set_defaults(func=_cmd_file)

    wp = sub.add_parser("watch", help="read NDJSON requests from stdin")
    wp.set_defaults(func=_cmd_watch)

    args = ap.parse_args()
    return asyncio.run(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
