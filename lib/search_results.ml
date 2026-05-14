(* Grep-style search result set, shared between single-file and
   project-wide search. Pure value type: no I/O, no buffer mutation.

   Designed as a streaming structure — [add_file] appends matches
   as a scanner produces them, the consumer reads [files] directly.
   For the file counts we encounter in real projects ([rocq dep] on
   the affine repo lists ~120 files), the O(n) [add_file] is fine;
   revisit if it shows up in a profile. *)

type match_loc = {
  ml_line : int;          (* 1-based, for display *)
  ml_col_start : int;     (* 0-based byte offset within ml_line_text *)
  ml_col_end : int;       (* exclusive *)
  ml_line_text : string;  (* the full source line *)
}

type file_matches = {
  fm_path : string;       (* absolute path *)
  fm_rel_path : string;   (* project-relative; "" if outside project *)
  fm_matches : match_loc array;
}

type t = {
  query : string;
  flags : Search.flags;
  mutable files : file_matches list;  (* in scan order *)
  mutable scanning : bool;
  mutable total : int;
  (* The F3 cursor, or None when no match has been visited. *)
  mutable current : (string * int) option;
}

let empty ~query ~flags = {
  query; flags;
  files = []; scanning = false; total = 0;
  current = None;
}

let query t = t.query
let flags t = t.flags
let total t = t.total
let scanning t = t.scanning
let files t = t.files
let current t = t.current
let set_scanning t b = t.scanning <- b

let add_file t fm =
  if Array.length fm.fm_matches > 0 then begin
    t.files <- t.files @ [fm];
    t.total <- t.total + Array.length fm.fm_matches
  end

let find_file t path =
  List.find_opt (fun fm -> fm.fm_path = path) t.files

let find_match t path idx =
  match find_file t path with
  | None -> None
  | Some fm ->
    if idx >= 0 && idx < Array.length fm.fm_matches
    then Some fm.fm_matches.(idx)
    else None

let set_current t cur = t.current <- cur

(* Cursor over the flattened (path, match_index, match_loc) sequence
   so [advance] doesn't have to materialize the whole list. *)
type cursor = {
  files_before : file_matches list;  (* visited file_matches, in reverse *)
  cur_file : file_matches option;
  cur_index : int;       (* index within cur_file.fm_matches *)
  files_after : file_matches list;
}

let first_cursor files =
  match files with
  | [] -> None
  | fm :: rest ->
    Some { files_before = []; cur_file = Some fm;
           cur_index = 0; files_after = rest }

let last_cursor files =
  let rec walk before = function
    | [] -> None
    | [fm] ->
      Some { files_before = before;
             cur_file = Some fm;
             cur_index = Array.length fm.fm_matches - 1;
             files_after = [] }
    | fm :: rest -> walk (fm :: before) rest
  in
  walk [] files

(* Locate a (path, index) cursor. Returns None if not present. *)
let cursor_of t path idx =
  let rec walk before = function
    | [] -> None
    | fm :: rest when fm.fm_path = path ->
      if idx >= 0 && idx < Array.length fm.fm_matches then
        Some { files_before = before;
               cur_file = Some fm;
               cur_index = idx;
               files_after = rest }
      else None
    | fm :: rest -> walk (fm :: before) rest
  in
  walk [] t.files

let step_forward c =
  match c.cur_file with
  | None -> c
  | Some fm ->
    if c.cur_index + 1 < Array.length fm.fm_matches then
      { c with cur_index = c.cur_index + 1 }
    else match c.files_after with
      | [] -> c  (* end of stream — caller wraps *)
      | next :: rest ->
        { files_before = fm :: c.files_before;
          cur_file = Some next;
          cur_index = 0;
          files_after = rest }

let step_backward c =
  match c.cur_file with
  | None -> c
  | Some _ ->
    if c.cur_index > 0 then
      { c with cur_index = c.cur_index - 1 }
    else match c.files_before with
      | [] -> c  (* start of stream — caller wraps *)
      | prev :: rest ->
        { files_before = rest;
          cur_file = Some prev;
          cur_index = Array.length prev.fm_matches - 1;
          files_after = (match c.cur_file with
                         | Some fm -> fm :: c.files_after
                         | None -> c.files_after) }

let advance t ~forward =
  if t.total = 0 then None
  else
    let base =
      match t.current with
      | Some (p, i) -> cursor_of t p i
      | None -> None
    in
    let stepped =
      match base, forward with
      | None, true -> first_cursor t.files
      | None, false -> last_cursor t.files
      | Some c, true ->
        let c' = step_forward c in
        (* Detect "didn't move" — we were at the end. Wrap. *)
        if c'.cur_file = c.cur_file && c'.cur_index = c.cur_index
        then first_cursor t.files
        else Some c'
      | Some c, false ->
        let c' = step_backward c in
        if c'.cur_file = c.cur_file && c'.cur_index = c.cur_index
        then last_cursor t.files
        else Some c'
    in
    match stepped with
    | None -> None
    | Some c ->
      match c.cur_file with
      | None -> None
      | Some fm ->
        let m = fm.fm_matches.(c.cur_index) in
        t.current <- Some (fm.fm_path, c.cur_index);
        Some (fm.fm_path, m)

(* Build a single-file [t] from an existing [Search.state] + the
   underlying buffer (whose [get_line] we use to materialize each
   match's source line). For multi-line matches the line_text is the
   start line; ml_col_end is clamped to the start line's length. *)
let of_single_file ~path ~rel_path (s : Search.state) buf =
  let mls = Array.map (fun (m : Search.match_) ->
    let line = m.start_.line in
    let line_text = Buffer.get_line buf line in
    {
      ml_line = line + 1;
      ml_col_start = m.start_.col;
      ml_col_end =
        if m.end_.line = line then m.end_.col
        else String.length line_text;
      ml_line_text = line_text;
    }
  ) s.matches in
  let fm = { fm_path = path; fm_rel_path = rel_path; fm_matches = mls } in
  let t = empty ~query:s.query ~flags:s.flags in
  if Array.length mls > 0 then begin
    t.files <- [fm];
    t.total <- Array.length mls;
    if s.current >= 0 && s.current < Array.length mls then
      t.current <- Some (path, s.current)
  end;
  t
