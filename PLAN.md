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
