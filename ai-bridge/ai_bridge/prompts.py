"""System prompts and user-message builders for the model."""
from __future__ import annotations

from .protocol import RecentEdit


EDIT_SYSTEM = """You are a code-editing assistant for the Rocq/Coq language. The user shows you a file and a list of recent edits they have just made. Propose the user's next intended edits to OTHER locations in the file by following the same pattern.

Output edits as Aider-style search/replace blocks, exactly this format:

<<<<<<< SEARCH
<exact text to find in the file>
=======
<replacement text>
>>>>>>> REPLACE

Rules:
- Multiple blocks allowed, one per intended edit.
- The SEARCH text must match the file exactly (whitespace included) and be unique.
- No commentary, no markdown fences, no prose outside blocks.
- Be conservative. If the pattern is unclear, or no further locations match, output nothing."""


def format_recent_edits(recent_edits: list[RecentEdit]) -> str:
    return "\n\n".join(
        f"Edit {i+1}:\nBEFORE:\n{e.before}\nAFTER:\n{e.after}"
        for i, e in enumerate(recent_edits)
    )


def build_edit_user_message(buffer: str, recent_edits: list[RecentEdit]) -> str:
    return (
        "File:\n```\n" + buffer + "\n```\n\n"
        "Recent edits I have made:\n" + format_recent_edits(recent_edits) +
        "\n\nPropose follow-up edits to OTHER locations in the file."
    )
