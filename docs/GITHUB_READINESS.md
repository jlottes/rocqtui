# GitHub Readiness Plan

Checklist for preparing rocqtui for public release on GitHub.

## 1. Investigate / Decide

### Glterm terminfo

The embedded terminal sets `TERM=glterm`, requiring a terminfo entry users won't have.
Options:

- Ship a `glterm.terminfo` source in the repo, document `tic glterm.terminfo` in install
- Fall back to `TERM=xterm-256color` if glterm isn't installed (check `infocmp glterm` at runtime)
- **Best option**: bundle the compiled terminfo entry and set `TERMINFO_DIRS` when
  spawning child processes — no system install required

### X11 header dependency

`lib/vterm/keyseq.c` and `kitty_keyseq.c` include `<X11/keysym.h>` and `<X11/Xlib.h>`.
Requires `libx11-dev` / `libX11-devel` at build time. Either:

- Document the build dependency
- Vendor the small set of keysym constants actually used, dropping the X11 dep entirely

### Platform scope

The codebase is Linux-specific but mostly POSIX:

- **inotify** — Linux-only. Would need kqueue/FSEvents on macOS. Main portability blocker.
- **PTY** (`/dev/ptmx`, `grantpt`, `setsid`, `TIOCSCTTY`) — works on macOS too.
- **termios, Unix.select, signals** — POSIX, works on macOS.
- **Verdict**: Linux-only for now is fine; document clearly. inotify is the main macOS blocker.

## 2. Clean Up

### Hardcoded paths in tests

These files reference `/home/jlottes/...` and need relative or synthetic paths:

- `test/test_tab_names.ml`
- `test/test_grid.ml`
- `test/test_project.ml`
- `test/test_locate.ml`

### Hardcoded paths in docs

`CLAUDE.md` and `CLAUDE_MCP.md` reference `/home/jlottes/...` in examples.
Replace with generic `$HOME/...` or `<path-to-rocqtui>`.

### .gitignore additions

Add: `.claude/`, `.rocqtui-mcp.sock`

## 3. Write README.md

Cover:

- **What it is**: terminal IDE for Rocq, no ncurses, direct ANSI escape sequences
- **Screenshot** (nice to have)
- **Requirements**: Linux, OCaml 4.14+, Dune 3.0+, Rocq 9.x, yojson, X11 headers, C compiler
- **Build & install**: `opam install` deps, then `dune build`
- **Usage**: invocation, theme flag, key bindings table
- **Project file**: explain `_RocqProject` / `_CoqProject` — file picker, build, and
  jump-to-definition all rely on it. This is standard Rocq convention; just emphasize it.
- **XCompose**: ESC triggers XCompose input via `~/.XCompose`. Linux/X11-specific,
  harmlessly ignored if no file exists. Motivation: math symbols for Rocq proofs.
- **Embedded terminal**: glterm terminfo requirement and workaround
- **MCP integration**: point to `CLAUDE_MCP.md`
- **Platform**: Linux-only (inotify)

## 4. Packaging / Release

### opam file

Create `rocqtui.opam` with proper dependencies so `opam install .` works.

### Makefile (thin wrapper)

`build`, `install`, `clean` targets wrapping dune. Conventional for OCaml projects
with C stubs.

### Terminfo bundling

Include glterm terminfo source. Either install via `make install` or locate at
runtime via `TERMINFO_DIRS`.

## 5. Rename / reorganize CLAUDE.md

`CLAUDE.md` serves as both Claude Code project instructions and architecture docs.
For GitHub:

- Rename to `ARCHITECTURE.md` or `HACKING.md` for the public-facing version
- Keep a smaller `CLAUDE.md` with essential project instructions (or keep as-is —
  many open-source projects have `CLAUDE.md` now)

## 6. Move planning docs to docs/

Move these to `docs/`:

- `PLAN.md`, `PLAN_TERMINAL.md`
- `MCP_PLAN.md`, `MCP_PROVE_DESIGN.md`
- `REFACTOR.md`, `REFACTOR_CHECKLIST.md`
- `TODO.md`
- `CLAUDE_INTEGRATION.md`
- `TERMINAL_FEATURES.md`

## 7. Suggested order of work

1. Decide on glterm terminfo strategy and X11 keysym vendoring
2. Clean hardcoded paths in tests and docs
3. Write `README.md`
4. Create `rocqtui.opam`
5. Update `.gitignore`
6. Move planning docs to `docs/`
7. Create GitHub repo, push `main`
