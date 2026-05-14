# Project-wide search — Design

Status: design draft. No code yet. Builds on the existing search
feature ([`SEARCH_PLAN.md`](SEARCH_PLAN.md), [`REPLACE_PLAN.md`](REPLACE_PLAN.md))
and the build-errors infrastructure (`lib/build_errors.ml` +
`Msg_pane.Errors`). Adds a `[proj]` scope toggle in the search prompt
and a new **Search** sub-tab in the messages pane that renders
matches grep-style. The matches surface is the messages pane, not
the file-tree panel — the build-errors tab is structurally the same
shape (file → line → content with click-to-jump and F9 stepping) and
already lives there.

## Goals

- **One results surface, two scopes.** A new `Msg_pane.Search` tab
  renders matches the same way regardless of whether the matcher ran
  against just the current buffer or every `.v` file in the project.
- **Async project scan.** Background work; the UI never blocks on a
  project scan. Partial results stream into the tab as files are
  consumed.
- **Persistence after prompt close.** Same model as single-buffer
  search today — ESC clears the search, Enter (or any prompt-close
  other than ESC) keeps it. F3 / Shift+F3 continue stepping, crossing
  file boundaries when project mode is active.
- **Auto-pop the tab when scope changes.** Toggling `[proj]` on is
  the "show me everywhere" gesture; the Search tab activates
  automatically. Same mechanism as `Build` auto-activating when a
  build starts. The file-tree panel is untouched.

Out of scope (deferred):

- **Replace across files.** Alt+A semantics across files gets fuzzy
  (atomic? per-file undo? preview?). Wait until project search is in
  your hands.
- **Any file-tree integration.** No match counts on file rows, no
  third VSearch view. Easy to add later if useful.
- **Match-row context lines** (grep `-C 2` style).
- **Persisting results across rocqtui restarts.**

## UX

### The search prompt gains a `[proj]` chip

```
Find:    foo█                              3/12  [aa] [..] [proj]
Replace: bar                                          ^J:Repl  ^H:All
```

- `Alt+P` toggles `[proj]`. (`^P` is cycle-pane.)
- When `[proj]` flips on, the matcher reruns project-wide (async)
  and `Msg_pane.activate Search` fires automatically. The Search tab
  shows partial results as files complete.
- When `[proj]` flips off, the project state is dropped and the
  matcher reverts to per-buffer (existing behaviour). The Search tab
  remains and shows the current-buffer matches.
- All existing prompt keys (`F3`, `Shift+F3`, `Alt+C` / `Alt+R`,
  `Alt+Enter`, `Alt+A`, Tab, Enter, ESC) keep their semantics.

### The Search messages tab

Mirrors `Msg_pane.Errors`'s "list with one expanded entry" pattern,
but every match-line is just one row (no need to expand multi-line
content). Files are grouped under header rows:

