(** Keyboard input handling for the editor. *)

type jump_point = {
  jp_tab_id : int;
  jp_file : string;
  jp_line : int;
  jp_col : int;
}

type action =
  | Continue
  | Quit
  | Close_tab
  | Save_prompt
  | Open_file of string
  | Jump_back of jump_point

(** Set a persistent error message to show when there's no session. *)
val set_init_error : string -> unit

(** Load XCompose sequences for input. *)
val init_compose : unit -> unit

(** Set callback for tab bar clicks. Called with x coordinate. *)
val set_tab_bar_click_handler : (int -> unit) -> unit

(** Set extra text to append to the status bar (e.g., MCP spinner). *)
val set_status_extra : string -> unit

(** Set callback to get list of open file paths (for file picker). *)
val set_open_files_fn : (unit -> string list) -> unit

(** Render the active tab's display. *)
val render_all : Display.t -> Tab.t -> unit

val handle_key : int -> Tab.t -> Display.t -> action

(** After Open_file action, get the target position (line, col) for jump.
    Returns and clears the value. *)
val take_jump_target : unit -> (int * int) option

(** Set the current theme name (for tracking the active theme). *)
val set_current_theme : string -> unit
