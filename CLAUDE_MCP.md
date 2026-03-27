# Rocqtui MCP Integration

Rocqtui is a terminal UI for the Rocq (Coq) proof assistant. It exposes an
MCP server over a Unix socket, allowing Claude Code to read proof state and
drive the editor programmatically.

## Connection

When rocqtui opens files, it creates a `.rocqtui-mcp.sock` symlink in the
project directory (the directory containing `_RocqProject` or `_CoqProject`).
The bridge script `rocqtui-mcp-bridge` connects stdio to this socket.

Configure in `.mcp.json`:
```json
{
  "mcpServers": {
    "rocqtui": {
      "command": "/home/jlottes/rocq/rocqtui/scripts/rocqtui-mcp-bridge"
    }
  }
}
```

## Resources

Read these with MCP resource reads to inspect current state.

| URI | Description |
|-----|-------------|
| `rocqtui://buffer` | Full file content (text/plain) |
| `rocqtui://goals` | Current proof goals (text/plain) |
| `rocqtui://messages` | Messages from Rocq (text/plain) |
| `rocqtui://cursor` | Cursor position as `{"line": N, "col": N}` (0-based) |
| `rocqtui://regions` | `{"verified_end": N, "target_end": N}` byte offsets |
| `rocqtui://sentences` | List of `{"start", "end", "status"}` for each sent sentence |
| `rocqtui://tabs` | Open tabs with `{"id", "index", "filename", "modified", "active"}` |

## Tools

All tools accept an optional `"tab"` parameter (integer tab ID) to target a
specific tab. If omitted, the active tab is used.

### Stepping

- **step_forward** — Advance the target by one Rocq sentence.
- **step_backward** — Retract the target by one sentence. May rewind Rocq.
- **go_to_end** — Set target to end of file and begin verifying everything.

### Editing

- **insert_text** `{offset, text}` — Insert text at a byte offset.
- **replace_range** `{start, end, text}` — Replace bytes `[start, end)` with text.
- **delete_range** `{start, end}` — Delete bytes `[start, end)`.
- **move_cursor** `{line, col}` — Move cursor to 0-based line and byte column.

### Querying Rocq

- **query** `{command, options?}` — Run a Rocq query (e.g. `"About nat."`,
  `"Print plus."`). Returns messages. Optional `options` object can set
  temporary printing options: `implicit`, `all`, `notations`, `coercions`,
  `universes`, `existential` (all booleans).
- **get_goals** `{options?}` — Get current goals with optional printing options
  (`implicit`, `all`, `notations`).

### Session Control

- **interrupt** — Send SIGINT to Rocq (cancel long computation).
- **is_busy** — Returns `"true"` or `"false"`. Check before reading goals
  after stepping — Rocq processes sentences asynchronously.
- **save** — Save the file.

### Tabs

- **switch_tab** `{tab}` — Switch to a tab by ID.
- **open_file** `{filename}` — Open a file in a new tab (or switch to it if
  already open). Returns the tab ID.

## Workflow Patterns

### Verify a file end-to-end
1. Call `go_to_end`.
2. Poll `is_busy` until it returns `"false"`.
3. Read `rocqtui://sentences` to check for errors.
4. Read `rocqtui://messages` for error details.

### Step through and inspect goals
1. Call `step_forward`.
2. Wait: poll `is_busy` until `"false"`.
3. Read `rocqtui://goals` to see the proof state.
4. Repeat.

### Edit and re-verify
1. Use `replace_range` or `insert_text` to modify the buffer.
   Edits past the verified region don't require rewinding.
   Edits within the verified region will automatically retract Rocq.
2. Call `go_to_end` to re-verify.
3. Poll `is_busy`, then check `rocqtui://sentences` for errors.

### Query with custom printing
```json
{"command": "Print Nat.add.", "options": {"all": true, "notations": false}}
```
This temporarily enables "Printing All" and disables notations for the query,
then restores the original settings.

## Important Notes

- **Byte offsets**: All offsets (`start`, `end`, `offset`) are byte positions
  in the UTF-8 buffer text, not character positions.
- **Async stepping**: After `step_forward` or `go_to_end`, Rocq processes
  sentences asynchronously. Always check `is_busy` before reading goals or
  assuming verification is complete.
- **Edits rewind**: If you edit text within the verified region, Rocq will
  retract to before the edit point. This is automatic.
- **Sentence boundaries**: Rocq sentences end with `.` followed by whitespace.
  When inserting tactics, include the trailing `.` and newline.
- **Resource notifications**: The server sends
  `notifications/resources/updated` when goals, regions, or messages change.

## Feedback

As you use rocqtui's MCP interface, pay attention to friction: tools that are
missing, information that requires too many round-trips to obtain, workflows
that feel clumsy, error messages that aren't helpful, etc. When you notice
something, append a short note to `mcp-feedback.md` in the project root. Use
this format:

```
## <date> — <short title>
<what you were trying to do, what was awkward, and what would help>
```

Don't duplicate entries that are already there. This file is read by the
rocqtui developers to prioritize MCP improvements.
