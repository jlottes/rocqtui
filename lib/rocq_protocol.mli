(** Communication with coqidetop via the XML protocol.
    Uses Spawn.Async with a select-based main loop. *)

type t

(** Spawn coqidetop and establish the XML protocol connection. *)
val spawn : ?prog:string -> ?args:string list -> unit -> t

(** Synchronous initialization. Runs once at session creation, before
    the main loop is up — this is the one place we block on a rocq
    response. *)
val init : t -> string option -> Stateid.t

(** Best-effort quit: send Quit and kill the subprocess. *)
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

(** Whether any call is currently queued or in flight. *)
val is_busy : t -> bool

(** Poll: dispatch any pending watch callbacks (non-blocking). *)
val poll : t -> unit

(** {2 Utility} *)

val pid : t -> int

(** Set a hook called when stdin has data during [init]'s blocking
    wait. Used to allow ^C to interrupt session creation. *)
val set_interrupt_hook : (t -> unit) -> unit
val drain_feedback : t -> Feedback.feedback list
