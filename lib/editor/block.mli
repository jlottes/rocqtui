(** Edit-blocking and verified-region rewinding. *)

(** Whether editing is currently blocked at the cursor — either because
    the buffer is locked (e.g. by MCP), or the cursor sits inside the
    pending-verified region. With [for_backspace=true] the boundary is
    inclusive (a backspace at the boundary is also blocked). *)
val edit_blocked : ?for_backspace:bool -> Tab.t -> bool

(** After an undo/redo, retract the verified target if the edit landed
    inside the pending region. *)
val rewind_if_needed : Tab.t -> unit
