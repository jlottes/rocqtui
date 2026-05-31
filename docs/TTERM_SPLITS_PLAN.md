# tterm splits + drag-tabs

Follow-up to [TTERM_PLAN.md](TTERM_PLAN.md). Adds vertical / horizontal
splits, mouse-draggable resize borders, and browser-style drag-tab
to move terminals between leaves.

## Goals

- Each "leaf" of the layout is what tterm v1 was: a tab strip + body
  + its own list of terminals.
- A leaf can be split into two leaves, vertically or horizontally,
  with a draggable border between them.
- Closing the last terminal in a leaf collapses the containing split,
  replacing it with the sibling leaf. Closing the last terminal in
  the last leaf exits the program.
- Tabs can be dragged from one leaf's tab strip to another's: drops
  on a different leaf's tab strip *or* body move the terminal to
  that leaf.
- Border drags are live (continuous repaint), matching rocqtui's
  existing horizontal/vertical splitter behavior.

## Non-goals (v2)

- Keyboard focus movement between leaves — mouse-only for now.
  (Click anywhere in a leaf's tab strip or body focuses it.)
- Dragging a tab onto an empty / outside region to create a split
  off-the-cuff. Splits come from `^Shift+T` / `^Shift+S` only.
- Reordering tabs *within* a leaf by drag. (You can `^W` and
  re-spawn if you really need to. v3 candidate.)
- Detach / attach (daemonless).

## UI summary

| Action | Affordance |
|---|---|
| New tab in focused leaf | `^T` (existing) |
| Split focused leaf vertically (new leaf to the right) | `^Shift+T` |
| Split focused leaf horizontally (new leaf below) | `^Shift+S` |
| Close current terminal (and collapse leaf if its last) | `^W` (existing) |
| Switch active tab within a leaf | click tab, wheel on strip |
| Focus a leaf | click anywhere in it |
| Resize a split | drag the border, live |
| Move a terminal between leaves | drag tab → drop on target leaf's strip or body |

## Architecture

### Data model

```ocaml
(* lib/layout.ml — new module owned by tterm; lives in lib/ so the
   types can be shared with view_terminal.ml. *)

type leaf = {
  id : int;                   (* stable identity for active-leaf
                                 tracking and drag-target hit-test *)
  mp : Msg_pane.t;            (* per-leaf sub-tab manager *)
  mutable rect : Render.rect; (* recomputed each frame from layout *)
}

and split = {
  mutable a : t;              (* left / top *)
  mutable b : t;              (* right / bottom *)
  mutable frac : float;       (* 0.1 .. 0.9 *)
  mutable rect : Render.rect; (* the divider's containing rect *)
}

and t =
  | Leaf of leaf
  | VSplit of split           (* a | b *)
  | HSplit of split           (* a / b *)
```

Per-leaf "owned terminals" are *not* held on the leaf record. We rely
on `Msg_pane.t` to list the Terminal sub-tabs and treat that list as
authoritative. The set of terminals tterm "knows about" is the union
across all leaves' Msg_pane instances. `Terminal.all ()` stays as it
is (one global list); the Msg_pane instances filter from it.

### Active leaf

`bin/tterm.ml` keeps `let active_leaf : leaf ref = ref initial_leaf`.
Leaves carry stable ids so we can still find the right leaf after
tree rewrites; in practice the `leaf` record itself persists across
splits (a Leaf becomes a child of a new Split, but the record is
reused), so the ref stays valid except after a *collapse*, where the
ref's leaf was just destroyed and we must reassign.

### Tree rewrites

- **Split focused leaf**: replace `Leaf focused` in the tree with
  `VSplit { a = Leaf focused; b = Leaf new; frac = 0.5 }` (or
  HSplit). `new` is a fresh leaf with a fresh `Msg_pane.t`; a new
  Terminal is spawned into it and activated. Focus moves to `new`.
- **Collapse a leaf** (last terminal closed): the containing
  `VSplit`/`HSplit` is replaced by the sibling subtree. If the
  collapsed leaf was the active one, focus the leftmost / topmost
  leaf in the sibling.
- **Move a terminal between leaves** (drag-tab): remove the
  Msg_pane sub-tab from the source leaf (this does *not* destroy
  the terminal); add it to the target leaf's Msg_pane. If the
  source leaf is now empty, collapse it.

Tree walks use a small set of helpers in `Layout`:

```ocaml
val leaves : t -> leaf list
val find_leaf_at : t -> x:int -> y:int -> leaf option
val find_split_border_at : t -> x:int -> y:int ->
  [ `VBorder of split | `HBorder of split ] option
val find_leaf_by_id : t -> int -> leaf option

(* Replace one subtree with another, returning the new root.
   Used by split / collapse / move. *)
val replace : t -> target:t -> with_:t -> t
val collapse_leaf : t -> leaf -> t  (* drops leaf, replaces parent
                                       split with the sibling *)
```

Layout-rect computation happens once per frame (cheap; ~tens of
nodes max in any sane usage):

```ocaml
val compute_rects : t -> bounds:Render.rect -> unit
```

Walks the tree and assigns `rect` to each `leaf` and `split`,
applying borders (1 column for VSplit, 1 row for HSplit), and
clamps `frac` to leave each side at least a minimum width/height
(say 8 cols / 3 rows).

## Msg_pane changes

Today `Msg_pane` is a singleton. Splits need multiple instances.
This is the only shared-library change — additive, rocqtui untouched.

Add a parallel per-instance API in `lib/msg_pane.{ml,mli}`:

```ocaml
val create : unit -> t

val ensure_in : t -> kind -> tab
val find_in : t -> kind -> (int * tab) option
val active_tab_in : t -> tab
val active_kind_in : t -> kind
val activate_in : t -> kind -> unit
val activate_unless_terminal_in : t -> kind -> unit
val remove_in : t -> kind -> unit
val pop_active_in : t -> unit
val activate_prev_in : t -> unit
val activate_next_in : t -> unit

(* Sync this instance's sub-tab list against a given subset of
   terminals (not [Terminal.all]). Used by tterm so that each leaf
   only sees the terminals it owns. *)
val sync_terminals_in : t -> Terminal.t list -> unit
```

The existing singleton API (`ensure`, `activate`, `sync_terminals`,
…) keeps working — they operate on a private default instance. The
plumbing inside `msg_pane.ml`:

```ocaml
let global = create ()
let state () = global
let ensure k = ensure_in global k
let activate k = activate_in global k
(* …etc. *)
```

Rocqtui call sites change zero lines. ~80 lines added to msg_pane.ml.

### Per-leaf terminal ownership

A terminal "belongs to" the leaf whose `Msg_pane.t` lists it as a
`Terminal _` sub-tab. With per-leaf `sync_terminals_in`, tterm
tracks ownership explicitly via a `leaf_id -> Terminal.t list` map
that mirrors which Msg_pane each terminal lives in. When tterm
spawns a new terminal it appends it to the active leaf's owned list
and calls `Msg_pane.sync_terminals_in active.mp owned`. When a
terminal is moved, the source leaf's owned list shrinks and the
target's grows.

`Terminal.all ()` returns the union (no changes to terminal.ml).

## View_terminal changes

`render_all` becomes recursive:

```ocaml
let rec render_node ctx r = function
  | Layout.Leaf leaf -> render_leaf ctx r leaf
  | Layout.VSplit s ->
    render_node ctx r s.a; render_node ctx r s.b;
    draw_vborder r s.rect
  | Layout.HSplit s ->
    render_node ctx r s.a; render_node ctx r s.b;
    draw_hborder r s.rect

(* New signature — tterm passes the full layout and the active leaf
   id so we know which strip to highlight. *)
val render_all : Editor_context.t -> Render.t ->
  Layout.t -> active_leaf_id:int -> unit
```

`render_leaf` is the body of today's `render_all`: tab strip + body
+ cursor placement + status. It draws into `leaf.rect` rather than
the previous `body_rect r`. The status bar still has one global row
at the bottom; its content reflects the *active* leaf's active
terminal.

The cursor is placed at the active leaf's terminal cursor (if
visible); inactive leaves don't get a cursor. Inactive leaves'
strips show as inactive (border-attr background instead of
tab-active attr) — already implicit in `draw_tab_bar`'s active-index
parameter, just pass `-1` (or skip the call entirely for inactive
leaves and draw the strip with a tterm-local helper that doesn't
highlight any tab as "active in the focused sense").

