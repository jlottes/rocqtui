(* Editor context: dependencies injected from main.ml.
   Replaces callback refs and global setters. *)

type drag_mode = NoDrag | DragV | DragH | DragBoth | DragMinimap | DragMinimapScroll | DragFileTree

(* Which pane currently receives keyboard input. Global rather than
   per-tab: switching buffers shouldn't change which pane is focused. *)
type focus = FScript | FGoals | FMessages | FFileTree

type jump_point = {
  jp_tab_id : int;
  jp_file : string;
  jp_line : int;
  jp_col : int;
}

type t = {
  switch_tab : int -> unit;
  open_files : unit -> (string * File_tree.file_status) list;
  set_project_dir : string -> unit;
  dep_state : unit -> Dep_graph.t option * bool;
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
  mutable project_mode : bool;
  mutable search : Search_results.t option;
  project_search : Project_search.t;
  mutable focus : focus;
  (* File-tree panel: lazily created on first F8. Survives across tabs.
     Whether the panel currently receives keys is [focus = FFileTree]. *)
  mutable file_tree : File_tree.t option;
}

let create
    ~switch_tab
    ~open_files
    ?(set_project_dir = fun _ -> ())
    ?(dep_state = fun () -> (None, false))
    () =
  { switch_tab;
    open_files;
    set_project_dir;
    dep_state;
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
    project_mode = false;
    search = None;
    project_search = Project_search.create ();
    focus = FScript;
    file_tree = None }