```
┌ Rocq │ Build │ [ Errors ] │ [ Search ] ──────────────────────────────────┐
│ interfaces/eq.v  (3)                                                     │
│   12: Lemma foo_assoc : foo x (foo y z) = foo (foo x y) z.               │
│ ▸ 25: Proof. unfold foo. intros.                                         │
│   89:   apply foo_eq.                                                    │
│ orders/preorder.v  (1)                                                   │
│   45: Definition foo (x : X) := x.                                       │
│ orders/lattices.v  (8)                                                   │
│   ...                                                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

- **File header rows**: project-relative path + match count.
- **Match rows**: line number, then the source line. The match span
  is highlighted with the existing `ga_search_match` theme attr.
- The **current match** (the one F3/Shift+F3 last advanced to) is
  prefixed with `▸ ` and rendered with the same selected-row
  highlight as the Errors tab uses for its current entry.
- Match-line truncation: since the messages pane has ~60% of the
  terminal width, plain right-clip is enough for the common case.
  No center-on-match logic required for v1.

### Tab activation behaviour

- `Alt+P` flipping `[proj]` on: `Msg_pane.activate_unless_terminal
  Search`. Matches how `Build` auto-activates when a build starts —
  same protect-the-terminal courtesy.
- The Search tab is not removed when results clear (only `Errors`
  has remove-on-empty in the current pattern, and that's specifically
  for build errors disappearing on next build). Search results
  persist until ESC or until a fresh `Alt+P`-on with different
  query.

### F3 / Shift+F3 stepping

When the search state has any matches:

- **Single-buffer (current behaviour preserved)**: F3 advances
  through the matches in the current buffer.
- **Project mode**: F3 advances across files. If the current cursor
  is in a file with more matches after it, jump to the next match in
  that file; otherwise open the next file with matches at its first
  match. Shift+F3 is the symmetric reverse. Stepping past the last
  match wraps to the first.

In both cases, the Search tab's `current match` updates to wherever
F3 left the cursor, and the tab scrolls to bring that row into view.
Clicking a match row in the Search tab does the same thing in
reverse (jump to that match, update current).

### Persistence and lifecycle

| Event | Effect |
|-------|--------|
| `^F` | Open prompt; preserve any existing state, otherwise empty. |
| Type in Find | Re-run matcher. Single-file: per-keystroke (today). Project: debounced (~150 ms) async scan; partial results stream in. |
| `Alt+P` toggles `[proj]` on | Trigger project scan; activate Search tab. |
| `Alt+P` toggles `[proj]` off | Drop project state; matcher reverts to per-buffer (state for the current buffer rebuilt). Search tab stays. |
| Enter | Close prompt; keep search state and Search tab. |
| ESC | Close prompt; clear all search state. Search tab body becomes empty. |

The "any prompt-close keeps state, ESC clears" rule mirrors
single-buffer search today.

## Architecture

### Phase 1 — Unified match model (`lib/search_results.ml`)

A pure value type both single-file and project search write into:

```ocaml
type match_loc = {
  ml_line : int;          (* 1-based, project-relative *)
  ml_col_start : int;     (* 0-based byte offset within the line *)
  ml_col_end : int;       (* exclusive *)
  ml_line_text : string;  (* the full source line, for grep display *)
}

type file_matches = {
  fm_path : string;       (* absolute *)
  fm_rel_path : string;   (* project-relative; "" if not in project *)
  fm_matches : match_loc array;
}

type t = {
  query : string;
  flags : Search.flags;
  mutable files : file_matches list;  (* scan order *)
  mutable scanning : bool;            (* worker still running *)
  mutable total : int;                (* sum of fm_matches lengths *)
  mutable current : (string * int) option;  (* (path, match_index) of the F3 cursor *)
}

val empty : query:string -> flags:Search.flags -> t

val add_file : t -> file_matches -> unit

(** Linear advance/retreat across all files in scan order. Returns the
    new [current] pointer and the corresponding match_loc, or [None] if
    [files] is empty. Wraps. *)
val advance : t -> forward:bool -> (string * match_loc) option

(** Look up a match by (file, index). For the click handler. *)
val find_match : t -> string -> int -> match_loc option

(** Single-file convenience: derive a [t] from an existing
    [Search.state] + buffer (for VSearch rendering of per-buffer
    search). *)
val of_single_file :
  path:string -> rel_path:string ->
  Search.state -> Buffer.t -> t
```

Tests in `test/test_search_results.ml`: empty/build/advance/wrap/
single-file derivation.

### Phase 2 — `lib/project_search.ml` async worker

The codebase's existing async pattern is "subprocess + fd in the
select loop" (Build, Dep_runner). Threads are not used anywhere. The
simplest scan that fits is **step-by-step on the main-loop tick**:

```ocaml
type t

val create : unit -> t

(** Start (or restart) a project-wide scan. Cancels any in-flight
    scan, captures the file list from [File_listing.enumerate ~All]
    so the scan is deterministic against the snapshot. *)
