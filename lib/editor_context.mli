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
  (** All currently-open tabs. Used by project-search merge to
      substitute live buffer matches for open files. *)
  tabs : unit -> Tab.t list;
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
  (** Global "what we're searching for" — the single source of truth
      for the search prompt's Find / Replace / flags / focus. None
      when no search is active. *)
  mutable search_query : Search.query_state option;
  (** Bumped on every prompt mutation that affects matches. Per-tab
      [Tab.search_matches] caches stamp this; mismatch = stale. *)
  mutable search_query_gen : int;
  (** Whether the search is project-wide. Affects (a) what the
      Search messages tab renders and (b) whether F3/Shift+F3 can
      cross file boundaries. Toggled by [Alt+P] inside the prompt. *)
  mutable project_mode : bool;
  (** Async project-wide scanner; populated when [project_mode] is on. *)
  project_search : Project_search.t;
  mutable focus : focus;
  mutable file_tree : File_tree.t option;
}

val create :
  switch_tab:(int -> unit) ->
  open_files:(unit -> (string * File_tree.file_status) list) ->
  tabs:(unit -> Tab.t list) ->
  ?set_project_dir:(string -> unit) ->
  ?dep_state:(unit -> Dep_graph.t option * bool) ->
  unit -> t

(** Tab's matches, lazily refreshed if either the global query gen or
    the tab's buffer revision has changed. Returns [None] when no
    search is active. Single accessor for the entire codebase — do
    not read [tab.search_matches] directly when a recompute might be
    needed. *)
val tab_matches : t -> Tab.t -> Search.buffer_matches option

(** Bump the global generation counter. Call after any mutation to
    [ctx.search_query]. *)
val bump_search_gen : t -> unit

(** Drop the global search state and invalidate all tabs. Called on
    ESC. *)
val clear_search : t -> unit

(** Build a [Search_results.t] for the active query. In single-file
    mode this is just the active tab's matches. In project mode it
    merges open-tab live matches into project_search.results,
    preserving the project's scan order for stable global ordering.
    Returns [None] when there's no active query. *)
val search_snapshot : t -> Tab.t -> Search_results.t option
