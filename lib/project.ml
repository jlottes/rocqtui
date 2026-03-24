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
