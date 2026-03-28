(** Tab management for multi-file editing. *)

type pane_selection = {
  mutable ps_anchor_line : int;
  mutable ps_anchor_col : int;
  mutable ps_cursor_line : int;
  mutable ps_cursor_col : int;
  mutable ps_active : bool;
}

type t = {
  id : int;
  buf : Buffer.t;
  mutable session : Session.t option;
  session_args : string list;
  mutable focused_pane : [`Script | `Goals | `Messages];
  mutable goals_scroll : int;
  mutable messages_scroll : int;
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable suppress_ensure_visible : bool;
  goals_sel : pane_selection;
  messages_sel : pane_selection;
  mutable goals_lines_cache : string list;
  mutable messages_lines_cache : string list;
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
val close_active : manager -> bool
val next_tab : manager -> unit
val prev_tab : manager -> unit
val create_manager : t -> manager
val poll_all : manager -> bool
val tab_at_x : manager -> int -> int option

(** Compute disambiguated display names for tabs.
    Returns [(tab_id, display_name)] pairs. When two tabs share a basename,
    parent directories are prepended until unique. *)
val display_names : manager -> (int * string) list

(** Project-relative path for a filename, or basename if no project found. *)
val project_relative_path : string option -> string
