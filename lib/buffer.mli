(** Text buffer with cursor tracking.

    All text-mutating operations live in the [Unsafe] sub-module and
    must only be called from [Region_buffer]. The top-level interface
    is read-only (plus filename, save, cursor, selection helpers).
    See [docs/REGION_INVARIANTS.md] for why. *)

type t

(** Create an empty buffer. *)
val create : unit -> t

(** Save buffer to its file. Returns false if no filename is set. *)
val save : t -> bool

(** Save buffer to a specific file. *)
val save_as : t -> string -> unit

(** Get/set the filename. *)
val filename : t -> string option
val set_filename : t -> string -> unit

(** Whether the buffer has been modified since last save. *)
val modified : t -> bool

(** Whether the file on disk has changed since last load/save. *)
val disk_changed : t -> bool

(** Set the disk_changed flag. *)
val set_disk_changed : t -> bool -> unit

(** Monotonic counter, bumped every time the buffer's text content is
    mutated. Observers can cache work keyed on this value and refresh
    when it changes. Stable across cursor / scroll / selection moves;
    unaffected by save (no content change). *)
val revision : t -> int

(** Line count. *)
val line_count : t -> int

(** Get a line by index (0-based). *)
val get_line : t -> int -> string

(** Cursor position (line, col), 0-based. *)
val cursor : t -> int * int

(** Scroll top (first visible line). *)
val scroll_top : t -> int
val set_scroll_top : t -> int -> unit

(** Horizontal scroll (in screen columns). *)
val hscroll : t -> int
val set_hscroll : t -> int -> unit

(** Ensure cursor is visible given visible dimensions (rows, cols). *)
val ensure_visible_h : t -> int -> int -> unit

(** Movement. *)
val move_left : t -> unit
val move_right : t -> unit
val move_up : t -> unit
val move_down : t -> unit
val move_home : t -> unit
val move_end : t -> unit
val move_page_up : t -> int -> unit
val move_page_down : t -> int -> unit

(** Move cursor to a byte offset in the buffer text. *)
val move_to_byte_offset : t -> int -> unit

(** Convert the cursor's (line, col) position to a byte offset. *)
val cursor_byte_offset : t -> int

(** Move cursor to a specific (line, byte_col) position. *)
val move_to : t -> int -> int -> unit

(** Selection. *)

(** Set the selection anchor at the current cursor position. *)
val set_anchor : t -> unit

(** Clear the selection. *)
val clear_selection : t -> unit

(** Get the selected byte range (start, end) in the buffer text, or None. *)
val selection : t -> (int * int) option

(** Get the selected text, or None. *)
val selected_text : t -> string option

(** Range of lines (inclusive) covered by the current selection, or
    just the cursor line if there is no selection. Used by line-wise
    operations and by the region-edit gateway. *)
val selection_line_range : t -> int * int

(** Ensure cursor is visible given the visible row count. *)
val ensure_visible : t -> int -> unit

(** Get the word (identifier) under the cursor. *)
val word_at_cursor : t -> string option

(** Select the word at the cursor. *)
val select_word_at_cursor : t -> unit

(** Get the full buffer text as a single string. *)
val text : t -> string

(** Read-only access to the cut buffer (used for paste). *)
val cut_buffer : t -> string list

(** Compute what [text buf] would be after a successful [undo]
    (or [redo]), without applying. Returns [None] if the stack is
    empty. Used by the region-edit gateway to validate invariants
    before committing. *)
val peek_undo_text : t -> string option
val peek_redo_text : t -> string option

(** {1 Unsafe mutators}

    These bypass the region-invariant gateway. Only [Region_buffer]
    should call them — every other path should go through the gateway
    so that verified-region/error-region/target invariants are
    enforced. The [Unsafe] prefix flags this at the call site. *)

module Unsafe : sig
  val reload : t -> unit
  val set_text : t -> string -> unit
  val undo : t -> unit
  val redo : t -> unit
  val insert_char : t -> char -> unit
  val insert_newline : t -> unit
  val insert_newline_auto_indent : t -> unit
  val delete_char_before : t -> unit
  val delete_char_at : t -> unit
  val delete_selection : t -> string option
  val cut_line : t -> unit
  val paste : t -> unit
  val indent_lines : t -> int -> unit
  val unindent_lines : t -> int -> unit
end
