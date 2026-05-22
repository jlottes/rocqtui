(** Rendering layer: pane layout on top of Grid.
    Replaces Display.t and ncurses window management. *)

(** Re-exported from [Grid] so the rect type is shared with the
    rect-aware drawing primitives. *)
type rect = Grid.rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

type pane_id =
  | PScript | PMinimap | PGoals | PMessages | PStatus | PTabBar
  | PFileTree
  | PBorderV | PBorderH | PBorderBoth | PBorderMinimap | PBorderFileTree
  | PNone

type t

val create : unit -> t
val resize : t -> unit

(** Pane hit testing *)
val pane_at : t -> x:int -> y:int -> pane_id

(** Drawing into panes (pane-relative coordinates) *)
val put_str : t -> pane_id -> row:int -> col:int -> string -> Grid.attr -> int
val set_cell : t -> pane_id -> row:int -> col:int -> string -> Grid.attr -> unit
val fill : t -> pane_id -> row:int -> col:int -> width:int -> char -> Grid.attr -> unit
val chgat : t -> pane_id -> row:int -> col:int -> width:int -> Grid.attr -> unit
val set_underline :
  t -> pane_id -> row:int -> col:int -> width:int ->
  style:Grid.underline_style -> color:Grid.color -> unit
val clear_pane : t -> pane_id -> unit

(** Get pane dimensions (height, width) *)
val pane_dims : t -> pane_id -> int * int

(** Get pane rectangle *)
val pane_rect : t -> pane_id -> rect

(** Access the raw grid (for direct manipulation) *)
val curr : t -> Grid.t

(** Draw borders and pane labels *)
val draw_chrome : t ->
  ?goals_focused:bool -> ?messages_focused:bool ->
  ?msg_tab_names:string list -> ?msg_tab_active:int ->
  unit -> unit

(** Layout *)
val set_tab_bar : t -> bool -> unit
val minimap_width : t -> int
val set_minimap_width : t -> int -> unit
val move_split_v : t -> int -> unit
val move_split_h : t -> int -> unit
val move_minimap_border : t -> int -> unit

(** File-tree panel layout. When visible, allocates a left-side pane
    [file_tree_width] columns wide plus a separator column; the script
    (and minimap, if any) shift right by that amount. *)
val file_tree_visible : t -> bool
val file_tree_width : t -> int
val set_file_tree_visible : t -> bool -> unit
val move_file_tree_border : t -> int -> unit

(** Cursor *)
val place_cursor : t -> row:int -> col:int -> unit
val set_cursor_visible : t -> bool -> unit

(** Place the hardware cursor on a status row, addressed by
    [row_from_bottom] (same convention as [set_status_line]). *)
val place_cursor_status : t -> row_from_bottom:int -> col:int -> unit

(** Tab bar *)
val draw_tab_bar : t -> (string * bool) list -> int -> unit

(** Status bar *)
val set_status : t -> string -> unit

(** Multi-row status panel.

    [set_panel_rows] sets the number of *extra* rows above the bottom status
    row that callers will paint into (via [set_status_line]). Default is 0
    (only the bottom row is the status bar). Does not change pane layouts —
    the painted rows simply cover the bottom of whatever pane sits beneath
    them. Reset to 0 when the panel closes so [pane_at] hit-testing returns
    the correct pane again. *)
val set_panel_rows : t -> int -> unit
val panel_rows : t -> int

(** Paint into a status row. [row_from_bottom = 0] is the bottom row (same
    cells as [set_status]). Higher values paint rows above it, up through
    [panel_rows]. The cells use the status attribute. *)
val set_status_line : t -> row_from_bottom:int -> string -> unit

(** Paint a status row from a list of styled segments. The row is first
    filled with the default status attribute, then segments are placed
    left-to-right starting at column 1, each with its own [Grid.attr].
    Useful for prompts that mix normal and dimmed text. *)
val set_status_line_styled :
  t -> row_from_bottom:int -> (string * Grid.attr) list -> unit

(** Message tab hit testing *)
val msg_tab_at_x : t -> x:int -> tab_names:string list -> int option

(** Overlay support *)
val set_overlay : t -> rect -> (Grid.t -> rect -> unit) -> unit
val clear_overlay : t -> unit

(** Diff current vs previous, write to terminal, swap buffers.
    [force]: skip diff, emit every cell (full redraw).
    Call after all rendering is done for this frame. *)
val present : ?force:bool -> t -> unit
