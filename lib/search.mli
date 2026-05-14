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

(** Which prompt field input is currently directed to. *)
type focus = Find | Replace

type state = private {
  query : string;
  flags : flags;
  matches : match_ array;  (** Sorted by start position. *)
  current : int;           (** Index into [matches]; -1 when none. *)
  saved_cursor : pos;      (** Cursor when search opened (cancel restore). *)
  replacement : string;    (** Replace-field text (empty in pure-search mode). *)
  focus : focus;           (** Which field receives typing. *)
}

(** New state model (see [docs/SEARCH_STATE_REFACTOR.md]). Coexists
    with [state] during the phased migration; [state] is retired in
    Phase 2. *)

(** Global "what we're searching for" — one instance lives in
    [Editor_context]. *)
type query_state = {
  query : string;
  flags : flags;
  replacement : string;
  focus : focus;
}

(** Per-buffer matches plus the user's cursor (the "active match")
    within them. *)
type buffer_matches = {
  matches : match_ array;
  mutable current : int;
  saved_cursor : pos;
}

val empty_flags : flags
val empty_query : query_state

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

(** Like [recompute] but on a raw text string. Used by the project-wide
    scanner so each file doesn't have to be wrapped in a [Buffer.t]. *)
val recompute_in_text : string -> string -> flags -> match_ array

(** Build a [buffer_matches] for [buf] using the given [query_state].
    [anchor] picks the new [current] — typically the previous current's
    start_ (preserving location across a recompute), or
    [saved_cursor] when there was no previous current. *)
val recompute_buffer_matches :
  query_state -> Buffer.t ->
  anchor:pos -> saved_cursor:pos -> buffer_matches

(** Previous-current's start_ when valid, else [m.saved_cursor]. The
    natural anchor for a recompute that wants to "stick to where the
    user was looking". *)
val anchor_of : buffer_matches -> pos

(** Mutating navigation on a [buffer_matches]. *)
val bm_next : buffer_matches -> unit
val bm_prev : buffer_matches -> unit
val bm_set_current : buffer_matches -> int -> unit

val bm_current_match : buffer_matches -> match_ option

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

(** Update the replace-field text. Does not recompute matches. *)
val set_replacement : state -> string -> state

(** Set the focused field. *)
val set_focus : state -> focus -> state

(** Compute the substituted text for [matched] under the current query and
    flags. In literal mode this is just [replacement]. In regex mode it
    expands `$1`-`$9`, `$&`, and `$$` against the regex groups matched on
    [matched]. Returns [replacement] verbatim if the regex no longer
    compiles. *)
val substitute :
  query:string -> flags:flags -> replacement:string -> matched:string -> string

(** Advance / retreat the current match. Wraps. No-op when there are
    no matches. *)
val next : state -> state
val prev : state -> state

(** Set the current match index directly. Clamps to [\[0, n)] when
    there are matches, sets to [-1] when there are none. *)
val set_current : state -> int -> state

(** The current match, or [None] when there are no matches. *)
val current_match : state -> match_ option

(** Whether [query] under [flags] would match case-insensitively. Useful
    for rendering the case toggle indicator. *)
val is_case_insensitive : query:string -> flags:flags -> bool
