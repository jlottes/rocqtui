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
**Decision**: remove X11 dependency upstream in glterm, vendor keysym constants.

### Platform scope

The codebase is Linux-specific but mostly POSIX:

- **inotify** — Linux-only. Would need kqueue/FSEvents on macOS. Main portability blocker.
- **PTY** (`/dev/ptmx`, `grantpt`, `setsid`, `TIOCSCTTY`) — works on macOS too.
- **termios, Unix.select, signals** — POSIX, works on macOS.
- **Verdict**: Linux-only for now is fine; document clearly. inotify is the main macOS blocker.

## 2. Clean Up

### Hardcoded paths in tests [DONE]

- `test/test_tab_names.ml` — synthetic `/test/project/...` paths
- `test/test_grid.ml` — UTF-8 demo guarded by `ROCQTUI_TEST_UTF8` env var
- `test/test_project.ml` — takes path from `argv`
- `test/test_locate.ml` — generic paths in strings; glob test guarded
  by `ROCQTUI_TEST_GLOB` / `ROCQTUI_TEST_GLOB_DEF` env vars

### Hardcoded paths in docs [DONE]

- `CLAUDE.md` and `CLAUDE_MCP.md` — `<path-to-rocqtui>` placeholder
- `docs/MCP_PLAN.md`, `docs/PLAN.md` — left as-is (historical planning)

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

## 5. Rename / reorganize CLAUDE.md [DONE]

Split into:
- `CLAUDE.md` — lean, AI-specific: build/test, conventions, gotchas
- `docs/ARCHITECTURE.md` — module map, design decisions, MCP architecture

Also removed: `lib/display.{ml,mli}` dead stubs, `scripts/rocqtui-mcp-bridge`
(old Python bridge superseded by `bridge/rocqtui_mcp.ml`).

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
