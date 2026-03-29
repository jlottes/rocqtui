(** Cell grid for terminal rendering.

    Each cell holds UTF-8 text (possibly with combining characters),
    a display width, and visual attributes. Supports wide characters
    (CJK), combining characters, 256-color, and true color. *)

type color =
  | Default
  | Basic of int
  | Color256 of int
  | TrueColor of int * int * int

type attr = {
  fg : color;
  bg : color;
  bold : bool;
  dim : bool;
  reverse : bool;
  underline : bool;
}

val default_attr : attr

type cell = {
  mutable text : string;
  mutable width : int;
  mutable attr : attr;
}

type t = {
  mutable cells : cell array array;
  mutable rows : int;
  mutable cols : int;
}

(** Create a grid with given dimensions, filled with spaces. *)
val create : int -> int -> t

(** Resize the grid, preserving existing content where possible. *)
val resize : t -> int -> int -> unit

(** Clear the entire grid to spaces with default attributes. *)
val clear : t -> unit

(** Clear a rectangular region. *)
val clear_region : t -> row:int -> col:int -> height:int -> width:int -> attr:attr -> unit

(** Set a single cell. Handles wide characters (marks continuation cell)
    and clears any wide char this cell was part of. *)
val set_cell : t -> row:int -> col:int -> string -> attr -> unit

(** Append a combining character to the cell at (row, col). *)
val append_combining : t -> row:int -> col:int -> string -> unit

(** Write a UTF-8 string. Returns number of columns consumed.
    Handles wide characters, combining characters, zero-width. *)
val put_str : t -> row:int -> col:int -> string -> attr -> int

(** Fill a region of a row with a character. *)
val fill : t -> row:int -> col:int -> width:int -> char -> attr -> unit

(** Compare two cells for equality. *)
val cell_eq : cell -> cell -> bool

(** Copy contents of src grid into dst grid. *)
val copy : src:t -> dst:t -> unit

(** Decode one UTF-8 codepoint. Returns (codepoint, bytes_consumed). *)
val decode_utf8 : string -> int -> int * int

(** Display width of a Unicode codepoint (via wcwidth). *)
val wcwidth : int -> int

(** Generate ANSI escape sequences for changed cells (diff rendering). *)
val diff : prev:t -> curr:t -> Stdlib.Buffer.t -> unit
