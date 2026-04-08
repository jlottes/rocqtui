# Embedded Terminal Plan

Add embedded terminal tabs to rocqtui, powered by glterm's vterm C library.
Terminal tabs live in the **message sub-tab bar** alongside "Rocq" and
"Build" — not in the top-level file tab bar. This means the user always
sees script + goals alongside the terminal. Terminals are global (shared
across file tabs, like build output). The primary use case is running
Claude Code connected to rocqtui's MCP server.

## Phase 1: C Binding Layer

Wrap the vterm C library for use from OCaml.

### 1a. Vendor vterm source files

Copy the minimal set of C files from `~/glterm-1` into `lib/vterm/`:

**Core:** `vterm.c`, `vterm.h`, `term.c`, `term.h`, `wrap.c`, `wrap.h`,
`sel.c`, `sel.h`

**Support:** `mem.h`, `sys.c`, `sys.h`, `fail.c`, `fail.h`, `c99.h`,
`types.h`, `utf-8.h`, `char_width.h`, `acs.c`, `acs.h`

**Key/mouse encoding:** `keyseq.c`, `keyseq.h`, `kitty_keyseq.c`,
`kitty_keyseq.h`, `mouseseq.c`, `mouseseq.h`

**Goal: no source modifications to vendored vterm files.** Both
projects are under the same ownership, so the right approach is to
make vterm cleanly embeddable upstream. For now, vendor as-is and
tolerate some extra code; refactor glterm later to make it cleaner.

Upstream refactors to do eventually (in glterm, not rocqtui):
- Split `sysbuf` out of `sys.c` into its own module (`sysbuf.c/h`).
- Split `get_pty`/`pty_set_size` out of `sys.c` (or make them
  optional — the embedder may provide its own PTY management).
**For now:** vendor `sys.c` in full. The extra glterm-specific code
(epoll, `procpath`, mkfifo, signal handling) is dead code in this
context but harmless. `fail.c` is fine as-is — it only triggers on
unrecoverable errors (OOM, mmap failure), where `exit()` is
reasonable.

Add to `lib/dune`:
```
(foreign_stubs
  (language c)
  (names locale_stubs inotify_stubs term_stubs
         vterm_stubs)
  (flags (:standard -std=c99 -D_XOPEN_SOURCE=600))
  (include_dirs vterm))
```

### 1b. OCaml C stubs (`lib/vterm_stubs.c`)

Write C stubs exposing vterm to OCaml. The vterm struct lives as a
custom block (or a pointer wrapped in `Obj.custom`). Key bindings:

```c
// Lifecycle
CAMLprim value caml_vterm_create(value backlog, value fwdlog,
    value w, value h, value wrap_mode);
CAMLprim value caml_vterm_destroy(value v);

// PTY
CAMLprim value caml_pty_open(value cmd, value args, value env);
  // returns (master_fd, child_pid)
CAMLprim value caml_pty_set_size(value fd, value w, value h);

// Data flow
CAMLprim value caml_vterm_proc(value v, value bytes, value off, value len);
CAMLprim value caml_vterm_sync(value v);
  // returns record: { feedback: bytes option; title: string option;
  //                    mouse_changed: bool; clipboard: string option }

// Resize
CAMLprim value caml_vterm_resize(value v, value w, value h);

// Display
CAMLprim value caml_vterm_prepare_rows(value v);  // returns int (row count)
CAMLprim value caml_vterm_get_row(value v, value y);
  // returns array of (codepoint, fg, bg, attrs, width, selected, cursor)
  // or writes directly into a Grid.t for efficiency (see Phase 3)

// Scroll
CAMLprim value caml_vterm_scroll(value v, value n);
CAMLprim value caml_vterm_scroll_to_end(value v, value top);

// Selection
CAMLprim value caml_vterm_hit_test(value v, value row, value col);
CAMLprim value caml_vterm_sel_start(value v, value line, value col);
CAMLprim value caml_vterm_sel_extend(value v, value line, value col);
CAMLprim value caml_vterm_sel_word(value v, value line, value col);
CAMLprim value caml_vterm_sel_text(value v);  // returns string option

// Key encoding
CAMLprim value caml_keyseq_lookup(value keysym, value mod_, value mode,
    value event_type);
CAMLprim value caml_kitty_keyseq_lookup(value keysym, value base_keysym,
    value mod_, value mode, value kitty_flags, value event_type,
    value text);

// Mouse encoding
CAMLprim value caml_mouseseq(value button, value mod_, value cx, value cy,
    value ev, value mode, value flags);

// State queries
CAMLprim value caml_vterm_mouse_mode(value v);
CAMLprim value caml_vterm_mouse_flags(value v);
CAMLprim value caml_vterm_kitty_flags(value v);
CAMLprim value caml_vterm_term_mode(value v);
CAMLprim value caml_vterm_alt_screen(value v);
CAMLprim value caml_vterm_bracketed_paste(value v);
CAMLprim value caml_vterm_has_selection(value v);
CAMLprim value caml_vterm_cursor_pos(value v);
  // returns (on_screen, x, y, w) or None
```

