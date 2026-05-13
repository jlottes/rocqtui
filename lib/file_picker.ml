(* File picker dialog — modal overlay showing project files in a tree.
   File enumeration and tree building live in [File_listing]; this module
   owns display flattening, selection, scroll, and input. *)

type flat_line = {
  indent : int;
  connector : string;  (* "--- ", "--- ", "|   ", "    " prefix piece *)
  name : string;
  full_path : string;  (* "" for directories *)
  rel_path : string;   (* project-relative, e.g. "theory/groups.v" or "theory/" *)
  is_dir : bool;
  in_project : bool;   (* listed in _RocqProject *)
}

type t = {
  mutable lines : flat_line array;
  mutable selected : int;
  mutable scroll : int;
  mutable mode : File_listing.mode;
  mutable input : string;  (* typed path filter *)
  project_dir : string;
  project_file : string;  (* path to _RocqProject *)
  open_files : string list;  (* currently open file paths *)
}

(* Flatten a tree of File_listing.node into display lines with box-drawing
   connectors. *)
let flatten tree =
  let lines = ref [] in
  let rec walk ~prefix ~depth nodes =
    let n = List.length nodes in
    List.iteri (fun i node ->
      let last = (i = n - 1) in
      let connector =
        if depth = 0 then ""
        else if last then "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 "  (* "└── " *)
        else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 "  (* "├── " *)
      in
      let child_prefix =
        if depth = 0 then ""
        else prefix ^ (if last then "    " else "\xe2\x94\x82   ")  (* "│   " *)
      in
      let entry, children = match node with
        | File_listing.File e -> e, None
        | File_listing.Dir (e, c) -> e, Some c
      in
      lines := { indent = depth; connector = prefix ^ connector;
                 name = entry.name; full_path = entry.full_path;
                 rel_path = entry.rel_path; is_dir = entry.is_dir;
                 in_project = entry.in_project } :: !lines;
      match children with
      | None -> ()
      | Some c -> walk ~prefix:child_prefix ~depth:(depth + 1) c
    ) nodes
  in
  walk ~prefix:"" ~depth:0 tree;
  Array.of_list (List.rev !lines)

let rebuild_lines t =
  let tree = File_listing.enumerate
    ~project_dir:t.project_dir
    ~project_file:t.project_file
    ~mode:t.mode in
  t.lines <- flatten tree;
  (* Clamp selection *)
  if t.selected >= Array.length t.lines then
    t.selected <- max 0 (Array.length t.lines - 1);
  t.scroll <- 0

(* Navigate selection to first line whose rel_path starts with the input *)
let navigate_to_input t =
  if t.input = "" then ()
  else begin
    let n = Array.length t.lines in
    let found = ref false in
    for i = 0 to n - 1 do
      if not !found then begin
        let line = t.lines.(i) in
        let rp = line.rel_path in
        if String.length rp >= String.length t.input
           && String.sub rp 0 (String.length t.input) = t.input then begin
          t.selected <- i;
          found := true
        end
      end
    done
  end

(* Tab completion: find the longest common prefix among all matching rel_paths *)
let tab_complete t =
  if t.input = "" then ()
  else begin
    let input_len = String.length t.input in
    let matches = Array.to_list t.lines
      |> List.map (fun l -> l.rel_path)
      |> List.filter (fun rp ->
           String.length rp >= input_len
           && String.sub rp 0 input_len = t.input) in
    match matches with
    | [] -> ()
    | [single] ->
      t.input <- single;
      navigate_to_input t
    | first :: rest ->
      let lcp = ref (String.length first) in
      List.iter (fun s ->
        let n = min !lcp (String.length s) in
        let i = ref 0 in
        while !i < n && first.[!i] = s.[!i] do incr i done;
        lcp := !i
      ) rest;
      let common = String.sub first 0 !lcp in
      if String.length common > input_len then begin
        t.input <- common;
        navigate_to_input t
      end
  end

let create ~project_dir ~project_file ~open_files =
  let t = {
    lines = [||]; selected = 0; scroll = 0;
    mode = File_listing.Project; input = "";
    project_dir; project_file; open_files;
  } in
  rebuild_lines t;
  t

let move_selection t delta =
  let n = Array.length t.lines in
  if n > 0 then
    t.selected <- max 0 (min (n - 1) (t.selected + delta))

