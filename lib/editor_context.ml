(* Editor context: dependencies injected from main.ml.
   Replaces callback refs and global setters. *)

type drag_mode = NoDrag | DragV | DragH | DragBoth | DragMinimap | DragMinimapScroll | DragFileTree

(* Which pane currently receives keyboard input. Global rather than
   per-tab: switching buffers shouldn't change which pane is focused. *)
type focus = FScript | FGoals | FMessages | FFileTree

(* Tracks ESC-rollback state for an in-flight search prompt. *)
type search_session = {
  origin_tab_id : int;
  mutable saved_cursors : (int * Search.pos) list;
}

type jump_point = {
  jp_tab_id : int;
  jp_file : string;
  jp_line : int;
  jp_col : int;
}

type t = {
  switch_tab : int -> unit;
  switch_to_tab_id : int -> unit;
  open_files : unit -> (string * File_tree.file_status) list;
  set_project_dir : string -> unit;
  dep_state : unit -> Dep_graph.t option * bool;
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
  (* Transient message shown in the search panel after replace-current /
     replace-all. Cleared by any other prompt interaction. Stays in the
     panel only — does not leak into the normal status bar. *)
  mutable search_panel_msg : string;
  mutable search_query : Search.query_state option;
  mutable search_query_gen : int;
  mutable search_session : search_session option;
  mutable project_mode : bool;
  project_search : Project_search.t;
  mutable focus : focus;
  (* File-tree panel: lazily created on first F8. Survives across tabs.
     Whether the panel currently receives keys is [focus = FFileTree]. *)
  mutable file_tree : File_tree.t option;
  (* AI suggestion subsystem. None when not configured / disabled at
     boot. Otherwise the State carries global on/off, in-flight
     request id, and per-tab ghost state. *)
  mutable ai : Ai.State.t option;
  (* Timestamp of the last user input event. Used by the AI idle
     trigger to debounce request firing. 0.0 = no input yet. *)
  mutable last_input_time : float;
}

let create
    ~switch_tab
    ~switch_to_tab_id
    ~open_files
    ~tabs
    ?(set_project_dir = fun _ -> ())
    ?(dep_state = fun () -> (None, false))
    () =
  { switch_tab;
    switch_to_tab_id;
    open_files;
    set_project_dir;
    dep_state;
    tabs;
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
    search_query = None;
    search_query_gen = 0;
    search_session = None;
    project_mode = false;
    project_search = Project_search.create ();
    focus = FScript;
    file_tree = None;
    ai = None;
    last_input_time = 0. }

(* Lazy accessor: refresh [tab.search_matches] if either the global
   generation or the tab's buffer revision has changed. Returns None
   when no search is active. *)
let tab_matches t (tab : Tab.t) =
  match t.search_query with
  | None -> None
  | Some q ->
    let cur_rev = Buffer.revision tab.buf in
    let gen_ok = tab.search_matches_gen = Some t.search_query_gen in
    let rev_ok = tab.search_matches_buf_revision = cur_rev in
    if gen_ok && rev_ok then tab.search_matches
    else begin
      let saved_cursor = match tab.search_matches with
        | Some old -> old.saved_cursor
        | None ->
          let (l, c) = Buffer.cursor tab.buf in
          { Search.line = l; col = c }
      in
      let anchor = match tab.search_matches with
        | Some old -> Search.anchor_of old
        | None -> saved_cursor
      in
      let bm = Search.recompute_buffer_matches q tab.buf
        ~anchor ~saved_cursor in
      tab.search_matches <- Some bm;
      tab.search_matches_gen <- Some t.search_query_gen;
      tab.search_matches_buf_revision <- cur_rev;
      Some bm
    end

let bump_search_gen t =
  t.search_query_gen <- t.search_query_gen + 1

let clear_search t =
  t.search_query <- None;
  t.search_query_gen <- t.search_query_gen + 1;
  t.search_session <- None;
  t.project_mode <- false;
  Project_search.cancel t.project_search

let pos_of_buffer_cursor (buf : Buffer.t) : Search.pos =
  let (l, c) = Buffer.cursor buf in
  { Search.line = l; col = c }

let begin_search_session t (active : Tab.t) =
  t.search_session <- Some {
    origin_tab_id = active.id;
    saved_cursors = [(active.id, pos_of_buffer_cursor active.buf)];
  }

let touch_tab_for_session t (tab : Tab.t) =
  match t.search_session with
  | None -> ()
  | Some s ->
    if not (List.mem_assoc tab.id s.saved_cursors) then
      s.saved_cursors <-
        (tab.id, pos_of_buffer_cursor tab.buf) :: s.saved_cursors

let rollback_search_session t =
  match t.search_session with
  | None -> false
  | Some s ->
    let tabs = t.tabs () in
    let find_tab id =
      List.find_opt (fun (tab : Tab.t) -> tab.id = id) tabs
    in
    List.iter (fun (tab_id, (pos : Search.pos)) ->
      match find_tab tab_id with
      | Some tab -> Buffer.move_to tab.buf pos.line pos.col
      | None -> ()
    ) s.saved_cursors;
    (* Switch back to origin (if still open). *)
    t.switch_to_tab_id s.origin_tab_id;
    t.search_session <- None;
    true

let drop_search_session t =
  t.search_session <- None

(* Compute the project-relative path of [abs] under [project_dir],
   or "" when outside the project root. *)
let rel_under project_dir abs =
  let prefix = project_dir ^ "/" in
  let plen = String.length prefix in
  if String.length abs > plen
     && String.sub abs 0 plen = prefix then
    String.sub abs plen (String.length abs - plen)
  else ""

(* Build a Search_results.t for the active query that the Search
   messages tab renders and the cross-file F3 dispatcher walks. In
   project mode this is the merged stream (open tabs' live matches
   substituted into the project_search.results scan order). In
   single-file mode it's just the active tab. None when no search is
   active. *)
let search_snapshot t (active_tab : Tab.t) : Search_results.t option =
  match t.search_query with
  | None -> None
  | Some q when q.query = "" -> None
  | Some q ->
    let active_path = Buffer.filename active_tab.buf in
    let project_dir =
      match active_path with
      | Some p ->
        (match Project.find_project_file (Filename.dirname p) with
         | Some (pd, _) -> pd
         | None -> Filename.dirname p)
      | None -> ""
    in
    if not t.project_mode then begin
      (* Single-file: just the active tab. *)
      match active_path, tab_matches t active_tab with
      | Some path, Some bm ->
        let rel_path = rel_under project_dir path in
        Some (Search_results.of_buffer_matches
                ~path ~rel_path q bm active_tab.buf)
      | _ -> None
    end
    else begin
      (* Project mode: merge open tabs' live matches into
         project_search.results, preserving the project's scan order
         for stability. *)
      let psr_opt = Project_search.results t.project_search in
      let project_files = match psr_opt with
        | Some r -> Search_results.files r
        | None -> []
      in
      let tabs = t.tabs () in
      let tab_by_path =
        List.filter_map (fun (tab : Tab.t) ->
          match Buffer.filename tab.buf with
          | Some f -> Some (f, tab)
          | None -> None
        ) tabs
      in
      let merged =
        Search_results.empty ~query:q.query ~flags:q.flags in
      let project_paths = ref [] in
      let live_for_open_tab path tab =
        (* Try the open tab's buffer_matches first. *)
        match tab_matches t tab with
        | Some bm ->
          let rel_path = rel_under project_dir path in
          let single = Search_results.of_buffer_matches
            ~path ~rel_path q bm tab.buf in
          (match Search_results.files single with
           | [fm] -> Some fm
           | _ -> None)
        | None -> None
      in
      List.iter (fun (fm : Search_results.file_matches) ->
        project_paths := fm.fm_path :: !project_paths;
        let live_fm =
          match List.assoc_opt fm.fm_path tab_by_path with
          | Some tab -> live_for_open_tab fm.fm_path tab
          | None -> Some fm
        in
        (match live_fm with
         | Some fm' -> Search_results.add_file merged fm'
         | None -> ())
      ) project_files;
      let project_path_set = !project_paths in
      List.iter (fun (tab : Tab.t) ->
        match Buffer.filename tab.buf with
        | None -> ()
        | Some path when List.mem path project_path_set -> ()
        | Some path ->
          (match live_for_open_tab path tab with
           | Some fm -> Search_results.add_file merged fm
           | None -> ())
      ) tabs;
      Search_results.set_scanning merged
        (match psr_opt with
         | Some r -> Search_results.scanning r
         | None -> false);
      (* Set [current] from the active tab if it has any matches. *)
      (match active_path, tab_matches t active_tab with
       | Some path, Some bm when bm.current >= 0 ->
         Search_results.set_current merged (Some (path, bm.current))
       | _ -> ());
      Some merged
    end
