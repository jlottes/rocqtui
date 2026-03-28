# Rocqtui TODO

## MCP Server

- [x] Implement `replace_range` properly (was a stub)
- [x] Add MCP notifications (goals_changed, verified_changed, messages via resource updated)
- [x] Add `open_file` tool (open a named file in a new tab)
- [x] Add `delete_range` tool
- [x] Timeout/clear active tab indicator after inactivity (5s)
- [x] Stale MCP socket cleanup on startup
- [x] State-changed bool properly threaded from tool handlers through dispatch
- [x] Sync stepping in bridge (step_forward/backward/go_to_end block, return goals+errors)
- [x] go_to_offset tool (set target to byte offset without moving cursor)
- [x] async flag for stepping tools
- [ ] Wire up Claude Code as an actual MCP client and test end-to-end
- [ ] Handle concurrency: Claude editing while user is typing
- [ ] Line/offset conversion: `offset_of_line {line, col}` tool and/or `line_offsets` resource
- [ ] Undo/redo tools (expose Buffer.undo/redo via MCP)
- [ ] Batch edits: `batch_edit` tool — list of edits applied as one undo group
- [ ] Error location in step responses — include byte range from Session.error_range
- [ ] Get context: `get_context {offset, before, after}` — return surrounding text
- [ ] Group Claude's edits into single undo units

## Per-tab State Refactor (Phase 9 remaining)

- [x] Move `goals_scroll`, `messages_scroll`, `focused_pane`, `show_all_hyps`
      from editor.ml globals into Tab.t
- [x] Move `goals_sel`, `messages_sel`, `goals_lines_cache`, `messages_lines_cache`
      into Tab.t
- [x] Move `mouse_selecting`, `suppress_ensure_visible` into Tab.t
- [x] Editor.handle_key takes Tab.t instead of separate buf + session
- Note: `dragging` and `clipboard` remain global (display-level / shared)

## Editor Features

- [ ] Search (^F) — find text in the editor, highlight matches
- [ ] Search and replace
- [ ] Line numbers gutter in the script pane
- [ ] Tab/indent support (Tab key inserts spaces or tab character)
- [ ] Auto-indent on newline (match previous line's indentation)
- [ ] Matching bracket/paren highlighting
- [ ] Go to line number (^G is taken — need another binding)

## Rocq Integration

- [x] "Check" and "Locate" queries (^Q menu)
- [x] Jump to definition (^L — Require line opens module, identifier jumps via Locate + .glob)
- [x] Jump back (^B — stack of previous locations)
- [ ] Completion (suggest identifiers/tactics based on context)
- [ ] Show proof diff (protocol supports proof_diff)
- [ ] Debugger integration (protocol has db_cmd, db_stack, etc.)

## Display / UX

- [ ] Vertical scroll bar in script pane
- [ ] Better horizontal scroll (scroll follows cursor more smoothly)
- [ ] Minimap / overview of file
- [ ] Configurable pane layout (e.g., goals below script, messages on right)
- [ ] Remember pane split positions across sessions
- [ ] Remember window size across sessions
- [ ] Color theme hot-reload

## Async / Performance

- [ ] Make `query` and `with_options` non-blocking (currently sync eval_call)
- [ ] Make `edit_at` (backward stepping) non-blocking
- [ ] Syntax highlighting caching (don't re-highlight unchanged lines)
- [ ] Incremental re-rendering (only redraw changed regions)
- [ ] Large file support (virtual scrolling, lazy line loading)

## Robustness

- [ ] Handle rocqtop crash gracefully (show error, allow restart)
- [ ] Handle broken pipe on rocqtop fd
- [ ] Recover from MCP client sending malformed JSON
- [ ] Session tests (test async stepping, error recovery, rewind)

## Documentation

- [ ] README with usage instructions, keybindings summary
- [ ] man page or --help output
- [ ] MCP API documentation for Claude Code integration
- [ ] Contributing guide
