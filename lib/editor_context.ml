(* Editor context: dependencies injected from main.ml.
   Replaces callback refs and global setters. *)

type drag_mode = NoDrag | DragV | DragH | DragBoth | DragMinimap | DragMinimapScroll

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
}

let create
    ~switch_tab
    ~open_files
    () =
  { switch_tab;
    open_files;
    modal = Modal.create ();
    status_extra = "";
    init_error = "";
    theme_name = "solarized-dark";
    clipboard = "";
    compose = None;
    dragging = NoDrag;
    jump_stack = [];
    jump_target = None }
