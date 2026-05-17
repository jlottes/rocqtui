(** Editor: input handling. *)

type jump_point = Action.jump_point

type action = Action.action =
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

(** Drain a deferred Open_file path queued by an async on_done callback
    (e.g. the jump-to-definition Locate chain). The main loop calls this
    after each session poll and dispatches the path as an Open_file. *)
val take_pending_open : Editor_context.t -> string option
