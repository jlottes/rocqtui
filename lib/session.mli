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

(** Set target to a byte offset (snapped to sentence boundary). May rewind. *)
val go_to_offset : t -> int -> unit

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

(** [width] is the target line width for Pp pretty-printing. Defaults
    to ~78 (matching {!Pp.string_of_ppcmds}). The View should pass the
    current goals/messages pane width so output reflows on resize. *)
val goals_text : ?all_hyps:bool -> ?width:int -> t -> string option

val messages : ?width:int -> t -> string list
val clear_messages : t -> unit
val set_messages : t -> string list -> unit
val sentence_ranges : t -> sentence_display list
val is_busy : t -> bool
val is_busy_opt : t option -> bool
val pid : t -> int

(** Run a query (e.g. [About foo.]) at the current tip with the
    current Printopts baked in. Per-call [extra_opts] override
    persistent options for this query only. Implementation: Add one
    [Set Printing X.] sentence per option to a transient state on top
    of [tip], query at that state, then [edit_at] back. Slightly
    expensive (one round-trip per option) but the only way to affect
    [Stm.query]'s rendering — see [session.ml] for the rationale. *)
val query :
  ?extra_opts:(string list * Interface.option_value) list ->
  t -> string -> unit

val fetch_goals_text :
  ?all_hyps:bool ->
  ?width:int ->
  ?extra_opts:(string list * Interface.option_value) list ->
  t -> string option
val sync_options_and_refresh : t -> unit
val quit : t -> unit
