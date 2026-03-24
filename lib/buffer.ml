type t = {
  mutable lines : string array;
  mutable num_lines : int;
  mutable cur_line : int;
  mutable cur_col : int;  (* byte offset within current line *)
  mutable desired_vcol : int;  (* desired screen column for vertical movement *)
  mutable scroll_top : int;
  mutable hscroll : int;  (* horizontal scroll in screen columns *)
  mutable modified : bool;
  mutable filename : string option;
  mutable cut_buf : string list;
  mutable anchor : (int * int) option;  (* (line, col) or None *)
}

let create () =
  { lines = Array.make 64 "";
    num_lines = 1;
    cur_line = 0;
    cur_col = 0;
    desired_vcol = 0;
    scroll_top = 0;
    hscroll = 0;
    modified = false;
    filename = None;
    cut_buf = [];
    anchor = None }

let ensure_capacity buf n =
  if n > Array.length buf.lines then begin
    let new_cap = max n (Array.length buf.lines * 2) in
    let new_arr = Array.make new_cap "" in
    Array.blit buf.lines 0 new_arr 0 buf.num_lines;
    buf.lines <- new_arr
  end

let update_desired_vcol buf =
  buf.desired_vcol <- Utf8.byte_to_col buf.lines.(buf.cur_line) buf.cur_col

let load_file path =
  let ic = open_in path in
  let buf = create () in
  buf.filename <- Some path;
  let lines = ref [] in
  (try while true do lines := input_line ic :: !lines done
   with End_of_file -> ());
  close_in ic;
  let lines = List.rev !lines in
  let n = max 1 (List.length lines) in
  ensure_capacity buf n;
  List.iteri (fun i l -> buf.lines.(i) <- l) lines;
  buf.num_lines <- n;
  buf.modified <- false;
  buf

let save buf =
  match buf.filename with
  | None -> false
  | Some path ->
    let oc = open_out path in
    for i = 0 to buf.num_lines - 1 do
      output_string oc buf.lines.(i);
      output_char oc '\n'
    done;
    close_out oc;
    buf.modified <- false;
    true

let save_as buf path =
  buf.filename <- Some path;
  ignore (save buf)

let filename buf = buf.filename
let set_filename buf f = buf.filename <- Some f
let modified buf = buf.modified
let line_count buf = buf.num_lines
let get_line buf i = buf.lines.(i)
let cursor buf = (buf.cur_line, buf.cur_col)
let scroll_top buf = buf.scroll_top
let set_scroll_top buf v = buf.scroll_top <- v
let hscroll buf = buf.hscroll
let set_hscroll buf v = buf.hscroll <- max 0 v

let clamp_col buf =
  let len = String.length buf.lines.(buf.cur_line) in
  if buf.cur_col > len then buf.cur_col <- len

(* Move cur_col to match desired_vcol on current line *)
let restore_vcol buf =
  buf.cur_col <- Utf8.col_to_byte buf.lines.(buf.cur_line) buf.desired_vcol

let move_left buf =
  let line = buf.lines.(buf.cur_line) in
  if buf.cur_col > 0 then begin
    buf.cur_col <- Utf8.prev line buf.cur_col;
    update_desired_vcol buf
  end else if buf.cur_line > 0 then begin
    buf.cur_line <- buf.cur_line - 1;
    buf.cur_col <- String.length buf.lines.(buf.cur_line);
    update_desired_vcol buf
  end

let move_right buf =
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  if buf.cur_col < len then begin
    buf.cur_col <- Utf8.next line buf.cur_col;
    update_desired_vcol buf
  end else if buf.cur_line < buf.num_lines - 1 then begin
    buf.cur_line <- buf.cur_line + 1;
    buf.cur_col <- 0;
    update_desired_vcol buf
  end

let move_up buf =
  if buf.cur_line > 0 then begin
    buf.cur_line <- buf.cur_line - 1;
    restore_vcol buf
  end

let move_down buf =
  if buf.cur_line < buf.num_lines - 1 then begin
    buf.cur_line <- buf.cur_line + 1;
    restore_vcol buf
  end

let move_home buf =
  buf.cur_col <- 0;
  update_desired_vcol buf

let move_end buf =
  buf.cur_col <- String.length buf.lines.(buf.cur_line);
  update_desired_vcol buf

