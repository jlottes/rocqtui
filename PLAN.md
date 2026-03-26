# Rocqtui: Terminal UI for the Rocq Proof Assistant

## Architecture Overview

OCaml modules + main entry point. Synchronous communication with `coqidetop`
via the XML protocol, using `Unix.select` to multiplex keyboard input and
rocqtop output.

Reuses the installed `coqide-server.protocol` and `coqide-server.core` opam
libraries directly -- no protocol reimplementation needed.

### Module Structure

```
~/rocq/rocqtui/
  bin/
    main.ml              -- Entry point, argument parsing, main loop
  lib/
    buffer.ml/.mli       -- Text buffer (array of lines) + cursor
    display.ml/.mli      -- Curses window layout and rendering
    editor.ml/.mli       -- Keyboard input handling, editing commands
    highlight.ml/.mli    -- Syntax highlighting via CLexer.LexerDiff
    utf8.ml/.mli         -- UTF-8 byte/column mapping, codepoint ops
    locale_stubs.c       -- C stubs for setlocale, wcwidth
    rocq_protocol.ml/.mli -- Spawn coqidetop, send/receive XML protocol
    sentence.ml/.mli     -- Sentence boundary detection in plain text
    session.ml/.mli      -- Session state: document, state tracking
  test/
    test_highlight.ml    -- Highlight test suite
  dune-project
  bin/dune
  lib/dune
```

---

## Phase 1: Skeleton + Curses Layout  ✅ DONE

- Four-pane layout: script (left 60%), goals (right top), messages (right bottom), status bar
- Borders with ACS line-drawing characters, pane labels
- Color pairs initialized, terminal resize handling
- `setlocale(LC_ALL, "")` called before `initscr` for UTF-8 support

---

## Phase 2: Text Buffer + Nano-like Editor  ✅ DONE

- Line-array buffer model with byte-offset cursor
- Arrow keys, Home, End, PageUp, PageDown
- Typing, backspace, delete, newline
- ^O save, ^X exit (with unsaved-changes prompt), ^K cut line, ^U paste
- Scrolling, status bar with filename/modified/cursor position

### UTF-8 support

- `utf8.ml`: codepoint-aware navigation (`next`/`prev`), `byte_to_col`/`col_to_byte` via `wcwidth()`
- Cursor movement steps one codepoint at a time
- Vertical movement preserves desired screen column (`desired_vcol`)
- Backspace/delete operate on whole codepoints
- Status bar shows screen column, not byte offset
- Rendering converts byte-offset spans to screen columns for highlighting

---

## Phase 2.5: Syntax Highlighting  ✅ DONE

### Approach: CLexer.LexerDiff + context-aware state machine

Uses the Rocq compiler's own lexer (`CLexer.LexerDiff`) which never crashes
on unknown tokens. All tokens come as `IDENT`; we check against our own
keyword/tactic sets.

### Context tracking

A state machine with a context **stack** tracks whether we're in:
- **Vernac**: top level (after sentence-ending `.`)
- **Ltac**: after `Proof.`, inside `Ltac <name> :=`, inside `ltac:(...)`
- **Constr**: inside `constr:(...)`, `open_constr:(...)`, `uconstr:(...)`

Paren depth is tracked per stack entry for correct `ltac:(`/`constr:(` nesting.
Tactics are only highlighted in Ltac context.

### Color scheme

| Pair | Color    | Use                                   |
|------|----------|---------------------------------------|
| 6    | blue+bold| Vernacular & Gallina keywords         |
| 7    | cyan     | Tactics (Ltac context only)           |
| 8    | green    | Comments (nested `(* ... *)`)         |
| 9    | yellow   | String literals                       |
| 10   | red+bold | Bullets                               |
| 11   | magenta  | Numbers                               |

### Comment handling

LexerDiff splits `(*` and `*)` into sub-tokens. The highlighter tracks
comment nesting with a counter and accumulates spans across the full comment.

---

## Phase 3: Rocq Protocol Communication

**Goal**: Spawn `coqidetop`, send Init, send Add for a sentence, get goals.

- Spawn `coqidetop --xml_format=Ppcmds` via `Unix.create_process`
- Communication pattern (from `fake_ide.ml`):
  1. Serialize: `Xmlprotocol.of_call call`
  2. Send: `Xml_printer.print printer xml`
  3. Receive: loop `Xml_parser.parse`, skip `Feedback` messages
  4. Decode: `Xmlprotocol.to_answer call xml`
