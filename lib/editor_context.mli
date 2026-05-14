(** Editor context: dependencies injected from main.ml. *)

type drag_mode = NoDrag | DragV | DragH | DragBoth | DragMinimap | DragMinimapScroll | DragFileTree

(** Which pane currently receives keyboard input. Global rather than
    per-tab — switching buffers should not change focus. *)
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
  (** Snapshot of the dep runner state. Cheap to call every frame. *)
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
  mutable search_panel_msg : string;
  (** Whether the search prompt is scanning the whole project rather
      than just the active buffer. Toggled by [Alt+P] inside the
      prompt. *)
  mutable project_mode : bool;
  (** Latest Search_results snapshot — single-file when
      [project_mode = false], project-wide when true. Read by the
      Search messages tab and by F3 / Shift+F3 stepping. *)
  mutable search : Search_results.t option;
  (** Async project-wide scanner; results land here when
      [project_mode] is on. *)
  project_search : Project_search.t;
  mutable focus : focus;
  mutable file_tree : File_tree.t option;
}

val create :
  switch_tab:(int -> unit) ->
  open_files:(unit -> (string * File_tree.file_status) list) ->
  ?set_project_dir:(string -> unit) ->
  ?dep_state:(unit -> Dep_graph.t option * bool) ->
  unit -> t
