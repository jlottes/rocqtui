(** Text buffer with cursor tracking. *)

type t

(** Create an empty buffer. *)
val create : unit -> t

(** Load a file into the buffer. *)
val load_file : string -> t

(** Reload the buffer from its file on disk. Resets undo history. *)
val reload : t -> unit

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

(** Delete the selected range and return the deleted text. *)
val delete_selection : t -> string option

(** Undo/redo. *)
val undo : t -> unit
val redo : t -> unit

(** Editing. *)
val insert_char : t -> char -> unit
val insert_newline : t -> unit
val delete_char_before : t -> unit
val delete_char_at : t -> unit

(** Cut the current line (nano ^K style: cuts and appends to cut buffer). *)
val cut_line : t -> unit

(** Paste the cut buffer below the current line. *)
val paste : t -> unit

(** Ensure cursor is visible given the visible row count. *)
val ensure_visible : t -> int -> unit

(** Get the word (identifier) under the cursor. *)
val word_at_cursor : t -> string option

(** Select the word at the cursor. *)
val select_word_at_cursor : t -> unit

(** Get the full buffer text as a single string. *)
val text : t -> string
