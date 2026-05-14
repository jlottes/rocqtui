(* Step-by-step project-wide search scanner.

   Called once per main-loop tick via [step]; consumes a small batch
   of files per call (~ms scale on typical projects) so the UI stays
   responsive while results stream in. No threads, no subprocess —
   the existing main loop is already select-based and a per-tick
   chunk fits that conventionally.

   Reads files from disk. Unsaved edits in open buffers are not
   reflected in project-wide results; the single-file Search.state
   on the active tab is the source of truth for the current buffer.
   Revisit if it becomes confusing. *)

let read_file path =
  try
    let ic = open_in path in
    let s = In_channel.input_all ic in
    close_in ic; Some s
  with _ -> None

(* Project-relative path for a file under [project_dir], or "" if it
   sits outside the project root. *)
let rel_to project_dir path =
  let prefix = project_dir ^ "/" in
  let plen = String.length prefix in
  if String.length path > plen
     && String.sub path 0 plen = prefix then
    String.sub path plen (String.length path - plen)
  else ""

(* Flatten a [File_listing] tree into a flat list of absolute file
   paths. Order follows the tree walk; project_search doesn't care
   about specific ordering beyond "deterministic". *)
let flatten_tree tree =
  let acc = ref [] in
  let rec walk = function
    | [] -> ()
    | File_listing.File e :: rest ->
      acc := e.full_path :: !acc;
      walk rest
    | File_listing.Dir (_, children) :: rest ->
      walk children;
      walk rest
  in
  walk tree;
  List.rev !acc

(* In-flight scan. *)
type scan = {
  project_dir : string;
  results : Search_results.t;
  mutable remaining : string list;
}

type t = {
  mutable scan : scan option;
}

let create () = { scan = None }

let cancel t =
  match t.scan with
  | None -> ()
  | Some s ->
    Search_results.set_scanning s.results false;
    t.scan <- None

let results t =
  match t.scan with
  | Some s -> Some s.results
  | None -> None

let scanning t =
  match t.scan with
  | Some s -> Search_results.scanning s.results
  | None -> false

let start t ~project_dir ~project_file ~query ~flags =
  cancel t;
  let tree = File_listing.enumerate
    ~project_dir
    ~project_file
    ~mode:File_listing.All in
  let files = flatten_tree tree in
  let results = Search_results.empty ~query ~flags in
  Search_results.set_scanning results true;
  t.scan <- Some {
    project_dir;
    results;
    remaining = files;
  }

(* Convert raw Search matches into match_locs with line text. The
   text was read once for the file; split it on newlines here. *)
let mk_match_locs text raw_matches =
  let lines = Array.of_list (String.split_on_char '\n' text) in
  let nlines = Array.length lines in
  Array.map (fun (m : Search.match_) ->
    let line = m.start_.line in
    let line_text =
      if line >= 0 && line < nlines then lines.(line) else ""
    in
    {
      Search_results.ml_line = line + 1;
      ml_col_start = m.start_.col;
      ml_col_end =
        if m.end_.line = line then m.end_.col
        else String.length line_text;
      ml_line_text = line_text;
    }
  ) raw_matches

let scan_one_file s path =
  let r = s.results in
  match read_file path with
  | None -> false
  | Some text ->
    let raw = Search.recompute_in_text text
      (Search_results.query r) (Search_results.flags r) in
    if Array.length raw = 0 then false
    else begin
      let mls = mk_match_locs text raw in
      Search_results.add_file r {
        Search_results.fm_path = path;
        fm_rel_path = rel_to s.project_dir path;
        fm_matches = mls;
      };
      true
    end

let step t =
  match t.scan with
  | None -> false
  | Some s when s.remaining = [] -> false  (* already drained *)
  | Some s ->
    let batch = 8 in
    let changed = ref false in
    let i = ref 0 in
    while !i < batch && s.remaining <> [] do
      let path = List.hd s.remaining in
      s.remaining <- List.tl s.remaining;
      if scan_one_file s path then changed := true;
      incr i
    done;
    if s.remaining = [] then begin
      Search_results.set_scanning s.results false;
      changed := true  (* header transitions from "scanning…" *)
    end;
    !changed
