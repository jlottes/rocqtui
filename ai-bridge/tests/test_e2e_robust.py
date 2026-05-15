"""Robustness tests — cancellation and error paths.

Gated by AI_BRIDGE_E2E=1 (uses the live bridge fixture).
"""
from __future__ import annotations
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from ai_bridge_cli.main import _send_recv


pytestmark = pytest.mark.skipif(
    not os.environ.get("AI_BRIDGE_E2E"),
    reason="set AI_BRIDGE_E2E=1",
)


EDITS_REQ = {
    "kind": "suggest",
    "buffer": (
        "Definition foo (n : nat) : nat := n.\n"
        "Definition bar (b : bool) : bool := b.\n"
        "Definition baz (l : list nat) : list nat := l.\n"
        "Definition qux {X Y : Set} (p : nat * nat) : nat := fst p.\n"
        "Definition wibble {X Y : Set} (s : string) : string := s.\n"
        "Definition wobble {X Y : Set} (a : nat) (b : nat) : nat := a + b.\n"
        "Definition flub {X Y : Set} (l : list bool) : nat := length l.\n"
    ),
    "cursor": {"line": 0, "col": 0},
    "language": "rocq",
    "recent_edits": [
        {"before": "Definition foo {X Y : Set} (n : nat) : nat := n.",
         "after":  "Definition foo (n : nat) : nat := n."},
        {"before": "Definition bar {X Y : Set} (b : bool) : bool := b.",
         "after":  "Definition bar (b : bool) : bool := b."},
        {"before": "Definition baz {X Y : Set} (l : list nat) : list nat := l.",
         "after":  "Definition baz (l : list nat) : list nat := l."},
    ],
}


# ---- cancellation ----

async def _cancel_midstream(socket_path, request):
    reader, writer = await asyncio.open_unix_connection(socket_path)
    writer.write((json.dumps(request) + "\n").encode())
    await writer.drain()
    writer.write_eof()
    # Read one response line (could be edit or done), then bail.
    await reader.readline()
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass


def test_cancel_midstream_then_new_request_succeeds(bridge_socket):
    """Drop the client mid-stream; confirm the bridge still serves
    subsequent requests."""
    req = dict(EDITS_REQ, req_id="cancel-1")
    asyncio.run(_cancel_midstream(bridge_socket, req))

    req2 = dict(EDITS_REQ, req_id="cancel-2")
    responses = asyncio.run(_send_recv(bridge_socket, req2))
    edits = [r for r in responses if r["type"] == "edit"]
    done = [r for r in responses if r["type"] == "done"]
    assert done, "no done response on retry"
    assert edits, "subsequent request produced no edits"


def test_many_quick_cancels_dont_jam_bridge(bridge_socket):
    """Hammer the bridge with quick cancels to confirm no leakage."""
    for i in range(5):
        req = dict(EDITS_REQ, req_id=f"hammer-{i}")
        asyncio.run(_cancel_midstream(bridge_socket, req))
    # Bridge should still respond to a real request.
    req = dict(EDITS_REQ, req_id="hammer-final")
    responses = asyncio.run(_send_recv(bridge_socket, req))
    assert any(r["type"] == "done" for r in responses)


# ---- malformed requests ----

async def _send_raw(socket_path, payload_bytes):
    reader, writer = await asyncio.open_unix_connection(socket_path)
    writer.write(payload_bytes)
    await writer.drain()
    writer.write_eof()
    out = []
    while True:
        raw = await reader.readline()
        if not raw:
            break
        s = raw.decode().strip()
        if s:
            out.append(json.loads(s))
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    return out


def test_malformed_json_yields_bad_request_error(bridge_socket):
    responses = asyncio.run(_send_raw(bridge_socket, b"{ not valid json\n"))
    errs = [r for r in responses if r["type"] == "error"]
    dones = [r for r in responses if r["type"] == "done"]
    assert errs, f"expected error response, got {responses}"
    assert errs[0]["code"] == "bad_request"
    assert dones, "expected done sentinel after error"


def test_missing_field_yields_bad_request_error(bridge_socket):
    payload = json.dumps({"req_id": "x"}).encode() + b"\n"
    responses = asyncio.run(_send_raw(bridge_socket, payload))
    errs = [r for r in responses if r["type"] == "error"]
    assert errs, f"expected error response, got {responses}"
    assert errs[0]["code"] == "bad_request"


# ---- backend unreachable ----

def test_backend_unreachable_yields_clean_error(bridge_socket_no_backend):
    """Bridge pointed at a non-listening port should emit backend_unreachable."""
    req = dict(EDITS_REQ, req_id="no-backend")
    responses = asyncio.run(_send_recv(bridge_socket_no_backend, req))
    errs = [r for r in responses if r["type"] == "error"]
    assert errs, f"expected error response, got {responses}"
    assert errs[0]["code"] in ("backend_unreachable", "backend_error"), \
        f"unexpected error code: {errs[0]['code']}"
    assert any(r["type"] == "done" for r in responses)


# ---- file mode of fake client ----

def test_cli_file_mode_smoke(bridge_socket, tmp_path):
    """The `file` subcommand reads a .v file, sends a request, prints
    responses to stdout. Just check it runs without crashing and emits
    a done line."""
    v = tmp_path / "test.v"
    v.write_text("Definition compose {A B C : Type} (g : B -> C) (f : A -> B) : A -> C :=\n  fun x => ")
    result = subprocess.run(
        [sys.executable, "-m", "ai_bridge_cli.main",
         "--socket", bridge_socket,
         "file", str(v), "--line", "1", "--col", "10"],
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    lines = [json.loads(l) for l in result.stdout.strip().split("\n") if l.strip()]
    types = [l["type"] for l in lines]
    assert "done" in types, f"no done in {types}"
    # Either a fim suggestion or no suggestion is acceptable; we're
    # just verifying the plumbing works.


def test_cli_watch_mode_smoke(bridge_socket, tmp_path):
    """The `watch` subcommand reads NDJSON requests from stdin, prints
    NDJSON responses to stdout."""
    req = dict(EDITS_REQ, req_id="watch-smoke")
    result = subprocess.run(
        [sys.executable, "-m", "ai_bridge_cli.main",
         "--socket", bridge_socket, "watch"],
        input=json.dumps(req) + "\n",
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, f"stderr: {result.stderr}"
    lines = [json.loads(l) for l in result.stdout.strip().split("\n") if l.strip()]
    types = [l["type"] for l in lines]
    assert "done" in types, f"no done in {types}"
