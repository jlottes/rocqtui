(** Grep-style search result set, shared between single-file and
    project-wide search. Pure value: no I/O. *)

type match_loc = {
  ml_line : int;          (** 1-based for display *)
  ml_col_start : int;     (** 0-based byte offset within ml_line_text *)
  ml_col_end : int;       (** exclusive *)
  ml_line_text : string;  (** full source line *)
}

type file_matches = {
  fm_path : string;       (** absolute path *)
  fm_rel_path : string;   (** project-relative; "" if outside project *)
  fm_matches : match_loc array;
}

type t

val empty : query:string -> flags:Search.flags -> t

val query : t -> string
val flags : t -> Search.flags
val total : t -> int
val scanning : t -> bool
val files : t -> file_matches list
val current : t -> (string * int) option

(** Append a file's matches to the result set in scan order. No-op
    if [fm.fm_matches] is empty. *)
val add_file : t -> file_matches -> unit

(** Whether a scan is in flight. Set by the worker. *)
val set_scanning : t -> bool -> unit

(** Lookup helpers — used by the click handler and F3 stepping. *)
val find_file : t -> string -> file_matches option
val find_match : t -> string -> int -> match_loc option

(** Set the (path, match_index) cursor. *)
val set_current : t -> (string * int) option -> unit

(** Advance the cursor across all files in scan order. Wraps. Returns
    the new (file path, match) or [None] if [total = 0]. As a side
    effect, updates [current]. *)
val advance : t -> forward:bool -> (string * match_loc) option

(** Derive a single-file result set from the existing [Search.state]
    + buffer. Convenience for the per-tab search case. *)
val of_single_file :
  path:string -> rel_path:string ->
  Search.state -> Buffer.t -> t
