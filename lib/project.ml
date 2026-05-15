(* Single source of truth for reading and editing _RocqProject /
   _CoqProject files. Callers get a [t] from [read] / [find] / [find_for]
   and read out [load_paths], [listed_files], [args], [project_dir],
   [path] directly — no module-level helpers re-parse the file.

   The line-by-line structure of the file is preserved only inside
   [toggle_member], which round-trips unchanged lines verbatim and
   re-emits toggled lines in a canonical form. *)

let filenames = ["_RocqProject"; "_CoqProject"]

type load_path = {
  implicit : bool;          (* -R = true, -Q = false *)
  physical_dir : string;
  logical_prefix : string;
}

type t = {
  path : string;
  project_dir : string;
  load_paths : load_path list;
  listed_files : string list;   (* abs paths, uncommented only *)
  args : string list;           (* args ready to pass to coqidetop *)
}

(* --- Path helpers --- *)

let resolve_path project_dir p =
  if p = "." then project_dir
  else if Filename.is_relative p then Filename.concat project_dir p
  else p

(* --- Tokenizer ---
   Whitespace splits tokens; "..." quotes a literal string (no escapes,
   matching Rocq's own coqProject_file.ml). Comments are handled at the
   line level (see [parse_line] / [classify_line]) before this runs. *)
let tokenize s =
  let toks = ref [] in
  let buf = Stdlib.Buffer.create 64 in
  let in_quote = ref false in
  let flush () =
    if Stdlib.Buffer.length buf > 0 then begin
      toks := Stdlib.Buffer.contents buf :: !toks;
      Stdlib.Buffer.clear buf
    end
  in
  String.iter (fun c ->
    if !in_quote then begin
      if c = '"' then in_quote := false
      else Stdlib.Buffer.add_char buf c
    end else if c = '"' then in_quote := true
    else if c = ' ' || c = '\t' then flush ()
    else Stdlib.Buffer.add_char buf c
  ) s;
  flush ();
  List.rev !toks

(* --- Line classification ---
   The minimal per-line view we need internally:
   - [Lf_file] = a line consisting of a single .v-ending token (possibly
     commented). Carries the relative path verbatim — that's the key we
     compare against on membership / toggle.
   - [Lf_directive] = a line with at least one token starting with '-'
     (or any other content); contributes to load paths / args.
   - [Lf_blank] = empty or comment-only line. *)
type line_form =
  | Lf_file of { commented : bool; rel : string }
  | Lf_directive of { tokens : string list }   (* uncommented only *)
  | Lf_blank

let classify_line raw =
  let s = String.trim raw in
  if s = "" then Lf_blank
  else
    let (commented, body) =
      if s.[0] = '#' then
        (true, String.trim (String.sub s 1 (String.length s - 1)))
      else (false, s)
    in
    if body = "" then Lf_blank
    else
      let toks = tokenize body in
      let is_listed_file = function
        | [t] when String.length t >= 2
                && String.sub t (String.length t - 2) 2 = ".v"
                && t.[0] <> '-' -> Some t
        | _ -> None
      in
      match is_listed_file toks with
      | Some rel -> Lf_file { commented; rel }
      | None ->
        if commented then Lf_blank
        else Lf_directive { tokens = toks }

(* --- Build a [t] from a list of raw lines ---
   Order of [load_paths] and [args] follows file order. *)
let build path lines =
  let project_dir = Filename.dirname path in
  let load_paths = ref [] in
  let listed_files = ref [] in
  let args = ref [] in
  let push_arg a = args := a :: !args in
  let consume_directive toks =
    let rec walk = function
      | [] -> ()
      | "-R" :: dir :: logical :: rest ->
        load_paths := { implicit = true;
                        physical_dir = resolve_path project_dir dir;
                        logical_prefix = logical } :: !load_paths;
        push_arg "-R"; push_arg (resolve_path project_dir dir);
        push_arg logical;
        walk rest
      | "-Q" :: dir :: logical :: rest ->
        load_paths := { implicit = false;
                        physical_dir = resolve_path project_dir dir;
                        logical_prefix = logical } :: !load_paths;
        push_arg "-Q"; push_arg (resolve_path project_dir dir);
        push_arg logical;
        walk rest
      | "-arg" :: a :: rest ->
        (* -arg values may be space-separated within a single quoted
           token (e.g. -arg "-w -foo"); split them. *)
        List.iter (fun p ->
          let p = String.trim p in
          if p <> "" then push_arg p
        ) (String.split_on_char ' ' a);
        walk rest
      | flag :: rest when String.length flag > 0 && flag.[0] = '-' ->
        push_arg flag;
        walk rest
      | _ :: rest -> walk rest  (* skip unknown tokens *)
    in
    walk toks
  in
  List.iter (fun raw ->
    match classify_line raw with
    | Lf_blank -> ()
    | Lf_file { commented = false; rel } ->
      listed_files := resolve_path project_dir rel :: !listed_files
    | Lf_file { commented = true; _ } -> ()
    | Lf_directive { tokens } -> consume_directive tokens
  ) lines;
  { path;
    project_dir;
    load_paths = List.rev !load_paths;
    listed_files = List.rev !listed_files;
    args = List.rev !args }

(* --- Reading --- *)

let read_lines path =
  In_channel.with_open_text path (fun ic ->
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> ());
    List.rev !lines)

