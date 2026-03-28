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

---

## Phase 9: Multi-file Tabs

**Goal**: Support multiple files open simultaneously, each with its own
Rocq session, in a tabbed interface.

### Architecture

Each open file gets a **tab** containing:
- Its own `Buffer.t`
- Its own `Session.t` (separate coqidetop process)
- Its own goals pane scroll, messages pane scroll, pane focus state
- Its own editor state (selection, compose, etc.)

A **tab manager** holds the list of tabs and tracks the active tab.
The main loop polls ALL sessions but only renders the active tab.

### Phase 9.1: Tab data structure

Create `lib/tab.ml`:

```ocaml
type t = {
  buf : Buffer.t;
  session : Session.t option;
  mutable goals_scroll : int;
  mutable messages_scroll : int;
  mutable focused_pane : pane;
  (* ... other per-tab state currently in editor.ml globals *)
}

type manager = {
  mutable tabs : t list;
  mutable active : int;  (* index into tabs *)
  mutable tab_scroll : int;  (* scroll offset for tab bar *)
}
```

Move all per-tab mutable state out of `editor.ml` globals and into `tab.t`.
This includes: `goals_scroll`, `messages_scroll`, `focused_pane`,
`show_all_hyps`, `goals_sel`, `messages_sel`, `goals_lines_cache`,
`messages_lines_cache`, `clipboard` (shared across tabs),
`mouse_selecting`, `dragging`, `suppress_ensure_visible`.

### Phase 9.2: Tab bar rendering

Add a tab bar at the top of the screen (row 0), shifting the script/goals/
messages panes down by one row.

Tab bar layout:
```
◀ file1.v │ file2.v │ *file3.v │ file4.v ▶
```

- Active tab is highlighted (bold, different background)
- Scroll arrows (`◀` `▶`) appear when tabs overflow the width
- Tab names show `filename.v` (basename only), with `*` prefix if modified
- Clicking a tab switches to it
- Scroll arrows respond to clicks

### Phase 9.3: Tab management keybindings

| Key              | Action                              |
|------------------|-------------------------------------|
| Alt+Left         | Previous tab                        |
| Alt+Right        | Next tab                            |
| ^B               | New blank tab                       |
| ^X               | Close tab (exit if last)            |

Uses the same modifier (Alt) as step forward/back (Alt+Up/Down)
but on left/right instead. ^T remains for printing options.

Opening named files will be addressed separately (file picker, etc).

### Phase 9.4: Refactor editor.ml

`handle_key` currently takes a single `Buffer.t` and `Session.t option`.
Refactor to take a `Tab.t` (or `Tab.manager`):

- All editor state reads/writes go through the active tab
- `render_all` renders only the active tab's content
- Global state (clipboard, compose) stays global

### Phase 9.5: Multi-session poll loop

Update the main loop:

```
while running do
  let timeout = ... in
  let ready = Main_loop.select_with_watches [stdin_fd] timeout in

  (* Poll ALL sessions, not just the active one *)
  List.iter (fun tab ->
    match tab.session with
    | Some s -> ignore (Session.poll s)
    | None -> ()
  ) manager.tabs;

  (* But only re-render the active tab *)
  let active = active_tab manager in
  if state_changed_any then
    render active;

  (* Handle keyboard input for active tab *)
  if stdin_ready then handle_key active_tab ...
done
```

Each session's watch callback is already registered with
`Main_loop` via `Spawn.Async`. `select_with_watches` dispatches
ALL watch callbacks for all sessions, so background tabs keep
processing sentences even when not visible.

### Phase 9.6: Opening files

- Command line: `rocqtui file1.v file2.v ...` opens each in a tab
- `^B` opens a new blank tab
- Named file opening (file picker, etc.) to be designed later
- Each tab gets its own `_RocqProject` lookup based on the file's
  directory (different files may be in different projects)
- Session args are per-tab

### Phase 9.7: Tab interactions

- Status bar shows tab-relevant info (filename from active tab)
- `^O` saves the active tab's file
- `^X` with multiple tabs: close active tab (prompt if unsaved)
- `^X` with one tab: exit (prompt if unsaved)
- Unsaved changes prompt is per-tab
- Mouse click on tab bar switches tabs