### 1c. OCaml wrapper module (`lib/vterm.ml`)

Type-safe OCaml interface:

```ocaml
type t  (* opaque, backed by C custom block *)

type sync_result = {
  feedback : bytes option;
  title : string option;
  mouse_changed : bool;
  clipboard : string option;
}

type cursor_info = {
  on_screen : bool;
  x : int; y : int; w : int;
}

val create : backlog:int -> fwdlog:int -> w:int -> h:int
  -> wrap_mode:int -> t
val destroy : t -> unit

val proc : t -> bytes -> off:int -> len:int -> unit
val sync : t -> sync_result
val resize : t -> w:int -> h:int -> unit

val prepare_rows : t -> int
val blit_row : t -> y:int -> grid:Grid.t -> row:int -> col:int
  -> width:int -> unit
  (* render row y directly into grid at (row, col), clipped to width *)

val scroll : t -> int -> bool
val scroll_to_end : t -> top:bool -> bool

val hit_test : t -> row:int -> col:int -> int * int  (* line, col *)
val sel_start : t -> line:int -> col:int -> unit
val sel_extend : t -> line:int -> col:int -> unit
val sel_word : t -> line:int -> col:int -> unit
val sel_text : t -> string option
val has_selection : t -> bool

val mouse_mode : t -> int
val mouse_flags : t -> int
val kitty_flags : t -> int
val term_mode : t -> int
val alt_screen : t -> bool
val bracketed_paste : t -> bool
val cursor : t -> cursor_info option

(* Key/mouse encoding *)
val keyseq : keysym:int -> modifiers:int -> mode:int
  -> event_type:int -> string option
val kitty_keyseq : keysym:int -> base_keysym:int -> modifiers:int
  -> mode:int -> kitty_flags:int -> event_type:int
  -> text:string -> string option
val mouseseq : button:int -> modifiers:int -> cx:int -> cy:int
  -> ev:int -> mode:int -> flags:int -> string
```

**Key design: `blit_row`** renders a vterm display row directly into
`Grid.t` cells, mapping `struct gr` to `Grid.attr`:

| `struct gr` | `Grid.attr` |
|-------------|-------------|
| MD=0, color 0-7 | `Basic color` |
| MD=0, color 8-15 | `Basic color` |
| MD=0, color 9 (default) | `Default` |
| MD=1 (256-color) | `Color256 index` |
| MD=2 (24-bit) | `TrueColor (r,g,b)` |
| ATTRB_BD | `bold = true` |
| ATTRB_UL | `underline = true` |
| ATTRB_IN | `reverse = true` |

This avoids allocating intermediate OCaml values for every cell every
frame. The C stub reads vterm cells and writes Grid cells directly.

### 1d. PTY module (`lib/pty.ml`)

