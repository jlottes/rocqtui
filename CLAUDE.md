# Rocqtui — project notes for Claude Code

Terminal IDE for the Rocq (Coq) proof assistant.

## Build & test

```bash
dune build
dune exec bin/main.exe -- -theme solarized-dark <path-to-file>.v
```

Tests are runnable but not automatic:

```bash
dune exec test/test_grid.exe
dune exec test/test_tab_names.exe
dune exec test/test_locate.exe
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
| F7 | Theme picker |
| F4 | Reload from disk |
| F5 | Build menu |
| F6 | Open Claude (in project dir) |
| F12 | Force redraw |
| ESC | Start XCompose (only if launched with `--xcompose`); otherwise sent to terminal when focused |
| ESC ESC | Send ESC to terminal (when compose is active and focused) |
