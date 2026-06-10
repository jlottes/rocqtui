(** UTF-8 utilities for mapping between byte offsets and screen columns. *)

(** Number of bytes in the UTF-8 codepoint starting at [s.[i]].
    Returns 1 for ASCII, 2-4 for multi-byte, 1 for invalid bytes. *)
val codepoint_len : string -> int -> int

(** Decode the codepoint starting at byte offset [i] in [s].
    Returns (codepoint, byte_length). *)
val decode : string -> int -> int * int

(** Codepoint classification — the single display-width authority,
    backed by the vendored char_width.h + cluster.h so layout agrees
    with the embedded terminal and with what glterm renders.
    Decode the result with the [class_*] accessors below. *)
val cp_class : int -> int

(** Display width from a [cp_class] result: wcwidth plus the
    Emoji_Presentation widening. Nonprintables report 1 (char_width
    semantics); use [class_nonprintable] to decide skip-vs-place. *)
val class_width : int -> int

(** True if libc wcwidth rejected the codepoint (controls,
    default-ignorables). *)
val class_nonprintable : int -> bool

(** Cluster classification (vendored cluster.h), used by the
    cluster-aware layout walker: trigger-extend codepoints (ZWJ,
    VS-15/16, keycap, skin tone, tags), regional indicators, and the
    pictographic approximation that bounds ZWJ extension. *)
val class_trigger_extend : int -> bool
val class_ri : int -> bool
val class_pictographic : int -> bool

(** Display width of a single Unicode codepoint: [class_width],
    except nonprintables count 0. *)
val codepoint_width : int -> int

(** Display width of a UTF-8 string (sum of codepoint widths). *)
val string_width : string -> int

(** Encode a Unicode codepoint as a UTF-8 string. *)
val encode : int -> string

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
