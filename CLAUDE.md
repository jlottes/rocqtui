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
- `bridge/rocqtui_mcp.ml` — OCaml bridge: stdio↔Unix socket, high-level proving tools
- `scripts/rocqtui-mcp-bridge` — old Python bridge (deprecated)

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
| ^W | Close tab / close terminal (when focused) |
| ^X | Exit all |
| ^C | Copy (also to system clipboard) |
| ^N | New tab |
| ^B | Jump back |
| ^L | Jump to definition |
| ^E | Go to cursor (set target) |
| Alt+Down/Up | Step forward/backward |
| Alt+. | Interrupt Rocq |
| ^P | Cycle pane focus |
| ^T | Open terminal (in project dir) |
| ^Q | Query menu |
| ^M | Minimap (Kitty protocol only) |
| F1 | Help (scrollable) |
| F2 | Print options |
| F3 | Theme picker |
| F4 | Reload from disk |
| F5 | Build menu |
| F6 | Open Claude (in project dir) |
| F12 | Force redraw |
| ESC | Compose (XCompose input) |
| ESC ESC | Send ESC to terminal (when focused) |

## MCP Server

Rocqtui exposes an MCP server over a Unix socket, allowing Claude Code
to drive the editor programmatically. Full API docs: `CLAUDE_MCP.md`
(projects import it via `@~/rocq/rocqtui/CLAUDE_MCP.md`).

### Architecture
- `mcp_server.ml` — JSON-RPC 2.0 low-level server, resources + tools
- `bridge/rocqtui_mcp.ml` — OCaml bridge (stdio↔socket), high-level proving tools
- `.rocqtui-mcp.sock` symlink created in project dirs for discovery

### Key tools (via bridge)
- **Proving**: `verify_to`, `proof_insert`, `proof_forward`, `proof_rewind`
  — all synchronous, text-based (no byte offsets), auto-lock buffer
- **Queries**: `query` (About, Print, Search, Check, Locate)
- **Session**: `save`, `open_file`, `build_deps`

### Key resources
- `rocqtui://proof_status` — goals, context (sentence-aligned), verified position
- `rocqtui://buffer` — full file text
- `rocqtui://tabs` — open tabs

### Connection
Configure in project `.mcp.json`:
```json
{ "mcpServers": { "rocqtui": {
    "command": "<path-to-rocqtui>/_build/default/bridge/rocqtui_mcp.exe"
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
