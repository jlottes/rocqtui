(** Session state: manages the Rocq connection, sentence tracking,
    and proof state display.

    The model: the user controls a "target" boundary that can be moved
    instantly. The "verified" boundary chases the target asynchronously
    by sending sentences to rocqtop one at a time. *)

type t

type sentence_status = Processing | Verified | Error of string

type sentence_display = {
  sd_start : int;
  sd_end : int;
  sd_status : sentence_status;
}

val create : ?prog:string -> ?args:string list -> Buffer.t -> t

(** Move target forward by one sentence. *)
val step_forward : t -> unit

(** Move target backward by one sentence. May rewind rocqtop. *)
val step_backward : t -> unit

(** Set target to cursor position. May rewind rocqtop. *)
val go_to_cursor : t -> unit

(** Poll: process feedback and drive async stepping toward target.
    Returns true if state changed (needs re-render). *)
val poll : t -> bool

(** End of the verified region (last confirmed sentence). *)
val verified_end : t -> int

(** End of the pending region (= target_end, for display). *)
val pending_end : t -> int

val error_range : t -> (int * int) option
val clear_error : t -> unit
val goals_text : ?all_hyps:bool -> t -> string option
val messages : t -> string list
val clear_messages : t -> unit
val sentence_ranges : t -> sentence_display list
val is_busy : t -> bool
val pid : t -> int
val query : t -> string -> unit
val sync_options_and_refresh : t -> unit
val quit : t -> unit
