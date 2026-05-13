# File-tree panel — Design

Status: design draft. No code yet. Adds a persistent left-side file-tree pane
that coexists with the existing modal file picker — they share file
enumeration but are otherwise independent widgets with different UX.

## Goals

- A persistent navigator pane on the left of the script pane, showing the
  project file tree. Toggled with `F8`. Survives across opens; not modal.
- **Existing modal picker is unchanged** in behavior. `^O` still opens it.
  Users who never press F8 see no difference.
- Tree-style interaction (expand/collapse directories) — not the flat
  filtered list the modal shows. Typing is *not* the primary affordance;
  arrow keys are.
- Minimal shared code with `File_picker`, behind a clean module boundary
  (`lib/file_listing.ml`). No "if panel_mode then …" forks inside either
  widget.
- Layout refactor in `lib/render.ml` that makes adding the new pane (and
  any future panes) a layout-function edit rather than a seven-place
  variant-match update.

## UX

When the user presses `F8`, a pane opens on the left of the script pane,
pushing the script (and goals/messages) right. Pressing `F8` again closes
it. `^P` (cycle pane focus) includes the panel when visible.

```
┌─ Files ──────┬─────────────────────────────────────┬────── Goals ──────┐
│ project.v    │ Theorem foo : ...                   │                   │
│ ▾ theory/    │   Proof.                            │                   │
│   • groups.v │     intros.                         │                   │
│     rings.v  │     ...                             │                   │
│ ▸ test/      │                                     ├── Messages ───────┤
│   util.v     │                                     │                   │
│              │                                     │                   │
└──────────────┴─────────────────────────────────────┴───────────────────┘
```

- No box border around the panel — it sits in the existing pane chrome
  (one-column vertical separator on its right, same as the
  script/minimap/goals separators).
- Header line at the top shows mode label ("Files" or "All .v"). No
  surrounding title-in-border.
- `▸` / `▾` glyphs on directories indicate collapsed / expanded.
- `•` marker on files that are currently open in a tab (same convention
  as the modal picker).
- Selected line uses reverse-video, same style as modal.
- Filter mode (see below) is *transient*: when active, a one-line input
  appears at the bottom of the panel; otherwise that row is blank.

### Key bindings inside the panel

