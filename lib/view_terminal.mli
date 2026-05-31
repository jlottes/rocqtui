(** Render driver for the [tterm] binary.

    The screen has a one-row status bar at the bottom (always
    visible); everything above it is the {!body_rect}, which hosts
    a {!Layout.t} of leaves and splits. Each leaf paints its own
    one-row tab strip at the top of its rect and its active
    terminal in the body below it. *)

val body_rect : Render.t -> Render.rect
(** The whole-screen area available to the layout tree: from row 1
    (right below where rocqtui would have its top file-tab bar; in
    tterm it's empty when no splits, or covered by the root leaf's
    own tab strip) through the row above the status bar. Used by
    [bin/tterm.ml] for the per-frame [Layout.compute_rects] call
    and for sizing newly spawned terminals. *)

val render_all :
  Editor_context.t -> Render.t -> Layout.t ->
  active_leaf_id:int -> overlay:(Grid.t -> unit) option -> unit
(** Walk the layout and paint every leaf's tab strip + body +
    cursor (cursor only for the active leaf, when its active
    terminal has its cursor visible). Draw split dividers. Update
    the global status bar from the active leaf's active terminal.

    [overlay] is an optional final drawing pass into the front
    grid — used by [bin/tterm.ml] to paint a drag-tab ghost on top
    of the rendered scene. *)
