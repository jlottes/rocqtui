(** Syntax highlighting using the Rocq compiler's lexer. *)

(** A span of text with a curses attribute and color pair. *)
type span = {
  start_col : int;
  length : int;
  attr : int;
  color : int;
  grid_attr : Grid.attr;
}

(** Tokenize an entire buffer and return spans per line (0-indexed).
    Returns an array where entry [i] is the list of spans for line [i]. *)
val highlight_buffer : Buffer.t -> span list array

(** Find the qualified identifier at the cursor's byte position, using the
    Coq lexer to identify IDENT/FIELD tokens. Adjacent IDENT/FIELD tokens
    (e.g. [Foo.Bar.baz]) are assembled into a single qualified name.
    Returns [None] if the cursor is not on an identifier token, or if the
    lexer fails before reaching the cursor — callers should fall back to
    [Buffer.word_at_cursor] in that case. *)
val qualid_at_cursor : Buffer.t -> string option

(** Map a syntax color pair to its verified-region variant (green background). *)
val verified_pair : int -> int
val processing_pair : int -> int
val color_default_v : int
val color_default_p : int
