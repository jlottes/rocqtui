(** Editor: input handling. *)

type jump_point = Editor_context.jump_point

type action =
  | Continue
  | Quit
  | Close_tab
  | Save_prompt
  | Reload
  | Open_file of string
  | Jump_back of jump_point

val init_compose : Editor_context.t -> unit

(** Handle an input event. *)
val handle_event : Editor_context.t -> Input.event -> Tab.t -> Render.t -> action

(** After Open_file action, get the target position (line, col) for jump. *)
val take_jump_target : Editor_context.t -> (int * int) option
