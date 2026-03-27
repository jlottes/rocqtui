# Integrating Claude Code with Rocqtui — Brainstorming

## Vision

Claude assists the user in writing Rocq proofs interactively, with
awareness of the proof state, goals, hypotheses, and the full file context.

## How RocqIDE's interaction model maps to AI assistance

RocqIDE (and rocqtui) provides a tight feedback loop:
1. User writes a tactic or command
2. Steps forward → sees goal state change
3. Adjusts and iterates

Claude could participate at multiple levels:

### Level 1: Query assistant
- User selects a term or identifier, asks Claude to explain it
- Claude sees the goal state, hypotheses, and surrounding context
- "What does this lemma do?" / "Why isn't this unifying?"
- Minimal integration: send context to Claude API, show response in messages pane

### Level 2: Tactic suggestion
- User is stuck on a goal
- Claude sees the current goal + hypotheses + file context
- Suggests one or more tactics to try
- User can accept/reject each suggestion
- Could show suggestions inline or in a dedicated pane

### Level 3: Proof search / auto-pilot
- User specifies a lemma statement
- Claude attempts to prove it, stepping forward one tactic at a time
- Uses rocqtop feedback to verify each step
- User can interrupt, edit, and resume
- MCP (Model Context Protocol) for tool use: Claude calls `rocq_step`,
  `rocq_query`, etc.

### Level 4: Proof refactoring
- Claude rewrites proof scripts (e.g., simplify, use different tactics)
- Verifies the new proof via rocqtop
- User reviews the diff

## Integration architecture options

### Option A: Claude Code as external process
- rocqtui communicates with Claude Code CLI via pipes
- Claude Code uses MCP tools to interact with rocqtop
- rocqtui provides a "chat pane" for interaction
- Pro: leverages existing Claude Code infrastructure
- Con: another process, IPC complexity

### Option B: Direct API integration
- rocqtui calls the Anthropic API directly (via HTTP)
- Sends goal state, file context as system/user messages
- Tool use for rocq_step, rocq_query, etc.
- Pro: tighter integration, lower latency
- Con: need to implement API client in OCaml, manage auth

### Option C: MCP server in rocqtui
- rocqtui exposes an MCP server that Claude Code connects to
- Tools: `open_file`, `get_goals`, `step_forward`, `insert_tactic`, etc.
- Claude Code drives the interaction
- Pro: Claude Code already supports MCP
- Con: rocqtui becomes a server as well as a TUI

### Option D: Hybrid — MCP tools + embedded chat
- rocqtui has a chat pane (like a split messages pane)
- User types natural language in the chat pane
- rocqtui sends it to Claude API with context (goals, buffer, etc.)
- Claude responds with tactics/explanations
- User can "accept" suggested tactics → inserted into buffer

## Context to send to Claude

For any approach, Claude needs:
- **Current goal state** (from goals pane)
- **Current file content** (or relevant portion)
- **Cursor position** / verified region boundary
- **Error messages** (if stuck)
- **Available lemmas/definitions** (via Search/About)
- **Project structure** (imports, dependencies)

### Context window considerations
- Rocq files can be large; send relevant portion around cursor
- Goal state is usually small
- Imports/dependencies could be summarized
- Previous interaction history (what was tried, what failed)

## MCP tools for Rocq (already exist?)

The system has `rocq-mcp` and `rocq-lsp-mcp` tools available:
- `rocq_step`, `rocq_step_multi` — step through proofs
- `rocq_query` — run queries
- `rocq_verify` — verify a file
- `rocq_compile` — compile
- `rocq_auto_solve` — attempt auto-solving
- `rocq_toc` — table of contents
- `rocq_notations` — list notations
- `rocq-lsp-mcp`: `open_file`, `get_buffer`, `get_diagnostics`,
  `goals_at`, `insert_tactic`, `undo`

These could potentially be reused or adapted.

## UI ideas for rocqtui

### Chat pane
- New pane (maybe below messages, or togglable)
- User types a question or request
- Claude's response appears in the pane
- Suggested tactics are highlighted / clickable

### Inline suggestions
- Ghost text (dimmed) showing suggested next tactic
- Tab to accept, Escape to dismiss
- Like GitHub Copilot but for proof tactics

### Proof attempt mode
- User writes `Lemma foo : ...` and positions cursor after `Proof.`
- Presses a key (^L?) to start AI proof attempt
- Claude generates tactics one at a time, verified by rocqtop
- Progress shown in real-time (tactics appearing in the buffer)
- User can interrupt with any key

### Explain mode
- Select a term/tactic, press a key
- Claude explains what it does in the context of the current proof
- Response in messages pane or a popup

## Authentication

- Anthropic API key: could read from `~/.config/anthropic/api_key`
  or `ANTHROPIC_API_KEY` env var
- For Claude Code integration: already handled by Claude Code

## Preferred approach: Rocqtui as MCP server

