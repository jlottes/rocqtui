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

(** A pull-style result handle. [None] until the response arrives,
    then [Some value]. *)
type 'a handle = 'a Interface.value option ref

(** Submit a call and return a handle for the result. Always safe —
    multiple submissions are queued FIFO and dispatched serially. *)
val submit : t -> 'a Xmlprotocol.call -> 'a handle

(** Read the result from a handle ([None] if still pending). *)
val poll_response : 'a handle -> 'a Interface.value option

(** Push-style: submit with a continuation. Equivalent to [submit]
    followed by polling, but the continuation fires automatically
    when the response arrives. *)
val send_call : t -> 'a Xmlprotocol.call ->
  ('a Interface.value -> unit) -> unit

(** Whether any call is currently queued or in flight. *)
val is_busy : t -> bool

(** Poll: dispatch any pending watch callbacks (non-blocking). *)
val poll : t -> unit

(** {2 Utility} *)

val pid : t -> int

(** Set a hook called when stdin has data during a blocking eval_call.
    Used to allow ^C to interrupt. *)
val set_interrupt_hook : (t -> unit) -> unit
val drain_feedback : t -> Feedback.feedback list
