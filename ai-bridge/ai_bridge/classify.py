"""Classify a request into a response shape.

When the request comes in with [shape="auto"], the server asks the
model itself which shape fits — a tiny one-token classification call.
The keystroke-granularity heuristic that lived here before got false-
positived too often; letting the model decide is more reliable.

The model is asked to reply with exactly one word: FIM, EDITS, or
NONE. We tolerate noisy outputs by substring-matching the answer.
"""
from __future__ import annotations
from typing import Literal

from .protocol import RecentEdit, BackendError, BackendUnreachableError
from .llama import LlamaClient


Kind = Literal["fim", "edits", "none"]


def _summarize_recent_edits(recent_edits: list[RecentEdit]) -> str:
    if not recent_edits:
        return "(no recent edits)"
    lines = []
    # Truncate each before/after to keep the prompt small. The
    # classifier only needs to see the shape of the edits, not their
    # full text.
    def short(s: str, n: int = 80) -> str:
        s = s.replace("\n", "\\n")
        return s if len(s) <= n else s[:n] + "…"
    for i, e in enumerate(recent_edits[:8], 1):
        lines.append(f"  {i}. BEFORE {short(e.before)!r}")
        lines.append(f"     AFTER  {short(e.after)!r}")
    return "\n".join(lines)


CLASSIFIER_SYSTEM = """You are a code-editing classifier for the Rocq/Coq language. Based on the user's recent edit history and cursor context, decide which kind of suggestion is most appropriate.

Reply with exactly ONE word, with no punctuation or explanation:
- FIM   — the user is typing fresh code at the cursor; suggest the immediate completion at that position
- EDITS — the user has just made a repeating refactor-style change and would benefit from propagating it to other locations in the file
- NONE  — neither applies; no useful suggestion

Bias toward NONE if the recent edits look like normal individual keystrokes (single characters, no repeated pattern). Bias toward EDITS only when you see at least two recent edits that share a clear pattern (same substring removed, same renaming, same keyword swap, etc.)."""


def classify_with_model(
    llama_url: str,
    buffer: str,
    cursor_line: int,
    cursor_col: int,
    recent_edits: list[RecentEdit],
    timeout: float = 5.0,
) -> Kind:
    """Ask the model which shape to produce. Falls back to a safe
    default ("fim") on backend trouble — the alternative is failing
    the request which feels worse from the user's perspective."""
    edits = _summarize_recent_edits(recent_edits)
    user_msg = (
        f"Recent edits (up to 8 most recent):\n{edits}\n\n"
        f"Cursor at line {cursor_line}, column {cursor_col}."
    )
    client = LlamaClient(llama_url, timeout=timeout)
    messages = [
        {"role": "system", "content": CLASSIFIER_SYSTEM},
        {"role": "user", "content": user_msg},
    ]
    try:
        text = ""
        for chunk in client.chat_stream(messages, max_tokens=8):
            text += chunk
            if len(text) > 32:
                break  # generous cap
    except (BackendError, BackendUnreachableError):
        return "fim"
    except Exception:
        return "fim"
    answer = text.strip().upper()
    # Substring match in priority order: NONE > EDITS > FIM. We
    # prefer NONE over the affirmative answers when the model's
    # output is ambiguous, since a missed suggestion is less harmful
    # than a spurious one.
    if "NONE" in answer:
        return "none"
    if "EDITS" in answer:
        return "edits"
    if "FIM" in answer:
        return "fim"
    return "fim"
