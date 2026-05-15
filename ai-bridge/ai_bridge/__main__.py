"""`python -m ai_bridge` entry point."""
from __future__ import annotations
import argparse
import asyncio
import logging
import os
import sys

from .server import serve


def _default_socket() -> str:
    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(runtime, "rocqtui-ai-bridge.sock")


def main() -> int:
    ap = argparse.ArgumentParser(prog="ai-bridge")
    ap.add_argument("--socket", default=os.environ.get("AI_BRIDGE_SOCKET", _default_socket()),
                    help="Unix socket path (env AI_BRIDGE_SOCKET)")
    ap.add_argument("--llama-url",
                    default=os.environ.get("AI_BRIDGE_LLAMA_URL", "http://127.0.0.1:8080"),
                    help="llama-server base URL (env AI_BRIDGE_LLAMA_URL)")
    ap.add_argument("--log-level", default=os.environ.get("AI_BRIDGE_LOG_LEVEL", "INFO"),
                    help="logging level (env AI_BRIDGE_LOG_LEVEL)")
    args = ap.parse_args()

    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
        stream=sys.stderr,
    )
    try:
        asyncio.run(serve(args.socket, args.llama_url))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
