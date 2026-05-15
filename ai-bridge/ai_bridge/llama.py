"""Synchronous HTTP client for llama-server.

Kept sync so it can be run in a thread from the asyncio server. The
active connection is tracked so the server can close it externally
to abort an in-flight request (i.e. when the rocqtui socket drops).
"""
from __future__ import annotations
import http.client
import json
import urllib.parse
from typing import Iterator

from .protocol import BackendError, BackendUnreachableError


class LlamaClient:
    def __init__(self, base_url: str = "http://127.0.0.1:8080",
                 timeout: float = 60.0):
        parsed = urllib.parse.urlparse(base_url)
        self.host = parsed.hostname or "127.0.0.1"
        self.port = parsed.port or 80
        self.timeout = timeout
        self._active: http.client.HTTPConnection | None = None

    def cancel_active(self) -> None:
        """Abort the in-flight request, if any. Safe to call from
        another thread — http.client doesn't formally support it but
        closing the underlying socket interrupts pending reads."""
        conn = self._active
        if conn is None:
            return
        try:
            conn.close()
        except Exception:
            pass

    def infill(self, prefix: str, suffix: str, n_predict: int = 80) -> str:
        body = {
            "input_prefix": prefix,
            "input_suffix": suffix,
            "n_predict": n_predict,
            "temperature": 0,
            "stream": False,
        }
        result = self._post_json("/infill", body)
        return result.get("content", "")

    def chat_stream(self, messages: list[dict],
                    max_tokens: int = 800) -> Iterator[str]:
        body = {
            "model": "local",
            "messages": messages,
            "temperature": 0,
            "max_tokens": max_tokens,
            "stream": True,
        }
        conn = self._connect()
        self._active = conn
        try:
            try:
                conn.request("POST", "/v1/chat/completions",
                             body=json.dumps(body),
                             headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
            except (ConnectionError, OSError, http.client.HTTPException) as e:
                raise BackendUnreachableError(str(e)) from e
            if resp.status != 200:
                raise BackendError(f"llama-server returned HTTP {resp.status}")
            for raw in resp:
                line = raw.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                choices = chunk.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                content = delta.get("content")
                if content:
                    yield content
        finally:
            self._active = None
            try:
                conn.close()
            except Exception:
                pass

    def _post_json(self, path: str, body: dict) -> dict:
        conn = self._connect()
        self._active = conn
        try:
            try:
                conn.request("POST", path, body=json.dumps(body),
                             headers={"Content-Type": "application/json"})
                resp = conn.getresponse()
            except (ConnectionError, OSError, http.client.HTTPException) as e:
                raise BackendUnreachableError(str(e)) from e
            if resp.status != 200:
                raise BackendError(f"llama-server returned HTTP {resp.status}")
            return json.loads(resp.read())
        finally:
            self._active = None
            try:
                conn.close()
            except Exception:
                pass

    def _connect(self) -> http.client.HTTPConnection:
        try:
            return http.client.HTTPConnection(self.host, self.port,
                                              timeout=self.timeout)
        except (ConnectionError, OSError) as e:
            raise BackendUnreachableError(str(e)) from e
