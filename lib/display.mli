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

(** Pane identification for mouse events. *)
type pane_id = PScript | PGoals | PMessages | PStatus | PNone
              | PBorderV | PBorderH | PTabBar

(** Determine which pane a screen coordinate falls in. *)
val pane_at : t -> x:int -> y:int -> pane_id

(** Read a mouse event. Returns (ok, x, y, bstate). *)
val get_mouse : unit -> int * int * int * int

(** Move the vertical split (script/goals border) to column [col]. *)
val move_split_v : t -> int -> unit

(** Move the horizontal split (goals/messages border) to row [row]. *)
val move_split_h : t -> int -> unit

(** Draw the tab bar. [tabs] is a list of (name, is_modified) pairs.
    [active] is the 0-based index of the active tab. *)
val draw_tab_bar : t -> (string * bool) list -> int -> unit

(** Whether the display has a tab bar (affects pane layout). *)
val set_tab_bar : t -> bool -> unit

(** Set the status bar text. *)
val set_status : t -> string -> unit

(** Move the terminal cursor to a position in the script pane. *)
val place_cursor : t -> row:int -> col:int -> unit

(** Refresh all windows. *)
val refresh_all : t -> unit
