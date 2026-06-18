(** Jump-to-definition, shared by the ^L key and the live-info pane's 🔍
    glyph. Resolves a name to its source location via [Locate] + the
    .glob index, records the current spot for ^B, and opens the target. *)

(** Jump to the definition of identifier [w], resolved against [session]
    (the session in which [w] is in scope). *)
val of_ident :
  Editor_context.t -> Render.t -> tab:Tab.t -> session:Session.t -> string -> unit

(** Jump to the source of a Required module [m]. [session] may be [None],
    in which case the project's module resolution is used. *)
val of_require_module :
  Editor_context.t -> Render.t -> tab:Tab.t -> session:Session.t option ->
  string -> unit