let ensure_visible t visible_rows =
  if t.selected < t.scroll then
    t.scroll <- t.selected
  else if t.selected >= t.scroll + visible_rows then
    t.scroll <- t.selected - visible_rows + 1

type action =
  | PickerContinue
  | PickerClose
  | PickerOpen of string  (* file path to open *)

let handle_key t ch visible_rows =
    if ch = 27 then begin (* Escape *)
      PickerClose
    end
    else if ch = 259 then begin (* up *)
      move_selection t (-1);
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 258 then begin (* down *)
      move_selection t 1;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 339 then begin (* page up *)
      move_selection t (-visible_rows);
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 338 then begin (* page down *)
      move_selection t visible_rows;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 10 || ch = 13 then begin (* Enter *)
      let n = Array.length t.lines in
      if n > 0 && t.selected >= 0 && t.selected < n then begin
        let line = t.lines.(t.selected) in
        if not line.is_dir && line.full_path <> "" then
          PickerOpen line.full_path
        else
          PickerContinue
      end else
        PickerContinue
    end
    else if ch = 9 then begin (* Tab -- complete *)
      tab_complete t;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 20 then begin (* ^T -- toggle project/all *)
      t.mode <- (match t.mode with
        | File_listing.Project -> File_listing.All
        | File_listing.All -> File_listing.Project);
      rebuild_lines t;
      navigate_to_input t;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch = 127 || ch = 263 then begin (* Backspace *)
      if String.length t.input > 0 then begin
        t.input <- String.sub t.input 0 (String.length t.input - 1);
        navigate_to_input t;
        ensure_visible t visible_rows
      end;
      PickerContinue
    end
    else if ch = Char.code '/' then begin (* / -- complete to directory *)
      tab_complete t;
      if String.length t.input > 0
         && t.input.[String.length t.input - 1] <> '/' then
        t.input <- t.input ^ "/";
      navigate_to_input t;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else if ch >= 32 && ch < 127 then begin (* Printable character *)
      t.input <- t.input ^ String.make 1 (Char.chr ch);
      navigate_to_input t;
      ensure_visible t visible_rows;
      PickerContinue
    end
    else
      PickerContinue

(* Handle mouse click -- returns action if a file was clicked *)
let handle_click t ~y ~x:_ ~box_top ~box_left:_ ~box_width:_ ~visible_rows =
  let content_row = y - box_top - 1 in
  if content_row >= 0 && content_row < visible_rows then begin
    let idx = t.scroll + content_row in
    if idx >= 0 && idx < Array.length t.lines then begin
      t.selected <- idx;
      let line = t.lines.(idx) in
      if not line.is_dir && line.full_path <> "" then
        PickerOpen line.full_path
      else
        PickerContinue
    end else
      PickerContinue
  end
  else
    PickerContinue

let handle_scroll t direction visible_rows =
  let n = Array.length t.lines in
  let delta = if direction > 0 then 3 else -3 in
  t.scroll <- max 0 (min (n - visible_rows) (t.scroll + delta))

