(** Tab management for multi-file editing. *)

type pane_selection = {
  mutable ps_anchor_line : int;
  mutable ps_anchor_col : int;
  mutable ps_cursor_line : int;
  mutable ps_cursor_col : int;
  mutable ps_active : bool;
}

(** Per-file state for the global Rocq sub-tab. The Rocq tab itself
    is a fixed entry on the global {!Msg_pane}; its content is
    pulled from each file's [Session.messages] each frame, but
    scroll position, pane-selection, and cached wrapped lines are
    per-file. *)
type rocq_msg_state = {
  mutable rms_scroll : int;
  rms_sel : pane_selection;
  mutable rms_lines_cache : Styled.line list;
}

type t = {
  id : int;
  buf : Buffer.t;
  rb : Region_buffer.t;  (** Edit gateway. Owns the lock state. *)
  mutable session : Session.t option;
  session_args : string list;
  mutable goals_scroll : int;
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable last_ensured_cur : (int * int) option;
  goals_sel : pane_selection;
  mutable goals_lines_cache : Styled.line list;
  rocq_msg : rocq_msg_state;
  mutable search : Search.state option;
  mutable search_revision : int;
}

type manager = {
  mutable tabs : t list;
  mutable active : int;
  mutable tab_scroll : int;
}

(** Canonicalize a path: make absolute (relative to cwd) and collapse
    `.`, `..`, redundant `/`. Used to dedupe tabs and to compare buffer
    filenames against build-error entries. *)
val canonical_path : string -> string

val create_blank : ?args:string list -> unit -> t
val create_from_file : ?args:string list -> string -> t

(** Tab's search state, refreshed against the buffer if the buffer has
    been mutated since the matches were last computed. Returns [None]
    when search is inactive on this tab. Callers should prefer this over
    reading the [search] field directly. *)
val search_state : t -> Search.state option

(** Replace the tab's search state. Records the current buffer revision
    so the next [search_state] read won't refresh unnecessarily. *)
val set_search : t -> Search.state option -> unit

val active_tab : manager -> t
val find_by_id : manager -> int -> t option
val index_of_id : manager -> int -> int option
val count : manager -> int
val add_tab : manager -> t -> unit

(** Switch to a tab by ID. Returns true if found. *)
val switch_to_id : manager -> int -> bool

(** Open a file or switch to it if already open.
    Returns (tab, created) where created=true if new tab was made. *)
val open_or_switch : manager -> ?extra_args:string list -> string -> t * bool

val close_active : manager -> bool
val next_tab : manager -> unit
val prev_tab : manager -> unit
val create_manager : t -> manager
val poll_all : manager -> bool
val tab_at_x : manager -> int -> int option

val display_names : manager -> (int * string) list
val project_relative_path : string option -> string

val fresh_pane_sel : unit -> pane_selection
val fresh_rocq_msg_state : unit -> rocq_msg_state
