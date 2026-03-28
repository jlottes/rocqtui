(* Parse _RocqProject / _CoqProject for coqidetop arguments. *)

let project_filenames = ["_RocqProject"; "_CoqProject"]

let find_project_file dir =
  let rec search d =
    let found = List.find_opt (fun name ->
      Sys.file_exists (Filename.concat d name)
    ) project_filenames in
    match found with
    | Some name -> Some (d, Filename.concat d name)
    | None ->
      let parent = Filename.dirname d in
      if parent = d then None  (* reached root *)
      else search parent
  in
  search dir

(* Resolve a path relative to the project directory *)
let resolve_path project_dir path =
  if path = "." then project_dir
  else if Filename.is_relative path then
    Filename.concat project_dir path
  else
    path

(* Parse a project file, extracting args relevant to coqidetop.
   We pass through: -R, -Q, -arg, and bare flags like -nois.
   We skip file listings (lines ending in .v).
   Paths in -R/-Q are resolved relative to the project file's directory. *)
let parse_project_file path =
  let project_dir = Filename.dirname path in
  let ic = open_in path in
  let args = ref [] in
  (try while true do
     let line = String.trim (input_line ic) in
     if line = "" || String.length line > 0 && line.[0] = '#' then
       ()  (* skip empty lines and comments *)
     else if String.length line > 2 && String.sub line (String.length line - 2) 2 = ".v" then
       ()  (* skip .v file listings *)
     else begin
       (* Split line into tokens respecting simple quoting *)
       let tokens = ref [] in
       let buf = Stdlib.Buffer.create 64 in
       let in_quote = ref false in
       String.iter (fun c ->
         if !in_quote then begin
           if c = '"' then in_quote := false
           else Stdlib.Buffer.add_char buf c
         end else if c = '"' then
           in_quote := true
         else if c = ' ' || c = '\t' then begin
           if Stdlib.Buffer.length buf > 0 then begin
             tokens := Stdlib.Buffer.contents buf :: !tokens;
             Stdlib.Buffer.clear buf
           end
         end else
           Stdlib.Buffer.add_char buf c
       ) line;
       if Stdlib.Buffer.length buf > 0 then
         tokens := Stdlib.Buffer.contents buf :: !tokens;
       let toks = List.rev !tokens in
       (* Process tokens *)
       let rec process = function
         | [] -> ()
         | "-R" :: dir :: logical :: rest ->
           args := logical :: (resolve_path project_dir dir) :: "-R" :: !args;
           process rest
         | "-Q" :: dir :: logical :: rest ->
           args := logical :: (resolve_path project_dir dir) :: "-Q" :: !args;
           process rest
         | "-arg" :: a :: rest ->
           (* -arg values may contain spaces; split them *)
           let parts = String.split_on_char ' ' a in
           List.iter (fun p ->
             let p = String.trim p in
             if p <> "" then args := p :: !args
           ) parts;
           process rest
         | flag :: rest when String.length flag > 0 && flag.[0] = '-' ->
           args := flag :: !args;
           process rest
         | _ :: rest ->
           process rest  (* skip unknown tokens *)
       in
       process toks
     end
   done with End_of_file -> ());
  close_in ic;
  List.rev !args

(* --- Load paths and project file listing --- *)

type load_path_entry = {
  physical_dir : string;
  logical_prefix : string;
  implicit : bool;
}

(* Parse a project file and extract load path entries *)
let load_paths path =
  let project_dir = Filename.dirname path in
  let ic = open_in path in
  let entries = ref [] in
  (try while true do
     let line = String.trim (input_line ic) in
     if line = "" || String.length line > 0 && line.[0] = '#' then ()
     else begin
       let tokens = ref [] in
       let buf = Stdlib.Buffer.create 64 in
       let in_quote = ref false in
       String.iter (fun c ->
         if !in_quote then begin
           if c = '"' then in_quote := false
           else Stdlib.Buffer.add_char buf c
         end else if c = '"' then
           in_quote := true
         else if c = ' ' || c = '\t' then begin
           if Stdlib.Buffer.length buf > 0 then begin
             tokens := Stdlib.Buffer.contents buf :: !tokens;
             Stdlib.Buffer.clear buf
           end
         end else
           Stdlib.Buffer.add_char buf c
       ) line;
       if Stdlib.Buffer.length buf > 0 then
         tokens := Stdlib.Buffer.contents buf :: !tokens;
       let toks = List.rev !tokens in
       let rec process = function
         | "-R" :: dir :: logical :: rest ->
           entries := { physical_dir = resolve_path project_dir dir;
                        logical_prefix = logical; implicit = true } :: !entries;
           process rest
         | "-Q" :: dir :: logical :: rest ->
           entries := { physical_dir = resolve_path project_dir dir;
                        logical_prefix = logical; implicit = false } :: !entries;
           process rest
         | _ :: rest -> process rest
         | [] -> ()
       in
       process toks
     end
   done with End_of_file -> ());
  close_in ic;
  List.rev !entries

(* List .v files explicitly listed in _RocqProject *)
let listed_files path =
  let project_dir = Filename.dirname path in
  let ic = open_in path in
  let files = ref [] in
  (try while true do
     let line = String.trim (input_line ic) in
     if String.length line > 2
        && String.sub line (String.length line - 2) 2 = ".v"
        && (String.length line < 1 || line.[0] <> '-') then
       files := resolve_path project_dir line :: !files
   done with End_of_file -> ());
  close_in ic;
  List.rev !files

(* Recursively find all .v files under a directory *)
let rec find_v_files dir =
  let entries = try Sys.readdir dir with _ -> [||] in
  let files = ref [] in
  Array.iter (fun name ->
    let path = Filename.concat dir name in
    if Sys.is_directory path then
      files := find_v_files path @ !files
    else if Filename.check_suffix name ".v" then
      files := path :: !files
  ) entries;
  List.sort String.compare !files

(* Get all .v files reachable through load paths *)
let all_v_files entries =
  let files = ref [] in
  List.iter (fun e ->
    files := find_v_files e.physical_dir @ !files
  ) entries;
  List.sort_uniq String.compare !files

(* Resolve a dotted module name to a .v file path *)
let resolve_module entries modname =
  let parts = String.split_on_char '.' modname in
  let path_of_parts dir parts =
    let relpath = String.concat "/" parts ^ ".v" in
    let full = Filename.concat dir relpath in
    if Sys.file_exists full then Some full else None
  in
  let rec try_entries = function
    | [] -> None
    | e :: rest ->
      let prefix_parts = String.split_on_char '.' e.logical_prefix in
      let prefix_len = List.length prefix_parts in
      (* Try stripping the logical prefix *)
      let stripped =
        if List.length parts > prefix_len then
          let rec matches a b = match a, b with
            | [], _ -> true
            | x :: xs, y :: ys when x = y -> matches xs ys
            | _ -> false
          in
          if matches prefix_parts parts then
            let rest_parts = List.filteri (fun i _ -> i >= prefix_len) parts in
            path_of_parts e.physical_dir rest_parts
          else None
        else None
      in
      (match stripped with
       | Some _ -> stripped
       | None ->
         (* For implicit (-R), also try without stripping *)
         if e.implicit then
           match path_of_parts e.physical_dir parts with
           | Some _ as r -> r
           | None -> try_entries rest
         else
           try_entries rest)
  in
  try_entries entries

let find_args filename =
  (* First check cwd *)
  let cwd = Sys.getcwd () in
  let from_cwd = find_project_file cwd in
  (* Then check file's directory *)
  let from_file = match filename with
    | Some f ->
      let dir = Filename.dirname (
        if Filename.is_relative f then Filename.concat cwd f else f
      ) in
      if dir = cwd then None  (* already checked *)
      else find_project_file dir
    | None -> None
  in
  match from_cwd, from_file with
  | Some (dir, path), _ ->
    (Some dir, parse_project_file path)
  | None, Some (dir, path) ->
    (Some dir, parse_project_file path)
  | None, None ->
    (None, [])
