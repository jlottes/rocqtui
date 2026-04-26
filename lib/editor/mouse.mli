(** Mouse event handling: click/drag/scroll across all panes. *)

(** Apply a mouse event: terminal forwarding, border drag, text
    selection drag, scroll, click-to-position. Mutates [ctx], [tab],
    and [r] as appropriate. *)
val handle :
  Editor_context.t -> Input.mouse_event -> Tab.t -> Render.t -> unit