### Notes

- `select` with many fds is fine — we'll have at most ~10 tabs,
  each with one fd. Well within `select`'s limits.
- Memory: each tab has a full buffer, session, and coqidetop process.
  This is fine — coqidetop processes are lightweight until they
  load large libraries.
- The tab bar takes one row from the terminal. On small terminals
  this matters. Could make it hideable.
- Consider: should closing the last tab exit, or show an empty
  tab / welcome screen?

---

## Phase 10: File Opening

**Goal**: Two ways to open files in new tabs — a project file picker dialog,
and a hotkey to jump to the file for a `Require Import` module at the cursor.

### Phase 10.1: Module resolution

Implement module-name-to-file-path resolution using the `-R` and `-Q` flags
from `_RocqProject`. This is needed for both the file picker (knowing which
files belong to the project) and the "open module at cursor" feature.

**`-R dir logical`** maps physical directory `dir` recursively to logical
prefix `logical`. Implicit: files can be imported with or without the prefix.

**`-Q dir logical`** maps physical directory `dir` to logical prefix `logical`.
Explicit: must use full qualified path.

Resolution logic for `Require Import A.B.C`:
1. For each `-R dir prefix` / `-Q dir prefix`:
   - If the module path starts with `prefix`, strip it. Remaining path
     `B.C` → file `dir/B/C.v`.
   - For `-R` (implicit): also try the full path without stripping.
     `A.B.C` → file `dir/A/B/C.v`.
2. First match wins.

Add to `project.ml`:
```ocaml
type load_path_entry = {
  physical_dir : string;   (* absolute path *)
  logical_prefix : string; (* dotted, e.g. "AffineConstructive" *)
  implicit : bool;         (* -R = true, -Q = false *)
}

val load_paths : string -> load_path_entry list
(* Parse _RocqProject and return load path entries *)

val resolve_module : load_path_entry list -> string -> string option
(* Map a dotted module name to a .v file path *)

val project_files : load_path_entry list -> string list
(* List all .v files reachable through the load paths *)
```

### Phase 10.2: Project file picker dialog (^O)

A modal overlay that shows project files in a tree view with
Unicode line-drawing characters.

**Layout:**
```
┌─ Open File ──────────────────────────┐
│ ▾ interfaces/                        │
│   ├── prelude.v                      │
│   ├── notation.v                     │
│   ├── orders.v                       │
│   └── subset/                        │
│       ├── notation.v                 │
│       └── ...                        │
│ ▾ theory/                            │
│   ├── groups.v                       │
│   ├── rings.v                        │
│   └── nno.v                          │
│ ▾ implementations/                   │
│   ├── nat/                           │
│   │   ├── nno.v                      │
│   │   └── rig.v                      │
│   └── bool.v                         │
│                                      │
│ [P] project files  [A] all .v files  │
└──────────────────────────────────────┘
```

**Features:**
- Tree view with `├──`, `└──`, `│` connectors
- Directories shown as nodes, files as leaves
- Highlight bar on selected item (navigate with Up/Down/PageUp/PageDown)
- Mouse wheel scrolls, mouse click selects
- Enter opens the selected file in a new tab (or switches to existing tab)
- Escape closes the dialog
- `p` key: show only files listed in `_RocqProject` (default)
- `a` key: show all `*.v` files found recursively in load path dirs
- Currently-open files shown with a marker (e.g., `•` prefix)
- **Tab disambiguation**: when two open tabs have the same basename (e.g.,
  two `notation.v` files), the tab bar shows enough parent directories to
  disambiguate: `interfaces/notation.v` vs `subset/notation.v`

**Implementation:**
- New module `file_picker.ml`:
  - `type tree_node = Dir of string * tree_node list | File of string`
  - Build tree from project file list or recursive directory scan
  - Flatten to display lines with indent + connectors
  - Track selection index, scroll offset
  - Render into a centered overlay window
- `editor.ml`: new `in_file_picker` mode, similar to `in_help_mode`
- Tree is built once on dialog open, not re-scanned on every keypress

