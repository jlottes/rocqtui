# Embedded Terminal Plan

Add embedded terminal tabs to rocqtui, powered by glterm's vterm C library.
Terminal tabs live in the **message sub-tab bar** alongside "Rocq" and
"Build" — not in the top-level file tab bar. This means the user always
sees script + goals alongside the terminal. Terminals are global (shared
across file tabs, like build output). The primary use case is running
Claude Code connected to rocqtui's MCP server.


## Status

### Done

**Phase 1: C Binding Layer** — COMPLETE
- Vendored glterm files into `lib/vterm/` (unmodified). After upstream
  refactor: `vterm.c/h, term.c/h, wrap.c/h, sel.c/h, mem.h, sysbuf.c/h,
  c99.h, types.h, utf-8.h, char_width.h, acs.c/h, keyseq.c/h,
  kitty_keyseq.c/h, mouseseq.c/h`. Dropped: `sys.c/h, fail.c/h`.
- Separate `vterm_lib` dune library with C stubs
- `vterm_stubs.c`: lifecycle, display (get_row/sentinel), scroll,
  selection, key/mouse encoding, PTY open/resize, state queries
- `vterm_api.ml/mli`: type-safe OCaml wrapper with color/attr types
  matching Grid's layout (Obj.magic cast between them)
- `pty.ml/mli`: PTY spawn (arbitrary commands), non-blocking buffered
  writes, read, close

**Phase 2: Terminal as Message Sub-Tab** — COMPLETE
- `terminal.ml/mli`: ties vterm + PTY, global terminal list, poll,
  render to Grid, resize
- `msg_tab` extended with `mt_terminal : Terminal.t option` field
- `sync_terminals` merges global terminals into per-file msg_tabs
- Sticky terminal: active terminal persists across file tab switches
- Auto-switch to Rocq/Build suppressed when terminal is active
- Dynamic display names via `msg_tab_display_name`

**Phase 3: Input Routing** — COMPLETE
- Printable characters: UTF-8 encoded and written directly to PTY
- Ctrl+letter: converted to control bytes (`cp land 0x1f`). Works
  with both legacy (cp < 32) and Kitty (cp = letter + ctrl flag) input.
- Special keys (arrows, F-keys, Home/End/PgUp/PgDn/Ins/Del): mapped
  to X11 keysyms, encoded via `keyseq_lookup` / `kitty_keyseq_lookup`
- Enter/Backspace/Tab/Escape: fallback to raw bytes when keyseq
  returns None
- Shift+Enter: `c_icrnl` disabled in raw mode so CR (0x0d) and
  LF (0x0a) are distinguishable. LF mapped to `Special(Enter, shift)`,
  `keyseq_lookup` produces `\n` for Shift+Return.
- Alt+key: ESC prefix + character
- Bracketed paste: wrapped in `\e[200~` / `\e[201~` when enabled
- **XCompose in terminal**: ESC enters compose mode, composed text
  written to PTY, double-ESC sends literal ESC (via kitty_keyseq)
- Reserved rocqtui keys (not forwarded to terminal):
  Ctrl+X (quit), Ctrl+W (close tab), Ctrl+P (cycle pane),
  Ctrl+S (save), F1 (help), F5 (build menu)
- Mouse forwarding with shift-override following glterm's model:
  click/drag/release forwarded when mouse reporting on, scroll wheel
  forwarded unless locally handled (alt-screen cursor keys or history)

**Phase 4: Rendering** — MOSTLY COMPLETE
- Terminal cells rendered into Grid via `vterm_get_row` → OCaml mapping
- Trailing blanks filled from row sentinel
- Wide characters (width=2): continuation cell (width=0) marked
- Combining characters (width=0): appended to previous cell's text
- Hardware cursor positioned at vterm cursor (no fake cursor rendering)
- Cursor hidden when terminal's MODE_SHOW_CURSOR is off
- Color mapping: struct gr → Grid.attr done in C stubs (gr_to_attr),
  includes bold, dim (ATTRB_DM), reverse, underline

**Phase 5: Main Loop Integration** — COMPLETE
- Terminal PTY fds added to select's extra_fds
- Poll terminals when fd ready, request render on change
- Flush write buffers each iteration
- Resize all terminals on SIGWINCH and on split border drag
- Child exit detection via waitpid(WNOHANG)

**Phase 6: Terminal Management UI** — PARTIAL
- F5 build menu: [t] opens shell terminal, [l] opens Claude
- TERM=glterm set in child environment
- Missing: close terminal command, terminal-specific status bar info

**Crash handling:**
- SIGSEGV/SIGBUS/SIGABRT handler resets terminal state (mouse,
  alt screen, cursor, termios) before re-raising — keeps terminal
  usable after a crash