```ocaml
type t = {
  fd : Unix.file_descr;
  pid : int;
  mutable write_buf : bytes;  (* buffered writes for non-blocking PTY *)
  mutable write_off : int;
  mutable write_len : int;
}

val spawn : cmd:string -> args:string list -> env:(string * string) list
  -> w:int -> h:int -> t
val set_size : t -> w:int -> h:int -> unit
val write : t -> string -> unit  (* buffered, non-blocking *)
val flush_write : t -> unit      (* drain write buffer when fd writable *)
val read : t -> bytes -> int     (* non-blocking read, returns bytes read *)
val close : t -> unit
val fd : t -> Unix.file_descr
```

Non-blocking writes are important: pastes and key sequences can be
large, and a blocking write would stall the event loop.


## Phase 2: Terminal as Message Sub-Tab

### 2a. Terminal type (`lib/terminal.ml`)

```ocaml
type t = {
  vterm : Vterm.t;
  pty : Pty.t;
  mutable title : string;       (* from OSC 2 *)
  mutable closed : bool;        (* child exited *)
  mutable exit_code : int option;
}

val create : ?cmd:string -> ?args:string list -> ?env:(string * string) list
  -> w:int -> h:int -> unit -> t
val destroy : t -> unit
val fd : t -> Unix.file_descr
val poll : t -> bool            (* read available data, returns true if changed *)
val resize : t -> w:int -> h:int -> unit
val render : t -> Grid.t -> row:int -> col:int -> width:int -> height:int -> unit
val handle_key : t -> Input.event -> bool  (* true if consumed *)
val handle_mouse : t -> button:int -> x:int -> y:int -> ev:int
  -> modifiers:Input.modifier -> bool
```

`create` defaults to `$SHELL` (or `/bin/bash`). For Claude, the caller
would pass `~cmd:"claude" ~args:["--chat"]` or similar.

### 2b. Global terminal list

Terminals are global (like `Build.active`), not per-file-tab:

```ocaml
(* lib/terminal.ml or lib/terminal_mgr.ml *)
let terminals : t list ref = ref []

val add : t -> unit
val remove : t -> unit
val all : unit -> t list
val fds : unit -> (Unix.file_descr * t) list
```

### 2c. Extend msg_tabs to include terminals

Currently `msg_tabs` holds text-based sub-tabs (lines + scroll).
Terminal sub-tabs are fundamentally different — they render via vterm,
not line lists. Extend the sub-tab concept:

```ocaml
type msg_tab_content =
  | TextTab of { mt_lines : string list; mt_scroll : int; ... }
  | TerminalTab of Terminal.t

type msg_tab = {
  mt_name : string;
  content : msg_tab_content;
  ...
}
```

Alternatively, keep `msg_tab` as-is for text tabs and add terminal
references by name into `msg_tabs`:

```ocaml
type msg_tabs = {
  mutable mt_tabs : msg_tab list;  (* existing text tabs *)
  mutable mt_active : int;
  (* terminal sub-tabs are interleaved by name *)
}
```

**Recommendation:** Use the variant approach (`msg_tab_content`).
The active sub-tab index already selects which sub-tab to render;
the renderer just needs to check whether it's text or terminal and
dispatch accordingly.

### 2d. Sub-tab bar display

Terminal sub-tabs appear in the message pane's tab bar alongside
"Rocq" and "Build". They show their title (from OSC 2, defaulting
to "Terminal" or "Claude"). The sub-tab bar already exists and
supports switching — terminal tabs just need to be added to the list.

### 2e. Relationship between file tabs and terminal sub-tabs

