"""Unix-socket NDJSON server.

One connection = one request + streamed responses + close. Cancellation
happens when the client closes its end of the socket; the bridge closes
the in-flight llama-server connection to abort the work.
"""
from __future__ import annotations
import asyncio
import json
import logging
import os

from . import classify as classify_mod
from . import parse as parse_mod
from . import prompts
from .llama import LlamaClient
from .protocol import (
    BackendError, BackendUnreachableError, BadRequestError, BridgeError,
    Request, done_response, edit_response, error_response, fim_response,
)


log = logging.getLogger("ai_bridge.server")

# Cap inside the bridge regardless of what rocqtui sends.
RECENT_EDITS_CAP = 8


class Bridge:
    def __init__(self, llama_url: str):
        self.llama_url = llama_url

    async def handle(self, reader: asyncio.StreamReader,
                     writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername") or "<unix>"
        req_id = "<unknown>"
        try:
            raw = await reader.read()  # client half-closes after writing
            if not raw:
                return
            try:
                payload = json.loads(raw.decode("utf-8"))
                req = Request.from_json(payload)
                req.recent_edits = req.recent_edits[-RECENT_EDITS_CAP:]
            except (json.JSONDecodeError, BadRequestError) as e:
                await self._write(writer, error_response(
                    req_id, f"malformed request: {e}", "bad_request"))
                return
            req_id = req.req_id
            log.info("req %s: kind=%s, recent_edits=%d, buffer_len=%d",
                     req_id, req.kind, len(req.recent_edits), len(req.buffer))
            await self._dispatch(req, writer)
        except asyncio.CancelledError:
            log.info("req %s: cancelled (peer %s)", req_id, peer)
            raise
        except Exception as e:
            log.exception("req %s: uncaught", req_id)
            try:
                await self._write(writer, error_response(req_id, str(e), "internal"))
            except Exception:
                pass
        finally:
            try:
                await self._write(writer, done_response(req_id))
            except Exception:
                pass
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _dispatch(self, req: Request, writer: asyncio.StreamWriter) -> None:
        if req.shape == "auto":
            kind = classify_mod.classify(req.recent_edits)
        else:
            kind = req.shape
        log.info("req %s: shape=%s (resolved=%s)", req.req_id, req.shape, kind)
        if kind == "fim":
            await self._handle_fim(req, writer)
        else:
            await self._handle_edits(req, writer)

    async def _handle_fim(self, req: Request, writer: asyncio.StreamWriter) -> None:
        offset = _line_col_to_offset(req.buffer, req.cursor.line, req.cursor.col)
        prefix = req.buffer[:offset]
        suffix = req.buffer[offset:]

        client = LlamaClient(self.llama_url)
        try:
            insertion = await asyncio.to_thread(client.infill, prefix, suffix)
        except asyncio.CancelledError:
            client.cancel_active()
            raise
        except BridgeError as e:
            await self._write(writer, error_response(req.req_id, str(e), e.code))
            return
        # Heuristic over-generation guard
        if "\n\n" in insertion:
            insertion = insertion.split("\n\n", 1)[0]
        if insertion.strip():
            log.info("req %s: fim insertion=%r", req.req_id, insertion)
            await self._write(writer, fim_response(req.req_id, insertion))
        else:
            log.info("req %s: fim no useful insertion (got %r)",
                     req.req_id, insertion)

    async def _handle_edits(self, req: Request, writer: asyncio.StreamWriter) -> None:
        messages = [
            {"role": "system", "content": prompts.EDIT_SYSTEM},
            {"role": "user",
             "content": prompts.build_edit_user_message(req.buffer, req.recent_edits)},
        ]
        client = LlamaClient(self.llama_url)
        queue: asyncio.Queue = asyncio.Queue()
        loop = asyncio.get_running_loop()

        def worker():
            try:
                for content in client.chat_stream(messages):
                    loop.call_soon_threadsafe(queue.put_nowait, ("data", content))
            except BridgeError as e:
                loop.call_soon_threadsafe(queue.put_nowait, ("err", e))
            except Exception as e:
                loop.call_soon_threadsafe(queue.put_nowait, ("err", BridgeError(str(e))))
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, ("end", None))

        thread_task = asyncio.create_task(asyncio.to_thread(worker))

        accumulated = ""
        seen = 0
        try:
            while True:
                kind, val = await queue.get()
                if kind == "end":
                    break
                if kind == "err":
                    err = val
                    code = getattr(err, "code", "internal")
                    await self._write(writer,
                        error_response(req.req_id, str(err), code))
                    break
                accumulated += val
                for i, search, replace in parse_mod.iter_new_blocks(accumulated, seen):
                    seen = i + 1
                    change = parse_mod.anchor(req.buffer, search, replace)
                    if change:
                        log.info("req %s: edit replace=%r at L%d:%d",
                                 req.req_id, change.replacement,
                                 change.range.start_line, change.range.start_col)
                        await self._write(writer,
                            edit_response(req.req_id, change))
                    else:
                        log.info("req %s: rejected block search=%r replace=%r",
                                 req.req_id, search, replace)
        except asyncio.CancelledError:
            client.cancel_active()
            raise
        finally:
            await thread_task

    async def _write(self, writer: asyncio.StreamWriter, resp) -> None:
        writer.write(resp.to_json_line().encode("utf-8"))
        await writer.drain()


def _line_col_to_offset(buf: str, line: int, col: int) -> int:
    """0-indexed line/col to byte offset. Falls back gracefully on out-of-range."""
    off = 0
    for _ in range(line):
        nl = buf.find("\n", off)
        if nl < 0:
            return len(buf)
        off = nl + 1
    line_end = buf.find("\n", off)
    if line_end < 0:
        line_end = len(buf)
    return min(off + col, line_end)


async def serve(socket_path: str, llama_url: str) -> None:
    bridge = Bridge(llama_url)
    # Remove stale socket
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    parent = os.path.dirname(socket_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    server = await asyncio.start_unix_server(bridge.handle, path=socket_path)
    # Tighten perms — user-only.
    os.chmod(socket_path, 0o600)
    log.info("listening on %s, llama at %s", socket_path, llama_url)
    async with server:
        await server.serve_forever()
