"""Decide which suggestion shape to produce for a given request.

Phase 0 measurements showed a trivial count-based heuristic gets
every scenario right, so no model classifier is involved.
"""
from __future__ import annotations
from typing import Literal

from .protocol import RecentEdit


Kind = Literal["fim", "edits"]


def classify(recent_edits: list[RecentEdit]) -> Kind:
    return "edits" if len(recent_edits) >= 2 else "fim"