Overlay support (for the drag ghost) reuses `Render.set_overlay` /
`clear_overlay`, which already exist.

### Borders

VSplit border: 1 column wide between `s.a.rect` and `s.b.rect`,
drawn as `│` in the border attr. HSplit border: 1 row, `─`.
Where two splits meet at a T or +, drawing precedence is "later
sibling wins" — fine in practice for a non-pathological tree.

## bin/tterm.ml changes

The main loop structure stays the same; what grows:

### State

```ocaml
let layout = ref (Layout.Leaf initial_leaf) in
let active_leaf = ref initial_leaf in
let dragging = ref Drag.Idle in   (* see drag state below *)
```

### Resize / layout pass

Once per frame, before render:

```ocaml
let bounds = View_terminal.body_rect r in    (* row=1..status-1 *)
Layout.compute_rects !layout ~bounds;
(* Resize each terminal to its leaf's body rect (rect minus tab
   strip row). Cheap if unchanged. *)
Layout.iter_leaves !layout (fun leaf ->
  let body = leaf_body_rect leaf in
  List.iter (fun (t : Msg_pane.tab) ->
    match t.kind with
    | Msg_pane.Terminal term ->
      Terminal.resize term ~w:body.width ~h:body.height
    | _ -> ()
  ) leaf.mp.tabs)
```

