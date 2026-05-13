(* File-tree panel widget. Persistent left-side navigator that shares
   file enumeration with [File_picker] via [File_listing] but otherwise
   has its own UX: expandable directories, arrow-key navigation, and
   transient `/`-to-filter mode. *)

type line = {
  depth : int;
  entry : File_listing.entry;
  expanded : bool;      (* meaningful for dirs *)
  has_children : bool;  (* dir with at least one visible child *)
}

type t = {
  project_dir : string;
  project_file : string;
  mutable mode : File_listing.mode;
  mutable tree : File_listing.node list;
  expanded : (string, unit) Hashtbl.t;  (* keys: dir rel_paths with "/" *)
  mutable lines : line array;
  mutable selected : int;
  mutable scroll : int;
  mutable filter : string option;       (* Some "" = active but empty *)
}

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

let rebuild_lines t =
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
  t.lines <- lines;
  let n = Array.length lines in
  if t.selected >= n then t.selected <- max 0 (n - 1);
  if t.selected < 0 then t.selected <- 0;
  if t.scroll > t.selected then t.scroll <- t.selected

let create ~project_dir ~project_file =
  let t = {
    project_dir; project_file;
    mode = File_listing.Project;
    tree = [];
    expanded = Hashtbl.create 32;
    lines = [||];
    selected = 0;
    scroll = 0;
    filter = None;
  } in
  rebuild_tree t;
  rebuild_lines t;
  t

let refresh t =
  rebuild_tree t;
  rebuild_lines t

(* --- Selection movement --- *)

let move_selection t delta =
  let n = Array.length t.lines in
  if n > 0 then
    t.selected <- max 0 (min (n - 1) (t.selected + delta))

let ensure_visible t visible_rows =
  if t.selected < t.scroll then
    t.scroll <- t.selected
  else if t.selected >= t.scroll + visible_rows then
    t.scroll <- t.selected - visible_rows + 1

let selected_line t =
  let n = Array.length t.lines in
  if n = 0 || t.selected < 0 || t.selected >= n then None
  else Some t.lines.(t.selected)

(* Move selection to the index of the parent directory of the currently
   selected node (i.e. the nearest ancestor row above with smaller depth).
   Returns true if it moved. *)
let move_to_parent t =
  match selected_line t with
  | None -> false
  | Some cur ->
    if cur.depth = 0 then false
    else begin
      let target_depth = cur.depth - 1 in
      let i = ref (t.selected - 1) in
      let found = ref false in
      while not !found && !i >= 0 do
        if t.lines.(!i).depth = target_depth then found := true
        else decr i
      done;
      if !found then (t.selected <- !i; true) else false
    end

(* --- Expand / collapse --- *)

let toggle_dir t rel_path =
  if Hashtbl.mem t.expanded rel_path then
    Hashtbl.remove t.expanded rel_path
  else
    Hashtbl.add t.expanded rel_path ();
  rebuild_lines t

let expand_dir t rel_path =
  if not (Hashtbl.mem t.expanded rel_path) then begin
    Hashtbl.add t.expanded rel_path ();
    rebuild_lines t
  end

let collapse_dir t rel_path =
  if Hashtbl.mem t.expanded rel_path then begin
    Hashtbl.remove t.expanded rel_path;
    rebuild_lines t
  end

(* --- Mode / filter --- *)

let toggle_mode t =
  t.mode <- (match t.mode with
    | File_listing.Project -> File_listing.All
    | File_listing.All -> File_listing.Project);
  refresh t

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

(* --- Key handling --- *)

type action =
  | TreeContinue
  | TreeOpen of string  (* file path *)

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
  if in_filter && ch = 27 then begin (* Esc exits filter mode *)
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
    t.selected <- 0;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 360 then begin (* End *)
    let n = Array.length t.lines in
    if n > 0 then t.selected <- n - 1;
    ensure_visible t visible_rows;
    TreeContinue
  end
  else if ch = 261 then begin (* Right *)
    (match selected_line t with
     | Some line when line.entry.is_dir ->
       if not line.expanded then begin
         expand_dir t line.entry.rel_path;
         ensure_visible t visible_rows
       end
       else begin
         (* Already expanded: move to first child if any *)
         move_selection t 1;
         ensure_visible t visible_rows
       end
     | _ -> ());
    TreeContinue
  end
  else if ch = 260 then begin (* Left *)
    (match selected_line t with
     | Some line when line.entry.is_dir && line.expanded ->
       collapse_dir t line.entry.rel_path
     | _ -> ignore (move_to_parent t));
    ensure_visible t visible_rows;
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
  else if ch = 20 then begin (* ^T toggle mode *)
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
  else TreeContinue

