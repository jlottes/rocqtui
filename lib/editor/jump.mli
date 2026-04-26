(** Jump-back stack: cursor-position history for cross-file navigation. *)

(** Push the current cursor position of [tab] onto the jump stack. *)
val push : Editor_context.t -> Tab.t -> unit

(** Pop and return the most recent jump point, or [None] if empty. *)
val pop : Editor_context.t -> Editor_context.jump_point option
