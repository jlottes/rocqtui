# Rocqtui

Terminal IDE for the Rocq (Coq) proof assistant. ~9500 lines of OCaml.

## Build & Run

```bash
dune build
dune exec bin/main.exe -- -theme solarized-dark ~/rocq/affine/theory/groups.v
```

Tests: `dune exec test/test_grid.exe`, `test_tab_names.exe`, `test_locate.exe`

Standalone tools: `dune exec tools/grid_cat.exe -- -color file.v`,
`dune exec tools/braille_cat.exe -- file.v`

## Architecture

**No ncurses.** All terminal I/O uses direct ANSI escape sequences.

### Terminal stack (lib/)
- `term.ml` — terminal init/teardown, raw mode, Kitty keyboard protocol, SIGWINCH
- `input.ml` — raw byte parser: CSI sequences, CSI u (Kitty), SGR mouse, paste, SS3
- `grid.ml` — cell grid with Unicode (wide/combining chars), attrs, ANSI diff renderer
- `render.ml` — pane layout on grid, chrome, overlays, tab/status bar, `present()`

### Editor (lib/)
- `editor.ml` (~1150 lines) — input event handling only (handle_event)
- `view.ml` (~610 lines) — all rendering (render_all, render_script, etc.)
- `editor_context.ml` — shared mutable state (clipboard, compose, dragging, jump stack)
- `modal.ml` — modal dialog stack (Help, QueryMenu, OptionsMenu, ThemeMenu, BuildMenu, FilePicker, Prompt)

### Rocq integration (lib/)
- `session.ml` — Rocq process, sentence tracking, async stepping, goals
- `rocq_protocol.ml` — XML protocol via Spawn.Async(Main_loop)
- `main_loop.ml` — select-based event loop for Spawn.Async watch callbacks
- `sentence.ml` — sentence boundary detection
- `highlight.ml` — syntax highlighting via CLexer.LexerDiff

### Buffer & tabs (lib/)
- `buffer.ml` — text buffer with undo/redo, UTF-8 cursor, selection
- `tab.ml` — tab manager, display name disambiguation, message sub-tabs

### Features (lib/)
- `file_picker.ml` — tree view file browser (^O)
- `minimap.ml` — braille minimap (F2)
- `build.ml` — async make subprocess (F5)
- `file_manager.ml` / `file_watch.ml` — inotify file watching, auto-reload
- `mcp_server.ml` — MCP server for Claude Code integration
- `theme.ml` — 5 color themes, Grid.attr with TrueColor support
- `keys.ml` — centralized key bindings
- `locate.ml` / `glob.ml` — jump-to-definition via Locate + .glob files
- `compose.ml` — XCompose input method
- `clipboard.ml` — OSC 52 system clipboard

### Entry point
- `bin/main.ml` (~390 lines) — main loop, tab management, render scheduling

### MCP bridge
- `scripts/rocqtui-mcp-bridge` — Python bridge: stdio↔Unix socket, sync stepping

## Key Design Decisions

- **Main_loop.select_with_watches** stays: Spawn.Async (coqidetop I/O) depends on it.
  The main loop calls `select_with_watches` which dispatches both coqidetop watch
  callbacks and our extra fds (stdin, MCP, build, inotify).
- **Input.read_event** is called only when stdin is ready from select, with timeout 0.
- **Render.present** diffs current grid vs previous frame; `~force:true` emits all cells.
- **Render_need.ml** tracks No/Yes/Full render requests per frame.
- **Editor_context.t** holds all editor mutable state — editor.ml has zero global refs.
- **Modal.t** is a stack of modal dialogs. Prompts are non-blocking modals.
- **File_picker.t** state lives in Modal.FilePicker, not a global ref.
- **Theme colors** are `Grid.color` (supports TrueColor directly in theme definitions).
- **inotify** watches need re-adding after atomic rename (DELETE_SELF → re-watch).
- **ESC[K** emitted after rows to clear trailing content (glterm compatibility).
- **Kitty keyboard protocol** level 1 enabled in Term.init. Input parser handles
  both Kitty CSI u and traditional encodings (SS3, CSI ~, CSI A-D).

## Key Bindings

| Key | Action |
|-----|--------|
| ^S | Save |
| ^O | Open file picker |
| ^W | Close tab (exit if last) |
| ^X | Exit all |
| ^N | New tab |
| ^B | Jump back |
| ^L | Jump to definition |
| ^E | Go to cursor (set target) |
| Alt+Down/Up | Step forward/backward |
| ^P | Cycle pane focus |
| ^T | Print options |
| ^Q | Query menu |
| F1 | Help (scrollable) |
| F2 | Minimap |
| F3 | Theme picker |
| F4 | Reload from disk |
| F5 | Build menu |
| F12 | Force redraw |

## MCP Server

Rocqtui exposes an MCP server over a Unix socket, allowing Claude Code
to drive the editor programmatically. Full API docs: `CLAUDE_MCP.md`
(projects import it via `@~/rocq/rocqtui/CLAUDE_MCP.md`).

### Architecture
- `mcp_server.ml` — JSON-RPC 2.0 server, resources + tools
- `scripts/rocqtui-mcp-bridge` — Python bridge (stdio↔socket) with sync stepping
- `.rocqtui-mcp.sock` symlink created in project dirs for discovery

### Key tools
- **Stepping** (sync via bridge): `step_forward`, `step_backward`, `go_to_offset`, `go_to_end`
  — block until done, return goals + errors + executed/next sentence
- **Editing**: `replace_text` (preferred, text-based), `insert_text`, `replace_range`,
  `delete_range`, `batch_edit`, `undo`, `redo` — all return context snippets
- **Queries**: `query`, `get_goals`, `get_position`, `get_context`, `offset_of_line`
- **Session**: `is_busy`, `interrupt`, `save`, `switch_tab`, `open_file`

### Key resources
- `rocqtui://buffer`, `goals`, `messages`, `error`, `regions`, `sentences`,
  `tabs`, `cursor`, `line_offsets` — all support `?tab=N` for per-tab access

### Connection
Configure in project `.mcp.json`:
```json
{ "mcpServers": { "rocqtui": {
    "command": "/home/jlottes/rocq/rocqtui/scripts/rocqtui-mcp-bridge"
} } }
```

### Feedback
Claude Code records usability friction in `mcp-feedback.md` in the project root.

## Planning & Tracking

- `PLAN.md` — phased implementation plan (Phases 1-13)
- `TODO.md` — categorized task list
- `REFACTOR.md` — refactoring brainstorm (9 ideas A-I)
- `REFACTOR_CHECKLIST.md` — progress tracker (H,E,F,I,B,G,A,C done; D optional)
- `CLAUDE_MCP.md` — MCP API reference (imported by projects via @)
- `TERMINAL_FEATURES.md` — terminal features reference

## Known Issues / Active Work

- `display.ml` is a dead stub — should be deleted
- F-key encodings vary by terminal (CSI ~, CSI P, SS3 — all handled)
- Solarized-dark uses terminal default fg/bg (not true solarized colors) — intentional for now
- Build.active is still a global ref (acceptable for singleton)
- The old ncurses worktree at ~/rocq/rocqtui-old can be removed (`git worktree remove`)

## Conventions

- Commit messages: descriptive title, bullet points for details
- Amend previous commit only for trivially related follow-ups (same logical change)
- Test before committing when possible
- `dune build` from the rocqtui directory (not parent)
