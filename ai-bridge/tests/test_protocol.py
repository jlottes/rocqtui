import json

from ai_bridge.protocol import (
    BadRequestError, EditChange, Range, Request, done_response,
    edit_response, error_response, fim_response,
)


def test_request_from_json_roundtrip():
    raw = {
        "req_id": "abc",
        "kind": "suggest",
        "buffer": "Definition x := 1.",
        "cursor": {"line": 0, "col": 5},
        "language": "rocq",
        "recent_edits": [{"before": "a", "after": "b"}],
    }
    req = Request.from_json(raw)
    assert req.req_id == "abc"
    assert req.cursor.line == 0
    assert req.cursor.col == 5
    assert len(req.recent_edits) == 1
    assert req.recent_edits[0].before == "a"


def test_request_from_json_missing_field_raises():
    try:
        Request.from_json({"req_id": "x"})
    except BadRequestError:
        pass
    else:
        raise AssertionError("expected BadRequestError")


def test_fim_response_serialization():
    line = fim_response("r1", "hello").to_json_line()
    obj = json.loads(line)
    assert obj == {"req_id": "r1", "type": "fim", "insertion": "hello"}


def test_edit_response_serialization():
    change = EditChange(
        range=Range(start_line=0, start_col=0, end_line=0, end_col=5),
        replacement="X",
    )
    line = edit_response("r1", change).to_json_line()
    obj = json.loads(line)
    assert obj["type"] == "edit"
    assert obj["change"]["replacement"] == "X"
    assert obj["change"]["range"]["start_line"] == 0


def test_error_response_serialization():
    line = error_response("r1", "boom", "backend_error").to_json_line()
    obj = json.loads(line)
    assert obj == {"req_id": "r1", "type": "error",
                   "message": "boom", "code": "backend_error"}


def test_done_response_serialization():
    line = done_response("r1").to_json_line()
    obj = json.loads(line)
    assert obj == {"req_id": "r1", "type": "done"}
