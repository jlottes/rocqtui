(** Session state: manages the Rocq connection, sentence tracking,
    and proof state display. *)

type t

type sentence_status = Processing | Verified | Error of string

type sentence_display = {
  sd_start : int;
  sd_end : int;
  sd_status : sentence_status;
}

val create : ?prog:string -> ?args:string list -> Buffer.t -> t
val step_forward : t -> unit
val step_backward : t -> unit
val go_to_cursor : t -> unit

(** Poll for asynchronous feedback from Rocq (non-blocking). *)
val poll : t -> unit

val verified_end : t -> int
val error_range : t -> (int * int) option
val goals_text : ?all_hyps:bool -> t -> string option
val messages : t -> string list
val clear_messages : t -> unit

(** Per-sentence status info for rendering, in document order. *)
val sentence_ranges : t -> sentence_display list

(** Get the PID of the coqidetop process (for sending signals). *)
val pid : t -> int

(** Run a query (e.g. "About foo", "Print bar") at the current tip. *)
val query : t -> string -> unit

(** Sync printing options to rocqtop and refresh goals. *)
val sync_options_and_refresh : t -> unit

val quit : t -> unit