Claude Code connects to a running rocqtui instance via MCP. Rocqtui
exposes its full state and operations as MCP tools/resources.

### MCP Resources (read-only state)

| Resource                | Description                              |
|-------------------------|------------------------------------------|
| `buffer`                | Full file content of active tab          |
| `buffer/{tab}`          | File content of specific tab             |
| `goals`                 | Current goal state (formatted)           |
| `messages`              | Current messages pane content            |
| `cursor`                | Cursor position (line, col, byte offset) |
| `verified_region`       | Start/end of verified region             |
| `target_region`         | Start/end of target (pending) region     |
| `sentence_ranges`       | List of sentences with their status      |
| `selection`             | Currently selected text, if any          |
| `tabs`                  | List of open tabs with filenames         |
| `word_at_cursor`        | Identifier under cursor                  |
| `diagnostics`           | Errors and warnings                      |

### MCP Tools (actions)

| Tool                    | Description                              |
|-------------------------|------------------------------------------|
| `step_forward`          | Advance target by one sentence           |
| `step_backward`         | Retract target by one sentence           |
| `go_to_cursor`          | Set target to cursor position            |
| `go_to_end`             | Set target to end of file                |
| `insert_text(pos, text)`| Insert text at position                  |
| `replace_range(s,e,txt)`| Replace text in range                    |
| `delete_range(s, e)`    | Delete text in range                     |
| `move_cursor(line, col)`| Move cursor to position                  |
| `query(cmd)`            | Run a Rocq query (About, Print, etc.)    |
| `set_option(name, val)` | Set a printing option                    |
| `save`                  | Save current file                        |
| `open_file(path)`       | Open file in new tab                     |
| `switch_tab(index)`     | Switch to tab                            |
| `close_tab`             | Close active tab                         |
| `wait_verified`         | Block until verified catches up to target|
| `interrupt`             | Send ^C to rocqtop                       |

### MCP Notifications (events, rocqtui → Claude Code)

| Notification            | Description                              |
|-------------------------|------------------------------------------|
| `goals_changed`         | Goal state updated                       |
| `verified_changed`      | Verified region moved                    |
| `error`                 | A sentence errored                       |
| `message`               | New message from rocqtop                 |

### Transport

MCP uses JSON-RPC over stdio or SSE. Options:
- **Unix socket**: rocqtui listens on `~/.rocqtui/mcp.sock`
- **TCP port**: rocqtui listens on localhost:PORT
- **stdio**: rocqtui spawns Claude Code as a child (less flexible)

Unix socket is probably cleanest — no port conflicts, auto-cleaned up.

### Workflow example

1. User opens `proof.v` in rocqtui, steps to a stuck goal
2. User runs `claude` in another terminal
3. Claude Code connects to rocqtui's MCP server
4. User tells Claude: "prove this goal"
5. Claude reads `goals` resource, sees the goal state
6. Claude reads `buffer` resource for context
7. Claude calls `insert_text` to add a tactic after the cursor
8. Claude calls `step_forward` to verify it
9. Claude reads `goals` to see the new state
10. Repeats until Qed or stuck
11. User watches the proof being constructed in real-time in rocqtui

### Implementation plan

Phase 1: MCP server skeleton
- JSON-RPC parser/handler
- Unix socket listener
- Registration with MCP protocol (initialize, list tools/resources)
- Integrate socket fd into the select loop

Phase 2: Read-only resources
- Expose buffer, goals, messages, cursor, etc.
- Claude Code can observe the full state

Phase 3: Action tools
- step_forward/backward, insert_text, move_cursor, query
- Claude Code can drive the IDE

Phase 4: Notifications
- Push events when state changes
- Claude Code can react to verification results

### Considerations

- **Concurrency**: MCP requests arrive on the socket while the user is
  also interacting via keyboard/mouse. Need to handle both without
  conflicts. The select loop already handles multiple fds.
- **Locking**: If Claude is inserting text while the user is typing,
  we need some form of coordination. Options:
  - Lock the buffer while Claude is operating
  - Queue Claude's operations behind user input
  - Optimistic: just apply both, let conflicts resolve naturally
- **Undo**: Claude's edits should be undoable. Group a sequence of
  Claude operations into a single undo unit.
- **Visibility**: Show when Claude is actively working (indicator in
  status bar? different cursor color?)

## Questions to resolve

1. Which integration level to start with? (Level 1 is simplest)
2. Direct API vs MCP vs Claude Code process?
3. How to handle latency? (API calls are 1-5 seconds)
4. How to manage context window budget?
5. Should Claude be able to edit the buffer directly, or only suggest?
6. How to handle multi-step proof attempts that fail partway?
7. What model to use? (Sonnet for speed, Opus for quality?)
8. Cost management — proof search could be expensive
9. Privacy — user's proof code is sent to the API
10. Offline mode — should anything work without API access?
