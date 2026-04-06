# MCP Proving Workflow — Design

The current MCP API exposes 22 low-level tools and 9 resources. For the
primary workflow — proving theorems — this is too many moving parts. Claude
must juggle `go_to_offset`, `step_forward`, `is_busy`, `replace_text`,
`get_goals`, `get_context`, error checking, etc. The Python bridge papers
over some of this with sync stepping and response enrichment, but the
fundamental workflow is still "assemble from primitives."

This document designs a focused, high-level API: **8 tools** and
**3 resources**, exposed through an **OCaml bridge** that replaces the
Python bridge.

---

## Architecture

```
Claude Code (stdio)
    │
    │  JSON-RPC 2.0
    │
┌───▼──────────────────────────────────┐
│  OCaml bridge  (bin/rocqtui_mcp.ml)  │
│                                      │
│  - Speaks MCP (stdio ↔ socket)       │
│  - Blocks freely (own process)       │
│  - Shares lib/ with rocqtui         │
│    (Sentence, Compose, etc.)         │
│  - Implements high-level tools by    │
│    orchestrating low-level ones      │
│  - Exposes curated tools + resources │
└───┬──────────────────────────────────┘
    │
    │  Unix domain socket
    │
┌───▼──────────────────────────────────┐
│  rocqtui MCP server (mcp_server.ml)  │
│                                      │
│  - Non-blocking (select loop)        │
│  - Low-level tools + resources       │
│  - Unchanged from current design     │
└──────────────────────────────────────┘
```

The bridge is a second dune binary linking the same `lib/` modules.
It can block on polling (`is_busy`), do sentence parsing, whitespace
normalization, and context extraction — all using shared OCaml code.
The TUI remains fully async and responsive.

---

## Common parameters

### Display options

Every tool and the `proof_status` resource accept an optional `display`
object that controls how Rocq prints terms in goals, errors, and messages.

```jsonc
{
  "display": {
    "implicit": false,   // Show implicit arguments
    "all": false,        // Show all low-level details
    "notations": true,   // Use notations
    "coercions": false,  // Show coercions
    "universes": false,  // Show universe levels
    "existential": false // Show existential variable instances
  }
}
```

### Tab

Every tool and resource accepts an optional `"tab": <int>` to target a
specific tab. If omitted, the active tab is used.

---

## Resources

### `proof_status`

Read-only snapshot of the current proof state. "Where am I?"

**URI:** `rocqtui://proof_status` (or `rocqtui://proof_status?tab=N`)

**Response:**

```jsonc
{
  // Line number (1-based) of the verified boundary.
  "verified_end_line": <int>,
  // Text of the last verified sentence (e.g. "Proof." or "intros n.").
  // null if nothing is verified.
  "last_sentence": "<text>" | null,
  // Current goal state. null if no goals (outside proof or proof complete).
  "goals": "<formatted goals>" | null,
  // Buffer text before the verified boundary, cut at sentence boundaries.
  // At least ~500 bytes of complete sentences. If there are active goals
  // (inside a proof), extended to always include the proof-introducing
  // sentence (Lemma, Theorem, etc.) and the Proof sentence.
  "context_before": "<text>",
  // Buffer text after the verified boundary, cut at sentence boundaries.
  // ~200 bytes of complete sentences.
  "context_after": "<text>",
  // Messages from Rocq (feedback, warnings, etc.). null if none.
  "messages": "<text>" | null
}
```

When inside a proof, `context_before` always extends back to include the
theorem/lemma statement, even if that's more than 500 bytes back. Claude
always sees: the thing being proved, tactics applied so far, and the
current goal state. Recognized proof-introducing commands: `Lemma`,
`Theorem`, `Corollary`, `Proposition`, `Property`, `Fact`, `Remark`,
`Example`, `Instance`, `Definition`, `Fixpoint`, `CoFixpoint`,
`Program`, `Let`.

Context is cut at sentence boundaries — no partial sentences.

### `buffer`

Full buffer text. Useful when Claude needs to see the whole file (e.g.
to find an anchor for `verify_to`, or to understand the file structure).

**URI:** `rocqtui://buffer` (or `rocqtui://buffer?tab=N`)

**Response:** Plain text, the full file contents.

### `tabs`

List of open tabs.

**URI:** `rocqtui://tabs`

**Response:**

```jsonc
[
  { "id": <int>, "index": <int>, "filename": "<path>",
    "modified": <bool>, "active": <bool> }
]
```

