(** Parser for Rocq .glob files (definition locations). *)

type entry = {
  kind : string;
  name : string;
  bp : int;
  ep : int;
}

(** Parse a .glob file. Returns definition entries. *)
val parse : string -> entry list

(** Find a definition by name. *)
val find_definition : entry list -> string -> entry option

(** Convert a byte offset to a 0-based line number in a source file. *)
val byte_offset_to_line : string -> int -> int option
