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
