(* Shared file enumeration for the modal File_picker and the panel
   File_tree. Owns the _RocqProject reading, the project-vs-all mode
   decision, and the sorted tree construction. Knows nothing about
   rendering, selection, input, or expansion state. *)

type mode = Project | All

type entry = {
  full_path : string;   (* absolute path; "" for directory nodes *)
  rel_path : string;    (* project-relative; dirs include a trailing "/" *)
  name : string;        (* display segment; dirs include a trailing "/" *)
  is_dir : bool;
  in_project : bool;    (* listed in _RocqProject (always true for dirs) *)
}

type node =
  | Dir of entry * node list
  | File of entry

(* Project-relative paths for a list of absolute paths. Files outside
   project_dir are dropped (we don't render them in the tree). *)
let relative_paths project_dir files =
  let prefix = project_dir ^ "/" in
  let prefix_len = String.length prefix in
  List.filter_map (fun f ->
    if String.length f > prefix_len
       && String.sub f 0 prefix_len = prefix then
      Some (String.sub f prefix_len (String.length f - prefix_len))
    else None
  ) files

(* Build a tree from a sorted list of file rel_paths. Directories are
   synthesized from path segments; their order in the tree follows
   first-encounter (then we sort below). *)
let build_tree project_dir project_files_set rel_paths =
  let is_in_project rel =
    let full = Filename.concat project_dir rel in
    List.mem full project_files_set
  in
  let mk_file_entry rel =
    let name = Filename.basename rel in
    { full_path = Filename.concat project_dir rel;
      rel_path = rel; name;
      is_dir = false;
      in_project = is_in_project rel }
  in
  let mk_dir_entry rel_with_slash =
    let no_slash =
      String.sub rel_with_slash 0 (String.length rel_with_slash - 1) in
    let name = Filename.basename no_slash ^ "/" in
    { full_path = ""; rel_path = rel_with_slash; name;
      is_dir = true; in_project = true }
  in
  let rec insert tree segments path_so_far =
    match segments with
    | [] -> tree
    | [leaf] ->
      let rel = path_so_far ^ leaf in
      tree @ [File (mk_file_entry rel)]
    | dir :: rest ->
      let dir_rel = path_so_far ^ dir ^ "/" in
      let found = ref false in
      let tree' = List.map (fun node ->
        match node with
        | Dir (e, children) when e.rel_path = dir_rel ->
          found := true;
          Dir (e, insert children rest dir_rel)
        | other -> other
      ) tree in
      if !found then tree'
      else tree' @ [Dir (mk_dir_entry dir_rel, insert [] rest dir_rel)]
  in
  let tree =
    List.fold_left (fun tree rel ->
      let parts = String.split_on_char '/' rel in
      insert tree parts ""
    ) [] rel_paths
  in
  (* Sort: dirs first (alphabetical), then files (alphabetical). *)
  let rec sort_tree = function
    | Dir (e, children) -> Dir (e, sort_children children)
    | File _ as f -> f
  and sort_children nodes =
    let dirs = List.filter_map (function
      | Dir _ as n -> Some (sort_tree n) | _ -> None) nodes in
    let files = List.filter_map (function
      | File _ as n -> Some n | _ -> None) nodes in
    let cmp a b = match a, b with
      | Dir (ea, _), Dir (eb, _) -> String.compare ea.rel_path eb.rel_path
      | File ea, File eb -> String.compare ea.rel_path eb.rel_path
      | _ -> 0
    in
    List.sort cmp dirs @ List.sort cmp files
  in
  sort_children tree

let enumerate ~project_dir ~project_file ~mode =
  let project_files = Project.listed_files project_file in
  let files = match mode with
    | Project -> project_files
    | All ->
      let load_paths = Project.load_paths project_file in
      Project.all_v_files load_paths
  in
  let rels = List.sort String.compare (relative_paths project_dir files) in
  build_tree project_dir project_files rels