- Implement: `init`, `add`, `edit_at`, `goals`, `quit`
- `has_data : t -> bool` via `Unix.select` with zero timeout

### Protocol call details

- **Add**: `Xmlprotocol.add ((((phrase, edit_id), (tip_state_id, verbose)), bp), (line_nb, bol_pos))`
  - `edit_id`: unique negative integer
  - `bp`: byte position in file
  - Response: `(new_state_id, Inl () | Inr tip_id)`
- **Edit_at**: `Xmlprotocol.edit_at state_id` -- rewind to after that state
- **Goals**: `Xmlprotocol.goals ()` -- returns `Interface.goals option`

---

## Phase 4: Sentence Splitting

**Goal**: Detect Rocq sentence boundaries in buffer text.

- Find `.` followed by whitespace or EOF
- Handle: string literals, nested comments `(* ... *)`, bullets (`-+*{}`), `...` token
- `find_next_sentence : string -> start:int -> int option`
- `split_sentences : string -> (int * int) list`

---

## Phase 5: Session State + Step Forward/Backward

**Goal**: Step through proof, display goals, color verified regions.

### Session state

```ocaml
type sentence_state = {
  start_offset : int;
  end_offset : int;
  state_id : Stateid.t;
  status : [ `Verified | `Processing | `Error of string ];
}

