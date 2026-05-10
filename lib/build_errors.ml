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

(* Cached parsed entries and the input we last parsed (for cheap
   reparse skipping). Use [==] to identify the same input list. *)
let entries : entry list ref = ref []
let last_input : string list ref = ref []
let current_idx : int ref = ref (-1)

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

let refresh ~project_dir lines =
  if lines = !last_input then ()
  else begin
    last_input := lines;
    let new_entries = parse ~project_dir lines in
    (* Try to keep the F9 cursor pointing at the same entry across
       re-parses — important while the build is still streaming output
       and the user has already navigated. *)
    let preserved =
      if !current_idx < 0 then -1
      else
        match List.nth_opt !entries !current_idx with
        | None -> -1
        | Some old ->
          let rec find i = function
            | [] -> -1
            | (e : entry) :: _
              when e.file = old.file && e.line = old.line
                && e.col_start = old.col_start
                && e.severity = old.severity -> i
            | _ :: rest -> find (i + 1) rest
          in
          find 0 new_entries
    in
    entries := new_entries;
    current_idx := preserved
  end

let all () = !entries

let for_file path =
  let path = Tab.canonical_path path in
  List.filter (fun e -> e.file = path) !entries

let severity_for_line ~file ~line =
  let file = Tab.canonical_path file in
  let rank = function Error -> 2 | Warning -> 1 in
  List.fold_left (fun acc e ->
    if e.file = file && e.line = line then
      match acc with
      | None -> Some e.severity
      | Some s -> if rank e.severity > rank s then Some e.severity else acc
    else acc
  ) None !entries

let lookup_by_output_row row =
  List.find_opt (fun e ->
    row >= e.output_row_start && row <= e.output_row_end
  ) !entries

let current_index () =
  if !current_idx < 0 then None else Some !current_idx

let advance ~forward =
  let es = !entries in
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
  let es = !entries in
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

let clear () =
  entries := [];
  last_input := [];
  current_idx := -1

(* Cache of the last Errors-tab rendering's row → entry-index map. *)
let errors_tab_row_to_idx : int array ref = ref [||]

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
  ) !entries;
  let body = List.rev !rows in
  let map_arr = Array.of_list (List.rev !map) in
  errors_tab_row_to_idx := map_arr;
  (body, !active_header_row)

let lookup_errors_tab_row row =
  let m = !errors_tab_row_to_idx in
  if row < 0 || row >= Array.length m then None
  else
    let i = m.(row) in
    let es = !entries in
    if i < 0 || i >= List.length es then None
    else Some (List.nth es i)
