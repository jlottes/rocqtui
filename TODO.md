# Rocqtui TODO

## MCP Server

- [ ] Implement `replace_range` properly (currently a stub)
- [ ] Add MCP notifications (goals_changed, verified_changed, error, message)
- [ ] Add `open_file` tool (open a named file in a new tab)
- [ ] Add `delete_range` tool
- [ ] Wire up Claude Code as an actual MCP client and test end-to-end
- [ ] Handle concurrency: Claude editing while user is typing
- [ ] Group Claude's edits into single undo units
- [ ] Timeout/clear active tab indicator after inactivity

## Per-tab State Refactor (Phase 9 remaining)

- [ ] Move `goals_scroll`, `messages_scroll`, `focused_pane`, `show_all_hyps`
      from editor.ml globals into Tab.t (currently still global)
- [ ] Move `goals_sel`, `messages_sel`, `goals_lines_cache`, `messages_lines_cache`
      into Tab.t
- [ ] Move `mouse_selecting`, `dragging`, `suppress_ensure_visible` into Tab.t
- [ ] Editor.handle_key should take a Tab.t instead of separate buf + session

## Editor Features

- [ ] Search (^F) — find text in the editor, highlight matches
- [ ] Search and replace
- [ ] Line numbers gutter in the script pane
- [ ] Tab/indent support (Tab key inserts spaces or tab character)
- [ ] Auto-indent on newline (match previous line's indentation)
- [ ] Matching bracket/paren highlighting
- [ ] Go to line number (^G is taken — need another binding)

## Rocq Integration

- [ ] "Check" query at cursor (type of expression under cursor)
- [ ] Jump to definition (look up identifier, open file + position)
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
- [ ] Stale MCP socket cleanup on startup

## Documentation

- [ ] README with usage instructions, keybindings summary
- [ ] man page or --help output
- [ ] MCP API documentation for Claude Code integration
- [ ] Contributing guide