---

## Tools

All tools are synchronous — they block until the operation completes
(verified and target regions are synced) before returning. All tool
responses include the same core context fields as `proof_status`:

```jsonc
{
  "verified_end_line": <int>,
  "last_sentence": "<text>" | null,
  "goals": "<formatted goals>" | null,
  "context_before": "<text>",
  "context_after": "<text>",
  "messages": "<text>" | null
  // ... plus tool-specific fields
}
```

### `verify_to`

Move the verified boundary to a target position identified by text.
If no positioning parameters are given, rewinds to the beginning of the
file (verified boundary = 0). This is useful for re-verifying imports
after dependencies have been rebuilt.

**Parameters:**

```jsonc
{
  // Text immediately before the desired boundary. The boundary is placed
  // right after this text. If omitted (along with line), go to beginning.
  "before_text": "<text>",
  // Optional: text immediately after the boundary. Disambiguates.
  "after_text": "<text>",
  // Optional: 1-based line number hint to disambiguate. Can be used
  // alone (without before_text) to verify up through that line.
  "line": <int>,
  // display, tab (common; both optional)
}
```

**Additional response fields:**

```jsonc
{
  // Error if verification failed before reaching the target.
  "error": "<text>" | null,
  "failed_sentence": "<text>" | null
}
```

**Behavior:**

1. Search the buffer for `before_text` (whitespace-normalized).
2. If `after_text` is provided, require it immediately after.
3. If `line` is provided, require the match on or near that line.
4. **Zero matches:** error with message.
5. **Multiple matches:** error listing line numbers of all matches.
6. **One match:** snap boundary to the sentence ending at or just after
   the match position.
7. Wait until idle.
8. Return context.

**Matching:** whitespace is normalized (runs of `[ \t\n\r]+` collapsed
to single spaces) in both search text and buffer. Match position maps
back to original byte offsets.

### `proof_insert`

Insert new sentences right after the verified boundary, verify them,
and clean up anything that fails.

**Parameters:**

```jsonc
{
  // Text to insert. Must contain one or more complete sentences.
  "text": "<text>",
  // display, tab (common; both optional)
}
```

**Additional response fields:**

```jsonc
{
  // Text that was successfully verified and kept in the buffer.
  // Empty string if nothing verified.
  "verified_text": "<text>",
  "failed_sentence": "<text>" | null,
  "error": "<text>" | null
}
```

**Behavior:**

1. **Validate input.** Parse `text` with `Sentence.split`. Reject if:
   - No complete sentences.
   - Trailing text after the last sentence boundary (incomplete sentence).
   The error reports what was parsed and what was left over.
2. **Ensure separation.** If the character before `verified_end` is not
   whitespace and `text` does not start with whitespace, prepend a single
   space. This prevents fusing with the previous sentence (e.g.
   `"intros."` + `"apply H."` → `"intros.apply H."` without the space).
   Claude can provide its own leading whitespace for formatting; the
   implicit space is only a safety fallback.
3. Record `old_verified_end`.
4. Insert the (possibly space-prefixed) text at `verified_end`.
5. Set target to end of inserted text.
6. Wait until idle.
7. Results:
   - **All verified:** `verified_text` = full inserted text.
   - **Partial:** `verified_text` = verified portion; `failed_sentence`
     and `error` set. Unverified text deleted from buffer.
   - **Total failure:** `verified_text` = `""`. All inserted text
     deleted. Boundary returns to `old_verified_end`.
8. Return context.

**Key invariant:** after return, the buffer contains only verified text
at and before the verified boundary.

**Sentence boundary safety:** validation (step 1) ensures complete
sentences; separation (step 2) prevents fusion with prior text.

### `proof_forward`

Verify existing sentences in the buffer immediately after the verified
boundary. The provided text must match what's already there.

**Parameters:**

```jsonc
{
  // Text of the sentences to verify. Must match buffer content
  // immediately after the verified boundary (whitespace-normalized).
  "sentences": "<text>",
  // display, tab (common; both optional)
}
```

**Additional response fields:**

```jsonc
{
  "verified_text": "<text>",
  "failed_sentence": "<text>" | null,
  "error": "<text>" | null
}
```

**Behavior:**

1. Match `sentences` against buffer text after `verified_end`
   (whitespace-normalized). On mismatch, error showing actual buffer
   content (~200 bytes, sentence-aligned).
