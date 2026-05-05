(** Tab management for multi-file editing. *)

type pane_selection = {
  mutable ps_anchor_line : int;
  mutable ps_anchor_col : int;
  mutable ps_cursor_line : int;
  mutable ps_cursor_col : int;
  mutable ps_active : bool;
}

(** A sub-tab in the messages pane (e.g. "Rocq", "Build", or a terminal). *)
type msg_tab = {
  mt_name : string;
  mutable mt_lines : string list;
  mutable mt_scroll : int;
  mt_sel : pane_selection;
  mutable mt_lines_cache : string list;
  mt_terminal : Terminal.t option;  (** Some = terminal sub-tab *)
}

(** Messages pane tab manager. *)
type msg_tabs = {
  mutable mt_tabs : msg_tab list;
  mutable mt_active : int;
}

type t = {
  id : int;
  buf : Buffer.t;
  rb : Region_buffer.t;  (** Edit gateway. Owns the lock state. *)
  mutable session : Session.t option;
  session_args : string list;
  mutable focused_pane : [`Script | `Goals | `Messages];
  mutable goals_scroll : int;
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable last_ensured_cur : (int * int) option;
  goals_sel : pane_selection;
  mutable goals_lines_cache : string list;
  msg : msg_tabs;
}

type manager = {
  mutable tabs : t list;
  mutable active : int;
  mutable tab_scroll : int;
}

val create_blank : ?args:string list -> unit -> t
val create_from_file : ?args:string list -> string -> t
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

(** Messages pane sub-tab helpers. *)
val fresh_pane_sel : unit -> pane_selection
val active_msg_tab : msg_tabs -> msg_tab
val find_msg_tab : msg_tabs -> string -> (int * msg_tab) option
val ensure_msg_tab : msg_tabs -> string -> msg_tab
val activate_msg_tab : msg_tabs -> string -> unit
val msg_tab_display_name : msg_tab -> string
val sync_terminals : msg_tabs -> unit
val set_sticky_terminal : Terminal.t option -> unit
val get_sticky_terminal : unit -> Terminal.t option