**Data flow:**
1. ^P pressed → `Project.load_paths` from active tab's project dir
2. If project mode: `Project.project_files` (files listed in _RocqProject)
3. If all mode: recursive scan of load path directories for `*.v`
4. Build tree, flatten, render
5. Enter → `Tab.create_from_file`, `Tab.add_tab`, close dialog

Note: this dialog is bound to ^O after the save→^S remap in Phase 10.5.
Implement 10.5 first or concurrently.

### Phase 10.3: Tab name disambiguation

When multiple tabs have the same `Filename.basename`, show enough
of the path to distinguish them. For example, if both
`interfaces/notation.v` and `interfaces/subset/notation.v` are open,
show `notation.v` and `subset/notation.v` (or more if still ambiguous).

Algorithm:
1. Group tabs by basename
2. For groups with >1 tab, progressively prepend parent directory
   components until all names in the group are unique
3. Cache the display names, recompute when tabs are added/closed

Update `tab_at_x` and the tab bar rendering in `main.ml` and `display.ml`
to use display names instead of raw basenames.

### Phase 10.4: Open module at cursor (^L)

When the cursor is on a `Require Import` or `From ... Require` line,
parse the module name(s) and open the corresponding file.

**Resolution strategy — two approaches, tried in order:**

1. **Query Rocq** via `Locate Library <module>.` — works for everything
   on the load path including the stdlib, prelude, and installed packages.
   Returns a `.vo` path; swap `.vo` → `.v` for the source file. Doesn't
   require the module to be loaded first. Requires a running session.

2. **Local resolution** via our `-R`/`-Q` load path logic — works for
   project-local files even if not yet compiled to `.vo`. Falls back
   to this if there's no session or `Locate Library` fails.

Tested: `Locate Library interfaces.prelude.` with `-R . AffineConstructive`
returns the full `.vo` path correctly, even with implicit (short) names.

**Parsing the Require line:**
- Detect lines matching: `(From <prefix>)? Require (Import|Export)? <modules>.`
- Extract the module name(s) — there may be several separated by spaces
- If `From X` form, prepend `X.` to each module name

