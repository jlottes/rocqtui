(** Styled text: a string with optional per-byte-range attribute spans.
    Used for the messages and goals panes; replaces the previous
    plain-string flow so producers can color/highlight inline. *)

type span = {
  start : int;       (** byte offset into [text] *)
  len : int;         (** byte length, [start + len <= String.length text] *)
  attr : Grid.attr;
}

type line = {
  text : string;
  spans : span list;
  (** Spans need not be disjoint or ordered. Render applies them in
      list order, so later spans overlay earlier ones. *)
}

(** Plain-text line with no styling. *)
val plain : string -> line

(** A line whose entire text uses [attr]. *)
val style : string -> Grid.attr -> line

(** Horizontal concatenation. Spans on each piece are shifted by the
    cumulative byte length of preceding pieces. *)
val concat : line list -> line

(** Byte length of the line text. *)
val length : line -> int

(** Display width of the line. *)
val width : line -> int

(** Strip styling, return the underlying text. *)
val to_string : line -> string

(** Wrap each input line to fit [width] display columns. Continuation
    segments are prefixed with [hanging] leading spaces (default 0).
    Spans are re-mapped to the per-segment byte offsets; the
    hanging-indent pad emits no spans. *)
val wrap : ?hanging:int -> int -> line list -> line list

(** [of_strings ss = List.map plain ss]. Convenience for callers that
    already produce plain strings. *)
val of_strings : string list -> line list
