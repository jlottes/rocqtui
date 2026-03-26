(** Communication with coqidetop via the XML protocol. *)

type t

(** Spawn coqidetop and establish the XML protocol connection. *)
val spawn : ?prog:string -> ?args:string list -> unit -> t

(** Send the Init call. Returns the initial state id. *)
val init : t -> string option -> Stateid.t

(** Add a sentence. *)
val add : t -> state_id:Stateid.t -> edit_id:int ->
  verbose:bool -> bp:int -> line:int -> bol:int ->
  string -> Interface.add_rty Interface.value

(** Rewind to just after the given state. *)
val edit_at : t -> Stateid.t -> Interface.edit_at_rty Interface.value

(** Fetch current goals. *)
val goals : t -> Interface.goals option Interface.value

(** Run a query (About, Print, Check, etc.) at a given state. *)
val query : t -> state_id:Stateid.t -> string -> unit

(** Set printing options. *)
val set_options : t -> (string list * Interface.option_value) list -> bool

(** Quit gracefully. *)
val quit : t -> unit

(** Get the file descriptor for the input channel (for Unix.select). *)
val input_fd : t -> Unix.file_descr

(** Check if there is data available to read (non-blocking). *)
val has_data : t -> bool

(** Get the pid of the coqidetop process. *)
val pid : t -> int

(** Accumulated feedback messages from the last call. *)
val drain_feedback : t -> Feedback.feedback list

(** Poll for any available feedback (non-blocking). *)
val poll_feedback : t -> unit