let render_overlay grid (rect : Render.rect) t =
  let box_h = rect.height in
  let box_w = rect.width in
  let box_top = rect.row in
  let box_left = rect.col in
  let visible_rows = box_h - 4 in
  let border_attr = { (Theme.attrs ()).ga_border with bold = true } in
  let normal_attr = Grid.default_attr in
  (* Fill background *)
  Grid.clear_region grid ~row:box_top ~col:box_left ~height:box_h ~width:box_w ~attr:normal_attr;
  (* Top border *)
  Grid.set_cell grid ~row:box_top ~col:box_left
    "\xe2\x94\x8c" border_attr;  (* ┌ *)
  Grid.set_cell grid ~row:box_top ~col:(box_left + 1)
    "\xe2\x94\x80" border_attr;  (* ─ *)
  let title = match t.mode with
    | File_listing.Project -> " Open File (project) "
    | File_listing.All -> " Open File (all .v) "
  in
  ignore (Grid.put_str grid ~row:box_top ~col:(box_left + 2) title border_attr);
  let title_end = 2 + String.length title in
  for c = title_end to box_w - 2 do
    Grid.set_cell grid ~row:box_top ~col:(box_left + c)
      "\xe2\x94\x80" border_attr  (* ─ *)
  done;
  Grid.set_cell grid ~row:box_top ~col:(box_left + box_w - 1)
    "\xe2\x94\x90" border_attr;  (* ┐ *)
  (* Bottom border *)
  Grid.set_cell grid ~row:(box_top + box_h - 1) ~col:box_left
    "\xe2\x94\x94" border_attr;  (* └ *)
  for c = 1 to box_w - 2 do
    Grid.set_cell grid ~row:(box_top + box_h - 1) ~col:(box_left + c)
      "\xe2\x94\x80" border_attr  (* ─ *)
  done;
  Grid.set_cell grid ~row:(box_top + box_h - 1) ~col:(box_left + box_w - 1)
    "\xe2\x94\x98" border_attr;  (* ┘ *)
  (* Side borders *)
  for r = 1 to box_h - 2 do
    Grid.set_cell grid ~row:(box_top + r) ~col:box_left
      "\xe2\x94\x82" border_attr;  (* │ *)
    Grid.set_cell grid ~row:(box_top + r) ~col:(box_left + box_w - 1)
      "\xe2\x94\x82" border_attr  (* │ *)
  done;
  (* Input field *)
  let input_row = box_top + box_h - 3 in
  ignore (Grid.put_str grid ~row:input_row ~col:(box_left + 2) "> " normal_attr);
  let input_width = box_w - 5 in
  let displayed_input =
    if String.length t.input > input_width then
      String.sub t.input (String.length t.input - input_width) input_width
    else t.input
  in
  ignore (Grid.put_str grid ~row:input_row ~col:(box_left + 4)
    displayed_input normal_attr);
  (* Mode / help bar *)
  let mode_row = box_top + box_h - 2 in
  let mode_label = match t.mode with
    | File_listing.Project -> "project"
    | File_listing.All -> "all .v"
  in
  ignore (Grid.put_str grid ~row:mode_row ~col:(box_left + 2)
    (Printf.sprintf "^T:%s  Tab:complete  Esc:close" mode_label) normal_attr);
  (* Draw file lines *)
  let content_width = box_w - 4 in
  for i = 0 to visible_rows - 1 do
    let row = box_top + 1 + i in
    let idx = t.scroll + i in
    if idx < Array.length t.lines then begin
      let line = t.lines.(idx) in
      let is_open_file = not line.is_dir &&
                    List.mem line.full_path t.open_files in
      let marker = if is_open_file then "\xe2\x80\xa2 " else "  " in
      let prefix_text = marker ^ line.connector in
      let name_text = line.name in
      let name_trunc =
        let avail = content_width - String.length prefix_text in
        if String.length name_text > avail then
          String.sub name_text 0 (max 0 avail)
        else name_text
      in
      if idx = t.selected then begin
        let rev_attr = { Grid.default_attr with reverse = true } in
        let cols_used = Grid.put_str grid ~row ~col:(box_left + 2)
          (prefix_text ^ name_trunc) rev_attr in
        let remaining = content_width - cols_used in
        for c = 0 to remaining - 1 do
          Grid.set_cell grid ~row
            ~col:(box_left + 2 + cols_used + c) " " rev_attr
        done
      end else begin
        let dim_attr = { Grid.default_attr with dim = true } in
        let bold_attr = { Grid.default_attr with bold = true } in
        let dim = not line.is_dir && not line.in_project
                  && t.mode = File_listing.All in
        let prefix_cols = Grid.put_str grid ~row ~col:(box_left + 2)
          prefix_text normal_attr in
        let name_attr =
          if line.is_dir then bold_attr
          else if dim then dim_attr
          else normal_attr
        in
        ignore (Grid.put_str grid ~row
          ~col:(box_left + 2 + prefix_cols)
          name_trunc name_attr)
      end
    end
  done

let compute_box_geometry term_h term_w =
  let box_h = min (term_h - 4) (max 10 (term_h * 3 / 4)) in
  let box_w = min (term_w - 4) (max 40 (term_w * 2 / 3)) in
  let box_top = (term_h - box_h) / 2 in
  let box_left = (term_w - box_w) / 2 in
  let visible_rows = box_h - 4 in
  (box_top, box_left, box_w, box_h, visible_rows)

let render t r =
  let (term_h, term_w) = Term.size () in
  let (box_top, box_left, box_w, box_h, _visible_rows) =
    compute_box_geometry term_h term_w in
  let rect = { Render.row = box_top; col = box_left;
               height = box_h; width = box_w } in
  Render.set_overlay r rect (fun grid rect -> render_overlay grid rect t)

let box_geometry () =
  let (term_h, term_w) = Term.size () in
  compute_box_geometry term_h term_w
