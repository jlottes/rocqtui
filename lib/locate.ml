(* Helpers for parsing Locate/Locate Library output from Rocq. *)

(* Parse "Locate <ident>." output.
   Input: message like "Constant Corelib.Init.Nat.add"
   Returns: Some (kind, module_path, name) or None *)
let parse_locate msg =
  let line = match String.split_on_char '\n' (String.trim msg) with
    | l :: _ -> String.trim l
    | [] -> ""
  in
  let space = try String.index line ' ' with Not_found -> -1 in
  if space <= 0 then None
  else
    let kind = String.sub line 0 space in
    let path = String.sub line (space + 1) (String.length line - space - 1) in
    let path = String.trim path in
    (* Split dotted path: last component = name, rest = module *)
    match String.rindex_opt path '.' with
    | Some dot ->
      let module_path = String.sub path 0 dot in
      let name = String.sub path (dot + 1) (String.length path - dot - 1) in
      Some (kind, module_path, name)
    | None -> Some (kind, "", path)

(* Parse "Locate Library <mod>." output.
   Input: message like "Corelib.Init.Nat has been loaded from file\n/path/to/Nat.vo"
   Returns: Some vo_path or None *)
let parse_locate_library msg =
  let lines = String.split_on_char '\n' (String.trim msg) in
  (* Look for a line containing a .vo path *)
  List.find_map (fun line ->
    let line = String.trim line in
    if String.length line > 3
       && String.sub line (String.length line - 3) 3 = ".vo" then
      Some line
    else None
  ) lines

(* Derive .v source path from .vo path *)
let vo_to_v path =
  if String.length path > 3
     && String.sub path (String.length path - 3) 3 = ".vo" then
    String.sub path 0 (String.length path - 3) ^ ".v"
  else path

(* Derive .glob path from .vo path *)
let vo_to_glob path =
  if String.length path > 3
     && String.sub path (String.length path - 3) 3 = ".vo" then
    String.sub path 0 (String.length path - 3) ^ ".glob"
  else path ^ ".glob"

(* Parse a Require line and extract module names with their byte positions.
   Returns: (from_prefix option, [(module_name, start_col, end_col)]) *)
let parse_require_line line =
  let line = String.trim line in
  let len = String.length line in
  (* Tokenize: split on whitespace, track positions *)
  let tokens = ref [] in
  let i = ref 0 in
  while !i < len do
    (* Skip whitespace *)
    while !i < len && (line.[!i] = ' ' || line.[!i] = '\t') do incr i done;
    if !i < len && line.[!i] <> '.' then begin
      let start = !i in
      (* Scan token — identifiers may contain dots *)
      while !i < len && line.[!i] <> ' ' && line.[!i] <> '\t'
            && line.[!i] <> '.' do
        incr i
      done;
      (* Include trailing dots that are part of qualified names *)
      while !i < len && line.[!i] = '.'
            && !i + 1 < len && line.[!i + 1] <> ' '
            && line.[!i + 1] <> '\t' && line.[!i + 1] <> '.' do
        incr i;
        while !i < len && line.[!i] <> ' ' && line.[!i] <> '\t'
              && line.[!i] <> '.' do
          incr i
        done
      done;
      let word = String.sub line start (!i - start) in
      tokens := (word, start, !i) :: !tokens
    end else if !i < len then
      incr i  (* skip final dot *)
  done;
  let tokens = List.rev !tokens in
  (* Check if this is a Require line *)
  match tokens with
  | ("From", _, _) :: (prefix, _, _) :: ("Require", _, _) :: rest ->
    (* From X Require [Import|Export] modules... *)
    let modules = List.filter (fun (w, _, _) ->
      w <> "Import" && w <> "Export"
    ) rest in
    let modules = List.map (fun (m, s, e) ->
      (prefix ^ "." ^ m, s, e)
    ) modules in
    Some (Some prefix, modules)
  | ("Require", _, _) :: rest ->
    let modules = List.filter (fun (w, _, _) ->
      w <> "Import" && w <> "Export"
    ) rest in
    Some (None, modules)
  | _ -> None

(* Find which module name the cursor is on (by byte column).
   Falls back to the first module if cursor isn't on any. *)
let module_at_col modules col =
  match List.find_opt (fun (_, s, e) -> col >= s && col < e) modules with
  | Some (m, _, _) -> Some m
  | None ->
    match modules with
    | (m, _, _) :: _ -> Some m
    | [] -> None
