(** Terminal setup, teardown, and low-level I/O.
    Replaces ncurses' initscr/endwin. *)

(** Initialize: raw mode, alternate screen, mouse tracking, bracketed paste. *)
val init : unit -> unit

(** Restore terminal to original state. *)
val teardown : unit -> unit

(** Get terminal size (rows, cols). *)
val size : unit -> int * int

(** Write raw bytes to stdout. *)
val write_stdout : string -> unit

(** Move cursor to 0-based (row, col). *)
val move_cursor : int -> int -> unit

(** Show the terminal cursor. *)
val show_cursor : unit -> unit

(** Hide the terminal cursor. *)
val hide_cursor : unit -> unit

(** Clear the entire screen. *)
val clear_screen : unit -> unit

(** Check if a SIGWINCH (terminal resize) has occurred since last check.
    Returns true and clears the flag. *)
val check_resize : unit -> bool

(** Bind a font slot to a fontconfig pattern via OSC 1547. The terminal
    resolves the pattern; cells whose [attr.font] equals [slot] render with
    that font. Slot must be in 1..255; 0 is the no-override sentinel and
    cannot be bound. [pattern] must not contain [;], ESC, or BEL. *)
val bind_font_slot : int -> string -> unit

(** Unbind a previously-bound slot. Cells using it fall through to the
    terminal's default codepoint dispatch. *)
val unbind_font_slot : int -> unit
