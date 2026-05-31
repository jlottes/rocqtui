type severity = Error | Warning

type entry = {
  file : string;
  line : int;
  col_start : int;
  col_end : int;
  severity : severity;
  message : string;
  output_row_start : int;
  output_row_end : int;
}

(* Per-file slot: the entries pinned to that file plus the .vo mtime we
   observed when the slot was last written. The mtime stamp lets us
   detect a successful rebuild of the file — when the .vo advances past
   what we stamped, the slot is stale and gets dropped (the file is
   clean now, even if the current build's output never said so).

   A new build does NOT wipe slots up-front. A file's slot is only
   replaced when fresh entries for it are parsed from the current
   build's output, or dropped when its .vo advances. Files that the
   build never touched keep their prior errors visible. *)
type slot = {
  entries : entry list;
  vo_mtime_at_record : float option;
}

let slots : (string, slot) Hashtbl.t = Hashtbl.create 16
(* Insertion order of files, preserved across builds. New files append;
   surviving files keep their position. *)
let file_order : string list ref = ref []
(* Cached parse input for cheap reparse skipping. *)
let last_input : string list ref = ref []
let current_idx : int ref = ref (-1)

let vo_of_v v_path =
  if Filename.check_suffix v_path ".v" then
    Filename.chop_suffix v_path ".v" ^ ".vo"
  else v_path ^ "o"

let stat_mtime path =
  try Some (Unix.stat path).Unix.st_mtime with _ -> None

let vo_mtime_for_v v_path = stat_mtime (vo_of_v v_path)

(* Flattened entry list in [file_order], for callers that expect a
   single sequence (Errors-tab listing, F9 cursor). *)
let flatten () =
  List.concat_map (fun f ->
    match Hashtbl.find_opt slots f with
    | Some s -> s.entries
    | None -> []
  ) !file_order

let prune_missing_files () =
  file_order := List.filter (Hashtbl.mem slots) !file_order

let resolve_path ~project_dir p =
  let joined =
    if Filename.is_relative p then Filename.concat project_dir p else p
  in
  Tab.canonical_path joined

(* Parse one header line: `File "<path>", line <N>, characters <M>-<K>:`.
   Returns (path, line, col_start, col_end). *)
let parse_header line =
  let prefix = "File \"" in
  let plen = String.length prefix in
  let llen = String.length line in
  if llen < plen || String.sub line 0 plen <> prefix then None
  else
    match String.index_from_opt line plen '"' with
    | None -> None
    | Some end_q ->
      let path = String.sub line plen (end_q - plen) in
      let rest = String.sub line (end_q + 1) (llen - end_q - 1) in
      (try
         Some (Scanf.sscanf rest ", line %d, characters %d-%d"
                 (fun l cs ce -> (path, l, cs, ce)))
       with _ -> None)

let starts_with s pfx =
  let lp = String.length pfx in
  String.length s >= lp && String.sub s 0 lp = pfx

(* A `make` recursion line: `make:`, `make[1]:`, etc. *)
let is_make_line line =
  starts_with line "make:" || starts_with line "make["

let detect_severity msg_lines =
  let rec scan = function
    | [] -> None
    | l :: rest ->
      let l = String.trim l in
      if starts_with l "Warning" then Some Warning
      else if starts_with l "Error" then Some Error
      else scan rest
  in
  scan msg_lines

let parse ~project_dir lines =
  let arr = Array.of_list lines in
  let n = Array.length arr in
  let out = ref [] in
  let i = ref 0 in
  while !i < n do
    let line = arr.(!i) in
    (match parse_header line with
     | None -> incr i
     | Some (path, lno, cs, ce) ->
       let header_row = !i in
       let j = ref (!i + 1) in
       let msg_lines = ref [] in
       let stop = ref false in
       while not !stop && !j < n do
         let l = arr.(!j) in
         if parse_header l <> None then stop := true
         else if is_make_line l then stop := true
         else begin
           msg_lines := l :: !msg_lines;
           incr j
         end
       done;
       let msg_rev = !msg_lines in
       let msg_lines = List.rev msg_rev in
       (match detect_severity msg_lines with
        | None -> ()  (* No Error/Warning prefix — drop *)
        | Some sev ->
          let trimmed_msg = String.trim (String.concat "\n" msg_lines) in
          let last_consumed =
            (* Highest j we actually consumed — !j is one past last,
               unless we stopped at boundary or end. *)
            !j - 1
          in
          let entry = {
            file = resolve_path ~project_dir path;
            line = lno; col_start = cs; col_end = ce;
            severity = sev;
            message = trimmed_msg;
            output_row_start = header_row;
            output_row_end = max header_row last_consumed;
          } in
          out := entry :: !out);
       i := !j);
  done;
  List.rev !out

(* Preserve the F9 cursor across slot mutations by matching the prior
   active entry's identity inside the new flattened list. *)
let preserve_cursor old_active =
  match old_active with
  | None -> ()
  | Some (old : entry) ->
    let rec find i = function
      | [] -> current_idx := -1
      | (e : entry) :: _
        when e.file = old.file && e.line = old.line
          && e.col_start = old.col_start
          && e.severity = old.severity -> current_idx := i
      | _ :: rest -> find (i + 1) rest
    in
    find 0 (flatten ())

let active_entry () =
  if !current_idx < 0 then None
  else List.nth_opt (flatten ()) !current_idx

let refresh ~project_dir lines =
  if lines = !last_input then ()
  else begin
    last_input := lines;
    let old_active = active_entry () in
    let parsed = parse ~project_dir lines in
    (* Group parsed entries by file, preserving in-build order. *)
    let by_file = Hashtbl.create 8 in
    let order = ref [] in
    List.iter (fun (e : entry) ->
      if not (Hashtbl.mem by_file e.file) then begin
        Hashtbl.add by_file e.file [e];
        order := e.file :: !order
      end else
        Hashtbl.replace by_file e.file (e :: Hashtbl.find by_file e.file)
    ) parsed;
    (* Replace slot for every file mentioned in this parse. Files NOT
       mentioned keep their prior slot — that's the whole point. *)
    List.iter (fun f ->
      let entries = List.rev (Hashtbl.find by_file f) in
      Hashtbl.replace slots f
        { entries; vo_mtime_at_record = vo_mtime_for_v f };
      if not (List.mem f !file_order) then
        file_order := !file_order @ [f]
    ) (List.rev !order);
    preserve_cursor old_active
  end

(* Walk every slot; drop those whose file's .vo has advanced past the
   mtime we stamped — that's a successful rebuild and the errors are no
   longer current. Returns true if anything changed. *)
let recheck_vo () =
  let old_active = active_entry () in
  let dropped = ref false in
  let to_drop = ref [] in
  Hashtbl.iter (fun f s ->
    match vo_mtime_for_v f, s.vo_mtime_at_record with
    | Some now, Some then_ when now > then_ -> to_drop := f :: !to_drop
    | Some _, None -> to_drop := f :: !to_drop
    | _ -> ()
  ) slots;
  List.iter (fun f ->
    Hashtbl.remove slots f;
    dropped := true
  ) !to_drop;
  if !dropped then begin
    prune_missing_files ();
    preserve_cursor old_active
  end;
  !dropped

let all () = flatten ()

let for_file path =
  let path = Tab.canonical_path path in
  match Hashtbl.find_opt slots path with
  | Some s -> s.entries
  | None -> []

let severity_for_line ~file ~line =
  let file = Tab.canonical_path file in
  match Hashtbl.find_opt slots file with
  | None -> None
  | Some s ->
    let rank = function Error -> 2 | Warning -> 1 in
    List.fold_left (fun acc e ->
      if e.line = line then
        match acc with
        | None -> Some e.severity
        | Some s -> if rank e.severity > rank s then Some e.severity else acc
      else acc
    ) None s.entries

let lookup_by_output_row row =
  List.find_opt (fun e ->
    row >= e.output_row_start && row <= e.output_row_end
  ) (flatten ())

let current_index () =
  if !current_idx < 0 then None else Some !current_idx

let advance ~forward =
  let es = flatten () in
  match es with
  | [] -> current_idx := -1; None
  | _ ->
    let len = List.length es in
    let next =
      if !current_idx < 0 then (if forward then 0 else len - 1)
      else
        let d = if forward then 1 else -1 in
        ((!current_idx + d) mod len + len) mod len
    in
    current_idx := next;
    Some (List.nth es next)

let set_current target =
  let es = flatten () in
  let rec find i = function
    | [] -> ()
    | e :: rest ->
      if e == target || (e.file = target.file
                          && e.line = target.line
                          && e.col_start = target.col_start
                          && e.severity = target.severity)
      then current_idx := i
      else find (i + 1) rest
  in
  find 0 es

(* Drop every slot. Project-switch / explicit reset only. *)
let clear () =
  Hashtbl.reset slots;
  file_order := [];
  last_input := [];
  current_idx := -1

(* Cache of the last Errors-tab rendering's row → entry-index map. *)
let errors_tab_row_to_idx : int array ref = ref [||]

(* Project-relative .v paths of every file with at least one Error
   entry in the current parse. Excludes warning-only files. Result is
   deduped, order is first-seen. *)
let error_files ~project_dir =
  let seen = Hashtbl.create 8 in
  let out = ref [] in
  List.iter (fun e ->
    if e.severity = Error then begin
      let rel =
        let project_dir = Tab.canonical_path project_dir in
        let prefix = project_dir ^ "/" in
        let plen = String.length prefix in
        if String.length e.file >= plen
           && String.length prefix > 0
           && String.sub e.file 0 plen = prefix then
          String.sub e.file plen (String.length e.file - plen)
        else e.file
      in
      if not (Hashtbl.mem seen rel) then begin
        Hashtbl.add seen rel ();
        out := rel :: !out
      end
    end
  ) (flatten ());
  List.rev !out

let format_relpath ~project_dir path =
  let project_dir = Tab.canonical_path project_dir in
  let prefix = project_dir ^ "/" in
  let plen = String.length prefix in
  if String.length path >= plen
     && String.length prefix > 0
     && String.sub path 0 plen = prefix then
    String.sub path plen (String.length path - plen)
  else path

let glyph_of sev = match sev with
  | Error -> "\xe2\x9c\x98"  (* ✘ *)
  | Warning -> "\xe2\x9a\xa0"  (* ⚠ *)

let render_errors_tab ~project_dir =
  let rows = ref [] in
  let map = ref [] in
  let active_header_row = ref None in
  let row_count = ref 0 in
  let emit_line idx (line : Styled.line) =
    rows := line :: !rows;
    map := idx :: !map;
    incr row_count
  in
  let attrs = Theme.attrs () in
  List.iteri (fun i (e : entry) ->
    let is_active = !current_idx = i in
    let glyph = glyph_of e.severity in
    let glyph_attr = match e.severity with
      | Error -> attrs.ga_marker_error
      | Warning -> attrs.ga_marker_warning
    in
    let relp = format_relpath ~project_dir e.file in
    let msg_lines = String.split_on_char '\n' e.message in
    let first = match msg_lines with [] -> "" | l :: _ -> l in
    let header_mark =
      if is_active then Styled.style "\xe2\x96\xbe " glyph_attr  (* ▾  *)
      else Styled.plain "  "
    in
    let location = Printf.sprintf "%s:%d:%d" relp e.line e.col_start in
    let header = Styled.concat [
      header_mark;
      Styled.style glyph glyph_attr;
      Styled.plain " ";
      Styled.style location attrs.ga_comment;
      Styled.plain "  ";
      Styled.plain first;
    ] in
    if is_active then active_header_row := Some !row_count;
    emit_line i header;
    if is_active then
      List.iteri (fun k l ->
        if k > 0 && l <> "" then
          emit_line i (Styled.plain ("      " ^ l))
      ) msg_lines
  ) (flatten ());
  let body = List.rev !rows in
  let map_arr = Array.of_list (List.rev !map) in
  errors_tab_row_to_idx := map_arr;
  (body, !active_header_row)

let lookup_errors_tab_row row =
  let m = !errors_tab_row_to_idx in
  if row < 0 || row >= Array.length m then None
  else
    let i = m.(row) in
    let es = flatten () in
    if i < 0 || i >= List.length es then None
    else Some (List.nth es i)
