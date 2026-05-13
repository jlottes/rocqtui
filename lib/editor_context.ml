(* Editor context: dependencies injected from main.ml.
   Replaces callback refs and global setters. *)

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
  set_project_dir : string -> unit;
  modal : Modal.t;
  mutable status_extra : string;
  mutable init_error : string;
  mutable theme_name : string;
  mutable clipboard : string;
  mutable compose : Compose.t option;
  mutable dragging : drag_mode;
  mutable jump_stack : jump_point list;
  mutable jump_target : (int * int) option;
  (* Transient message shown in the search panel after replace-current /
     replace-all. Cleared by any other prompt interaction. Stays in the
     panel only — does not leak into the normal status bar. *)
  mutable search_panel_msg : string;
  (* File-tree panel: lazily created on first F8. Survives across tabs.
     [file_tree_focused] tracks whether key events route to the panel
     instead of the focused script/goals/messages pane. *)
  mutable file_tree : File_tree.t option;
  mutable file_tree_focused : bool;
}

let create
    ~switch_tab
    ~open_files
    ?(set_project_dir = fun _ -> ())
    () =
  { switch_tab;
    open_files;
    set_project_dir;
    modal = Modal.create ();
    status_extra = "";
    init_error = "";
    theme_name = "solarized-dark";
    clipboard = "";
    compose = None;
    dragging = NoDrag;
    jump_stack = [];
    jump_target = None;
    search_panel_msg = "";
    file_tree = None;
    file_tree_focused = false }