let move_page_up buf rows =
  let target = max 0 (buf.cur_line - rows) in
  buf.cur_line <- target;
  buf.scroll_top <- max 0 (buf.scroll_top - rows);
  restore_vcol buf

let move_page_down buf rows =
  let target = min (buf.num_lines - 1) (buf.cur_line + rows) in
  buf.cur_line <- target;
  buf.scroll_top <- min (max 0 (buf.num_lines - rows)) (buf.scroll_top + rows);
  restore_vcol buf

let move_to_byte_offset buf offset =
  let off = ref 0 in
  let found_line = ref 0 in
  let found_off = ref 0 in
  let i = ref 0 in
  while !i < buf.num_lines do
    let line_len = String.length buf.lines.(!i) + 1 in
    if !off + line_len <= offset && !i < buf.num_lines - 1 then begin
      off := !off + line_len;
      incr i
    end else begin
      found_line := !i;
      found_off := !off;
      i := buf.num_lines  (* break *)
    end
  done;
  buf.cur_line <- !found_line;
  buf.cur_col <- min (offset - !found_off) (String.length buf.lines.(!found_line));
  update_desired_vcol buf

let text buf =
  let parts = Array.to_list (Array.sub buf.lines 0 buf.num_lines) in
  String.concat "\n" parts ^ "\n"

(* Convert (line, col) to byte offset in the buffer text *)
let pos_to_offset buf line col =
  let off = ref 0 in
  for i = 0 to line - 1 do
    off := !off + String.length buf.lines.(i) + 1
  done;
  !off + col

let set_anchor buf =
  buf.anchor <- Some (buf.cur_line, buf.cur_col)

let clear_selection buf =
  buf.anchor <- None

let selection buf =
  match buf.anchor with
  | None -> None
  | Some (al, ac) ->
    let a_off = pos_to_offset buf al ac in
    let c_off = pos_to_offset buf buf.cur_line buf.cur_col in
    if a_off = c_off then None
    else Some (min a_off c_off, max a_off c_off)

let selected_text buf =
  match selection buf with
  | None -> None
  | Some (s, e) ->
    let t = text buf in
    Some (String.sub t s (e - s))

let delete_selection buf =
  match selection buf with
  | None -> None
  | Some (s, e) ->
    let t = text buf in
    let deleted = String.sub t s (e - s) in
    (* Rebuild lines from the text with the selection removed *)
    let new_text = String.sub t 0 s ^ String.sub t e (String.length t - e) in
    let new_lines = String.split_on_char '\n' new_text in
    let n = List.length new_lines in
    let n = if n = 0 then 1 else n in
    ensure_capacity buf n;
    List.iteri (fun i l -> buf.lines.(i) <- l) new_lines;
    (* Clear any leftover lines *)
    for i = n to buf.num_lines - 1 do buf.lines.(i) <- "" done;
    buf.num_lines <- n;
    (* Position cursor at the start of the deleted region *)
    move_to_byte_offset buf s;
    buf.anchor <- None;
    buf.modified <- true;
    Some deleted

let insert_char buf ch =
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  let new_line =
    String.sub line 0 col
    ^ String.make 1 ch
    ^ String.sub line col (len - col)
  in
  buf.lines.(buf.cur_line) <- new_line;
  buf.cur_col <- col + 1;
  buf.modified <- true

let insert_newline buf =
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  let before = String.sub line 0 col in
  let after = String.sub line col (len - col) in
  ensure_capacity buf (buf.num_lines + 1);
  (* Shift lines down *)
  for i = buf.num_lines downto buf.cur_line + 2 do
    buf.lines.(i) <- buf.lines.(i - 1)
  done;
  buf.lines.(buf.cur_line) <- before;
  buf.lines.(buf.cur_line + 1) <- after;
  buf.num_lines <- buf.num_lines + 1;
  buf.cur_line <- buf.cur_line + 1;
  buf.cur_col <- 0;
  buf.modified <- true

