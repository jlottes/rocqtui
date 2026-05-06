# Architecture

Rocqtui is ~12000 lines of OCaml with some vendored C for the terminal
emulator. **No ncurses** — all terminal I/O is direct ANSI escape sequences.

## Module map

### Terminal stack (`lib/`)

- `term.ml` — terminal init/teardown, raw mode, Kitty keyboard protocol, SIGWINCH
- `input.ml` — raw byte parser: CSI sequences, CSI u (Kitty), SGR mouse, paste, SS3
- `grid.ml` — cell grid with Unicode (wide/combining chars), attrs, ANSI diff renderer
- `render.ml` — pane layout on grid, chrome, overlays, tab/status bar, `present()`
- `render_need.ml` — tracks No/Yes/Full render requests per frame

### Editor (`lib/editor/` namespace + `lib/`)

`lib/editor/` is a namespace using dune's `(include_subdirs qualified)`.
From outside, modules are accessed as `Editor.Foo`; siblings inside
`lib/editor/` reference each other unprefixed (`Geom`, `Mouse`, etc.).

Top-level dispatch:

- `editor/editor.ml` — `handle_event`: compose preprocessing → modal
  pre-handling → `handle_global` (chained keybinding match) → per-pane
  routing (delegates to `Script` / `Mouse` / `Pty`)
- `editor/action.ml` — `action` and `jump_point` types, factored out
  so submodules can return `Action.action` without circular deps with
  `editor.ml`. `Editor.action` re-exports as a transparent alias

Pure utilities:

- `editor/keymatch.ml` — `match_binding`, `codepoint_of_event`
  (input event ↔ keybinding match, both legacy ncurses and Kitty codes)
- `editor/geom.ml` — screen ↔ buffer/pane coordinate conversion
- `editor/jump.ml` — jump-back stack push/pop

Per-event-source handlers:

- `editor/script.ml` — script-pane keyboard: navigation
  (with/without selection), cut/copy/paste, delete, Enter with
  auto-indent, Tab/Shift+Tab indent, printable input
- `editor/mouse.ml` — mouse handling for all panes: terminal mouse
  forwarding, border drag, text selection drag, scroll,
  click-to-position
- `editor/pty.ml` — PTY routing: open terminal sub-tab, send escape,
  forward input events to the PTY (UTF-8 encoding, Kitty protocol)
- `editor/modals.ml` — modal event dispatchers (Prompt, FilePicker,
  OptionsMenu, ThemeMenu, BuildMenu, QueryMenu, Help) plus
  `query_subject` / `run_query` helpers

Outside the editor namespace:

- `view.ml` — rendering (`render_all`, `render_script`, etc.)
- `editor_context.ml` — shared mutable state (clipboard, compose,
  dragging, jump stack)
- `modal.ml` — modal dialog stack (Help, QueryMenu, OptionsMenu,
  ThemeMenu, BuildMenu, FilePicker, Prompt, SearchPrompt)
- `keys.ml` — centralized key bindings

### Rocq integration (`lib/`)

- `session.ml` — Rocq process, sentence tracking, async stepping, goals
- `rocq_protocol.ml` — XML protocol via `Spawn.Async(Main_loop)`
- `main_loop.ml` — select-based event loop for `Spawn.Async` watch callbacks
- `sentence.ml` — sentence boundary detection
- `highlight.ml` — syntax highlighting via `CLexer.LexerDiff`
- `locate.ml` / `glob.ml` — jump-to-definition via Locate + `.glob` files

### Buffer & tabs (`lib/`)

- `buffer.ml` — text buffer with undo/redo, UTF-8 cursor, selection.
  All mutators are gated under `Buffer.Unsafe`; only `Region_buffer`
  should call them. The top-level interface is read-only.
- `region_buffer.ml` — text-mutation gateway. Sole writer of buffer
  text. Each user-visible edit goes through a `try_*` function returning
  `Applied | Rejected of {In_verified_region | Erodes_boundary |
  In_pending_region}`. Pre-flight check, no apply-then-revert. Also
  owns the per-buffer "external client" lock (queryable, not consulted
  by `try_*`). See [`docs/REGION_INVARIANTS.md`](REGION_INVARIANTS.md).
- `search.ml` — pure incremental-search state (matcher + match list,
  refreshed lazily on buffer revision change)