**Debug tooling:**
- `tools/keyspy.ml`: raw byte display for testing key encoding
- `ROCQTUI_DEBUG_INPUT=1` env var logs input events to stderr
- Sanitizers (ASan + UBSan) enabled in debug builds


### Remaining Work

**Phase 4 gaps:**
- Status bar: show terminal title, process status, scroll indicator
  when terminal sub-tab is focused
- `blit_row` optimization: currently get_row returns OCaml tuples,
  mapped to Grid cells in OCaml. A C stub writing directly into
  Grid.t cells would avoid per-cell allocation. Profile first.

**Phase 6 gaps:**
- Keybinding to close a terminal sub-tab (with confirmation if
  running)
- Resize terminals when messages pane size changes via any mechanism
  (currently only SIGWINCH and border drag are handled)

**Phase 7: Selection & Clipboard** — NOT STARTED
- Mouse selection in terminal using vterm's sel API
- Copy selected text to clipboard (OSC 52)
- Paste from clipboard to PTY (with bracketed paste)
- OSC 52 clipboard data from child process

**Phase 8: Claude Integration** — PARTIAL
- Can launch `claude --chat` from F5 menu ([l])
- Missing: MCP auto-connection (set env var for socket path),
  dedicated keybinding outside of build menu


## Lessons Learned

1. **Terminal-in-terminal input is fundamentally different from X11
   input.** glterm receives X11 keysyms with modifier bitmasks.
   We receive pre-encoded terminal bytes (ESC sequences, raw control
   chars). The translation layer needs to handle both legacy and
   Kitty protocol inputs, and re-encode them for the embedded
   terminal — which may itself request Kitty protocol.

2. **c_icrnl must be disabled.** The kernel's line discipline converts
   CR→NL by default, making Enter and Shift+Enter indistinguishable.
   Disabling `c_icrnl` in raw mode is essential.

3. **Ctrl+letter encoding varies.** Legacy terminals send control
   bytes (1-26). Kitty protocol sends the letter codepoint (97-122)
   with a ctrl modifier. Both must be handled.

4. **Global vs per-file sub-tab merging** works via `sync_terminals`
   which adds/removes terminal entries in each file tab's `msg_tabs`
   on each render. A "sticky terminal" reference prevents auto-switch
   to Rocq/Build from overriding the user's terminal selection.

5. **keyseq_lookup doesn't handle basic keys** (Enter, Backspace,
   Tab, Escape) in the unmodified case — those are expected to be
   sent as raw bytes by the caller. Only modified variants (e.g.
   Shift+Enter) go through keyseq.


## Architecture Notes

### Build structure
```
lib/vterm/           — separate vterm_lib dune library
  *.c, *.h           — vendored glterm files (unmodified)
  vterm_stubs.c      — OCaml C stubs
  vterm_api.ml/mli   — OCaml wrapper
  pty.ml/mli         — PTY management
  dune               — library config

lib/terminal.ml/mli  — ties vterm + PTY, global list, in rocqtui_lib
lib/tab.ml            — msg_tab extended with mt_terminal field
```

### Data flow
```
Outer terminal → stdin → Input.read_event → handle_event
  → term_focused? → translate Input.event to PTY bytes
  → Pty.write (buffered, non-blocking)
  → PTY master fd

PTY master fd → select ready → Terminal.poll
  → Pty.read → Vterm_api.proc → Vterm_api.sync
  → feedback → Pty.write
  → title change → Terminal.title
  → Render_need.request

Render → Terminal.render → Vterm_api.prepare_rows / get_row
  → Grid cells → Render.present → diff → ANSI output
```

### Key input translation
```
Input.Key (cp, {ctrl=true})  where cp >= 64  →  chr(cp & 0x1f)
Input.Key (cp, {ctrl=true})  where cp < 32   →  chr(cp)
Input.Key (cp, {alt=true})                   →  ESC + chr(cp)
Input.Key (cp, no mods)      where cp >= 32  →  UTF-8 encode cp
Input.Special (key, mods)                    →  keyseq_lookup(keysym, mods)
                                                 fallback: raw byte
Input.Paste text                             →  bracketed paste wrap
```


## Future Considerations

### Flexible subwindow layout (Phase 2f)
Eventually want script, goals, messages, and terminal all visible
simultaneously. Keep Terminal.render self-contained (takes grid
region, no layout knowledge). Keep sub-tab switching decoupled from
pane layout.

### Upstream glterm refactors
- Split `sysbuf` out of `sys.c` into its own module
- Split `get_pty`/`pty_set_size` out of `sys.c`
- Goal: no source modifications needed to vendor vterm

### Resolved decisions
- TERM=glterm (glterm terminfo must be installed)
- scroll_dh=0, scroll_dw=0 (scroll state in rocqtui status bar)
- Write buffering from day one
- No auto-expansion of messages pane
- fail.c is fine as-is (only triggers on OOM)