let delete_char_before buf =
  if buf.cur_col > 0 then begin
    let line = buf.lines.(buf.cur_line) in
    let len = String.length line in
    let col = min buf.cur_col len in
    let prev_col = Utf8.prev line col in
    buf.lines.(buf.cur_line) <-
      String.sub line 0 prev_col
      ^ String.sub line col (len - col);
    buf.cur_col <- prev_col;
    update_desired_vcol buf;
    buf.modified <- true
  end else if buf.cur_line > 0 then begin
    (* Join with previous line *)
    let prev = buf.lines.(buf.cur_line - 1) in
    let cur = buf.lines.(buf.cur_line) in
    let new_col = String.length prev in
    buf.lines.(buf.cur_line - 1) <- prev ^ cur;
    (* Shift lines up *)
    for i = buf.cur_line to buf.num_lines - 2 do
      buf.lines.(i) <- buf.lines.(i + 1)
    done;
    buf.lines.(buf.num_lines - 1) <- "";
    buf.num_lines <- buf.num_lines - 1;
    buf.cur_line <- buf.cur_line - 1;
    buf.cur_col <- new_col;
    buf.modified <- true
  end

let delete_char_at buf =
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  if col < len then begin
    let next_col = Utf8.next line col in
    buf.lines.(buf.cur_line) <-
      String.sub line 0 col
      ^ String.sub line next_col (len - next_col);
    buf.modified <- true
  end else if buf.cur_line < buf.num_lines - 1 then begin
    (* Join with next line *)
    buf.lines.(buf.cur_line) <- line ^ buf.lines.(buf.cur_line + 1);
    for i = buf.cur_line + 1 to buf.num_lines - 2 do
      buf.lines.(i) <- buf.lines.(i + 1)
    done;
    buf.lines.(buf.num_lines - 1) <- "";
    buf.num_lines <- buf.num_lines - 1;
    buf.modified <- true
  end

let cut_line buf =
  let line = buf.lines.(buf.cur_line) in
  buf.cut_buf <- buf.cut_buf @ [line];
  if buf.num_lines > 1 then begin
    for i = buf.cur_line to buf.num_lines - 2 do
      buf.lines.(i) <- buf.lines.(i + 1)
    done;
    buf.lines.(buf.num_lines - 1) <- "";
    buf.num_lines <- buf.num_lines - 1;
    if buf.cur_line >= buf.num_lines then
      buf.cur_line <- buf.num_lines - 1;
    clamp_col buf
  end else begin
    buf.lines.(0) <- "";
    buf.cur_col <- 0
  end;
  buf.modified <- true

let paste buf =
  match buf.cut_buf with
  | [] -> ()
  | lines ->
    let n = List.length lines in
    ensure_capacity buf (buf.num_lines + n);
    (* Shift lines down to make room at current line *)
    for i = buf.num_lines - 1 + n downto buf.cur_line + n do
      buf.lines.(i) <- buf.lines.(i - n)
    done;
    List.iteri (fun i l ->
      buf.lines.(buf.cur_line + i) <- l
    ) lines;
    buf.num_lines <- buf.num_lines + n;
    clamp_col buf;
    buf.modified <- true;
    buf.cut_buf <- []

let is_ident_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') || c = '_' || c = '\'' || c = '.'

let word_at_cursor buf =
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  if col >= len then None
  else if not (is_ident_char line.[col]) then None
  else begin
    (* Expand left *)
    let l = ref col in
    while !l > 0 && is_ident_char line.[!l - 1] do decr l done;
    (* Expand right *)
    let r = ref col in
    while !r < len && is_ident_char line.[!r] do incr r done;
    let word = String.sub line !l (!r - !l) in
    (* Trim trailing dots (qualified name separator vs sentence end) *)
    let word = if String.length word > 0 && word.[String.length word - 1] = '.'
      then String.sub word 0 (String.length word - 1) else word in
    if word = "" then None else Some word
  end

let ensure_visible buf visible_rows =
  if buf.cur_line < buf.scroll_top then
    buf.scroll_top <- buf.cur_line
  else if buf.cur_line >= buf.scroll_top + visible_rows then
    buf.scroll_top <- buf.cur_line - visible_rows + 1

let ensure_visible_h buf visible_rows visible_cols =
  ensure_visible buf visible_rows;
  let line = buf.lines.(buf.cur_line) in
  let cursor_vcol = Utf8.byte_to_col line buf.cur_col in
  (* Keep some margin when scrolling horizontally *)
  let margin = min 4 (visible_cols / 4) in
  if cursor_vcol < buf.hscroll then
    buf.hscroll <- max 0 (cursor_vcol - margin)
  else if cursor_vcol >= buf.hscroll + visible_cols then
    buf.hscroll <- cursor_vcol - visible_cols + 1 + margin