2. Set target to end of matched region.
3. Wait until idle.
4. On error, failed sentences are **not deleted** (they were already in
   the buffer). Boundary stops at last successful sentence.
5. Return context.

### `proof_rewind`

Rewind recently verified sentences. The provided text must match the
tail of the verified region.

**Parameters:**

```jsonc
{
  // Text of the sentences to rewind. Must match the tail of the
  // verified region (whitespace-normalized).
  "sentences": "<text>",
  // Whether to delete the rewound text. Default: true.
  "delete": true | false,
  // display, tab (common; both optional)
}
```

**Additional response fields:**

```jsonc
{
  "count": <int>,          // Number of sentences rewound
  "rewound_text": "<text>" // Text that was rewound (and optionally deleted)
}
```

**Behavior:**

1. Match `sentences` against tail of verified region (whitespace-
   normalized). On mismatch, error showing actual tail (~200 bytes,
   sentence-aligned).
2. Rewind boundary to before matched region.
3. Wait until idle.
4. If `delete` is true, delete matched text from buffer.
5. Return context.

### `query`

Run a Rocq query (About, Print, Search, Check, Locate, etc.).

**Parameters:**

```jsonc
{
  "command": "<text>",  // e.g. "About nat.", "Search (_ + _ = _)."
  // display, tab (common; both optional)
}
```

**Response:** Common context fields (goals and context are unchanged;
`messages` contains the query result).

### `save`

Save the current file to disk.

**Parameters:**

```jsonc
{
  // tab (optional)
}
```

**Response:** `{ "ok": true }` or error.

### `open_file`

Open a file (or switch to it if already open).

**Parameters:**

```jsonc
{
  "filename": "<path>"
}
```

**Response:**

```jsonc
{
  "tab": <int>,        // Tab index
  "existed": <bool>    // Whether the tab was already open
}
```

### `build_deps`

Build the dependencies of the current file. Runs `rocq dep` to discover
`.vo` dependencies, then `make` to build them. Blocks until the build
completes.

This is essential when imports fail because upstream files have changed.
Typical workflow: `build_deps` → `verify_to()` (go to beginning) →
re-verify imports.

**Parameters:**

```jsonc
{
  // tab (optional — determines which file's deps to build)
}
```

**Response:**

```jsonc
{
  "ok": <bool>,        // Whether the build succeeded (exit code 0)
  "exit_code": <int>,  // Make exit code
  "output": "<text>"   // Build output (stdout + stderr)
}
```

---

## Typical proving session

```
Claude                                    Bridge → rocqtui
  │                                         │
  ├─ read proof_status                      │
  │  ──────────────────────────────────►    │ (read-only)
  │  ◄──────────────────────────────────    │ context + goals
  │                                         │
  ├─ read buffer                            │
  │  ──────────────────────────────────►    │ (full file)
  │  ◄──────────────────────────────────    │ find the lemma to prove
  │                                         │
  ├─ verify_to(                             │
  │    before_text:"Lemma foo : ...\nProof.")│
  │  ──────────────────────────────────►    │ go_to_offset + poll is_busy
  │  ◄──────────────────────────────────    │ goals + context
  │                                         │
  ├─ proof_insert(text:"\n  intros n.")     │
  │  ──────────────────────────────────►    │ insert + verify + poll
  │  ◄──────────────────────────────────    │ verified_text, goals
  │                                         │
  ├─ proof_insert(text:"\n  induction n.")  │
  │  ──────────────────────────────────►    │ insert + verify + poll
  │  ◄──────────────────────────────────    │ verified_text, goals (2 subgoals)
  │                                         │
  ├─ proof_insert(text:"\n  - simpl.\n    reflexivity.")
  │  ──────────────────────────────────►    │ insert + verify + poll
  │  ◄──────────────────────────────────    │ error at reflexivity
  │                                         │ (simpl verified, reflexivity
  │                                         │  failed and was deleted)
  │                                         │
  ├─ proof_rewind(                          │
  │    sentences:"simpl.", delete:true)      │
  │  ──────────────────────────────────►    │ rewind + delete + poll
  │  ◄──────────────────────────────────    │ back to after "induction n."
  │                                         │
  ├─ query(command:"Search (_ + 0 = _).")   │
  │  ──────────────────────────────────►    │ query
  │  ◄──────────────────────────────────    │ search results in messages
  │                                         │
  ├─ proof_insert(text:"\n  - auto.")       │
  │  ──────────────────────────────────►    │ insert + verify ✓
  │  ◄──────────────────────────────────    │ subgoal 1 done
  │                                         │
  │  ... continues until Qed. ...           │
  │                                         │
  ├─ save()                                 │
  │  ──────────────────────────────────►    │ save
  │  ◄──────────────────────────────────    │ ok
```