### Key bindings

`^Shift+T` and `^Shift+S` are new bindings in `lib/keys.ml`. The
kitty-protocol modifier for Ctrl+Shift is `6` (= 1 + 1 (shift) + 4
(ctrl)). Tterm only matches them via the kitty_codes path:

```ocaml
let split_vertical = {
  name = "split_v"; codes = []; kitty_codes = [(116, 6)];  (* ^Sh+T *)
  display = "^Sh+T";
}
let split_horizontal = {
  name = "split_h"; codes = []; kitty_codes = [(115, 6)];  (* ^Sh+S *)
  display = "^Sh+S";
}
```

`Terminal_input.handle` does *not* learn about them — keep that
module's surface small. tterm matches them at the top of its input
drain, before calling `Terminal_input.handle`:

```ocaml
if Keymatch.match_binding ev Keys.split_vertical then split_v ()
else if Keymatch.match_binding ev Keys.split_horizontal then split_h ()
else match Terminal_input.handle … with …
```

### Mouse: focus + border drag

Body click anywhere in a leaf focuses it (in addition to whatever
in-body behavior runs):

```ocaml
let focus_leaf_at r x y =
  match Layout.find_leaf_at !layout ~x ~y with
  | Some leaf -> active_leaf := leaf
  | None -> ()
```

Border hit-test runs first; if a left press lands on a border,
enter `Drag.Border of split * direction` mode. Subsequent motion
events update `s.frac` from the cursor; release ends the drag.
Continuous repaint matches rocqtui's `lib/editor/mouse.ml:55–65`
which already does this for the script/messages splitter.

### Mouse: drag tabs

The drag-tab state machine:

```ocaml
type drag_state =
  | Idle
  | TabPressed of {       (* mouse down on a tab; not yet a drag *)
      source : leaf;
      tab_index : int;
      start_x : int;
      start_y : int;
    }
  | TabDragging of {
      source : leaf;
      tab : Msg_pane.tab;        (* the source tab — captured at
                                    drag-start; the source leaf's
                                    Msg_pane still owns it until
                                    drop *)
    }
  | Border of { … }
```

State transitions:

- **Left press on a tab strip** (any leaf, even inactive): record
  `TabPressed { source; tab_index; start_x = x; start_y = y }`.
  Don't activate the tab yet — we'll decide on release.
- **Motion while `TabPressed`**:
  - If `|x - start_x| < 3 && |y - start_y| < 1`: stay in
    `TabPressed`. (3-cell horizontal dead zone, 1-row vertical.)
  - Otherwise promote to `TabDragging { source; tab = source.mp
    .tabs.(tab_index) }` and install a drag-ghost overlay (see
    below).
- **Motion while `TabDragging`**: update the overlay's anchor to
  `(x, y)`. Hit-test the leaf under the cursor; if it's a different
  leaf than `source`, set a transient "drop target" highlight on
  that leaf's strip (a single-row reverse-video band, drawn via
  the overlay).
- **Release while `TabPressed`**: the user clicked, didn't drag.
  Activate the clicked tab in its leaf; focus the leaf. Return to
  `Idle`.
