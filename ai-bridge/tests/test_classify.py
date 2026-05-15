"""Tests for the classifier.

The model-based classifier itself needs a live llama-server; that's
covered by the e2e suite. These tests cover the input summarization
and output parsing — the parts that don't need a model in the loop.
"""
from unittest.mock import patch

from ai_bridge.classify import classify_with_model, _summarize_recent_edits
from ai_bridge.protocol import RecentEdit


def _edits(*pairs):
    return [RecentEdit(before=b, after=a) for b, a in pairs]


def test_summarize_empty():
    assert _summarize_recent_edits([]) == "(no recent edits)"


def test_summarize_shows_recent_first_eight():
    es = _edits(*[(f"b{i}", f"a{i}") for i in range(12)])
    summary = _summarize_recent_edits(es)
    # only first 8 (well, "first 8" of input; the bridge caps to 8
    # before reaching the classifier anyway)
    assert "b0" in summary
    assert "b7" in summary
    assert "b8" not in summary


def test_summarize_truncates_long_strings():
    long = "x" * 200
    es = _edits((long, "short"))
    summary = _summarize_recent_edits(es)
    assert "…" in summary
    assert "x" * 100 not in summary  # truncated below original length


def _mock_chat_stream(text):
    """Return a mock that yields the given text in one chunk."""
    def mock_stream(self, messages, max_tokens=8):
        yield text
    return mock_stream


def test_classify_fim_response():
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("FIM")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "fim"


def test_classify_edits_response():
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("EDITS")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "edits"


def test_classify_none_response():
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("NONE")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "none"


def test_classify_lowercase_response():
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("edits")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "edits"


def test_classify_noisy_response():
    """Model emitting a sentence still classifies."""
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("I think EDITS makes sense here.")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "edits"


def test_classify_none_takes_priority():
    """When both NONE and another word appear, NONE wins (cautious default)."""
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("NONE — but maybe EDITS")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "none"


def test_classify_unknown_response_defaults_to_fim():
    with patch("ai_bridge.classify.LlamaClient.chat_stream",
               _mock_chat_stream("???")):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "fim"


def test_classify_backend_error_falls_back_to_fim():
    from ai_bridge.protocol import BackendUnreachableError

    def raises(self, messages, max_tokens=8):
        raise BackendUnreachableError("nope")
        yield  # pragma: no cover

    with patch("ai_bridge.classify.LlamaClient.chat_stream", raises):
        assert classify_with_model("http://x:8080", "", 0, 0, []) == "fim"