---

## Implementation notes

### Low-level API (rocqtui → bridge)

The low-level MCP server in `mcp_server.ml` is refactored to expose a
**minimal set** of primitives. The bridge is the only client.

#### Low-level tools

| Tool | Parameters | Purpose |
|------|-----------|---------|
| `go_to_offset` | `offset` | Set verification target (forward or backward) |
| `insert_text` | `offset`, `text` | Insert text at byte offset |
| `delete_range` | `start`, `end` | Delete byte range |
| `query` | `command`, `options?` | Run Rocq query |
| `save` | | Save current file |
| `open_file` | `filename` | Open/switch file |
| `lock` | | Lock buffer (prevent user edits on this tab) |
| `unlock` | | Unlock buffer |
| `build_deps` | | Start building dependencies (async) |
| `interrupt` | | Send SIGINT to rocqtop |

No `is_busy`, `step_forward`, `step_backward`, etc. — see `get_state`.

#### Low-level resource: `get_state`

A single batched state read that returns everything in one round-trip:

```jsonc
{
  "buffer": "<full text>",
  "verified_end": <int>,         // byte offset
  "target_end": <int>,           // byte offset
  "is_busy": <bool>,
  "goals": "<formatted>" | null,
  "messages": ["<line>", ...],
  "error": { "start": <int>, "end": <int>, "message": "<text>" } | null,
  "sentences": [
    { "start": <int>, "end": <int>, "status": "<verified|processing|error:...>" }
  ],
  "locked": <bool>
}
```

The bridge polls this (via `is_busy` field) instead of a separate
`is_busy` tool. One socket round-trip gives the bridge everything it
needs to compute context, check errors, and assemble responses.

#### `tabs` resource

Remains as a separate resource: `rocqtui://tabs`.

### Buffer locking

- `lock` marks the active tab as locked. User keystrokes that would
  modify the buffer are ignored. Status bar shows a lock indicator +
  animated spinner.
- `unlock` releases the lock.
- **Auto-unlock on disconnect:** if the bridge's socket closes (crash,
  timeout, etc.), all locks held by that client are released.
- **Per-tab:** locking is per-tab. User can switch tabs and edit other
  files while Claude works on a locked tab.
- **Per-client:** the lock tracks which client holds it. Only that
  client can unlock or edit the locked buffer.

### OCaml bridge (bin/rocqtui_mcp.ml)

A second dune binary linking against the same `lib/` modules:

```
(executable
 (name rocqtui_mcp)
 (libraries rocqtui_lib yojson ...))
```

The bridge:
- Reads JSON-RPC from stdin, writes to stdout (MCP protocol).
- Connects to rocqtui via Unix socket (discovered via `.rocqtui-mcp.sock`
  symlink, same as current bridge).
- Implements high-level tools by orchestrating low-level calls.
- Shares `Sentence`, whitespace normalization, and context extraction
  code with rocqtui via `lib/`.

### Shared library code (lib/)

**Context extraction** — sentence-aligned context windows:
- Scan backward from `verified_end` through sentence boundaries until
  ~500 bytes accumulated.
- If goals are active, extend back to the proof-introducing sentence.
- Scan forward for ~200 bytes.
- Return complete sentences only.

**Text matching** — whitespace-normalized matching:
- Collapse runs of `[ \t\n\r]+` to single spaces in both search and buffer.
- Literal substring search on normalized forms.
- Map matches back to original byte offsets.
- For ambiguity reporting, compute 1-based line numbers of all matches.

### Blocking model

The bridge blocks freely — it's a separate process. Typical flow for a
mutating tool call:

1. Receive JSON-RPC request from stdin.
2. Send `lock` to rocqtui.
3. Send low-level tool call(s) (insert, go_to_offset, etc.).
4. Poll `get_state` every 50ms until `is_busy` is false (60s timeout).
5. Inspect state, compute context, assemble response.
6. If cleanup needed (delete failed text), send more tool calls.
7. Send `unlock`.
8. Write JSON-RPC response to stdout.

The TUI remains fully async and responsive throughout.
