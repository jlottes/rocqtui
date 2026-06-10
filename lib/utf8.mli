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

(** Cluster classification (vendored cluster.h + generated
    emoji_props.h), used by the cluster-aware layout walker:
    trigger-extend codepoints (ZWJ, VS-15/16, keycap, skin tone,
    tags), regional indicators, Extended_Pictographic (bounds ZWJ
    extension), and the promotion-gating predicates. *)
val class_trigger_extend : int -> bool
val class_ri : int -> bool
val class_pictographic : int -> bool
val class_vs16_base : int -> bool
val class_modifier_base : int -> bool
val class_emoji_presentation : int -> bool

(** A display cell: a leader (one codepoint, or a cluster's worth of
    them) plus zero or more zero-width followers, as byte ranges into
    the source string. The segmentation is an OCaml port of glterm's
    cluster_step + cluster_gate, so editor layout agrees with the
    terminal stack. *)
type display_cell = {
  cell_off : int;                     (** leader start byte *)
  leader_len : int;                   (** leader byte length *)
  cell_width : int;                   (** 1 or 2 *)
  cell_followers : (int * int) list;  (** (off, len) per zero-width
                                          follower, oldest first *)
}

(** Segment a string into display cells. Also returns the zero-width
    codepoints that arrived before any cell existed (callers attach
    them to the cell left of the write position). Nonprintable
    codepoints are skipped and kill clustering. *)
val display_cells : string -> (int * int) list * display_cell list

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

(** Convert a byte offset within a string to a screen column.
    Display-cell based: an offset inside a cell (between cluster
    codepoints, or before a follower) counts as past the cell. *)
val byte_to_col : string -> int -> int

(** Convert a screen column to the byte offset of the display cell at
    that column. Returns cell boundaries only — never an offset that
    would split a cluster or separate a follower from its leader. A
    column inside a wide cell maps to that cell's start. *)
val col_to_byte : string -> int -> int
