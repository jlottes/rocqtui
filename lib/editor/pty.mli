(** PTY routing: open a terminal sub-tab, forward input events to its PTY. *)

(** Open a new terminal sub-tab. If [cmd] is given, run it; otherwise
    a default shell. Switches focus to the Messages pane. *)
val open_tab : ?cmd:string -> Editor_context.t -> Tab.t -> Render.t -> unit

(** Send an Escape keypress to the active terminal of [tab], if any. *)
val send_escape : Tab.t -> unit

(** Forward a single input event to a terminal's PTY. Encodes printable
    keys as UTF-8, control/modified keys via the kitty protocol when
    enabled, and pastes via bracketed-paste when supported. *)
val forward_event : Terminal.t -> Input.event -> unit
