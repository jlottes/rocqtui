"""End-to-end scenario tests.

Requires a running `llama-server` (URL from AI_BRIDGE_LLAMA_URL, default
http://127.0.0.1:8080). The bridge process is spawned by the conftest
fixture for the duration of the test session.

Gated by AI_BRIDGE_E2E=1 to keep `pytest` fast in the default case.

Invocation:
    AI_BRIDGE_E2E=1 pytest ai-bridge/tests/test_e2e.py
"""
from __future__ import annotations
import asyncio
import json
import os
from pathlib import Path

import pytest

from ai_bridge_cli.main import _check_scenario, _send_recv


pytestmark = pytest.mark.skipif(
    not os.environ.get("AI_BRIDGE_E2E"),
    reason="set AI_BRIDGE_E2E=1 (requires running llama-server)",
)


ROOT = Path(__file__).resolve().parent.parent
SCENARIO_FILES = sorted(str(p) for p in ROOT.glob("scenarios/**/*.json"))


@pytest.mark.parametrize("scenario_path", SCENARIO_FILES,
                         ids=lambda p: Path(p).stem)
def test_scenario(bridge_socket, scenario_path):
    with open(scenario_path) as f:
        scenario = json.load(f)
    req = dict(scenario["request"])
    req.setdefault("req_id", f"e2e-{Path(scenario_path).stem}")
    responses = asyncio.run(_send_recv(bridge_socket, req))
    ok, reasons = _check_scenario(scenario, responses)
    if not ok:
        print("\n  responses:")
        for r in responses:
            print(f"    {json.dumps(r)}")
    assert ok, f"{Path(scenario_path).name}: " + "; ".join(reasons)
