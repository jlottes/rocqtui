(** Whitespace-normalized text matching for MCP tools. *)

(** Collapse runs of whitespace to single space, trim ends. *)
val normalize : string -> string

(** Find all whitespace-normalized matches of [needle] in [haystack].
    Returns byte offsets in the original [haystack] at the end of each match. *)
val find_all : haystack:string -> needle:string -> int list

(** Result of [find_unique]. *)
type match_result =
  | Unique of int        (** Exactly one match; byte offset at end of match *)
  | No_match             (** No match found *)
  | Ambiguous of int list (** Multiple matches; 1-based line numbers *)

(** Convert a byte offset to a 1-based line number. *)
val line_of_offset : string -> int -> int

(** Find a unique whitespace-normalized match.
    [after_text] if provided must appear immediately after the match.
    [line] if provided filters to matches on that 1-based line number. *)
val find_unique :
  haystack:string -> needle:string ->
  ?after_text:string -> ?line:int -> unit -> match_result

(** Check if [pattern] matches the tail of [text] ending at [tail_end].
    Returns the start offset of the match in the original text, or None. *)
val tail_matches : text:string -> tail_end:int -> pattern:string -> int option
