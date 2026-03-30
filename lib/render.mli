(** Rendering layer: pane layout on top of Grid.
    Replaces Display.t and ncurses window management. *)

type rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

type pane_id =
  | PScript | PMinimap | PGoals | PMessages | PStatus | PTabBar
  | PBorderV | PBorderH | PBorderMinimap | PNone

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

(** Cursor *)
val place_cursor : t -> row:int -> col:int -> unit
val set_cursor_visible : t -> bool -> unit

(** Tab bar *)
val draw_tab_bar : t -> (string * bool) list -> int -> unit

(** Status bar *)
val set_status : t -> string -> unit

(** Message tab hit testing *)
val msg_tab_at_x : t -> x:int -> tab_names:string list -> int option

(** Overlay support *)
val set_overlay : rect -> (Grid.t -> rect -> unit) -> unit
val clear_overlay : unit -> unit

(** Diff current vs previous, write to terminal, swap buffers.
    [force]: skip diff, emit every cell (full redraw).
    Call after all rendering is done for this frame. *)
val present : ?force:bool -> t -> unit
