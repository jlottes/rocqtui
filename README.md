# rocqtui

A terminal IDE for the [Rocq](https://rocq-prover.org/) (formerly Coq) proof assistant.

No ncurses — direct ANSI escape sequences. Interactive stepping, syntax
highlighting, jump-to-definition, an embedded terminal, and an MCP server for
Claude Code integration.

## Requirements

- **Linux**. macOS/BSD would need a port (see [platform notes](#platform-notes)).
- **OCaml** 4.14 or later with **opam**.
- **Rocq** 9.0 or later (provides `rocq-runtime` and `coqide-server` opam packages).
- **ncurses** — specifically the `tic` program, at build time only, to compile
  the bundled terminfo entry. (Installed with ncurses on every distro.)
- A terminal emulator that supports 256 colors and UTF-8. Any modern one will do
  (kitty, alacritty, wezterm, foot, gnome-terminal, xterm, etc.). For full
  keybinding support, use one that implements the
  [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/).

## Install

```bash
git clone https://github.com/jlottes/rocqtui
cd rocqtui
opam install .
```

This installs two binaries (`rocqtui` and `rocqtui-mcp`), a bundled
`glterm` terminfo entry, and the [MCP API reference](CLAUDE_MCP.md)
as package documentation (see [MCP integration](#mcp-integration) below).

To build without installing:

```bash
dune build
dune exec bin/main.exe -- <path-to-file>.v
```

## Usage

```bash
rocqtui path/to/file.v
rocqtui -theme solarized-dark path/to/file.v
```

### Key bindings

| Key | Action |
|-----|--------|
| `^S` | Save |
| `^O` | Open file picker |
| `^N` | New tab |
| `^W` | Close tab (or close terminal, when focused) |
| `^X` | Exit |
| `^C` | Copy to system clipboard |
| `^B` | Jump back |
| `^L` | Jump to definition |
| `^E` | Set proof target to cursor |
| `Alt+Down` / `Alt+Up` | Step forward / backward |
| `Alt+.` | Interrupt Rocq |
| `^F` | Find / re-open search prompt |
| `F3` / `Shift+F3` | Next / previous match |
| `^P` | Cycle pane focus |
| `^T` | Open embedded terminal (in project dir) |
| `^Q` | Query menu (About, Print, Search, Check, Locate) |
| `^M` | Minimap (Kitty keyboard protocol required) |
| `F1` | Help |
| `F2` | Options menu |
| `F4` | Reload from disk |
| `F5` | Build menu |
| `F6` | Open Claude Code in project dir |
| `F7` | Theme picker |
| `F12` | Force redraw |

## Project files

rocqtui assumes a `_RocqProject` (or legacy `_CoqProject`) file at the project
root. This is the standard Rocq/Coq convention for declaring load paths and
compile options; `rocq dep` and `coq_makefile` use the same file. rocqtui uses
it to drive the file picker, dependency build, Rocq command-line flags, and
jump-to-definition.

If you open a file without a project file anywhere in its parent chain, most
features still work but the file picker and build menu won't have anything to
show.

## XCompose input

Run with `--xcompose` to enable an in-editor compose-key mode that parses
your `~/.XCompose` directly. When enabled, `ESC` starts a compose sequence
and subsequent keys are matched against your compose rules to insert the
resulting character (Greek letters, math symbols, etc.).

This is **off by default** and unconventional: terminal applications normally
let the outer terminal or the window manager's input method handle compose.
The in-editor path exists for editing over SSH — when you're connected to a
remote host and want to use *that* host's `~/.XCompose` without setting up
input method forwarding (or, on the client side, an XCompose-equivalent
input method at all).

If you're on Linux locally with a working compose setup, you probably don't
need `--xcompose`.

## Embedded terminal

`^T` opens an embedded terminal pane running your `$SHELL` in the project
directory. The terminal emulator is vendored from a work-in-progress project
called glterm; it has some unusual properties (variable-length lines, tabs
preserved literally instead of expanded to spaces) that differ from standard
terminals. To avoid confusing programs running inside it, rocqtui bundles a
`glterm` terminfo entry and sets `TERMINFO_DIRS` in the child environment so
it's found without a system-wide install.

## MCP integration

rocqtui exposes an MCP server over a Unix socket so Claude Code (or other
MCP clients) can drive the editor programmatically — step the proof, insert
tactics, query goals, run `Search`, etc. See [`CLAUDE_MCP.md`](CLAUDE_MCP.md)
for the API.

### Using from a Claude Code project

Add rocqtui's MCP bridge to your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "rocqtui": {
      "command": "rocqtui-mcp"
    }
  }
}
```

(`rocqtui-mcp` is installed by `opam install` alongside the `rocqtui` binary.)

Then pull the MCP API reference into the project's `CLAUDE.md` so Claude
knows how to use the tools:

```markdown
@~/.opam/<your-switch>/doc/rocqtui/CLAUDE_MCP.md
```

Replace `<your-switch>` with your active opam switch name (e.g. `rocq`).
You can find the exact path with `opam var rocqtui:doc`.

## Platform notes

rocqtui is **Linux-only** right now:

- File watching uses `inotify`. Porting to macOS would mean adding a
  `kqueue` or `FSEvents` backend.
- Everything else (PTY, termios, signals, `Unix.select`) is POSIX and
  should work on any Unix.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the module map and
design decisions. Historical planning docs live in [`docs/`](docs/).

## License

MIT. rocqtui links against `rocq-runtime` and `coqide-server`, which are
LGPL-2.1-only. Linking from MIT-licensed code against LGPL libraries is
explicitly permitted by the LGPL; the LGPL license applies only to those
libraries, not to rocqtui itself.
