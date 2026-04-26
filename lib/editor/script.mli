(** Script-pane keyboard handling: navigation, editing, clipboard. *)

(** Normalize \r\n and \r to \n — terminals send \r in bracketed paste. *)
val normalize_newlines : string -> string

(** Insert a string into [tab]'s buffer one character at a time,
    respecting the verified-region/locked-buffer edit gate. No-op if
    editing is blocked. *)
val insert_string : Tab.t -> string -> unit

(** Handle a key event when the script pane has keyboard focus.
    Returns [Some action] if the event was consumed (almost always
    [Continue]), or [None] to fall through to the global default. *)
val handle :
  Editor_context.t -> Input.event -> Tab.t -> Render.t -> Action.action option
