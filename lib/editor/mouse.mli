(** Mouse event handling: click/drag/scroll across all panes. *)

(** Apply a mouse event: terminal forwarding, border drag, text
    selection drag, scroll, click-to-position. Mutates [ctx], [tab],
    and [r] as appropriate.

    Returns [Some action] when the click should bubble up an editor
    action (e.g. [Open_file] for jump-to-error in the Build / Errors
    tab); [None] otherwise. *)
val handle :
  Editor_context.t -> Input.mouse_event -> Tab.t -> Render.t ->
  Action.action option
