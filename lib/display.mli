(** Terminal display management using curses. *)

(** The display state, holding all window references. *)
type t

(** Color pairs for script coloring. *)
val color_verified : int
val color_processing : int
val color_error : int
val color_status : int
val color_border : int

(** Initialize curses and create the pane layout. *)
val init : unit -> t

(** Tear down curses and restore terminal. *)
val teardown : t -> unit

(** Recompute layout after terminal resize. *)
val resize : t -> unit

(** Get the script pane window. *)
val script_win : t -> Curses.window

(** Get the goals pane window. *)
val goals_win : t -> Curses.window

(** Get the messages pane window. *)
val messages_win : t -> Curses.window

(** Get the status bar window. *)
val status_win : t -> Curses.window

(** Get the usable dimensions (rows, cols) of the script pane. *)
val script_dims : t -> int * int

(** Draw borders and pane labels. [goals_focused] and [messages_focused]
    control focus indicators. *)
val draw_chrome : ?goals_focused:bool -> ?messages_focused:bool -> t -> unit

(** Set the status bar text. *)
val set_status : t -> string -> unit

(** Move the terminal cursor to a position in the script pane. *)
val place_cursor : t -> row:int -> col:int -> unit

(** Refresh all windows. *)
val refresh_all : t -> unit
