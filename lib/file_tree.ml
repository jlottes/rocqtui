(* File-tree panel widget. Persistent left-side navigator. Supports
   two views over the same project — [VTree] is the filesystem tree
   with expandable directories; [VDepOrder] is a flat list of .v
   files in dependency order, with the selected file's closure
   highlighted and the rest dim. *)

type file_status = {
  modified : bool;
  disk_changed : bool;
}

type line = {
  depth : int;
  entry : File_listing.entry;
  expanded : bool;      (* meaningful for dirs *)
  has_children : bool;  (* dir with at least one visible child *)
}

type view = VTree | VDepOrder

(* Per-view selection / scroll / lines — switching views preserves
   each one's position. *)
type view_state = {
  mutable lines : line array;
  mutable selected : int;
  mutable scroll : int;
}

let fresh_view_state () = { lines = [||]; selected = 0; scroll = 0 }

type t = {
  project_dir : string;
  project_file : string;
  (* Tree view state *)
  mutable mode : File_listing.mode;
  mutable tree : File_listing.node list;
  expanded : (string, unit) Hashtbl.t;  (* dir rel_paths with "/" *)
  tree_state : view_state;
  (* Dep view state *)
  mutable dep_graph : Dep_graph.t option;
  mutable dep_running : bool;
  dep_state : view_state;
  mutable closure : (string, unit) Hashtbl.t;  (* in-closure rel_paths *)
  mutable closure_for : int option;            (* dep_state.selected when [closure] was computed *)
  (* Shared *)
  mutable view : view;
  mutable filter : string option;       (* Some "" = active but empty *)
}

let current_state t = match t.view with
  | VTree -> t.tree_state
  | VDepOrder -> t.dep_state

(* --- Filter matching --- *)

let substring_contains hay needle =
  let nl = String.length needle in
  let hl = String.length hay in
  if nl = 0 then true
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else loop (i + 1)
    in
    loop 0

let rec node_matches needle node =
  let entry, children = match node with
    | File_listing.File e -> e, None
    | File_listing.Dir (e, c) -> e, Some c
  in
  if substring_contains entry.rel_path needle then true
  else
    match children with
    | None -> false
    | Some c -> List.exists (node_matches needle) c

(* --- Tree rebuild --- *)

let rebuild_tree t =
  t.tree <- File_listing.enumerate
    ~project_dir:t.project_dir
    ~project_file:t.project_file
    ~mode:t.mode

let rebuild_tree_lines t =
  let needle, filter_active =
    match t.filter with
    | Some s when s <> "" -> s, true
    | _ -> "", false
  in
  let visible node =
    not filter_active || node_matches needle node
  in
  let lines = ref [] in
  let rec walk ~depth nodes =
    List.iter (fun node ->
      if visible node then begin
        let entry = match node with
          | File_listing.File e -> e
          | File_listing.Dir (e, _) -> e
        in
        let is_expanded =
          filter_active || Hashtbl.mem t.expanded entry.rel_path
        in
        let has_children = match node with
          | File_listing.Dir (_, c) -> List.exists visible c
          | _ -> false
        in
        lines := { depth; entry;
                   expanded = is_expanded; has_children } :: !lines;
        match node with
        | File_listing.Dir (_, children) when is_expanded ->
          walk ~depth:(depth + 1) children
        | _ -> ()
      end
    ) nodes
  in
  walk ~depth:0 t.tree;
  let lines = Array.of_list (List.rev !lines) in
  t.tree_state.lines <- lines;
  let n = Array.length lines in
  if t.tree_state.selected >= n then
    t.tree_state.selected <- max 0 (n - 1);
  if t.tree_state.selected < 0 then t.tree_state.selected <- 0;
  if t.tree_state.scroll > t.tree_state.selected then
    t.tree_state.scroll <- t.tree_state.selected

(* --- Dep view rebuild --- *)

let rebuild_dep_lines t =
  let needle, filter_active =
    match t.filter with
    | Some s when s <> "" -> s, true
    | _ -> "", false
  in
  let visible rel_path =
    not filter_active || substring_contains rel_path needle
  in
  let lines = match t.dep_graph with
    | None -> []
    | Some g ->
      let topo = Dep_graph.toposort g in
      List.filter_map (fun rel_path ->
        if not (visible rel_path) then None
        else
          let entry = {
            File_listing.full_path =
              Filename.concat t.project_dir rel_path;
            rel_path;
            (* Show the project-relative path in the dep view so files
               with the same basename in different subdirs are
               distinguishable. Tree view still uses basenames. *)
            name = rel_path;
            is_dir = false;
            in_project = true;
          } in
          Some { depth = 0; entry;
                 expanded = false; has_children = false }
      ) topo
  in
  let arr = Array.of_list lines in
  t.dep_state.lines <- arr;
  let n = Array.length arr in
  if t.dep_state.selected >= n then
    t.dep_state.selected <- max 0 (n - 1);
  if t.dep_state.selected < 0 then t.dep_state.selected <- 0;
  if t.dep_state.scroll > t.dep_state.selected then
    t.dep_state.scroll <- t.dep_state.selected;
  t.closure_for <- None  (* force closure recompute on next render *)

let rebuild_lines t =
  match t.view with
  | VTree -> rebuild_tree_lines t
  | VDepOrder -> rebuild_dep_lines t

(* --- Closure --- *)

let recompute_closure t =
  Hashtbl.clear t.closure;
  let st = t.dep_state in
  let n = Array.length st.lines in
  match t.dep_graph with
  | None -> ()
  | Some g when n > 0 && st.selected >= 0 && st.selected < n ->
    let rel = st.lines.(st.selected).entry.rel_path in
    List.iter (fun p -> Hashtbl.replace t.closure p ())
      (Dep_graph.closure_bidirectional g rel)
  | Some _ -> ()

let ensure_closure t =
  if t.view = VDepOrder
     && t.closure_for <> Some t.dep_state.selected then begin
    recompute_closure t;
    t.closure_for <- Some t.dep_state.selected
  end

let create ~project_dir ~project_file =
  let t = {
    project_dir; project_file;
    mode = File_listing.Project;
    tree = [];
    expanded = Hashtbl.create 32;
    tree_state = fresh_view_state ();
    dep_graph = None;
    dep_running = false;
    dep_state = fresh_view_state ();
    closure = Hashtbl.create 32;
    closure_for = None;
    view = VTree;
    filter = None;
  } in
  rebuild_tree t;
  rebuild_tree_lines t;
  t

let project_file t = t.project_file

let refresh t =
  rebuild_tree t;
  rebuild_lines t

let in_filter t = t.filter <> None

let view t = t.view

(* Snap the selection to the entry for [path]. Expands all ancestor
   directories, clears any active filter, and rebuilds the visible
   lines. Works in both views. Silently no-ops when [path] is not
   under the project root or no matching entry is in the tree. *)
let reveal t ~path =
  if t.project_dir = "" then ()
  else
    let prefix = t.project_dir ^ "/" in
    let plen = String.length prefix in
    if String.length path <= plen
       || String.sub path 0 plen <> prefix then ()
    else
      let rel = String.sub path plen (String.length path - plen) in
      let parts = String.split_on_char '/' rel in
      let rec mark_ancestors prefix = function
        | [] | [_] -> ()
        | dir :: rest ->
          let dir_rel = prefix ^ dir ^ "/" in
          Hashtbl.replace t.expanded dir_rel ();
          mark_ancestors dir_rel rest
      in
      mark_ancestors "" parts;
      t.filter <- None;
      rebuild_lines t;
      let st = current_state t in
      let n = Array.length st.lines in
      let i = ref 0 in
      let found = ref false in
      while not !found && !i < n do
        if st.lines.(!i).entry.rel_path = rel then begin
          st.selected <- !i;
          found := true
        end else incr i
      done;
      t.closure_for <- None

(* --- Selection movement (view-aware) --- *)

let move_selection t delta =
  let st = current_state t in
  let n = Array.length st.lines in
  if n > 0 then
    st.selected <- max 0 (min (n - 1) (st.selected + delta))

let ensure_visible t visible_rows =
  let st = current_state t in
  if st.selected < st.scroll then
    st.scroll <- st.selected
  else if st.selected >= st.scroll + visible_rows then
    st.scroll <- st.selected - visible_rows + 1

let selected_line t =
  let st = current_state t in
  let n = Array.length st.lines in
  if n = 0 || st.selected < 0 || st.selected >= n then None
  else Some st.lines.(st.selected)

(* Move selection to the index of the parent directory of the currently
   selected node (tree view only). Returns true if it moved. *)
let move_to_parent t =
  let st = current_state t in
  match selected_line t with
  | None -> false
  | Some cur ->
    if cur.depth = 0 then false
    else begin
      let target_depth = cur.depth - 1 in
      let i = ref (st.selected - 1) in
      let found = ref false in
      while not !found && !i >= 0 do
        if st.lines.(!i).depth = target_depth then found := true
        else decr i
      done;
      if !found then (st.selected <- !i; true) else false
    end

(* --- Expand / collapse (tree view only) --- *)

let toggle_dir t rel_path =
  if Hashtbl.mem t.expanded rel_path then
    Hashtbl.remove t.expanded rel_path
  else
    Hashtbl.add t.expanded rel_path ();
  rebuild_tree_lines t

let expand_dir t rel_path =
  if not (Hashtbl.mem t.expanded rel_path) then begin
    Hashtbl.add t.expanded rel_path ();
    rebuild_tree_lines t
  end

let collapse_dir t rel_path =
  if Hashtbl.mem t.expanded rel_path then begin
    Hashtbl.remove t.expanded rel_path;
    rebuild_tree_lines t
  end

(* --- Mode / filter / view --- *)

let toggle_mode t =
  if t.view = VTree then begin
    t.mode <- (match t.mode with
      | File_listing.Project -> File_listing.All
      | File_listing.All -> File_listing.Project);
    refresh t
  end
  (* No-op in dep view: scope isn't user-tunable there. *)

let cycle_view t =
  t.view <- (match t.view with
    | VTree -> VDepOrder
    | VDepOrder -> VTree);
  rebuild_lines t;
  t.closure_for <- None

let enter_filter t =
  if t.filter = None then begin
    t.filter <- Some "";
    rebuild_lines t
  end

let exit_filter t =
  if t.filter <> None then begin
    t.filter <- None;
    rebuild_lines t
  end

let append_filter t ch =
  match t.filter with
  | None -> ()
  | Some s ->
    t.filter <- Some (s ^ String.make 1 ch);
    rebuild_lines t

let backspace_filter t =
  match t.filter with
  | Some s when String.length s > 0 ->
    t.filter <- Some (String.sub s 0 (String.length s - 1));
    rebuild_lines t
  | Some _ ->
    exit_filter t
  | None -> ()

(* --- Dep graph injection --- *)

let set_dep_graph t ~graph ~running =
  let changed = match t.dep_graph, graph with
    | None, None -> false
    | Some _, None | None, Some _ -> true
    | Some a, Some b -> a != b  (* physical eq is fine — Dep_runner always
                                   installs a fresh value *)
  in
  t.dep_running <- running;
  if changed then begin
    t.dep_graph <- graph;
    if t.view = VDepOrder then rebuild_dep_lines t
    else begin
      (* Pre-build for fast view switch later. *)
      rebuild_dep_lines t
    end
  end

(* --- Key handling --- *)

type action =
  | TreeContinue
  | TreeOpen of string  (* file path *)
  | TreeToggleProject of string  (* rel path under [project_dir] *)
  | TreeRename of string  (* rel path of file (non-dir) to rename *)
  | TreeUnhandled       (* let global key handlers run *)

let activate_selected t =
  match selected_line t with
  | None -> TreeContinue
  | Some line ->
    if line.entry.is_dir then begin
      toggle_dir t line.entry.rel_path;
      TreeContinue
    end
    else if line.entry.full_path <> "" then
      TreeOpen line.entry.full_path
    else TreeContinue

(* Dep-view-only: step to the next/previous file in the current
   selection's dependency closure (skipping dimmed files). When no
   closure is computable (no graph yet, or selected isn't in graph)
   we fall back to a plain step so Left/Right still moves something. *)
let move_to_in_closure t direction =
  if t.view <> VDepOrder then ()
  else begin
    ensure_closure t;
    let st = t.dep_state in
    let n = Array.length st.lines in
    if n = 0 then ()
    else if Hashtbl.length t.closure = 0 then
      move_selection t direction
    else
      let i = ref (st.selected + direction) in
      let found = ref false in
      while not !found && !i >= 0 && !i < n do
        if Hashtbl.mem t.closure st.lines.(!i).entry.rel_path
        then begin
          st.selected <- !i;
          found := true
        end else
          i := !i + direction
      done
  end

(* Number of file lines visible in the panel (height minus header minus
   filter row when active). *)
let visible_content_rows t r =
  let (h, _) = Render.pane_dims r Render.PFileTree in
  let used = 1 + (if t.filter <> None then 1 else 0) in
  max 0 (h - used)

(* [ch] uses the same int-code convention File_picker accepts; the editor
   dispatcher translates Input.events. *)
let handle_key t r ch =
  let visible_rows = visible_content_rows t r in
  let in_filter = t.filter <> None in
  let st () = current_state t in
  if in_filter && ch = 27 then begin
    exit_filter t;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 259 then begin (* Up *)
    move_selection t (-1);
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 258 then begin (* Down *)
    move_selection t 1;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 339 then begin (* PageUp *)
    move_selection t (-visible_rows);
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 338 then begin (* PageDown *)
    move_selection t visible_rows;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 262 then begin (* Home *)
    (st ()).selected <- 0;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 360 then begin (* End *)
    let s = st () in
    let n = Array.length s.lines in
    if n > 0 then s.selected <- n - 1;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 261 then begin (* Right *)
    if t.view = VDepOrder then begin
      move_to_in_closure t 1;
      ensure_visible t visible_rows
    end
    else begin
      (match selected_line t with
       | Some line when line.entry.is_dir ->
         if not line.expanded then begin
           expand_dir t line.entry.rel_path;
           ensure_visible t visible_rows
         end
         else begin
           move_selection t 1;
           ensure_visible t visible_rows
         end
       | _ -> ())
    end;
    TreeContinue
  end
  else if ch = 260 then begin (* Left *)
    if t.view = VDepOrder then begin
      move_to_in_closure t (-1);
      ensure_visible t visible_rows
    end
    else begin
      (match selected_line t with
       | Some line when line.entry.is_dir && line.expanded ->
         collapse_dir t line.entry.rel_path
       | _ -> ignore (move_to_parent t));
      ensure_visible t visible_rows
    end;
    TreeContinue
  end
  else if ch = 10 || ch = 13 then begin (* Enter *)
    let a = activate_selected t in
    ensure_visible t visible_rows;
    a
  end
  else if not in_filter && ch = Char.code '/' then begin
    enter_filter t;
    TreeContinue
  end
  else if not in_filter && ch = Char.code 'v' then begin
    cycle_view t;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if not in_filter && t.view = VTree && ch = Char.code 'p' then begin
    (* Toggle project membership of the selected file. Dirs and
       non-.v files fall through to the editor for a status message. *)
    match selected_line t with
    | Some line when not line.entry.is_dir ->
      TreeToggleProject line.entry.rel_path
    | Some _ | None -> TreeContinue
  end
  else if not in_filter && t.view = VTree && ch = Char.code 'r' then begin
    (* Open the rename prompt for the selected file. Dirs are
       a no-op (we don't support renaming directories yet). *)
    match selected_line t with
    | Some line when not line.entry.is_dir ->
      TreeRename line.entry.rel_path
    | Some _ | None -> TreeContinue
  end
  else if ch = 20 then begin (* ^T toggle mode (tree view only) *)
    toggle_mode t;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if in_filter && (ch = 127 || ch = 263) then begin (* Backspace *)
    backspace_filter t;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if in_filter && ch >= 32 && ch < 127 then begin
    append_filter t (Char.chr ch);
    ensure_visible t visible_rows;
    TreeContinue
  end
  else TreeUnhandled

(* --- Mouse --- *)

let line_at_y t ~y ~content_top =
  let st = current_state t in
  let row = y - content_top in
  if row < 0 then None
  else
    let idx = st.scroll + row in
    if idx >= 0 && idx < Array.length st.lines then Some idx
    else None

let handle_click t r ~y =
  let visible_rows = visible_content_rows t r in
  let rect = Render.pane_rect r Render.PFileTree in
  let content_top = rect.row + 1 in
  match line_at_y t ~y ~content_top with
  | None -> TreeContinue
  | Some idx ->
    (current_state t).selected <- idx;
    ensure_visible t visible_rows;
    activate_selected t

let handle_scroll t r direction =
  let visible_rows = visible_content_rows t r in
  let st = current_state t in
  let n = Array.length st.lines in
  let delta = if direction > 0 then 3 else -3 in
  st.scroll <- max 0 (min (max 0 (n - visible_rows)) (st.scroll + delta))

(* --- Render --- *)

let title_of t =
  match t.view, t.dep_running with
  | VTree, _ ->
    (match t.mode with
     | File_listing.Project -> " Files (project)"
     | File_listing.All -> " Files (all .v)")
  | VDepOrder, true -> " Files (deps, computing\xe2\x80\xa6)"  (* … *)
  | VDepOrder, false -> " Files (deps)"

let render t r ~open_files ~focused =
  let rect = Render.pane_rect r Render.PFileTree in
  if rect.width <= 0 || rect.height <= 0 then ()
  else begin
    Render.clear_pane r Render.PFileTree;
    ensure_closure t;
    let border_attr = (Theme.attrs ()).ga_border in
    let header_attr =
      if focused then { border_attr with bold = true; reverse = true }
      else { border_attr with bold = true }
    in
    let normal_attr = (Theme.attrs ()).ga_default in
    let dim_attr = { normal_attr with dim = true } in
    let bold_attr = { normal_attr with bold = true } in
    ignore (Render.put_str r Render.PFileTree ~row:0 ~col:0
              (title_of t) header_attr);
    let filter_visible = t.filter <> None in
    let content_top_row = 1 in
    let content_bottom = rect.height - (if filter_visible then 1 else 0) in
    let visible_rows = max 0 (content_bottom - content_top_row) in
    let st = current_state t in
    let n = Array.length st.lines in
    let max_scroll = max 0 (n - visible_rows) in
    if st.scroll > max_scroll then st.scroll <- max_scroll;
    (* Closure dimming only applies in dep view, and only when a
       graph + non-empty closure exist. *)
    let apply_dim_for_closure =
      t.view = VDepOrder
      && t.dep_graph <> None
      && Hashtbl.length t.closure > 0
    in
    for i = 0 to visible_rows - 1 do
      let row = content_top_row + i in
      let idx = st.scroll + i in
      if idx < n then begin
        let line = st.lines.(idx) in
        let entry = line.entry in
        let indent = String.make (line.depth * 2) ' ' in
        let glyph =
          if entry.is_dir then
            (if line.expanded then "\xe2\x96\xbe "
             else "\xe2\x96\xb8 ")
          else
            match List.assoc_opt entry.full_path open_files with
            | None -> "  "
            | Some { modified; disk_changed } ->
              let m = if modified then "*" else "" in
              let d = if disk_changed then "\xe2\x9f\xb3" else "" in
              let s =
                if modified || disk_changed then m ^ d
                else "\xe2\x80\xa2"
              in
              if Utf8.string_width s >= 2 then s
              else s ^ " "
        in
        let text = indent ^ glyph ^ entry.name in
        let in_closure =
          not apply_dim_for_closure
          || Hashtbl.mem t.closure entry.rel_path
        in
        let base_attr =
          if not in_closure then dim_attr
          else if entry.is_dir then bold_attr
          else if not entry.in_project then dim_attr
          else normal_attr
        in
        let attr =
          if idx = st.selected then
            { base_attr with reverse = true }
          else base_attr
        in
        let used = Render.put_str r Render.PFileTree ~row ~col:0 text attr in
        if idx = st.selected && used < rect.width then
          Render.fill r Render.PFileTree ~row ~col:used
            ~width:(rect.width - used) ' ' attr;
        (* Right-margin build-status marker for .v files. Drawn last so
           it punches through any selection fill and keeps its own
           color regardless of the highlighted row. *)
        if not entry.is_dir
           && Filename.check_suffix entry.name ".v"
           && rect.width >= 2
        then begin
          let a = Theme.attrs () in
          let marker = match Build_status.get entry.rel_path with
            | Build_status.Built_fresh ->
              Some ("\xe2\x9c\x94", a.ga_marker_success)        (* ✔ *)
            | Build_status.Build_error ->
              Some ("\xe2\x9c\x98", a.ga_marker_error)          (* ✘ *)
            | Build_status.Stale ->
              Some ("\xe2\x97\x8b", dim_attr)                   (* ○ *)
            | Build_status.Never_built -> None
          in
          match marker with
          | None -> ()
          | Some (g, mattr) ->
            Render.set_cell r Render.PFileTree ~row
              ~col:(rect.width - 1) g mattr
        end
      end
    done;
    if filter_visible then begin
      let filt = match t.filter with Some s -> s | None -> "" in
      let row = rect.height - 1 in
      let prompt = "/" in
      let avail = rect.width - String.length prompt in
      let shown =
        if String.length filt > avail then
          String.sub filt (String.length filt - avail) avail
        else filt
      in
      let attr = { normal_attr with bold = true } in
      ignore (Render.put_str r Render.PFileTree ~row ~col:0 prompt attr);
      ignore (Render.put_str r Render.PFileTree ~row
                ~col:(String.length prompt) shown normal_attr)
    end
  end
