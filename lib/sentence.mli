(** Sentence boundary detection for Rocq source text. *)

(** Check if a character is whitespace (space, tab, newline, CR, FF). *)
val is_space : char -> bool

(** Find the byte offset just past the end of the next sentence
    starting at or after [start] in [text].
    Returns [None] if no complete sentence is found. *)
val find_end : string -> start:int -> int option

(** Split text into sentences. Returns a list of (start, end) byte
    offset pairs. Incomplete trailing text is not included. *)
val split : string -> (int * int) list