val start : t ->
  project_dir:string -> project_file:string ->
  query:string -> flags:Search.flags ->
  unit

val cancel : t -> unit

(** Called once per main-loop tick. Scans up to N files (N chosen so
    each call stays under ~5 ms on the affine repo — enough for the
    UI to feel live). Returns [true] when the result set changed and
    the panel should re-render. *)
val step : t -> bool

val results : t -> Search_results.t option
val scanning : t -> bool
```

No fd to add to the select loop. `main.ml` just calls `step` every
tick alongside the existing polls.

Scan strategy:

- Enumerate files via `File_listing.enumerate ~mode:All`.
- For each file, prefer the contents of the corresponding open
  `Buffer.t` if a tab has it (so unsaved edits are visible in the
  results); fall back to reading from disk.
- Run `Search`'s existing matcher.
- Drop files with zero matches (`fm_matches = [||]`).
- Mark `t.scanning <- false` after the last file.

Cancelling re-running because the query changed: `start` discards
the current `Search_results.t` and begins fresh. The intermediate
state is lost — that's fine, the cost of re-scanning is bounded
and live partial results are confusing if they're from a stale
query.

### Phase 3 — `Msg_pane.Search` tab variant

Extend the existing `kind` variant:

```ocaml
type kind =
  | Rocq
  | Build
  | Errors
  | Search    (* new *)
  | Terminal of Terminal.t
```

New module `lib/search_tab.ml` mirrors `Build_errors`'s render path:

```ocaml
(** Render the Search-tab body from the active Search_results.t.
    The current match (if any) is marked with the same prefix-and-
    highlight convention Build_errors uses for its current entry.
    Returns ([lines], current_row_offset) for auto-scroll. *)
val render :
  Search_results.t option ->
  Styled.line list * int option

(** Inverse of render's row layout: which (file, match_index) sits at
    body row [r]? None if the row is out of bounds or on a file
    header. Used by click handling in [editor/mouse.ml]. *)
