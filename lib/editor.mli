(** Keyboard input handling for the editor. *)

type action =
  | Continue
  | Quit
  | Save_prompt

(** Set a persistent error message to show when there's no session. *)
val set_init_error : string -> unit

(** Load XCompose sequences for input. *)
val init_compose : unit -> unit

(** Set callback for tab bar clicks. Called with x coordinate. *)
val set_tab_bar_click_handler : (int -> unit) -> unit

(** Set extra text to append to the status bar (e.g., MCP spinner). *)
val set_status_extra : string -> unit

(** Render the active tab's display. *)
val render_all : Display.t -> Tab.t -> unit

val handle_key : int -> Tab.t -> Display.t -> action
