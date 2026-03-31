(** Editor: rendering and input handling. *)

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
  | Reload
  | Open_file of string
  | Jump_back of jump_point

val init_compose : unit -> unit

(** Render the active tab. *)
val render_all : Editor_context.t -> Render.t -> Tab.t -> unit

(** Handle an input event. *)
val handle_event : Editor_context.t -> Input.event -> Tab.t -> Render.t -> action

(** After Open_file action, get the target position (line, col) for jump. *)
val take_jump_target : unit -> (int * int) option
