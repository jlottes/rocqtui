(** OCaml interface to the vterm terminal emulator library. *)

type t
(** Opaque handle to a vterm instance. *)

(** Color type — matches Grid.color layout so values can be cast. *)
type color =
  | Default
  | Basic of int
  | Color256 of int
  | TrueColor of int * int * int

(** Attribute type — matches Grid.attr layout. *)
type attr = {
  fg : color;
  bg : color;
  bold : bool;
  dim : bool;
  reverse : bool;
  underline : bool;
}

type sync_result = {
  feedback : bytes option;
  title : string option;
  mouse_changed : bool;
  clipboard : string option;
}

type cursor_info = {
  x : int;
  y : int;
  w : int;
}

type row_cell = {
  text : string;
  width : int;
  attr : attr;
  selected : bool;
  cursor : bool;
}

(** {2 Lifecycle} *)

val create : backlog:int -> fwdlog:int -> w:int -> h:int
  -> wrap_mode:int -> t
val destroy : t -> unit

(** {2 Data flow} *)

val proc : t -> bytes -> off:int -> len:int -> unit
(** Feed raw bytes from PTY to the terminal state machine. *)

val sync : t -> sync_result
(** Drain pending flags after a [proc] batch. Must be called after
    feeding data. Returns feedback to write back to PTY, title
    changes, clipboard data, etc. *)

(** {2 Resize} *)

val resize : t -> w:int -> h:int -> unit

(** {2 Display} *)

val prepare_rows : t -> int
(** Force recomputation of layout. Returns number of display rows. *)

val get_row : t -> int -> row_cell array
(** Get display row [y] as an array of cells. Call [prepare_rows]
    first. Each call overwrites the internal buffer, so consume
    data before calling again. *)

val get_row_sentinel : t -> int -> (attr * int * bool) option
(** Get the sentinel (trailing blank info) for row [y].
    Returns [Some (bg_attr, end_col, selected)] or [None]. *)

(** {2 Scroll} *)

val scroll : t -> int -> bool
(** Scroll by n sublines (negative=up). Returns true if scrolled. *)

val scroll_to_end : t -> bool -> bool
(** Jump to top (true) or bottom (false). Returns true if changed. *)

(** {2 Selection} *)

val hit_test : t -> row:int -> col:int -> int * int
(** Map display coordinates to buffer position (line, col). *)

val sel_start : t -> line:int -> col:int -> unit
val sel_extend : t -> line:int -> col:int -> unit
val sel_word : t -> line:int -> col:int -> unit
val sel_text : t -> string option
val has_selection : t -> bool

(** {2 State queries} *)

val mouse_mode : t -> int
val mouse_flags : t -> int
val kitty_flags : t -> int
val term_mode : t -> int
val alt_screen : t -> bool
val bracketed_paste : t -> bool
val cursor_info : t -> cursor_info option
val is_scrolled : t -> bool
val scroll_info : t -> string option
val width : t -> int
val height : t -> int
val set_wrap_mode : t -> int -> bool

(** {2 Key encoding} *)

val keyseq : keysym:int -> modifiers:int -> mode:int
  -> event_type:int -> string option
(** Encode a key event as an xterm-style escape sequence. *)

val kitty_keyseq : keysym:int -> base_keysym:int -> modifiers:int
  -> mode:int -> kitty_flags:int -> event_type:int
  -> text:string -> string option
(** Encode a key event using the Kitty keyboard protocol. *)

(** {2 Mouse encoding} *)

val mouseseq : button:int -> modifiers:int -> cx:int -> cy:int
  -> ev:int -> mode:int -> flags:int -> string
(** Encode a mouse event as an escape sequence. *)

(** {2 Constants} *)

val mouse_mode_off : int
val mouse_mode_x10 : int
val mouse_mode_norm : int
val mouse_mode_btn : int
val mouse_mode_any : int

val mouse_sgr : int
val mouse_focus : int
val mouse_alt_scroll : int

val mouse_ev_press : int
val mouse_ev_release : int
val mouse_ev_motion : int

val mode_app_keypad : int
val mode_app_cursor : int
val mode_meta : int

val mod_shift : int
val mod_alt : int
val mod_ctrl : int
