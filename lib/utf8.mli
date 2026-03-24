(** UTF-8 utilities for mapping between byte offsets and screen columns. *)

(** Number of bytes in the UTF-8 codepoint starting at [s.[i]].
    Returns 1 for ASCII, 2-4 for multi-byte, 1 for invalid bytes. *)
val codepoint_len : string -> int -> int

(** Decode the codepoint starting at byte offset [i] in [s].
    Returns (codepoint, byte_length). *)
val decode : string -> int -> int * int

(** Display width of a single Unicode codepoint using wcwidth. *)
val codepoint_width : int -> int

(** Display width of a UTF-8 string (sum of codepoint widths). *)
val string_width : string -> int

(** Byte offset of the next codepoint after byte offset [i].
    Returns [String.length s] if at end. *)
val next : string -> int -> int

(** Byte offset of the codepoint before byte offset [i].
    Returns 0 if at start. *)
val prev : string -> int -> int

(** Convert a byte offset within a string to a screen column. *)
val byte_to_col : string -> int -> int

(** Convert a screen column to the byte offset of the codepoint at that column.
    If the column is in the middle of a wide character, returns the byte offset
    of that character. Clamps to string bounds. *)
val col_to_byte : string -> int -> int
