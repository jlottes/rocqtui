(** Keyboard input handling for the editor. *)

type action =
  | Continue
  | Quit
  | Save_prompt

(** Set a persistent error message to show when there's no session. *)
val set_init_error : string -> unit

(** Load XCompose sequences for input. *)
val init_compose : unit -> unit

val handle_key : int -> Buffer.t -> Display.t -> Session.t option -> action