(* --- Mouse --- *)

let line_at_y t ~y ~content_top =
  let row = y - content_top in
  if row < 0 then None
  else
    let idx = t.scroll + row in
    if idx >= 0 && idx < Array.length t.lines then Some idx
    else None

let handle_click t r ~y =
  let visible_rows = visible_content_rows t r in
  let rect = Render.pane_rect r Render.PFileTree in
  let content_top = rect.row + 1 in  (* header occupies row rect.row *)
  match line_at_y t ~y ~content_top with
  | None -> TreeContinue
  | Some idx ->
    t.selected <- idx;
    ensure_visible t visible_rows;
    activate_selected t

let handle_scroll t r direction =
  let visible_rows = visible_content_rows t r in
  let n = Array.length t.lines in
  let delta = if direction > 0 then 3 else -3 in
  t.scroll <- max 0 (min (max 0 (n - visible_rows)) (t.scroll + delta))

(* --- Render --- *)

let title_of_mode = function
  | File_listing.Project -> " Files (project)"
  | File_listing.All -> " Files (all .v)"

let render t r ~open_files ~focused =
  let rect = Render.pane_rect r Render.PFileTree in
  if rect.width <= 0 || rect.height <= 0 then ()
  else begin
    Render.clear_pane r Render.PFileTree;
    let border_attr = (Theme.attrs ()).ga_border in
    let header_attr =
      if focused then { border_attr with bold = true; reverse = true }
      else { border_attr with bold = true }
    in
    let normal_attr = Grid.default_attr in
    let dim_attr = { normal_attr with dim = true } in
    let bold_attr = { normal_attr with bold = true } in
    (* Header row *)
    let header = title_of_mode t.mode in
    let header =
      if String.length header > rect.width then
        String.sub header 0 rect.width
      else header
    in
    ignore (Render.put_str r Render.PFileTree ~row:0 ~col:0 header header_attr);
    (* Filter row (when active) takes the bottom row; reserve for it. *)
    let filter_visible = t.filter <> None in
    let content_top_row = 1 in
    let content_bottom = rect.height - (if filter_visible then 1 else 0) in
    let visible_rows = max 0 (content_bottom - content_top_row) in
    (* Clamp scroll *)
    let n = Array.length t.lines in
    let max_scroll = max 0 (n - visible_rows) in
    if t.scroll > max_scroll then t.scroll <- max_scroll;
    if t.selected < t.scroll then t.scroll <- t.selected
    else if t.selected >= t.scroll + visible_rows then
      t.scroll <- max 0 (t.selected - visible_rows + 1);
    (* Lines *)
    for i = 0 to visible_rows - 1 do
      let row = content_top_row + i in
      let idx = t.scroll + i in
      if idx < n then begin
        let line = t.lines.(idx) in
        let entry = line.entry in
        let indent = String.make (line.depth * 2) ' ' in
        let glyph =
          if entry.is_dir then
            (if line.expanded then "\xe2\x96\xbe "  (* ▾ *)
             else "\xe2\x96\xb8 ")                  (* ▸ *)
          else if List.mem entry.full_path open_files then
            "\xe2\x80\xa2 "                          (* • *)
          else "  "
        in
        let text = indent ^ glyph ^ entry.name in
        let is_dim =
          not entry.is_dir && not entry.in_project
          && t.mode = File_listing.All
        in
        let attr =
          if idx = t.selected then
            { normal_attr with reverse = true }
          else if entry.is_dir then bold_attr
          else if is_dim then dim_attr
          else normal_attr
        in
        let used = Render.put_str r Render.PFileTree ~row ~col:0 text attr in
        if idx = t.selected && used < rect.width then
          Render.fill r Render.PFileTree ~row ~col:used
            ~width:(rect.width - used) ' ' attr
      end
    done;
    (* Filter input row *)
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

let project_file t = t.project_file
