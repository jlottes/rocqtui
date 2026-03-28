(** Helpers for parsing Locate output and Require lines. *)

(** Parse "Locate <ident>." output.
    Returns (kind, module_path, def_name) or None. *)
val parse_locate : string -> (string * string * string) option

(** Parse "Locate Library <mod>." output.
    Returns the .vo file path or None. *)
val parse_locate_library : string -> string option

(** Derive .v source path from .vo path. *)
val vo_to_v : string -> string

(** Derive .glob path from .vo path. *)
val vo_to_glob : string -> string

(** Parse a Require line.
    Returns (from_prefix, [(module_name, start_col, end_col)]) or None
    if the line is not a Require. Module names have the From prefix
    prepended if present. *)
val parse_require_line : string -> (string option * (string * int * int) list) option

(** Find which module the cursor column is on. *)
val module_at_col : (string * int * int) list -> int -> string option