Terminals are **global**: the same terminal sub-tabs are visible
regardless of which file tab is active. The "Rocq" sub-tab remains
per-file-tab (it shows messages from that file's Rocq session).
"Build" is already global.

This means `msg_tabs` needs to merge per-file text tabs with global
terminals. Options:

**Option A: msg_tabs references global terminals**
Each file tab's `msg_tabs` always includes the global terminal list.
When rendering the sub-tab bar, combine the file-tab's own text tabs
(like "Rocq") with the global terminal list.

**Option B: separate the sub-tab bar from msg_tabs**
The sub-tab bar becomes a UI concept that mixes per-file and global
sub-tabs. The data stays separate: `tab.msg` for text, global list
for terminals.

**Recommendation: Option A** — simpler rendering, the sub-tab bar
just iterates `msg_tabs` which contains everything.

### 2f. Future: flexible subwindow layout

Currently the layout is hardcoded in `render.ml`: script on the left,
goals/messages stacked on the right, with fixed split positions. The
messages pane and goals pane share a single vertical region, switched
by the sub-tab / pane focus.

Eventually we may want **all four panes visible simultaneously**:
script, goals, messages, and terminal. This suggests moving toward
a more general layout model — something like a tiling window manager
where panes can be split and resized independently.

**For now:** keep the current layout. Terminals render in the messages
pane area, swapped via the sub-tab bar. This works and avoids a large
layout refactor.

**Design considerations for later:**
- The right side could split into three regions (goals / messages /
  terminal) instead of two. But this gets cramped quickly.
- A more general approach: each "pane" (script, goals, messages,
  terminal) is an independent renderable with a size, and the layout
  engine tiles them according to a user-configurable tree of splits.
- The current `Render.t` with its fixed `script`, `goals`, `messages`
  rects would become a list/tree of `pane` rects.
- Input routing (`focused_pane`) would generalize from the current
  fixed variant to indexing into the pane tree.

**What to keep in mind now:** avoid design choices in Phase 2 that
make this harder later. In particular:
- Keep terminal rendering self-contained in `Terminal.render` — it
  takes a grid region, not knowledge of the overall layout.
- Keep the sub-tab concept (messages/terminal switching) decoupled
  from the pane layout — the sub-tab bar is a UI for selecting what
  fills a pane slot, which is orthogonal to how many slots exist.
- Don't hardcode assumptions about the messages pane being the *only*
  place a terminal can render.


## Phase 3: Input Routing

### 3a. Key translation

When the messages pane is focused (`focused_pane = `Messages`) and the
active sub-tab is a terminal, keyboard input goes to the PTY instead
of the editor. The translation from `Input.event` to PTY bytes:

1. **`Input.Key (codepoint, mods)`**: Map to X11-style keysym, call
   `kitty_keyseq_lookup` (if vterm has kitty flags) or `keyseq_lookup`.
   If neither produces output, write raw UTF-8.

2. **`Input.Special (key, mods)`**: Map special keys to X11 keysyms
   (Up→0xff52, F1→0xffbe, etc.), call keyseq lookup.

3. **`Input.Paste text`**: Wrap in bracketed paste if
   `Vterm.bracketed_paste` is set.

4. **`Input.Resize`**: Handle at the main loop level (resize all
   terminals).

### 3b. Escape key handling

Need a way to "escape" from terminal input to rocqtui commands.
Options:
- **Ctrl+Shift prefix** (like tmux/screen prefix key)
- **Double-Escape** (ESC ESC within a short window)
- **Specific combo** like Ctrl+\ or Ctrl+]

Recommended: a configurable prefix key, defaulting to something that
doesn't conflict with common terminal usage. A status bar indicator
shows when the terminal is capturing input.

### 3c. Reserved keys

Some keys always go to rocqtui even when a terminal sub-tab is focused:
- Ctrl+P to cycle pane focus (escape back to script pane)
- File tab switching (Ctrl+PageUp/PageDown)
- Message sub-tab switching (existing mechanism)
- Ctrl+W to close file tab
- Ctrl+X to exit


## Phase 4: Rendering

### 4a. Terminal pane rendering

When the active message sub-tab is a terminal, the messages pane
renders the terminal instead of text lines. The terminal occupies
the existing messages pane rect — script and goals remain visible
in their usual positions.

`Terminal.render` calls:
1. `Vterm.prepare_rows vt` to get row count
2. For each visible row, `Vterm.blit_row vt ~y grid ~row ~col ~width`
   writes cells directly into the Grid

**Cursor:** no fake cursor rendering. When the terminal sub-tab is
focused, use `Render.place_cursor` to position the real hardware
cursor at the vterm's cursor location (offset into the messages pane
rect). The outer terminal draws the cursor natively. This is what the
editor already does for the script pane — just a different source for
the cursor position. `Vterm.cursor` returns `(x, y)` relative to the
vterm display; add the messages pane origin to get screen coordinates.

### 4b. Color mapping in `blit_row`

The C stub `caml_vterm_blit_row` needs access to `Grid.t`'s internal
representation. Since `Grid.cell` is an OCaml record and `Grid.t` has
`cells : cell array array`, the stub would:

1. Get the Grid's row array for the target row
2. For each vterm cell, construct an OCaml `Grid.cell` record:
   - `text`: UTF-8 encode the codepoint (handle combining chars)
   - `width`: from `vterm_cell.w`
   - `attr`: map `struct gr` to `Grid.attr` (color mode + attributes)
3. Store into the array

Alternative: do the mapping in OCaml. `vterm_get_row` returns raw cell
data, OCaml code maps to Grid cells. Simpler stubs, slightly more
allocation. **Start with this approach** for correctness, optimize to
`blit_row` later if needed.

### 4c. Status bar

When the messages pane is focused on a terminal sub-tab, the status
bar shows:
- Terminal title / process status (running / exited with code N)
- Scroll indicator (if scrolled back in terminal history)
- Input mode indicator (terminal is capturing keys)


## Phase 5: Main Loop Integration

### 5a. FD collection

In `bin/main.ml`, collect terminal PTY fds from the global terminal
list alongside other watched fds:

```ocaml
let term_fds = Terminal.fds () in  (* list of (fd, terminal) pairs *)
let extra_fds = stdin_fd :: mcp_fds @ build_fds @ watch_fds
  @ List.map fst term_fds in
```

### 5b. Polling

When a terminal fd is ready:
```ocaml
List.iter (fun (fd, term) ->
  if List.mem fd ready then begin
    if Terminal.poll term then
      Render_need.request ()
  end
) term_fds
```

### 5c. Write buffer draining

If any terminal has buffered writes, add its fd to the write set in
select, and call `Pty.flush_write` when writable. (This may require
extending `select_with_watches` to accept write fds, or handling it
separately.)

### 5d. Child exit detection

`Terminal.poll` detects EOF on the PTY fd (read returns 0). At that
point, reap the child with `waitpid` and store the exit code. The
terminal remains viewable (scrollback preserved) but stops polling.


## Phase 6: Terminal Management UI

### 6a. Creating terminals

- Menu item or keybinding to open a new terminal sub-tab
  (e.g., from the existing Query menu or a new terminal menu)
- Option to specify command (default: `$SHELL`)
- Shortcut to open Claude (see Phase 8)

### 6b. Closing terminals

- Close terminal sub-tab: if process is running, prompt for
  confirmation. Send SIGHUP to process group on close.
- If process has exited, close immediately and remove the sub-tab.
- Closing a file tab does not close global terminal sub-tabs.

### 6c. Resize

When the outer terminal resizes (SIGWINCH), or when the messages
pane dimensions change (split adjustment), resize all terminal
vtems to match the messages pane dimensions and call `pty_set_size`.


## Phase 7: Selection & Clipboard

### 7a. Mouse selection

When mouse events land in the terminal pane:
- If the terminal has mouse reporting enabled (and Shift is not held),
  forward mouse events to the PTY via `mouseseq`
- Otherwise, use vterm's selection API (`sel_start`, `sel_extend`,
  `sel_word`) for local selection
- Selected text goes to clipboard via OSC 52 (existing
  `Clipboard.copy`)

### 7b. Paste

Ctrl+V (or middle-click): read clipboard, write to PTY with bracketed
paste wrapping if enabled.

### 7c. OSC 52 from child

When `vterm_sync` returns clipboard data, store it via
`Clipboard.copy`.


## Phase 8: Claude Integration

### 8a. "Open Claude" command

A keybinding or menu item that:
1. Creates a terminal tab
2. Spawns `claude` with appropriate arguments
3. Sets `TERM=glterm`
4. The MCP socket is already available in the project dir

### 8b. MCP auto-connection

If rocqtui's MCP server is running, set an environment variable
(e.g., `ROCQTUI_MCP_SOCKET`) in the child's environment so Claude
can auto-discover and connect.

### 8c. Bidirectional interaction

Claude (in the terminal sub-tab) uses MCP to drive rocqtui. The user
sees Claude's output in the messages pane while simultaneously viewing
the script and goals. As Claude steps through proofs via MCP, the
script highlighting and goals pane update in real time alongside
Claude's terminal output.


## Implementation Order

| Step | Phase | Est. Effort | Description |
|------|-------|-------------|-------------|
| 1 | 1a | Medium | Vendor and adapt vterm C files |
| 2 | 1b | Large | Write C stubs |
| 3 | 1c | Medium | OCaml Vterm module |
| 4 | 1d | Small | PTY module |
| 5 | 2a | Medium | Terminal.t module |
| 6 | 2c,2e | Medium | Extend msg_tabs with terminal variant |
| 7 | 3a | Medium | Key translation (Input.event -> PTY bytes) |
| 8 | 4a,4b | Medium | Terminal rendering in messages pane |
| 9 | 5a-d | Medium | Main loop integration (global terminal fds) |
| 10 | 3b,3c | Small | Escape key / reserved keys |
| 11 | 4c | Small | Status bar for terminal sub-tabs |
| 12 | 6a-c | Small | Terminal management UI |
| 13 | 7a-c | Medium | Selection & clipboard |
| 14 | 8a-c | Small | Claude integration shortcuts |

Steps 1-4 (C binding) are the foundation. Steps 5-9 get a working
terminal in the messages pane. Steps 10-14 are polish and integration.

### Milestones

**M1 — Proof of concept:** Steps 1-4 complete. Can create a vterm,
feed it data, read cells from OCaml. No UI yet.

**M2 — Visible terminal:** Steps 5-9 complete. Terminal sub-tab
appears in the messages pane alongside "Rocq". Can type commands,
see output, while script+goals remain visible.

**M3 — Usable terminal:** Steps 10-13 complete. Selection, clipboard,
proper escape keys, resize handling.

**M4 — Claude integration:** Step 14. One-key Claude launch with MCP
auto-connection.


## Open Questions

1. **msg_tab variant design:** The `msg_tab_content` variant
   (`TextTab | TerminalTab`) changes how msg_tabs are rendered and
   how input is dispatched. How much of view.ml's message rendering
   needs refactoring? Currently it renders lines from `mt_lines`;
   the terminal path is completely different (vterm cells to Grid).

2. **Global vs per-file sub-tab merging:** Each file tab has its own
   "Rocq" messages but terminals are global. The sub-tab bar needs to
   combine both. Should `msg_tabs` store global terminals inline
   (rebuilt on tab switch), or should the renderer merge two lists
   at display time?

3. **TERM environment variable:** Set `TERM=glterm`. The glterm
   terminfo must be installed on the system.

4. **Scroll delta:** Use `scroll_dh=0`, `scroll_dw=0`. Show scroll
   state in the rocqtui status bar (no row stolen from the terminal).
   A vertical scrollbar (`scroll_dw=-1`) might be nice but isn't
   implemented on the vterm side yet.

5. **Write buffering:** Yes, from day one. Non-blocking writes with
   buffering fit naturally into the select loop — add the PTY fd to
   the write set when there's buffered data, drain on writable.

6. **sys.c adaptation:** `sysbuf` (mmap-backed buffers) is essential —
   it's the scrollback storage for `struct term`. `get_pty` and
   `pty_set_size` are also needed. Strip: epoll, signal handling,
   `procpath`, mkfifo, and other glterm-app-level code. The remaining
   `sys.c` should be fairly clean.

7. **Messages pane size for terminal use:** No auto-expansion. The
   terminal uses whatever size the messages pane currently is. The
   user can adjust the split manually. Layout changes deferred to
   future work.
