"""Shared fixtures for e2e tests."""
from __future__ import annotations
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest


_ROOT = Path(__file__).resolve().parent.parent


def _spawn_bridge(socket_path: str, llama_url: str):
    proc = subprocess.Popen(
        [sys.executable, "-m", "ai_bridge",
         "--socket", socket_path, "--llama-url", llama_url, "--log-level", "WARNING"],
        stderr=subprocess.PIPE,
    )
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if os.path.exists(socket_path):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(socket_path)
                s.close()
                return proc
            except OSError:
                pass
        time.sleep(0.05)
    proc.kill()
    out = proc.stderr.read().decode() if proc.stderr else ""
    raise RuntimeError(f"bridge didn't come up. stderr:\n{out}")


def _teardown_bridge(proc):
    proc.terminate()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


@pytest.fixture(scope="session")
def bridge_socket(tmp_path_factory):
    """Bridge pointed at a live llama-server."""
    sock = str(tmp_path_factory.mktemp("ai-bridge") / "bridge.sock")
    llama_url = os.environ.get("AI_BRIDGE_LLAMA_URL", "http://127.0.0.1:8080")

    import urllib.request
    try:
        with urllib.request.urlopen(llama_url + "/health", timeout=2) as r:
            assert r.status == 200
    except Exception as e:
        pytest.skip(f"llama-server not reachable at {llama_url}: {e}")

    proc = _spawn_bridge(sock, llama_url)
    yield sock
    _teardown_bridge(proc)


@pytest.fixture(scope="session")
def bridge_socket_no_backend(tmp_path_factory):
    """Bridge pointed at a port that's not listening — for testing the
    backend_unreachable error path."""
    sock = str(tmp_path_factory.mktemp("ai-bridge-noback") / "bridge.sock")
    # http://127.0.0.1:1 — port 1 should not have a listener
    proc = _spawn_bridge(sock, "http://127.0.0.1:1")
    yield sock
    _teardown_bridge(proc)
