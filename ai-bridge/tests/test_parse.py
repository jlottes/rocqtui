from ai_bridge.parse import anchor, find_all_blocks, iter_new_blocks


SR_TEXT = """<<<<<<< SEARCH
foo
=======
bar
>>>>>>> REPLACE

<<<<<<< SEARCH
baz
=======
qux
>>>>>>> REPLACE
"""


def test_find_all_blocks_basic():
    blocks = find_all_blocks(SR_TEXT)
    assert blocks == [("foo", "bar"), ("baz", "qux")]


def test_iter_new_blocks_incremental():
    seen = 0
    out = list(iter_new_blocks(SR_TEXT, seen))
    assert len(out) == 2
    assert out[0] == (0, "foo", "bar")
    assert out[1] == (1, "baz", "qux")


def test_iter_new_blocks_skips_already_seen():
    out = list(iter_new_blocks(SR_TEXT, 1))
    assert out == [(1, "baz", "qux")]


def test_anchor_unique_match():
    buf = "line one\nfoo\nline three\n"
    change = anchor(buf, "foo", "FOO")
    assert change is not None
    assert change.replacement == "FOO"
    assert change.range.start_line == 1
    assert change.range.start_col == 0
    assert change.range.end_line == 1
    assert change.range.end_col == 3


def test_anchor_no_match_returns_none():
    buf = "line one\nfoo\n"
    assert anchor(buf, "missing", "x") is None


def test_anchor_non_unique_returns_none():
    """The safety guard — duplicate substrings shouldn't anchor."""
    buf = "foo bar\nfoo bar\n"
    assert anchor(buf, "foo bar", "x") is None


def test_anchor_empty_search_returns_none():
    assert anchor("hello", "", "x") is None
