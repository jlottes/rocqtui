# Build error / warning navigation — plan

Today the Build sub-tab in the messages pane shows raw `make` output. To
interact with errors and warnings, the user has to read it as plain text.
This plan adds:

1. **Click-to-jump** from the Build tab to the offending file/line.
2. **F9 / Shift+F9** to cycle through next/previous error.
3. **Errors sub-tab** — a parsed/filtered view of just the entries.
4. **Gutter markers** ✘ / ⚠ in the script pane for lines with errors/warnings.

All four jump paths share the same jump stack as `^L` (jump-to-definition),
so `^B` (jump back) returns the user to where they were.

---

## Module layout

### New: `lib/build_errors.ml` + `.mli`

Parses the current build's accumulated output into structured entries and
caches them in a module-level ref. Re-parses when the build's output list
changes (cheap — output is bounded to a few hundred lines per build).

```ocaml
type severity = Error | Warning

type entry = {
  file : string;          (* absolute path *)
  line : int;             (* 1-based, as printed by rocq *)
  col_start : int;        (* 0-based byte column *)
  col_end : int;
  severity : severity;
  message : string;       (* trimmed, possibly multi-line *)
  output_row_start : int; (* 0-based row in build output (the File "..." line) *)
  output_row_end : int;   (* inclusive — last row consumed by this entry *)
}

val refresh : project_dir:string -> string list -> unit
(** Re-parse if [output] differs from cached input. Cheap when unchanged. *)

val all : unit -> entry list
val for_file : string -> entry list  (* filtered by absolute path *)
val severity_for_line : file:string -> line:int -> severity option
val lookup_by_output_row : int -> entry option
val current_index : unit -> int option
val advance : forward:bool -> entry option
(** Move the F9 cursor; wraps around. Returns the new current entry. *)
val clear : unit -> unit
```

Implementation notes:

- Header regex (string scanning, no `Re` dep):
  `File "<path>", line <N>, characters <M>-<K>:`
  - Path may be relative (rocq prints relative to its CWD = `project_dir`).
- After a header, accumulate following lines as the message until any of:
  - Another `File "..."` header
  - A line starting with `make` (e.g. `make: *** [Makefile:NN] ...`)
  - End of input
- Severity = first match of `Error` / `Warning` at start of any message line.
- Discard a header that has no `Error`/`Warning` follow-up (rare; defensive).
- Cache invalidation: `refresh` compares the input list (physical equality of
  the head, then `==` per element) to a cached list. If mismatched, re-parse
  and reset the F9 cursor index to `None`.

### Build module changes (`lib/build.ml`)

- Store `project_dir` on the `t` record (currently ignored).
- Expose `Build.project_dir : unit -> string option`.

### View module (`lib/view.ml`)

`update_msg_tabs`:
- After updating the Build tab, call
  `Build_errors.refresh ~project_dir (Build.output ())`.
- If `Build_errors.all () <> []`, ensure an "Errors" sub-tab exists and
  populate `mt_lines` with one row per entry. The **currently active**
  entry (the one F9 cursored to last) is **expanded** to show its full
  multi-line message; all other entries collapse to a one-line summary.
  ```
  ✘ relpath:LL:CC — Error: <first message line>
  ▾ ✘ relpath:LL:CC — Error:                ← active entry
        the term "foo" has type "T"            ← message lines indented
        while it was expected to have type "U".
  ⚠ relpath:LL:CC — Warning: deprecated foo
  ```
  Continuation rows of the expanded entry map back to the same entry for
  click-to-jump (Errors tab keeps a `row → entry index` table built at
  render time).
- After F9 navigation, scroll the Errors tab so the active (expanded)
  entry is in view.
- If F9 has not been used yet (no current index), no entry is expanded —
  all are one-line.
- Do **not** auto-activate the Errors tab on build failure (per user
  preference for non-aggressive UI).
- When no entries exist, drop the Errors tab if present (avoid dead tabs).

`render_script` (gutter):
- After painting line numbers, for each rendered row look up
  `Build_errors.severity_for_line` for the buffer's filename and that line.
  If a marker exists, paint column 0 of the gutter with the glyph + color.
- Use new `ga_marker_error` / `ga_marker_warning` Grid.attrs.

### Theme (`lib/theme.ml`)

Add to `grid_attrs`:
```ocaml
ga_marker_error : Grid.attr;     (* ✘ — red on default bg *)
ga_marker_warning : Grid.attr;   (* ⚠ — yellow on default bg *)
```
Derived from existing theme fields:
- `ga_marker_error = make_attr theme.error_bg theme.bg`
- `ga_marker_warning = make_attr theme.string_fg theme.bg`