type t = {
  rocq : Rocq_protocol.t;
  buffer : Buffer.t;
  mutable tip : Stateid.t;
  mutable sentences : sentence_state list;  (* stack, most recent first *)
  mutable goals : Interface.goals option;
  mutable messages : string list;
}
```

### Keybindings

| Key       | Action           |
|----------|------------------|
| Ctrl+Down | Step forward     |
| Ctrl+Up   | Step backward    |
| Ctrl+E    | Step to cursor   |

### Rendering

- Color script text: green (verified), yellow (processing), red (error)
- Goals pane: hypotheses + conclusion via `Pp.string_of_ppcmds`
- Messages pane: messages and errors from Rocq

---

## Phase 6: Feedback Handling  ✅ DONE

- Per-sentence status: `Processing`, `Verified`, `Error of string`
- Feedback handler processes: `Processed` → Verified, `Message(Error)` → Error
- Automatic rewind on async errors (sentence accepted then fails during execution)
- `poll_feedback` via `Unix.select` with zero timeout
- Main loop polls every 100ms timeout, re-renders on new feedback
- Messages cleared on each user action (step/go-to-cursor)

---

## Phase 7: Polish  ✅ DONE

- ^C sends SIGINT to coqidetop (our process ignores SIGINT)
- Scrollable goals and messages panes
- Status bar shows: basename, modified flag, cursor pos, verified/processing count
- Goals/messages scroll resets on step actions
- `-theme NAME` CLI flag with 5 themes (solarized-dark, solarized-light, classic, monokai, nord)
- `-R`/`-Q` paths from `_RocqProject` resolved to absolute paths
- `_RocqProject`/`_CoqProject` auto-detected from cwd and file directory
- CLI: `rocqtui [-theme NAME] [file.v] [-- rocq-args...]`

---

## Phase 8: Asynchronous Stepping  (REDO)

**Goal**: Make sentence stepping non-blocking so the UI remains responsive
and the Processing state is visible.

Currently, `eval_call` blocks until rocqtop responds. This means:
- No visual feedback while a sentence is being checked
- `go_to_cursor` freezes the entire UI while stepping through many sentences
- The `Processing` status (yellow) is never visible — it goes straight to `Verified`

### Lessons learned

First attempt used `Spawn.Sync` with `send_call`/`try_receive` and `has_data`
via `Unix.select`. This failed because `Xml_parser` reads from an `in_channel`
which has its own internal buffer — `Unix.select` on the raw fd doesn't see
buffered data, causing responses to be missed.

RocqIDE uses `Spawn.Async(GlibMainLoop)` which:
1. Sets the fd to **non-blocking** mode
2. GLib's main loop calls a **watch callback** when data arrives on the fd
3. The watch callback reads and parses XML, invokes stored continuations
4. Everything is single-threaded, event-driven via a task monad

We will follow the same architecture, replacing GLib with our own curses
`select`-based event loop.

### Phase 8.1: Revert current async attempt

Revert `rocq_protocol.ml` and `session.ml` to synchronous operation.
Remove `send_call`, `try_receive`, `pending_call`, `submit_next_sentence`,
`send_goals_async`, and the `async_state` machine. Restore the sync
`step_forward_inner` and sync `go_to_cursor`.

This gives us a clean baseline that works correctly (if blockingly).

### Phase 8.2: Implement CursesMainLoop

Create `lib/main_loop.ml` implementing the `Spawn.MainLoopModel` signature:

```ocaml
module CursesMainLoop : Spawn.MainLoopModel = struct
  type async_chan = Unix.file_descr
  type condition = [`IN | `ERR | `HUP]
  type watch_id = int

  (* Registry of watched fds and their callbacks *)
  val add_watch : callback:(condition list -> bool) -> async_chan -> watch_id
  val remove_watch : watch_id -> unit
  val read_all : async_chan -> string
  val async_chan_of_file_or_socket : Unix.file_descr -> async_chan
end
```

`add_watch` registers an fd + callback in a mutable table.
`read_all` reads all available bytes from the fd (non-blocking).

### Phase 8.3: Switch to Spawn.Async

Replace `Spawn.Sync` with `Spawn.Async(CursesMainLoop)` in `rocq_protocol.ml`:

- Spawn gives us `process * out_channel` (no `in_channel` — data arrives
  via the watch callback)
- The watch callback receives raw bytes, feeds them to an `Xml_parser`
- When a complete XML message is parsed, dispatch it:
  - Feedback → accumulate in `pending_feedback`
  - Response → invoke the stored continuation

The `eval_call` pattern (from RocqIDE):
1. Store `(call, continuation)` in `handle.waiting_for`
2. `Xml_printer.print` sends the request
3. Return immediately (control back to main loop)
4. When response arrives via watch callback, invoke continuation

### Phase 8.4: Task monad

Implement RocqIDE's task monad for chaining async operations:

```ocaml
type 'a task = handle -> ('a -> unit) -> unit

val return : 'a -> 'a task
val bind : 'a task -> ('a -> 'b task) -> 'b task
val seq : unit task -> 'a task -> 'a task
val lift : (unit -> 'a) -> 'a task
```

This allows chaining: `add >>= fun id -> goals >>= fun gs -> ...`
without callback nesting.

### Phase 8.5: Async session operations

Rewrite session operations as tasks:

- `step_forward`: `set_options >>= add >>= goals` task chain
- `step_backward`: `edit_at >>= goals` (can stay sync since rewind is fast)
- `go_to_cursor`: sets a target, submits first sentence; the Add callback
  checks if more steps are needed and submits the next one

Each sentence goes through: send Add → Processing → response → Verified/Error.
The main loop renders between each step.

### Phase 8.6: Main loop integration

Update `bin/main.ml` main loop:

```
while running do
  (* Check all watched fds + stdin with select *)
  let timeout = 100ms in
  let ready_fds = Unix.select (watched_fds @ [stdin]) [] [] timeout in

  (* Dispatch watched fd callbacks *)
  List.iter dispatch_watch ready_fds;

  (* Handle keyboard input *)
  if stdin_ready then
    let ch = Curses.getch () in
    handle_key ch ...;

  (* Render if state changed *)
  if state_changed then render_all ()
done
```

Key: `select` multiplexes stdin (keyboard) and rocqtop output in one call.
Both are handled in the same iteration, no separate timeout poll needed.

### Phase 8.7: Cancellation

- Editing in unverified region while stepping: cancel `go_to_cursor`
- `^C`: send SIGINT to rocqtop, cancel pending operations
- New `step_forward` while already stepping: queue or ignore

### Notes

- `select(2)` is fine for 2-3 fds. No need for epoll/pselect.
- `set_options` and `query` can remain synchronous — they're fast and
  don't benefit from async (and `set_options` must complete before `goals`).
- The `Xml_parser` must work with the raw bytes from `read_all`, not an
  `in_channel`. This avoids the buffering issue from the first attempt.
- `edit_at` (backward stepping) can stay synchronous since rewind is fast
  and we need the result before proceeding.
