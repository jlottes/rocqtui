(** Match input events against key bindings. *)

(** Whether [ev] matches binding [b]. Handles both legacy ncurses-style
    codes and the kitty keyboard protocol's modifier-aware codes. *)
val match_binding : Input.event -> Keys.binding -> bool

(** Extract a codepoint from an event for compose-feeding or
    single-key dispatch. Returns [None] for events that aren't a single
    key press (mouse, paste, resize). *)
val codepoint_of_event : Input.event -> int option
