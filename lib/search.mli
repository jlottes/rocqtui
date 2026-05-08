(** Per-tab incremental search state.

    Pure module: no I/O, no buffer mutation. The renderer reads matches
    via the public fields; the editor's modal handler builds new states
    by calling [update_query], [toggle_case], [next], etc. *)

type case_mode =
  | Smart      (** Case-insensitive unless [query] contains uppercase. *)
  | Sensitive  (** Always case-sensitive. *)

type flags = {
  case : case_mode;
  regex : bool;  (** PCRE regex when true; literal string otherwise. *)
}

(** 0-based [(line, byte-col)] — matches the [Buffer] cursor convention. *)
type pos = { line : int; col : int }

type match_ = { start_ : pos; end_ : pos }

type state = private {
  query : string;
  flags : flags;
  matches : match_ array;  (** Sorted by start position. *)
  current : int;           (** Index into [matches]; -1 when none. *)
  saved_cursor : pos;      (** Cursor when search opened (cancel restore). *)
}

val empty_flags : flags

(** Empty state anchored at the buffer's current cursor. *)
val create : Buffer.t -> state

(** Refresh [saved_cursor] from the buffer's current cursor. Called when
    the prompt is (re-)opened so cancel restores to the position before
    *this* prompt session, not the position before search first became
    active. *)
val resave_cursor : state -> Buffer.t -> state

(** Compute matches for [query] against the full buffer text. Returns an
    empty array for an empty query or an invalid regex. *)
val recompute : Buffer.t -> string -> flags -> match_ array

(** Replace [query] and recompute. Picks the first match at or after the
    saved cursor as the new [current]. *)
val update_query : state -> Buffer.t -> string -> state

(** Recompute after a buffer edit. Anchors [current] to its previous
    match start when possible; falls back to [saved_cursor]. *)
val update_after_edit : state -> Buffer.t -> state

(** Replace [flags] and recompute, anchoring like [update_after_edit]. *)
val set_flags : state -> Buffer.t -> flags -> state

val toggle_case : state -> Buffer.t -> state
val toggle_regex : state -> Buffer.t -> state

(** Advance / retreat the current match. Wraps. No-op when there are
    no matches. *)
val next : state -> state
val prev : state -> state

(** The current match, or [None] when there are no matches. *)
val current_match : state -> match_ option

(** Whether [query] under [flags] would match case-insensitively. Useful
    for rendering the case toggle indicator. *)
val is_case_insensitive : query:string -> flags:flags -> bool
