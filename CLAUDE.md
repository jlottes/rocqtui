# Rocqtui — project notes for Claude Code

Terminal IDE for the Rocq (Coq) proof assistant.

## Build & test

```bash
dune build
dune exec bin/main.exe -- -theme solarized-dark <path-to-file>.v
```

Tests:

```bash
dune runtest          # all unit tests in test/
dune build @e2e       # e2e suite in test/e2e/ (kept off runtest)
```

`dune runtest` is fast (subsecond once compiled). `@e2e` spawns
headless rocqtui + bridge subprocess per test and runs them in
parallel — wall time ~0.5s with a warm Rocq install. Run `@e2e`
whenever touching MCP/bridge/Session/Printopts. Set
`ROCQTUI_E2E_TRACE=1` to dump the JSON-RPC traffic.

Single tests still work directly:

```bash
dune exec test/e2e/test_smoke.exe
```

The headless rocqtui used by the e2e harness is also accessible
manually:

```bash
dune exec bin/main.exe -- --headless --socket-path /tmp/x.sock file.v
```

Standalone tools:

```bash
dune exec tools/grid_cat.exe -- -color file.v
dune exec tools/braille_cat.exe -- file.v
```

## Docs you should read when relevant

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module map, design decisions
- [`CLAUDE_MCP.md`](CLAUDE_MCP.md) — MCP API reference (imported by projects
  using rocqtui via `@~/rocq/rocqtui/CLAUDE_MCP.md`)
- `docs/` — historical planning docs (PLAN.md, REFACTOR.md, etc.)

## Conventions

- Commit messages: descriptive title, bullet points for details.
- Amend previous commit only for trivially related follow-ups (same logical
  change). Otherwise create a new commit.
- Test before committing when possible.
- Run `dune build` from the rocqtui directory, not the parent.
- Prefer editing existing files to creating new ones.
- Don't add backwards-compat shims or half-finished abstractions — the user
  wants clean changes.

## Gotchas

- **Two `keys.ml` files**: `lib/keys.ml` holds editor key *bindings*;
  `lib/vterm/keys.ml` holds kitty-protocol key *identity* constants
  (`KEY_UP`, `KEY_ESCAPE`, etc.) used when forwarding keys to the embedded
  terminal. Don't confuse them.
- **`Buffer` shadowing**: `lib/buffer.ml` shadows `Stdlib.Buffer`. In other
  `lib/` modules, use `Stdlib.Buffer.*` explicitly when you want the
  standard-library buffer.
- **F-key encodings** vary by terminal (CSI ~, CSI P, SS3 — all handled in
  `input.ml`).
- **Solarized-dark theme** uses terminal default fg/bg, not true solarized
  colors — intentional.
- **inotify** is Linux-specific. The project is Linux-only for now; macOS
  would need kqueue/FSEvents as an alternative.
- **Embedded terminal terminfo**: `lib/terminal.ml` sets `TERMINFO_DIRS`
  in the child env to point at the bundled compiled terminfo under
  `data/terminfo/`. Don't assume `TERM=glterm` is installed system-wide.

## MCP integration

Rocqtui exposes an MCP server over a Unix socket. Full API docs in
[`CLAUDE_MCP.md`](CLAUDE_MCP.md). Claude Code records usability friction in
`mcp-feedback.md` in whatever project is using rocqtui.

## Key bindings

See `lib/keys.ml` for the source of truth. Summary:

| Key | Action |
|-----|--------|
| ^S | Save (prompts for filename on a new/blank tab; locked `.v` extension, project-relative path) |
| ^O | Open file picker |
| ^W | Close tab / close terminal (when focused) |
| ^X / ^K | Cut line / selection (script pane) |
| ^Q | Exit all |
| ^C | Copy (also to system clipboard) |
| ^N | New tab |
| ^F | Find / re-open find & replace panel |
| F3 / Shift+F3 | Next / previous match (with active search) |
| Tab | Toggle Find / Replace field (in panel) |
| Alt+Enter | Replace current match, advance (in panel) |
| Alt+A | Replace all matches (in panel) |
| Alt+P | Toggle project-wide search (in panel); auto-opens "Search" messages tab |
| F9 / Shift+F9 | Next / previous build error / warning |
| ^B | Jump back |
| ^L | Jump to definition |
| ^E / Alt+E | Go to cursor (set target) |
| Alt+Down/Up | Step forward/backward |
| Alt+Home / Alt+R | Rewind to start of buffer |
| Alt+End | Verify to end of buffer |
| Alt+. | Interrupt Rocq |
| ^P | Cycle pane focus |
| ^T | Open terminal (in project dir) |
| Alt+Q | Query menu |
| ^M | Minimap (Kitty protocol only) |
| F1 | Help (scrollable) |
| F2 | Print options |
| F7 | Theme picker |
| F4 | Reload from disk |
| F5 | Build menu |
| F6 | Open Claude (in project dir) |
| F8 | Toggle file-tree panel (focus + snap to current file on initial show; close on second) |
| . | (in file-tree panel) Snap selection to current tab's file |
| v | (in file-tree panel) Cycle view: filesystem tree ↔ dependency order |
| p | (in file-tree panel, tree view) Toggle selected file's `_RocqProject` membership (commented ↔ active, or inserts new entry in sorted position) |
| r | (in file-tree panel, tree view) Rename selected file. Prompt pre-fills the project-relative path with the `.v` extension locked. Add `/` to move into a different (existing or new) directory; new directories require a confirmation. `_RocqProject` entries (active or commented) are renamed in place. |
| F12 | Force redraw |
| ESC | Start XCompose (only if launched with `--xcompose`); otherwise sent to terminal when focused |
| ESC | Cancel search (prompt: restores cursor; outside prompt: clears highlights). Under `--xcompose`, ESC starts compose so the user-visible cancel is ESC ESC; the second ESC also doubles as "send ESC to terminal" when one is focused and no search is in flight. |
