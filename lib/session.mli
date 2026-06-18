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

(** The current document tip — the state a query runs at. Use as part of
    a cache key to detect when a re-query is needed (e.g. a symbol that
    has just become defined as the verified region advanced). *)
val tip : t -> Stateid.t

(** End of the pending region (= target_end, for display). *)
val pending_end : t -> int

val error_range : t -> (int * int) option
val clear_error : t -> unit

(** [width] is the target line width for Pp pretty-printing. Defaults
    to ~78 (matching {!Pp.string_of_ppcmds}). The View should pass the
    current goals/messages pane width so output reflows on resize. *)
val goals_text : ?all_hyps:bool -> ?width:int -> t -> string option

val messages : ?width:int -> t -> string list

(** Render a single [Pp.t] to a string at the given width (default ~78).
    Use when consuming [on_done] callbacks from {!query} — those receive
    raw Pp values, not formatted strings. *)
val string_of_pp : ?width:int -> Pp.t -> string
val clear_messages : t -> unit
val set_messages : t -> string list -> unit
val sentence_ranges : t -> sentence_display list
val is_busy : t -> bool
val is_busy_opt : t option -> bool
val pid : t -> int

(** Interrupt the running rocqtop. Sends SIGINT and enqueues a
    benign drain call so a leftover [Control.interrupt] in coqtop's
    main thread (set when the signal arrives between interruptible
    calls) doesn't trip the next [edit_at] / [Add]. *)
val interrupt : t -> unit

(** Mark this session as having a user-initiated step in flight.
    Call before {!step_forward}/{!step_backward}/{!go_to_offset}/
    {!go_to_cursor} when the step originates from a user action
    (key binding, mouse click). MCP/internal callers don't tag, so
    {!consume_user_step_result} never fires for them. *)
val set_user_step_pending : t -> unit

(** Once per poll cycle, consume the result of a settled user step.
    Returns [Some `Ok] / [Some `Error] when a user step has just
    completed (clears the pending flag), [None] otherwise. The
    editor uses [`Error] to auto-switch to the Rocq sub-tab. *)
val consume_user_step_result : t -> [`Ok | `Error] option

(** Run a query (e.g. [About foo.]) at the current tip with the
    current Printopts baked in. Per-call [extra_opts] override
    persistent options for this query only.

    Implementation: Add one [Set Printing X.] sentence per option to
    a transient state on top of [tip], query at that state, then
    [edit_at] back. Slightly expensive (one round-trip per option)
    but the only way to affect [Stm.query]'s rendering — see
    [session.ml] for the rationale.

    Pull-style: this sets the pending intent. [poll] picks it up
    when the session is idle. Without [on_done] (editor case), the
    result lands in [messages]. With [on_done] (MCP case), the
    callback receives the result and the editor's prior [messages]
    are preserved. Second calls while a query is pending are
    silently dropped. *)
val query :
  ?extra_opts:(string list * Interface.option_value) list ->
  ?on_done:(Pp.t list -> unit) ->
  t -> string -> unit

(** Set the pending fetch_goals intent. [poll] picks it up when the
    session is idle. The formatted goals text (or [None] if there's
    no proof in progress) is delivered to [on_done]. Second calls
    while a fetch is pending are silently dropped. *)
val start_fetch_goals :
  ?all_hyps:bool ->
  ?width:int ->
  ?extra_opts:(string list * Interface.option_value) list ->
  t -> on_done:(string option -> unit) -> unit
val sync_options_and_refresh : t -> unit
val quit : t -> unit
