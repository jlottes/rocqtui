(** Tab management for multi-file editing. *)

type t = {
  buf : Buffer.t;
  mutable session : Session.t option;
  session_args : string list;
  mutable goals_scroll : int;
  mutable messages_scroll : int;
  mutable focused_pane : [`Script | `Goals | `Messages];
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable suppress_ensure_visible : bool;
}

type manager = {
  mutable tabs : t list;
  mutable active : int;
  mutable tab_scroll : int;
}

(** Create a new tab with an empty buffer and a fresh session. *)
val create_blank : ?args:string list -> unit -> t

(** Create a tab from a file, optionally starting a Rocq session. *)
val create_from_file : ?args:string list -> string -> t

(** Get the active tab. *)
val active_tab : manager -> t

(** Number of tabs. *)
val count : manager -> int

(** Add a tab and make it active. *)
val add_tab : manager -> t -> unit

(** Close the active tab. Returns false if it was the last tab. *)
val close_active : manager -> bool

(** Switch to next/previous tab. *)
val next_tab : manager -> unit
val prev_tab : manager -> unit

(** Create a manager with an initial tab. *)
val create_manager : t -> manager

(** Poll all sessions. Returns true if any state changed. *)
val poll_all : manager -> bool

(** Find which tab index was clicked given x coordinate on the tab bar. *)
val tab_at_x : manager -> int -> int option
