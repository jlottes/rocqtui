(** Sentence boundary detection for Rocq source text. *)

(** Check if a character is whitespace (space, tab, newline, CR, FF). *)
val is_space : char -> bool

(** Skip a Rocq string starting at [pos] (the byte just after the
    opening quote). Returns the byte offset just past the closing
    quote, or [String.length text] if unterminated. Handles the
    doubled-quote escape [""]. *)
val skip_string : string -> int -> int

(** Skip a Rocq comment starting at [pos] (the byte just after the
    opening ["(*"]). Handles nesting. Returns the byte offset just
    past the closing ["*)"]. *)
val skip_comment : string -> int -> int

(** Find the byte offset just past the end of the next sentence
    starting at or after [start] in [text].
    Returns [None] if no complete sentence is found. *)
val find_end : string -> start:int -> int option

(** Split text into sentences. Returns a list of (start, end) byte
    offset pairs. Incomplete trailing text is not included. *)
val split : string -> (int * int) list
