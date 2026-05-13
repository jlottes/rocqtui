(** Editor context: dependencies injected from main.ml. *)

type drag_mode = NoDrag | DragV | DragH | DragBoth | DragMinimap | DragMinimapScroll | DragFileTree

type jump_point = {
  jp_tab_id : int;
  jp_file : string;
  jp_line : int;
  jp_col : int;
}

type t = {
  switch_tab : int -> unit;
  open_files : unit -> string list;
  modal : Modal.t;
  mutable status_extra : string;
  mutable init_error : string;
  mutable theme_name : string;
  mutable clipboard : string;
  mutable compose : Compose.t option;
  mutable dragging : drag_mode;
  mutable jump_stack : jump_point list;
  mutable jump_target : (int * int) option;
  mutable search_panel_msg : string;
  mutable file_tree : File_tree.t option;
  mutable file_tree_focused : bool;
}

val create :
  switch_tab:(int -> unit) ->
  open_files:(unit -> string list) ->
  unit -> t
