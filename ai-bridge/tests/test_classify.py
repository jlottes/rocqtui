from ai_bridge.classify import classify
from ai_bridge.protocol import RecentEdit


def _edits(n: int) -> list[RecentEdit]:
    return [RecentEdit(before=f"x{i}", after=f"y{i}") for i in range(n)]


def test_empty_recent_edits_yields_fim():
    assert classify([]) == "fim"


def test_one_recent_edit_yields_fim():
    assert classify(_edits(1)) == "fim"


def test_two_recent_edits_yields_edits():
    assert classify(_edits(2)) == "edits"


def test_many_recent_edits_yields_edits():
    assert classify(_edits(8)) == "edits"