| Key | Effect |
|-----|--------|
| Up / Down | Move selection. |
| PageUp / PageDown | Scroll by visible-rows. |
| Home / End | Jump to first / last visible node. |
| Right | If selected node is a collapsed directory, expand it. If expanded, move to first child. If a file, no-op. |
| Left | If selected node is an expanded directory, collapse it. Otherwise move to parent directory. |
| Enter | On a directory: toggle expansion. On a file: open it in a new tab (or focus the existing tab if already open), keep panel open. |
| `/` | Enter filter mode — show input row at bottom, characters narrow the visible tree to nodes whose path contains the substring. Esc / Enter exit filter mode. |
| `^T` | Toggle Project vs All .v mode (same as modal). |
| `F8` | Close the panel. Focus returns to whichever pane had it before. |
| `^P` | Standard pane cycle. |
| Esc | If in filter mode, exit filter mode. Otherwise no-op (consistent with other panes — Esc doesn't dismiss panes). |
| Mouse click | Move selection to clicked line. Single click on a file opens it; single click on a directory toggles expansion. (No double-click distinction.) |
| Mouse scroll | Scroll the visible region. |

Notes:

- The modal picker treats typing as the primary input and Tab as completion.
  The panel treats arrow keys as primary and `/` as an opt-in filter. This
  is the main UX divergence and the reason for splitting the widget.
- Filter mode in the panel does *not* flatten the tree; it just hides
  non-matching siblings, keeping the hierarchy intact. Matching ancestors
  stay expanded. (This is the netrw/NERDTree convention.)

## Architecture

### Phase 1 — Render layer rect consolidation

Standalone refactor, no user-visible change. Goal: kill the boilerplate
that makes adding a pane painful today.

Current state: `lib/render.ml` has `pane_id` matched in seven places
(`put_str`, `set_cell`, `fill`, `chgat`, `clear_pane`, `pane_dims`,
`pane_rect`) just to look up the rect for each pane. Each new pane
variant requires updating all seven sites.

Refactor: introduce a single internal `rect_of_pane : t -> pane_id ->
rect` and route every other function through it. Same external API;
internal call sites collapse.

Layout side (`compute_layout`) stays a hand-written function — the layout
shape is finite and a generic split-tree engine would be overkill. But
the mutable per-pane rect fields (`script`, `goals`, `messages`,
`status`, `minimap_rect`) become a single `panes : (pane_id, rect)`
lookup (likely a record with one field per variant, or a small hashtable
— pick whichever survives `ocamlc` warnings best; record is probably
nicer for exhaustiveness).

No behavior change. Existing unit tests should still pass; add one if a
gap shows up.

### Phase 2 — Dynamic pane allocation

Add `PFileTree` to the `pane_id` variant and an input to
`compute_layout`:

```ocaml
type layout_inputs = {
  file_tree_visible : bool;
  file_tree_width : int;  (* 0 when not visible *)
}
```

When `file_tree_visible` is true, the script pane's left edge moves right
by `file_tree_width + 1` (the +1 is the separator column, same as
minimap). All other panes are computed off the script pane's right edge,
so they ride along unchanged.

`pane_at` gains a clause for the file-tree column range. Mouse routing
into the new pane works automatically once that lands.

Chrome (`draw_chrome`): one extra vertical separator on the right edge
of the file-tree pane, drawn under the same conditions as the minimap
separator.

Still no widget — the pane is allocated but empty. Useful intermediate
commit because the layout change is testable in isolation.

### Phase 3 — `lib/file_listing.ml`

Small shared module. Clean API, no rendering:

```ocaml
type entry = {
  full_path : string;     (* absolute *)
  rel_path : string;      (* project-relative; "" for project root *)
  is_dir : bool;
  in_project : bool;      (* listed in _RocqProject *)
}

type mode = Project | All

val enumerate :
  project_dir:string ->
  project_file:string ->
  mode:mode ->
  entry list
(** Returns entries sorted by rel_path. Directories included.
    Caller decides how to render — flat list, tree, whatever. *)

val is_open : entry -> open_files:string list -> bool
```

`File_picker` is refactored to call `File_listing.enumerate`, then build
its existing `flat_line array` from the result. Its `entry` /
`flat_line` types stay private. Net diff inside `file_picker.ml`:
deletion of the enumeration logic, addition of a small adapter.

This module is roughly 60–80 lines. If a third caller never appears,
it's still a worthwhile extraction — the modal and panel will both
need to stay consistent with `_RocqProject` load-path semantics, and
having one place to fix that is the point.

### Phase 4 — `lib/file_tree.ml`

New module. Owns:

- Tree state: a recursive `node` type with mutable `expanded : bool` on
  dir nodes, mutable list of visible nodes derived from expansion +
  filter state.
- Selection / scroll indices (into the visible-nodes list).
- Filter state: `filter : string option` plus a normalized cache.
- Mode: `mode : File_listing.mode`.
- Open-files list (passed in from editor context, used for the `•`
  marker).
- Key / mouse / scroll handlers — analogous shape to `File_picker`'s
  handlers but operating on the tree model.
- `render : t -> Render.t -> unit` that draws into the `PFileTree`
  pane's rect via `Render.put_str` etc. (no overlay).

The tree is rebuilt from `File_listing.enumerate` on open, on
`^T`-mode-toggle, and when the project file watcher signals a change.
Expansion state persists across rebuilds *by rel_path* — i.e., a
directory the user expanded stays expanded after a file is added
elsewhere. (Persistence across sessions: out of scope for v1; see
below.)

State lives in `editor_context`. The panel is one global widget (not
per-tab) — opening a different `.v` file doesn't reset which dirs are
expanded. That feels right for a project navigator; revisit if it
proves wrong.

### Phase 5 — Wiring

- `lib/keys.ml`: bind `F8` to `Toggle_file_tree`.
- `lib/editor/editor.ml`: handle `Toggle_file_tree` — flip
  `ctx.file_tree_visible`, update `Render` layout inputs, recompute
  layout. If the panel is being shown for the first time this session,
  build the tree.
- Focus integration: `^P` cycle includes `PFileTree` when visible. The
  panel's key handler is dispatched by `view.ml`'s pane router
  alongside script / goals / messages.
- `Render.draw_chrome`: include the new separator + a `focused`
  indicator (reuse the existing focused-pane border highlight).
- Mouse — clicks inside the pane: pane hit-test from Phase 2 already
  routes clicks; just hook up the click handler.
- Mouse — drag-to-resize: follow the existing border-drag pattern (see
  `editor/mouse.ml:54–75, 172–188` for the template used by `PBorderV`,
  `PBorderH`, `PBorderMinimap`):
  - Add `PBorderFileTree` to `pane_id` and a hit-test clause for the
    panel's right-edge column when `file_tree_visible`.
  - Add `DragFileTree` to `drag_mode` in `editor_context`.
  - Add `Render.move_file_tree_border : t -> int -> unit` that sets the
    new width with clamping (min ~10 cols, max `term_w - script_min -
    other_panes`), then recomputes layout.
  - Mouse-down on `PBorderFileTree` sets `ctx.dragging <-
    DragFileTree`; motion dispatches to `move_file_tree_border`;
    release clears.
  - No vterm resize signals fired anywhere along this path, same as
    the existing border drags.
- Help text (`Keys.generate_help`) gains a "File tree" section with
  the bindings above.
- `CLAUDE.md` keybindings table: add the F8 row.

## Module map summary

| File | Status | Purpose |
|------|--------|---------|
| `lib/file_listing.ml` | new | Shared enumeration. No rendering, no state beyond a return value. |
| `lib/file_picker.ml` | modified | Modal picker. Delegates enumeration to `File_listing`. Behavior unchanged. |
| `lib/file_tree.ml` | new | Panel widget — tree model, expansion state, filter, render-into-pane. |
| `lib/render.ml` | refactored | Rect-lookup consolidation (Phase 1) + new `PFileTree` pane + dynamic layout (Phase 2). |
| `lib/editor_context.ml` | modified | Holds file-tree state and visibility flag. |
| `lib/editor/editor.ml` | modified | F8 handler + layout-input wiring. |
| `lib/keys.ml` | modified | New `Toggle_file_tree` action + binding. |
| `lib/view.ml` | modified | Pane router includes the new pane; chrome includes the new separator. |

## State ownership

- `file_tree.ml` widget state lives in `editor_context`. Not per-tab —
  it's a project navigator, not a per-buffer thing.
- `file_tree_visible : bool` also lives in `editor_context`. The
  layout-input to `Render.compute_layout` is derived from it on each
  resize / toggle.
- Modal picker state continues to live on the modal stack (unchanged).
- No persistence to disk in v1 — expansion state and visibility reset
  on relaunch. (Easy follow-up: stash in a small dotfile next to
  `_RocqProject`.)

## Out of scope for this work

- Persistence of expansion / visibility / width across sessions.
- File operations from the tree (rename, delete, create file). v1 is
  read-only navigation.
- Showing build / verification status indicators per file. Could be a
  natural follow-up; intentionally not in v1 to keep the diff
  contained.
- Replacing or unifying the modal picker. The two are designed to
  coexist; consolidating later is possible but not the goal here.
- Generic split-tree pane engine. Phase 1 stops at rect-lookup
  consolidation.

## Implementation order

1. **Phase 1** — render rect consolidation. Single commit. No
   user-visible change. Tests for layout still pass.
2. **Phase 2** — `PFileTree` pane variant + dynamic layout input.
   Single commit. Manually verifiable by hard-coding `file_tree_visible
   = true` and confirming the script pane shrinks; revert that toggle
   before merge.
3. **Phase 3** — `file_listing.ml` extraction + `file_picker.ml`
   refactor to use it. Single commit. Modal picker behavior should be
   bit-for-bit identical; spot-check with `^O`.
4. **Phase 4 + 5** — `file_tree.ml` widget + wiring + F8 + help + docs.
   One commit, or split into "widget" and "wiring" if Phase 4 grows.

## Open questions

These are deliberately deferred until implementation; reasonable
defaults are noted but worth a sanity check before coding each phase.

- **Initial panel width.** Proposal: 28 columns. Wide enough for most
  filenames, narrow enough not to dominate. User can drag the right
  border to resize; persistence across sessions is a follow-up.
- **Default visibility.** Proposal: hidden at startup. The user opts
  in with F8. Avoids surprising existing users.
- **Behavior when F8 pressed while panel is focused.** Proposal: close
  panel, return focus to script. Symmetric with how other toggles
  behave.
- **Filter syntax — substring or fuzzy.** Proposal: simple substring
  match on rel_path. Matches the modal picker's current behavior
  (which is also substring). Fuzzy is a follow-up if we want it
  consistently across both widgets.
- **What happens to expansion state when `^T` flips Project ↔ All
  mode.** Proposal: preserve by rel_path — dirs visible in both modes
  keep their state; new dirs revealed by All start collapsed.
