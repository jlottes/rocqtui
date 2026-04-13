# Rocqtui MCP Integration

Rocqtui is a terminal UI for the Rocq (Coq) proof assistant. It exposes an
MCP interface for Claude Code to read proof state and drive the editor
programmatically, with high-level tools designed for theorem proving.

## Connection

When rocqtui opens files, it creates a `.rocqtui-mcp.sock` symlink in the
project directory (the directory containing `_RocqProject` or `_CoqProject`).
The OCaml bridge binary connects stdio to this socket.

Configure in `.mcp.json`:
```json
{
  "mcpServers": {
    "rocqtui": {
      "command": "<path-to-rocqtui>/_build/default/bridge/rocqtui_mcp.exe"
    }
  }
}
```

## Resources

| URI | Description |
|-----|-------------|
| `rocqtui://proof_status` | Proof state snapshot (goals, context, verified position) — see below |
| `rocqtui://buffer` | Full file content (text/plain) |
| `rocqtui://tabs` | Open tabs: `[{"id", "index", "filename", "modified", "active"}]` |

Append `?tab=N` to any URI to target a specific tab by ID. If omitted,
the active tab is used.

### `proof_status`

Returns a JSON object with the current proof state:

```jsonc
{
  "verified_end_line": 42,           // 1-based line of verified boundary
  "last_sentence": "intros n.",      // last verified sentence (or null)
  "goals": "1 goal\n\nn : nat\n...", // formatted goals (or null if not in proof)
  "context_before": "...",           // complete sentences before boundary (~500 bytes)
  "context_after": "...",            // complete sentences after boundary (~200 bytes)
  "messages": "..."                  // Rocq messages (or null)
}
```

Context is cut at sentence boundaries — no partial sentences. When inside a
proof, `context_before` always extends back to include the theorem/lemma
statement (Lemma, Theorem, Instance, Definition, etc.) even if that exceeds
500 bytes.

## Tools

All tools are **synchronous** — they block until Rocq finishes processing
and return the result. No need to poll. All mutating tools lock the buffer
during execution (user edits are blocked until the tool completes).

All tools accept optional `"tab"` (integer tab ID) and `"display"` parameters.

### Display options

Optional on every tool. Controls how Rocq prints terms in goals, errors,
and messages.

```jsonc
{
  "display": {
    "implicit": true,    // Show implicit arguments
    "all": true,         // Show all low-level details
    "notations": false,  // Use notations
    "coercions": true,   // Show coercions
    "universes": true,   // Show universe levels
    "existential": true  // Show existential variable instances
  }
}
```

### Proving tools

These four tools cover the complete theorem proving workflow. Their
responses all include the common proof state fields (same as `proof_status`).

#### `verify_to` — Move the verified boundary

Position the verified boundary using text-based anchoring. No byte offsets.

```jsonc
{
  "before_text": "Proof.",    // text immediately before desired boundary
  "after_text": "...",        // optional: text after boundary (disambiguates)
  "line": 42                  // optional: 1-based line hint (disambiguates)
}
```

- If `before_text` matches multiple locations, returns an error listing
  line numbers of all matches. Use `line` or `after_text` to disambiguate.
- If no parameters given, goes to the beginning of the file (useful for
  re-verifying imports after a `build_deps`).
- Whitespace in `before_text` is normalized for matching.

**Additional response fields:** `error`, `failed_sentence` (if verification
failed en route to the target).

#### `proof_insert` — Insert and verify new sentences

Insert tactic/command sentences at the verified boundary. Anything that
fails to verify is automatically deleted.

```jsonc
{
  "text": "\n  intros n.\n  induction n."   // complete sentences to insert
}
```

- Text must contain complete sentences (ending with `.`). Rejects incomplete.
- A space is prepended automatically if needed to prevent sentence fusion.
- On partial failure: verified sentences are kept, the failed sentence and
  everything after it is deleted from the buffer.

**Key invariant:** after return, only verified text exists at/before the
boundary.

**Additional response fields:** `verified_text`, `failed_sentence`, `error`.

#### `proof_forward` — Verify existing buffer text

Verify sentences already in the buffer after the boundary. Text must match.

```jsonc
{
  "sentences": "intros n."   // must match buffer text after boundary
}
```

- On mismatch, returns error showing actual buffer content.
- On verification failure, text is NOT deleted (it was already there).

**Additional response fields:** `verified_text`, `failed_sentence`, `error`.

#### `proof_rewind` — Rewind verified sentences

Retract recently verified sentences, optionally deleting them.

```jsonc
{
  "sentences": "apply foo.",  // must match tail of verified region
  "delete": true              // default: true. false = keep text but unverify
}
```

- Text must match the end of the verified region (whitespace-normalized).
- On mismatch, returns error showing actual verified tail.

**Additional response fields:** `count`, `rewound_text`.

### Other tools

#### `query` — Run a Rocq query

```jsonc
{
  "command": "About nat."       // About, Print, Search, Check, Locate, etc.
}
```

Returns proof state with query results in `messages`.

#### `save` — Save the current file

Returns `{"ok": true}` or error.

#### `open_file` — Open or switch to a file

```jsonc
{
  "filename": "/path/to/file.v"
}
```

Returns `{"tab": <id>, "existed": <bool>}`.

#### `build_deps` — Build dependencies

Runs `rocq dep` to find `.vo` dependencies, then `make` to build them.
Use this when imports fail because upstream files have changed.

Typical workflow: `build_deps` → `verify_to()` (no args, go to beginning)
→ re-verify imports.

## Proving Workflow

### Prove a theorem

1. Read `buffer` to find the theorem.
2. `verify_to(before_text: "Lemma foo : ...\nProof.")` — position after Proof.
3. `proof_insert(text: "\n  intros n.")` — insert tactics.
4. Check `goals` in response. Insert more tactics.
5. If stuck: `proof_rewind(sentences: "bad_tactic.", delete: true)`, try again.
6. Use `query(command: "Search ...")` to explore.
7. Finish with `proof_insert(text: "\nQed.")`.
8. `save()`.

### Verify existing proof

1. `verify_to(before_text: "Proof.")` — position after Proof.
2. `proof_forward(sentences: "intros n. ...")` — verify existing text.
3. If it fails, `failed_sentence` tells you where.

### Rebuild and re-verify

1. `build_deps()` — rebuild upstream `.vo` files.
2. `verify_to()` — go to beginning.
3. `verify_to(before_text: "end of imports")` — re-verify.

## Important Notes

- **No byte offsets in the API.** All positioning is text-based.
- **Synchronous.** All tools block until completion. No polling needed.
- **Buffer locking.** Mutating tools lock the buffer — user cannot edit
  while Claude is working. Lock is released automatically when the tool
  returns, or if the bridge disconnects.
- **Sentence boundaries.** Rocq sentences end with `.` followed by whitespace
  or EOF. Bullets (`-`, `+`, `*`) and braces (`{`, `}`) are also sentences.
- **Whitespace normalization.** Text matching in `verify_to`, `proof_forward`,
  and `proof_rewind` normalizes whitespace (collapses runs to single space).
  `"intros  n."` matches `"intros n."`.
- **Context in proofs.** When inside a proof, `context_before` always includes
  the Lemma/Theorem statement, so you can always see what you're proving.

## Feedback

When you notice friction — missing tools, clumsy workflows, unhelpful
errors — append a note to `mcp-feedback.md` in the project root:

```
## <date> — <short title>
<what you were trying to do, what was awkward, and what would help>
```