(Both are accent colors already in every theme; avoids adding new fields.)

### Keys (`lib/keys.ml`)

Two new bindings:
```ocaml
let next_error =
  { name = "next_error"; codes = [273]; (* F9 *) kitty_codes = [];
    display = "F9"; context = Global; description = "Next build error" }
let prev_error =
  { name = "prev_error"; codes = []; kitty_codes = [(273, 2)]; (* Shift+F9 *)
    display = "Shift+F9"; context = Global; description = "Previous build error" }
```
(Verify F9 codes; the search bindings use F3=267, so F9 should be 273. If
the codes differ I'll fix them when wiring.)

Add both to the `display_bindings` list and to `bindings`. Update the help
table and `CLAUDE.md` keybinding summary.

### Editor (`lib/editor/editor.ml`)

New handler block (alongside `jump_to_def`):
```ocaml
else if Keymatch.match_binding ev Keys.next_error
     || Keymatch.match_binding ev Keys.prev_error then begin
  let forward = Keymatch.match_binding ev Keys.next_error in
  match Build_errors.advance ~forward with
  | None ->
    Render.set_status r "No build errors.";
    Some Continue
  | Some e ->
    Jump.push ctx tab;
    ctx.jump_target <- Some (e.line - 1, e.col_start);
    Some (Open_file e.file)
end
```

### Mouse (`lib/editor/mouse.ml`, `mouse.mli`)

Refactor `Mouse.handle` to return `Action.t option` (today: `unit`). Most
paths return `None`; the new click-to-jump path returns `Some (Open_file p)`.

Editor.ml's mouse dispatch:
```ocaml
if is_mouse_event then begin
  match Mouse.handle ctx mev tab r with
  | Some action -> Some action
  | None -> Some Continue
end
```

In `Mouse.handle`, after the existing PMessages click branch, when:
- `pane = PMessages`
- `is_left && not is_release`
- The active sub-tab name is `"Build"` or `"Errors"`
- `Geom.screen_to_pane_pos` returns `Some (row, _)`, and the row maps to
  an entry via:
  - **Build tab**: `Build_errors.lookup_by_output_row row` (header row or
    any consumed continuation row).
  - **Errors tab**: a per-render `row → entry index` table maintained by
    view.ml when populating `mt_lines`. The expanded entry occupies
    multiple rows; all of them map to the same entry. Stored on a new
    field of `Tab.msg_tab` (e.g. `mt_row_to_entry : int array option`)
    or in a module-level ref keyed by the active tab.
→ push jump, set `ctx.jump_target`, return `Some (Open_file e.file)`.

The current click handler also kicks off `mouse_selecting`; we should run
the jump branch *before* the selection branch so the click doesn't also
start a drag-select on the same coordinates. To keep it simple: the jump
branch is exclusive — if it fires, skip the selection setup.

---

## Non-goals (deferred)

- Multi-line message expansion in the Errors tab (each entry is one row).
- Inline virtual-text rendering of the message at the error site.
- Auto-jump to first error on build failure.
- Following errors across edits (markers clear on next build, period).
- Special handling for `make[N]:` recursive output beyond using it as a
  terminator.
- Coloring the Errors tab body text (post-render chgat is possible later;
  the glyph alone communicates severity for the first cut).

## Test plan

- `dune runtest` — unit tests still pass.
- `dune build @e2e` — full e2e suite still passes.
- Manual: run a project with a deliberate type error in a `.v` file.
  - Build tab shows raw output; Errors tab appears with one entry.
  - Click in Errors tab jumps to the right file and line.
  - Click in Build tab on the `File "..."` line also jumps.
  - F9 cycles forward, Shift+F9 backward; status bar shows
    "No build errors." when none.
  - `^B` from any of the above returns to the previous location.
  - Gutter shows ✘ on the error line. Add a `(* Warning *)` deprecated
    construct to also see ⚠.
  - After a successful rebuild, all markers and the Errors tab disappear.

## Implementation order

1. `Build` stores + exposes `project_dir`.
2. `lib/build_errors.ml` + `.mli` (parser + storage + cursor).
3. Theme attrs `ga_marker_error` / `ga_marker_warning`.
4. View: gutter glyph rendering.
5. View: Errors sub-tab population in `update_msg_tabs`.
6. Keys: F9 / Shift+F9 + help.
7. Editor: handler for next/prev error.
8. Mouse: refactor to return `Action.t option`; click-to-jump.
9. `dune build`, `dune runtest`, `dune build @e2e`.
10. Update `docs/TODO.md` (check off the jump-to-error item; note warnings
    are also covered).