val lookup_tab_row : int -> (string * int) option
```

The internal row→entry map is kept module-private, populated by
`render`. Same pattern as `Build_errors.lookup_errors_tab_row`.

### Phase 4 — `Editor_context` plumbing

Add a global:

```ocaml
mutable search : Search_results.t option;
project_search : Project_search.t;
```

The `search` field is the live one the Search tab and F3 stepping
read from. It's:

- The single-buffer `Search_results.t` (derived from the active
  tab's `Search.state`) when `[proj]` is off.
- The `Project_search.results ps` value when `[proj]` is on.

A small helper `Editor_context.refresh_search ctx tab` chooses
between the two and updates `ctx.search`. Called from the prompt
dispatcher on every relevant event, and from the main loop on
`Project_search.step` change.

### Phase 5 — Prompt UI + dispatcher

`view.ml`'s search prompt rendering gains the `[proj]` chip. Same
attribute treatment as the existing `[aa]` / `[..]` chips.

`Modals.handle_search_prompt` gains a case for `Alt+P` that:

- Flips the per-tab "project mode" flag (stored where? — see open
  questions; simplest is a `mutable project_mode : bool` field on
  `Editor_context`).
- If turning on: calls `Project_search.start` with the current query
  and `Msg_pane.activate_unless_terminal Search`.
- If turning off: calls `Project_search.cancel` and refreshes the
  per-buffer search.

### Phase 6 — F3 / Shift+F3 across files

`Modals.search_advance` (or wherever F3/Shift+F3 dispatch lives —
currently in `editor.ml`) gets the across-files branch:

- If `ctx.search` is per-buffer: existing behaviour.
- If `ctx.search` is project-wide: `Search_results.advance ~forward`
  returns the new `(path, match_loc)`. The handler then `Open_file
  path` (or switches tab if open) and moves the cursor to the
  `match_loc`. The Search tab's `current` pointer updates; the tab
  scrolls to bring the row into view.

### Phase 7 — Mouse + scroll + edge cases

- **Click in the Search tab body**: `editor/mouse.ml`'s existing
  Build/Errors click handler dispatches on the active `Msg_pane`
  kind. Add a `Msg_pane.Search` arm that calls
  `Search_tab.lookup_tab_row` and jumps to the match.
- **Scroll**: `tab.scroll` and `tab.sel` on the `Msg_pane.tab`
  already exist; reused as-is.
- **ProjectChanged event**: while project search is active, re-run
  the scan from scratch. Already debounced naturally by being
  attached to ProjectChanged.
- **Edits in an open buffer**: matches in that file may go stale.
  Cheapest is to re-scan just the affected file and merge into the
  results. v1: re-scan the whole project on every commit-grade buffer
  event (debounced). Revisit if it's noticeable on large projects.

## Module map

| File | Status | Purpose |
|------|--------|---------|
| `lib/search_results.ml/.mli` | new | Pure: file_matches, match_loc, advance. |
| `lib/project_search.ml/.mli` | new | Step-by-step async scan; owns a `Search_results.t`. |
| `lib/search_tab.ml/.mli` | new | Renders the Search tab body, exposes click hit-test. |
| `lib/msg_pane.ml/.mli` | modified | New `Search` kind + display name. |
| `lib/editor_context.ml/.mli` | modified | `search` (active results), `project_search`, `project_mode`. |
| `lib/editor/modals.ml` | modified | `Alt+P` handler; refresh ctx.search on edits. |
| `lib/editor/editor.ml` | modified | F3 / Shift+F3 cross-file branch. |
| `lib/editor/mouse.ml` | modified | Click on Search-tab row jumps to match. |
| `lib/view.ml` | modified | `[proj]` chip on prompt; render the Search-tab body. |
| `bin/main.ml` | modified | Call `Project_search.step` each tick. |

## State ownership

- **Per-tab**: existing `Search.state` (byte-offset matches in this
  buffer). When `[proj]` is off, used as the source for ctx.search.
- **Global**: `Project_search.t` (one in-flight scan), `project_mode`
  bool, `search` snapshot for rendering / stepping.
- **Not persisted** across rocqtui restarts.

## Implementation order

1. **Phase 1** — `Search_results` + tests. Pure code, no UI.
2. **Phase 2** — `Project_search` worker + smoke against
   `~/rocq/affine`. Standalone; no UI yet.
3. **Phase 3 + 4** — Msg_pane.Search variant, `Search_tab` renderer,
   editor_context plumbing. Manually testable by injecting a fake
   `Search_results.t` and switching to the tab.
4. **Phase 5 + 6 + 7** — Prompt chip, `Alt+P`, cross-file F3, click
   handling. End-to-end user-visible from here.

## Open questions

- **Where does `project_mode : bool` live.** Editor_context is the
  natural home, but it'd be cleaner if it were carried by the
  `Search.flags` record (so the prompt's persistent search state
  includes the scope). Worth thinking through during Phase 5.
- **What happens to per-buffer search when toggling `[proj]` off.**
  Proposal: re-derive ctx.search from the current tab's
  `Search.state` (the per-buffer matcher kept running in the
  background, or we re-run it on toggle). The simpler version is to
  re-run it on toggle; the matcher is fast.
- **Re-scan strategy on edits during project search.** Proposal:
  debounced full re-scan on `ProjectChanged` (existing trigger) and
  on tab edits where the edited file is among the matched files.
  Revisit if it costs too much.
- **Removing the Search tab.** Proposal: never auto-remove; it stays
  in the bar even when the body is empty (mirrors how `Build` works
  before any build runs). User-removable later if needed.
- **`v` cycle in the file tree panel.** Unchanged. The panel does
  not gain a search view in v1.