- **Release while `TabDragging`**:
  - If the cursor is over a different leaf (strip or body): call
    `move_term source target tab`. The `Msg_pane.tab` record is
    removed from `source.mp` and appended to `target.mp`; the
    terminal itself is untouched. If `source.mp.tabs` is now empty,
    collapse the source leaf. Focus the target leaf and activate
    the moved tab there.
  - Otherwise (release over no leaf, or back over source): cancel,
    no change. (v1 doesn't reorder within a leaf.)
  - Clear the overlay.
- **Any non-mouse event during `TabPressed` / `TabDragging`**:
  cancel back to `Idle`. Belt-and-braces in case of focus loss.

The drag-ghost overlay is drawn with `Render.set_overlay`. It
renders a single-row label like ` mytab ` in tab-active attr at
`(cursor_x, cursor_y)`, plus the highlighted drop-target strip.
Cleared on drop. The overlay reuses the existing mechanism so we
don't need a new render layer.

### Window title

Active leaf's active terminal's title (today's logic, just routed
through `active_leaf`).

## Implementation order

1. `lib/msg_pane.ml(i)`: add the per-instance API. Verify rocqtui
   unaffected (`dune runtest`, `@e2e`).
2. `lib/layout.ml(i)`: data model + tree helpers + `compute_rects`
   + `iter_leaves` + `replace` + `collapse_leaf`.
3. `lib/view_terminal.ml(i)`: recursive `render_all`, per-leaf
   tab strip + body + cursor placement, global status bar.
4. `bin/tterm.ml`:
   - State plumbing (`layout`, `active_leaf`, ownership map).
   - Replace single-leaf code with layout-aware code (mouse hit
     testing through `Layout.find_leaf_at`, ^T spawns into
     `active_leaf`).
   - Border-drag handling.
5. `lib/keys.ml`: add `split_vertical` / `split_horizontal`.
6. `bin/tterm.ml`: split keybindings + tree-rewrite operations
   (split-active-leaf, collapse, focus assignment).
7. `bin/tterm.ml`: drag-tab state machine + ghost overlay.

Each step is independently testable; commit after each.

## Test plan

- Single leaf still works (start tterm, observe shell, type, exit
  with `^W` then last leaf collapses → exits).
- `^Shift+T` splits vertically; both leaves run independent shells.
- `^Shift+S` splits horizontally; ditto.
- Repeated splits build a tree; each `^Shift+*` splits the
  focused leaf only.
- Border drag (vertical): both sides resize live; terminal contents
  reflow.
- Border drag (horizontal): ditto.
- Close last terminal in a leaf → leaf collapses → sibling expands
  to fill the freed space.
- Drag tab from leaf A's strip to leaf B's strip → terminal moves
  to leaf B, source's other tabs (if any) survive, focus follows
  to leaf B.
- Drag tab to leaf B's body → same.
- Drag tab off the edge / onto own leaf → no-op.
- Drag a tab when leaf A had only that tab → source collapses,
  destination grows.
- Drag tab from a leaf to a deeply-nested split → still works.
- Click without drag (release before threshold) → ordinary activate.
- `^Q` and last-leaf-^W both exit.
- Existing `--xcompose`, `^Y`, middle-click-paste still work in
  every leaf.
- No `dune runtest` / `@e2e` regressions.

## Open questions

1. **Status bar with splits.** Today: title + scrollback + `[i/n]`
   of the (only) leaf's tab. Proposed for splits: same fields, but
   for the *active leaf's* active tab. The `[i/n]` is the within-
   leaf position; no global "leaf 2 of 3" indicator. Confirm OK?
2. **Per-leaf title prefix.** A drag-target leaf currently has no
   way to be identified visually except by mouse position. Should
   we letter the leaves (A/B/C…) so users can refer to them?
   Probably v3.
3. **Minimum split sizes.** Proposed: 8 cols wide × 3 rows tall
   minimum per leaf. Smaller → refuse the split (status-bar message?
   silent no-op?).
4. **`^Shift+T` / `^Shift+S` on a non-kitty terminal.** Without
   the kitty protocol the shift modifier doesn't reach us — those
   keys send the same bytes as plain `^T` / `^S`. tterm assumes
   kitty; if the host terminal doesn't, the split keys silently
   fail and `^T` opens a normal tab. Document, don't paper over.
