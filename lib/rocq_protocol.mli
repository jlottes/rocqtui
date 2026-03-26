(** Communication with coqidetop via the XML protocol.
    Uses Spawn.Async with a select-based main loop. *)

type t

(** Spawn coqidetop and establish the XML protocol connection. *)
val spawn : ?prog:string -> ?args:string list -> unit -> t

(** {2 Synchronous operations (block until response)} *)

val init : t -> string option -> Stateid.t
val add : t -> state_id:Stateid.t -> edit_id:int ->
  verbose:bool -> bp:int -> line:int -> bol:int ->
  string -> Interface.add_rty Interface.value
val edit_at : t -> Stateid.t -> Interface.edit_at_rty Interface.value
val goals : t -> Interface.goals option Interface.value
val query : t -> state_id:Stateid.t -> string -> unit
val set_options : t -> (string list * Interface.option_value) list -> bool
val quit : t -> unit

(** {2 Async operations} *)

(** Send a call with a continuation. The continuation is invoked when
    the response arrives (via poll or eval_call). *)
val send_call : t -> 'a Xmlprotocol.call ->
  ('a Interface.value -> unit) -> unit

(** Whether there is a pending async call. *)
val is_busy : t -> bool

(** Poll: dispatch any pending watch callbacks (non-blocking). *)
val poll : t -> unit

(** {2 Utility} *)

val pid : t -> int
val drain_feedback : t -> Feedback.feedback list