**Behavior:**
- ^L with cursor on a Require line: resolve the module name nearest
  the cursor (or the first one if cursor isn't on a specific name)
- If file found: open in new tab (or switch to existing tab)
- If not found: show message in status bar ("Module Foo.Bar not found")
- If multiple modules on the line: open the one the cursor is on
  (by finding which module name span contains the cursor column)

**Edge cases:**
- `Require Import A B C.` — three modules on one line
- `From Lib Require Import A B.` — prefix applied to all
- Module not in project (stdlib, etc.) — resolve via `Locate Library`,
  which finds stdlib `.vo` files; derive `.v` from the path
- Cursor not on a Require line — show "No Require at cursor"

### Phase 10.5: Remap save to ^S, open to ^O

Change `^O` (currently save) to `^S` (universally expected for save).
Free up `^O` for "open file" (the file picker from 10.2).

**Flow control:** `^S` is the XOFF character that freezes terminals
with flow control enabled. At startup, disable flow control by
clearing the IXON flag via `tcsetattr` (same approach as nano/vim).
Add a C stub or use `Unix.tcsetattr` in OCaml.

Update keybindings:
| Key | Old Action | New Action |
|-----|-----------|------------|
| ^S  | (free)    | Save       |
| ^O  | Save      | Open file picker |
| ^P  | (free)    | (available for other use) |

### Notes

- The file picker tree is purely cosmetic — it doesn't represent the
  logical module hierarchy, just the physical directory structure.
  This is simpler and matches what users see in their file manager.
- The `_RocqProject` file lists files in compilation order, but the
  picker should show them in alphabetical/tree order.
- For large projects, the tree could be long. Scrolling is essential.
  Consider: should directories be collapsible? Start with flat expanded
  tree — collapsibility is a nice-to-have.
- The "all .v files" mode helps when files exist but aren't yet added
  to `_RocqProject`.
- ^O for open (after remapping save to ^S) is the standard binding.
  ^L (12) is free and works for "locate module".
- Disabling IXON is safe — no modern terminal workflow depends on
  ^S/^Q flow control, and nano/vim both do this.

---

## Phase 10.6: Jump to Definition (^L)

**Goal**: ^L opens the definition of the identifier or module under the
cursor. On a `Require` line, open the imported file. On any other line,
locate the identifier and jump to its definition in the source file.

### Glob file parser

Rocq compiles `.glob` files alongside `.vo` files. These contain byte
offsets for every definition in the source. Format:

```
DIGEST <hex>
F<logical_module_name>
R<start>:<end> <module> <name> <kind>    (reference)
def <start>:<end> <section> <name>       (definition)
prf <start>:<end> <section> <name>       (proof)
ind <start>:<end> <section> <name>       (inductive)
constr <start>:<end> <section> <name>    (constructor)
class <start>:<end> <section> <name>     (class)
ax <start>:<end> <section> <name>        (axiom)
sec <start>:<end> <section> <name>       (section)
not <start>:<end> <section> <name>       (notation)
abbrev <start>:<end> <section> <name>    (abbreviation)
```

Start/end are byte offsets in the `.v` source file. We convert to line
numbers by counting newlines in the source.

New module `glob.ml`:
```ocaml
type entry = { kind: string; name: string; bp: int; ep: int }
val parse : string -> entry list
(* Parse a .glob file, return definition entries *)

val find_definition : entry list -> string -> entry option
(* Find a definition by name *)
```

### Resolution pipeline

**Case 1: Cursor on a Require/Import line**

1. Parse the line: `(From <prefix>)? Require (Import|Export)? <modules>.`
2. Identify the module name at/near cursor column
3. `Locate Library <module>.` via Session.query → parse messages for
   the `.vo` path
4. Derive `.v` path (strip `.vo`, add `.v`)
5. Open file in new tab (or switch to existing)

**Case 2: Cursor on any other identifier**

1. Get word at cursor (`Buffer.word_at_cursor`)
2. `Locate <word>.` via Session.query → parse messages
3. Response format: `<Kind> <dotted.logical.path>` where Kind is
   `Constant`, `Inductive`, `Constructor`, `Notation`, etc.
4. Extract module path: everything up to the last `.` component
5. Extract definition name: the last `.` component
6. `Locate Library <module_path>.` → get `.vo` path → derive `.v`
7. Derive `.glob` path (strip `.vo`, add `.glob`)
8. If `.glob` exists: parse it, find the definition by name,
   convert byte offset to line number
9. Open file, jump cursor to that line

**Fallback chain:**
- If `Locate` fails (identifier not in scope): show "Not found" in status
- If `Locate Library` fails: try local `Project.resolve_module`
- If `.glob` doesn't exist: open file at line 1 (no jump)
- If `.v` doesn't exist (stdlib, only .vo): show path in status bar
- If no session: try local resolution only

### Require line parsing

Detect lines matching (anywhere on the line, ignoring leading whitespace):
```
(From <prefix> )?Require (Import |Export )?<mod1> <mod2> ... .
```

Multiple modules may appear on one line. To pick the right one:
- Find all module name spans (start col, end col) on the line
- Select the one containing the cursor column
- If cursor isn't on any module name, use the first one
- If `From X` form, prepend `X.` to each module name

### Locate output parsing

Parse the first line of `Session.messages` after a `Locate` query.
Expected formats:
```
Constant <path>
Inductive <path>
Constructor <path>
Notation <path>
```

Extract the dotted path. Split on `.`: all but last = module, last = name.

For `Locate Library`, expected format:
```
<logical_name> has been loaded from file
<absolute_path_to_vo>
```

Or for libraries on the load path but not yet loaded:
```
<logical_name> has been loaded from file
<path>
```

### Query menu additions

Add to the ^Q menu:
- `l` — Locate (word at cursor): shows where a name is defined
- `c` — Check (word at cursor): shows the type of an expression

These are queries only (display in messages pane), not jump-to actions.

### Keybinding

| Key | Action |
|-----|--------|
| ^L  | Jump to definition (Require → open file; other → locate + jump) |
| ^Q l | Locate query (show result in messages) |
| ^Q c | Check query (show type in messages) |

### Implementation order

1. Add `Locate` and `Check` to ^Q menu (trivial)
2. Implement `glob.ml` (parse .glob files)
3. Implement `Locate` output parsing helpers
4. Implement Require line parsing
5. Wire up ^L in editor.ml

---

## Phase 12: Key Binding Refactor + Kitty Keyboard Protocol

**Goal**: Centralize all key bindings in one module with named constants,
display strings, and context. Enable the Kitty keyboard protocol for
terminals that support it, disambiguating keys like ^M/Enter and ^I/Tab.

### Phase 12.1: Key binding registry (`keys.ml`)

A central module that defines all key bindings:

```ocaml
type context =
  | Global        (* works everywhere *)
  | Script        (* only in script pane *)
  | GoalsMessages (* only in goals/messages panes *)
  | QueryMenu     (* inside ^Q menu *)
  | BuildMenu     (* inside F5 menu *)
  | ThemeMenu     (* inside F3 menu *)
  | OptionsMenu   (* inside ^T menu *)
  | HelpScreen    (* inside help *)
  | FilePicker    (* inside file picker *)

type binding = {
  name : string;           (* e.g. "save", "quit", "step_forward" *)
  codes : int list;        (* key codes that trigger this binding *)
  display : string;        (* e.g. "^S", "Alt+Down", "F5" *)
  context : context;
  description : string;    (* e.g. "Save file" *)
}
```

Each binding is a named value:
```ocaml
let save = { name = "save"; codes = [19]; display = "^S";
             context = Global; description = "Save file" }
let quit = { name = "quit"; codes = [24]; display = "^X";
             context = Global; description = "Exit all" }
let step_forward = { name = "step_forward";
  codes = [526; 532; 517]; display = "Alt+Down";
  context = Global; description = "Step forward" }
```

A `match_key` function tests if a keycode matches a binding:
```ocaml
val match_key : int -> binding -> bool
```

A `all_bindings` list grouped by context, used to generate the help
screen and status bar text.

### Phase 12.2: Refactor editor.ml and main.ml

Replace all magic integer constants with `Keys.xyz.codes` checks.
The pattern `if ch = 19 then ...` becomes
`if Keys.match_key ch Keys.save then ...`.

For the status bar, instead of hardcoded strings like
`"^S:Save ^W:Close"`, generate from bindings:
```ocaml
let status_hint bindings =
  String.concat " " (List.map (fun b ->
    Printf.sprintf "%s:%s" b.display b.description
  ) bindings)
```

### Phase 12.3: Generate help screen from bindings

Instead of the hardcoded `Help.text`, generate the help screen from
`Keys.all_bindings`, grouped by context:

```
─── Navigation ──────────────
  Alt+Down     Step forward
  Alt+Up       Step backward
  ^E           Go to cursor
  ...
─── Editing ─────────────────
  ^S           Save file
  ...
```

The `Help.text` string is computed once at startup from the registry.

### Phase 12.4: Kitty keyboard protocol

The Kitty keyboard protocol sends enhanced key reports that disambiguate:
- `^M` (Ctrl+M) vs `Enter` (keycode 13 vs a distinct report)
- `^I` (Ctrl+I) vs `Tab`
- `^H` (Ctrl+H) vs `Backspace`
- Modifier combinations: Shift+Enter, Ctrl+Enter, etc.

**Enable**: send `\x1b[>1u` to enable progressive enhancement level 1.
**Disable**: send `\x1b[<u` on exit.
**Detect**: check if the terminal responds to `\x1b[?u` (query mode).

Key reports come as `\x1b[<keycode>;<modifiers>u` CSI sequences.
ncurses may or may not parse these — we may need to handle them in
our escape sequence parser (the one that already handles bracketed paste).

**New bindings unlocked by Kitty protocol:**
- `^M` for minimap toggle (currently F2)
- `^I` for indent / completion (currently blocked by Tab)
- Shift+Enter for newline-without-autoindent
- Ctrl+Enter for execute-and-step

**Fallback**: terminals without Kitty support ignore the enable sequence.
We detect this and use the current key mappings. The binding registry
supports alternative codes per binding for this.

### Phase 12.5: Alternative bindings

Each binding can have primary and fallback codes:
```ocaml
type binding = {
  ...
  codes : int list;          (* primary codes *)
  kitty_codes : int list;    (* codes with Kitty protocol enabled *)
  ...
}
```

When Kitty protocol is active, `match_key` checks `kitty_codes` first.
This allows `^M` to be both "Enter" (in non-Kitty mode) and "minimap
toggle" (in Kitty mode) without conflict.

### Implementation order

1. Create `keys.ml` with all binding definitions
2. Refactor `editor.ml` to use `Keys.match_key`
3. Refactor `main.ml` to use `Keys.match_key`
4. Generate status bar hints from bindings
5. Generate help screen from bindings
6. Add Kitty keyboard protocol detection and enable/disable
7. Add Kitty-specific key parsing
8. Add alternative bindings for Kitty mode

### Notes

- The refactor should be mechanical — no behavior changes in steps 1-5.
- The help screen generation replaces the hand-maintained `help.ml`.
- Context-specific bindings (like query menu keys) still need their
  own dispatch logic, but the keys themselves are defined centrally.
- The Kitty protocol is strictly additive — no existing functionality
  breaks if the terminal doesn't support it.

---

## Phase 11: Messages Pane Tabs

**Goal**: The messages pane supports multiple content tabs — "Messages"
(Rocq output) and "Build" (build subprocess output). Future tabs could
include search results, compilation errors, etc. The tab design is
generic so adding new tabs is easy.

### Architecture

A **messages tab** is a named content source with its own scroll position,
selection state, and line cache:

```ocaml
type msg_tab = {
  name : string;                   (* "Rocq", "Build", etc. *)
  mutable lines : string list;     (* content lines *)
  mutable scroll : int;
  sel : Tab.pane_selection;
  mutable lines_cache : string list;
}
```

A **messages tab manager** holds the list of tabs and the active tab index:

```ocaml
type msg_tabs = {
  mutable tabs : msg_tab list;
  mutable active : int;
}
```

This lives inside `Tab.t` (per main-editor-tab), so each file tab has
its own set of messages sub-tabs.

### Tab bar rendering

The messages pane label (currently "Messages" or "[ Messages ]") becomes
a mini tab bar:

```
 Rocq │ Build
```

Active tab is highlighted (bold or brackets). Tabs are clickable.
The horizontal divider already has space for the label — just replace
the fixed label with the tab names.

### Content sources

**Rocq tab** — populated from `Session.messages`. Updated on each
render (same as current behavior). Cleared on step actions as now.

**Build tab** — populated from `Build.output ()`. Created when a build
starts, persists until cleared. Updated on each render during a build.

**Future tabs** — search results, error list, etc. Each is a `msg_tab`
with its own content provider.

### Auto-activation

When content changes in a tab, it auto-activates:
- Build starts or produces new output → switch to Build tab
- Rocq emits a message (error, query result) → switch to Rocq tab
- This way the user sees what's relevant without manual switching

### Mouse interaction

- Click on a tab name in the messages label → switch to that tab
- Scroll/select within the active tab works as now

### Cleanup

- Build tab is removed (or cleared) when the user dismisses it, or
  after a new build starts (replacing old output)
- `Build.clear()` removes the build output and the tab

### Implementation steps

1. **Define `msg_tab` type** in `tab.ml` (or a new `msg_pane.ml`)
2. **Add `msg_tabs` to `Tab.t`** — initialize with a single "Rocq" tab
3. **Refactor `render_messages`** — render the active msg_tab's lines
   instead of directly reading `Session.messages`
4. **Refactor the messages label** in `display.ml` — draw tab names
   instead of a fixed label, handle clicks
5. **Wire up Build tab** — create/update on build start/poll, auto-activate
6. **Wire up Rocq tab** — update from `Session.messages`, auto-activate
   on new messages
7. **Scroll/selection** — each msg_tab has its own scroll and selection,
   switching tabs restores their state

### Notes

- The goals pane does NOT get tabs — it always shows the current goals.
  If we wanted a "proof diff" view, that could be a goals pane tab later.
- Tab switching in the messages pane should not conflict with main tab
  switching (Alt+Left/Right). Click-only is fine for now; could add a
  keybinding later if needed.
- Keep the default state simple: if no build has run, only the "Rocq"
  tab exists and the tab bar looks identical to the current label.
