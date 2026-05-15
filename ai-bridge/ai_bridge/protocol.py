"""Wire-format types for the AI bridge.

The single source of truth for what crosses the Unix socket. See
docs/AI_BRIDGE_PROTOCOL.md for the v0 spec.
"""
from __future__ import annotations
from dataclasses import dataclass, field, asdict
from typing import Any, Literal


# ---- request ----

@dataclass
class Cursor:
    line: int
    col: int


@dataclass
class RecentEdit:
    before: str
    after: str


@dataclass
class Request:
    req_id: str
    buffer: str
    cursor: Cursor
    language: str = "rocq"
    kind: Literal["suggest"] = "suggest"
    recent_edits: list[RecentEdit] = field(default_factory=list)

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> Request:
        try:
            return cls(
                req_id=data["req_id"],
                kind=data.get("kind", "suggest"),
                buffer=data["buffer"],
                cursor=Cursor(**data["cursor"]),
                language=data.get("language", "rocq"),
                recent_edits=[RecentEdit(**e) for e in data.get("recent_edits", [])],
            )
        except (KeyError, TypeError) as e:
            raise BadRequestError(f"malformed request: {e}") from e


# ---- response ----

@dataclass
class Range:
    start_line: int
    start_col: int
    end_line: int
    end_col: int


@dataclass
class EditChange:
    range: Range
    replacement: str


@dataclass
class Response:
    """Serialized as a single NDJSON line."""
    req_id: str
    type: Literal["fim", "edit", "error", "done"]
    insertion: str | None = None        # fim
    change: EditChange | None = None    # edit
    message: str | None = None          # error
    code: str | None = None             # error

    def to_json_line(self) -> str:
        import json
        obj: dict[str, Any] = {"req_id": self.req_id, "type": self.type}
        if self.type == "fim":
            obj["insertion"] = self.insertion or ""
        elif self.type == "edit":
            assert self.change is not None
            obj["change"] = {
                "range": asdict(self.change.range),
                "replacement": self.change.replacement,
            }
        elif self.type == "error":
            obj["message"] = self.message or ""
            obj["code"] = self.code or "internal"
        return json.dumps(obj) + "\n"


def fim_response(req_id: str, insertion: str) -> Response:
    return Response(req_id=req_id, type="fim", insertion=insertion)


def edit_response(req_id: str, change: EditChange) -> Response:
    return Response(req_id=req_id, type="edit", change=change)


def error_response(req_id: str, message: str, code: str = "internal") -> Response:
    return Response(req_id=req_id, type="error", message=message, code=code)


def done_response(req_id: str) -> Response:
    return Response(req_id=req_id, type="done")


# ---- errors ----

class BridgeError(Exception):
    code: str = "internal"


class BackendUnreachableError(BridgeError):
    code = "backend_unreachable"


class BackendError(BridgeError):
    code = "backend_error"


class BadRequestError(BridgeError):
    code = "bad_request"
