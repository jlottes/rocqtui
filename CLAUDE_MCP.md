# Rocqtui MCP

Terminal UI for Rocq (Coq). Drives proof state programmatically with
high-level tools designed for theorem proving.

## Resources

| URI | Description |
|-----|-------------|
| `rocqtui://proof_status` | Proof state snapshot (schema below) |
| `rocqtui://buffer` | Full file content |
| `rocqtui://tabs` | `[{"id", "index", "filename", "modified", "active"}]` |

Append `?tab=N` to target a specific tab. Default: active tab.

`proof_status` schema:
```jsonc
{
  "verified_end_line": 42,
  "last_sentence": "intros n.",
  "goals": "1 goal\n\nn : nat\n...",   // null if not in proof
  "context_before": "...",             // ~500 bytes of preceding sentences
  "context_after": "...",              // ~200 bytes of following sentences
  "messages": "..."                    // null if none
}
```

Context is cut at sentence boundaries. When inside a proof,
`context_before` always reaches back to the enclosing
Lemma/Theorem/Definition statement, even past 500 bytes.

## Tools

All tools accept optional `"tab"` (integer ID) and `"display"`. The
`display` block sets per-call printing options when rendering the goal
text (and, for `query`, the query's output). Omitted keys fall through
to the IDE's persistent toggles.

```jsonc
"display": {
  "implicit": true, "coercions": true, "notations": false,
  "all": true, "existential": true, "universes": true,
  "parens": true, "unfocused": true, "records": false,
  "matching": false, "synth": false, "goal_names": true,
  "projections": true, "compact_contexts": true, "evar_line": false
}
```

Tool responses (except `save`/`open_file`) include `proof_status` fields.

### Proving tools

#### `verify_to` — move the verified boundary

```jsonc
{ "before_text": "Proof.",   // text immediately before desired boundary
  "after_text": "...",        // optional disambiguator
  "line": 42 }                // optional: 1-based line hint
```

No args = beginning of file. Returns error listing line numbers if
`before_text` matches multiple locations. Whitespace in match args is
normalized.

Extra response: `error`, `failed_sentence`.

#### `proof_insert` — insert and verify new sentences

```jsonc
{ "text": "\n  intros n.\n  induction n." }
```

Inserts at the boundary, steps through to verify, deletes anything
that fails. **Invariant: only inserts verified text.**

Text must be complete sentences. A space is auto-prepended if needed
to prevent fusion with the preceding token.

Extra response: `verified_text`, `failed_sentence`, `error`.

#### `proof_forward` — verify existing buffer text

```jsonc
{ "sentences": "intros n." }   // must match buffer text after boundary
```

Steps through what's already in the buffer. Failed text is NOT deleted
(it was already there).

Extra response: `verified_text`, `failed_sentence`, `error`.

#### `proof_rewind` — retract verified sentences

```jsonc
{ "sentences": "apply foo.",   // must match tail of verified region
  "delete": true }             // default true; false = unverify but keep text
```

Extra response: `count`, `rewound_text`.

### Other tools

- `query({ "command": "About nat." })` — runs a Rocq query. Result in
  `messages`.
- `save()` — saves the file. Returns `{"ok": true}` or error.
- `open_file({ "filename": "/path" })` — open or switch.
  Returns `{"tab": <id>, "existed": <bool>}`.
- `build_deps()` — `rocq dep` then `make` for upstream `.vo`s. Use
  when imports fail.

## Workflows

**Prove a theorem:**
1. Read `buffer`, find the theorem.
2. `verify_to(before_text: "Lemma foo : ...\nProof.")`
3. `proof_insert` tactics, check `goals`, repeat. `proof_rewind` if
   stuck. `query` to explore.
4. `proof_insert("\nQed.")`, `save()`.

**Re-verify after upstream changes:**
1. `build_deps()`
2. `verify_to()` (beginning), then `verify_to(before_text: ...)` to
   advance.

## Notes

- Text matching in `verify_to`/`proof_forward`/`proof_rewind` collapses
  whitespace runs to a single space.
- Sentences end with `.` followed by whitespace/EOF, or are bullets
  (`-`, `+`, `*`) or braces (`{`, `}`).

## Feedback

Worked around a missing capability, or hit a tool error you couldn't
recover from? Append a dated note to `mcp-feedback.md` in the project
root describing what you wanted to do and what got in the way.