- `tab.ml` — tab manager, display name disambiguation, message sub-tabs.
  `Tab.t` owns the `Region_buffer.t` and the per-tab `Search.state`.

### Features (`lib/`)

- `file_picker.ml` — tree view file browser (^O)
- `minimap.ml` — braille minimap (F2)
- `build.ml` — async `make` subprocess (F5)
- `file_manager.ml` / `file_watch.ml` — inotify file watching, auto-reload
- `mcp_server.ml` — MCP server for Claude Code integration
- `theme.ml` — color themes, `Grid.attr` with TrueColor support
- `compose.ml` — XCompose input method
- `clipboard.ml` — OSC 52 system clipboard
- `project.ml` — `_RocqProject` / `_CoqProject` discovery and parsing

### Embedded terminal (`lib/vterm/`, `lib/terminal.ml`)

Vendored from [glterm](https://glterm-project-url) — a virtual terminal
emulator with variable-length lines (tabs and newlines preserved literally,
no padding). Spawns shell with `TERM=glterm` and `TERMINFO_DIRS` pointing at
the bundled compiled terminfo under `data/terminfo/`.

- `lib/vterm/` — vendored C vterm code plus OCaml bindings
  (`vterm_api.ml`, `pty.ml`, `keys.ml`)
- `lib/terminal.ml` — glue: owns global terminal list, drives I/O, renders
  onto the grid

### Entry point

- `bin/main.ml` — main loop, tab management, render scheduling

### MCP bridge

- `bridge/rocqtui_mcp.ml` — stdio↔Unix socket bridge with high-level
  proving tools (synchronous wrappers for the async MCP server)

## Key design decisions

- **`Main_loop.select_with_watches`** stays: `Spawn.Async` (coqidetop I/O)
  depends on it. The main loop calls `select_with_watches`, which dispatches
  both coqidetop watch callbacks and our extra fds (stdin, MCP, build, inotify).
- **`Input.read_event`** is called only when stdin is ready from select, with
  timeout 0.
- **`Render.present`** diffs current grid vs previous frame; `~force:true`
  emits all cells.
- **`Editor_context.t`** holds all editor mutable state — `editor.ml` has no
  global refs.
- **Region invariants are enforced at one chokepoint** — `Region_buffer`
  is the sole writer of buffer text. Every editor path (keystrokes,
  mouse paste, MCP `text_edit`, file-watch reload, undo/redo) routes
  through a `try_*` function that pre-flight checks the verified-region
  and sentence-boundary invariants. `Buffer.Unsafe` flags any direct
  caller. See [`docs/REGION_INVARIANTS.md`](REGION_INVARIANTS.md).
- **The MCP "buffer lock"** lives on `Region_buffer.t` and is queryable
  only — `try_*` does not consult it. It's the bridge's "appear atomic"
  mechanism for compound ops; the keystroke path, user stepping, and
  inotify-driven auto-reload yield to it explicitly. Deferred file
  events are retried on each poll until the lock releases.
- **`Modal.t`** is a stack of modal dialogs. Prompts are non-blocking modals.
- **`File_picker.t`** state lives inside `Modal.FilePicker`, not a global ref.
- **Theme colors** are `Grid.color` values, supporting TrueColor directly in
  theme definitions.
- **inotify watches** need re-adding after atomic rename
  (`DELETE_SELF` → re-watch).
- **`ESC[K`** is emitted after rows to clear trailing content (needed when
  rocqtui runs inside glterm as the outer terminal, which has variable-width
  lines).
- **Kitty keyboard protocol** level 1 is enabled in `Term.init`. The input
  parser handles both Kitty CSI u and traditional encodings (SS3, CSI ~,
  CSI A-D).
- **Embedded terminal `TERMINFO_DIRS`**: `lib/terminal.ml` resolves
  `data/terminfo/` relative to the executable and injects `TERMINFO_DIRS` into
  the child environment so the bundled glterm entry is found without
  system-wide installation.

## MCP server

Rocqtui exposes an MCP server over a Unix socket so Claude Code can drive
the editor programmatically. See [`CLAUDE_MCP.md`](../CLAUDE_MCP.md) for the
user-facing API.

- `lib/mcp_server.ml` — JSON-RPC 2.0 low-level server, resources + tools
- `bridge/rocqtui_mcp.ml` — OCaml bridge (stdio↔socket), high-level proving tools
- `.rocqtui-mcp.sock` symlink created in project dirs for discovery
