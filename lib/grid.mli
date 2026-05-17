(** Cell grid for terminal rendering.

    Each cell holds UTF-8 text (possibly with combining characters),
    a display width, and visual attributes. Supports wide characters
    (CJK), combining characters, 256-color, and true color. *)

type color =
  | Default
  | Basic of int                 (** 0..15 — full 16-color palette *)
  | Color256 of int              (** 0..255 *)
  | TrueColor of int * int * int

(** Underline style — extended via SGR 4:n sub-parameter (colon syntax). *)
type underline_style =
  | UL_none
  | UL_single
  | UL_double
  | UL_curly
  | UL_dotted
  | UL_dashed

type italic_style = Italic_none | Italic_on | Italic_fraktur
type blink_style  = Blink_none  | Blink_slow | Blink_rapid
type frame_style  = Frame_none  | Frame_box  | Frame_circle
type script_style = Script_none | Script_super | Script_sub

(** Full SGR rendition state. Most consumers should build values with
    [{ default_attr with ... }] rather than naming every field. *)
type attr = {
  fg : color;
  bg : color;
  ul : color;                    (** underline color *)
  bold : bool;
  dim : bool;                    (** SGR 2 faint *)
  italic : italic_style;
  underline : underline_style;
  reverse : bool;
  strikethrough : bool;
  conceal : bool;
  overline : bool;
  blink : blink_style;
  frame : frame_style;
  script : script_style;
  font : int;                    (** 0 = primary, 1..9 = alt fonts *)
  spacing : bool;                (** SGR 26 proportional *)
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

(** A rectangular sub-region of the grid in absolute coordinates. *)
type rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

(** Create a grid with given dimensions, filled with spaces. *)
val create : int -> int -> t

(** Resize the grid, preserving existing content where possible. *)
val resize : t -> int -> int -> unit

(** Clear the entire grid to spaces. Uses default attributes unless overridden. *)
val clear : ?attr:attr -> t -> unit

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

(** Change attributes of a row region without touching the text. *)
val chgat : t -> row:int -> col:int -> width:int -> attr -> unit

(** Rect-aware drawing. Coordinates are relative to [rect]'s top-left;
    writes are clipped to [rect] so neighbouring panes are never
    touched. Each variant mirrors the corresponding unclipped function.
    [put_str_in_rect] returns the number of columns advanced. *)

val put_str_in_rect :
  t -> rect -> row:int -> col:int -> string -> attr -> int

val set_cell_in_rect :
  t -> rect -> row:int -> col:int -> string -> attr -> unit

val fill_in_rect :
  t -> rect -> row:int -> col:int -> width:int -> char -> attr -> unit

val chgat_in_rect :
  t -> rect -> row:int -> col:int -> width:int -> attr -> unit

val clear_rect : t -> rect -> attr:attr -> unit

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

(** Generate ANSI escape sequences for all cells (full redraw). *)
val emit_all : t -> Stdlib.Buffer.t -> unit
