"""Parse Aider-style SEARCH/REPLACE blocks and anchor them into a buffer."""
from __future__ import annotations
import re
from typing import Iterator

from .protocol import EditChange, Range


SR_RE = re.compile(
    r"<<<<<<<\s*SEARCH\s*\n(.*?)\n=======\s*\n(.*?)\n>>>>>>>\s*REPLACE",
    re.DOTALL,
)


def find_all_blocks(text: str) -> list[tuple[str, str]]:
    """All complete SEARCH/REPLACE blocks in `text`, in order."""
    return SR_RE.findall(text)


def iter_new_blocks(text: str, already_seen: int) -> Iterator[tuple[int, str, str]]:
    """Yield (index, search, replace) for blocks whose index >= already_seen.
    Caller updates `already_seen` to the next index to consume."""
    matches = list(SR_RE.finditer(text))
    for i, m in enumerate(matches):
        if i >= already_seen:
            yield i, m.group(1), m.group(2)


def _offset_to_line_col(buf: str, off: int) -> tuple[int, int]:
    pre = buf[:off]
    line = pre.count("\n")
    last_nl = pre.rfind("\n")
    col = off - (last_nl + 1)
    return line, col


def anchor(buffer: str, search: str, replacement: str) -> EditChange | None:
    """Return an EditChange for replacing `search` in `buffer`, but
    only if `search` occurs exactly once. Otherwise None — that's the
    safety guard against hallucinated edits."""
    if not search:
        return None
    i = buffer.find(search)
    if i < 0:
        return None
    if buffer.find(search, i + 1) != -1:
        return None  # not unique
    s_line, s_col = _offset_to_line_col(buffer, i)
    e_line, e_col = _offset_to_line_col(buffer, i + len(search))
    return EditChange(
        range=Range(start_line=s_line, start_col=s_col,
                    end_line=e_line, end_col=e_col),
        replacement=replacement,
    )