let read path = build path (read_lines path)

(* Walk upward from [dir] looking for a project file. *)
let find dir =
  let rec search d =
    match List.find_opt (fun n -> Sys.file_exists (Filename.concat d n))
            filenames with
    | Some n -> Some (read (Filename.concat d n))
    | None ->
      let parent = Filename.dirname d in
      if parent = d then None else search parent
  in
  search dir

let find_for ?filename () =
  let cwd = Sys.getcwd () in
  match find cwd with
  | Some _ as r -> r
  | None ->
    match filename with
    | None -> None
    | Some f ->
      let abs = if Filename.is_relative f then Filename.concat cwd f else f in
      let dir = Filename.dirname abs in
      if dir = cwd then None else find dir

(* --- Filesystem walks --- *)

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

let all_v_files t =
  let files = ref [] in
  List.iter (fun e ->
    files := find_v_files e.physical_dir @ !files
  ) t.load_paths;
  List.sort_uniq String.compare !files

(* --- Module resolution --- *)

let resolve_module t modname =
  let parts = String.split_on_char '.' modname in
  let path_of_parts dir parts =
    let relpath = String.concat "/" parts ^ ".v" in
    let full = Filename.concat dir relpath in
    if Sys.file_exists full then Some full else None
  in
  let rec try_entries = function
    | [] -> None
    | (e : load_path) :: rest ->
      let prefix_parts = String.split_on_char '.' e.logical_prefix in
      let prefix_len = List.length prefix_parts in
      let stripped =
        if List.length parts > prefix_len then
          let rec matches a b = match a, b with
            | [], _ -> true
            | x :: xs, y :: ys when x = y -> matches xs ys
            | _ -> false
          in
          if matches prefix_parts parts then
            let rest_parts =
              List.filteri (fun i _ -> i >= prefix_len) parts in
            path_of_parts e.physical_dir rest_parts
          else None
        else None
      in
      (match stripped with
       | Some _ -> stripped
       | None ->
         if e.implicit then
           match path_of_parts e.physical_dir parts with
           | Some _ as r -> r
           | None -> try_entries rest
         else
           try_entries rest)
  in
  try_entries t.load_paths

(* --- Membership and toggle --- *)

type membership = [`Active | `Commented | `Absent]

let membership t ~rel =
  let lines = read_lines t.path in
  let found = ref `Absent in
  List.iter (fun raw ->
    match classify_line raw with
    | Lf_file { rel = r; commented } when r = rel ->
      (* If we've already seen a match, an active one wins over a
         commented one (so toggle prefers to deactivate the live entry).
         Otherwise keep what we found. *)
      (match !found, commented with
       | `Active, _ -> ()
       | _, false -> found := `Active
       | `Absent, true -> found := `Commented
       | `Commented, true -> ())
    | _ -> ()
  ) lines;
  !found

type toggle_outcome = [`Added | `Removed]

(* [toggle_member] is the only function that needs a line-preserving
   view of the file. We read lines, mutate (or insert) the matching
   entry, write back, then re-read into a fresh [t]. *)
let toggle_member t ~rel =
  let lines = read_lines t.path in
  let arr = Array.of_list lines in
  let n = Array.length arr in
  (* Locate the entry. Prefer an active match for commenting; only fall
     back to a commented match when no active match exists. *)
  let active_idx = ref None in
  let commented_idx = ref None in
  let last_file_idx = ref (-1) in
  let first_gt_idx = ref None in
  for i = 0 to n - 1 do
    match classify_line arr.(i) with
    | Lf_file { commented; rel = r } ->
      if r = rel then begin
        if not commented && !active_idx = None then active_idx := Some i
        else if commented && !commented_idx = None then commented_idx := Some i
      end;
      last_file_idx := i;
      if !first_gt_idx = None && String.compare r rel > 0 then
        first_gt_idx := Some i
    | _ -> ()
  done;
  let (new_lines, outcome) = match !active_idx, !commented_idx with
    | Some i, _ ->
      (* Comment out the existing active entry. *)
      let out = Array.copy arr in
      out.(i) <- "# " ^ rel;
      (Array.to_list out, `Removed)
    | None, Some i ->
      (* Uncomment the existing commented entry. *)
      let out = Array.copy arr in
      out.(i) <- rel;
      (Array.to_list out, `Added)
    | None, None ->
      (* Insert a new line. Sorted position: before the first .v line
         whose rel sorts greater; else after the last .v line; else at
         end of file. *)
      let insert_at = match !first_gt_idx with
        | Some i -> i
        | None ->
          if !last_file_idx >= 0 then !last_file_idx + 1 else n
      in
      let prefix = Array.sub arr 0 insert_at in
      let suffix = Array.sub arr insert_at (n - insert_at) in
      (Array.to_list prefix @ [rel] @ Array.to_list suffix, `Added)
  in
  let oc = open_out t.path in
  List.iter (fun line ->
    output_string oc line;
    output_char oc '\n'
  ) new_lines;
  close_out oc;
  (read t.path, outcome)
