(** Syntax highlighting using the Rocq compiler's lexer. *)

(** A span of text with a curses attribute and color pair. *)
type span = {
  start_col : int;
  length : int;
  attr : int;
  color : int;
}

(** Tokenize an entire buffer and return spans per line (0-indexed).
    Returns an array where entry [i] is the list of spans for line [i]. *)
val highlight_buffer : Buffer.t -> span list array

(** Map a syntax color pair to its verified-region variant (green background). *)
val verified_pair : int -> int
val processing_pair : int -> int
val color_default_v : int
val color_default_p : int
