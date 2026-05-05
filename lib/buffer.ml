type snapshot = {
  s_lines : string array;
  s_num_lines : int;
  s_cur_line : int;
  s_cur_col : int;
}

type edit_kind = Insert | Delete | Newline | Cut | Other

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
  mutable disk_changed : bool;  (* file changed on disk since last load/save *)
  mutable revision : int;  (* monotonic counter, bumped on any content mutation *)
  mutable cut_buf : string list;
  mutable anchor : (int * int) option;  (* (line, col) or None *)
  mutable undo_stack : snapshot list;
  mutable redo_stack : snapshot list;
  mutable last_edit : edit_kind;
}

let max_undo = 500

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
    anchor = None;
    undo_stack = [];
    redo_stack = [];
    last_edit = Other;
    disk_changed = false;
    revision = 0 }

let ensure_capacity buf n =
  if n > Array.length buf.lines then begin
    let new_cap = max n (Array.length buf.lines * 2) in
    let new_arr = Array.make new_cap "" in
    Array.blit buf.lines 0 new_arr 0 buf.num_lines;
    buf.lines <- new_arr
  end

let take_snapshot buf =
  { s_lines = Array.sub buf.lines 0 buf.num_lines;
    s_num_lines = buf.num_lines;
    s_cur_line = buf.cur_line;
    s_cur_col = buf.cur_col }

let restore_snapshot buf snap =
  let n = snap.s_num_lines in
  ensure_capacity buf n;
  Array.blit snap.s_lines 0 buf.lines 0 n;
  for i = n to buf.num_lines - 1 do buf.lines.(i) <- "" done;
  buf.num_lines <- n;
  buf.cur_line <- snap.s_cur_line;
  buf.cur_col <- snap.s_cur_col

(* Push an undo snapshot. Called before an edit that starts a new undo group. *)
let push_undo buf kind =
  (* Coalesce consecutive inserts or consecutive deletes *)
  let coalesce = match buf.last_edit, kind with
    | Insert, Insert -> true
    | Delete, Delete -> true
    | _ -> false
  in
  if not coalesce then begin
    let snap = take_snapshot buf in
    buf.undo_stack <- snap :: (if List.length buf.undo_stack >= max_undo
      then List.filteri (fun i _ -> i < max_undo - 1) buf.undo_stack
      else buf.undo_stack);
    buf.redo_stack <- []
  end;
  buf.last_edit <- kind

let undo buf =
  match buf.undo_stack with
  | [] -> ()
  | snap :: rest ->
    buf.redo_stack <- take_snapshot buf :: buf.redo_stack;
    restore_snapshot buf snap;
    buf.undo_stack <- rest;
    buf.last_edit <- Other;
    buf.modified <- true;
  buf.revision <- buf.revision + 1

let redo buf =
  match buf.redo_stack with
  | [] -> ()
  | snap :: rest ->
    buf.undo_stack <- take_snapshot buf :: buf.undo_stack;
    restore_snapshot buf snap;
    buf.redo_stack <- rest;
    buf.last_edit <- Other;
    buf.modified <- true;
  buf.revision <- buf.revision + 1

let update_desired_vcol buf =
  buf.desired_vcol <- Utf8.byte_to_col buf.lines.(buf.cur_line) buf.cur_col

let reload buf =
  match buf.filename with
  | None -> ()
  | Some path ->
    let ic = open_in path in
    let lines = ref [] in
    (try while true do lines := input_line ic :: !lines done
     with End_of_file -> ());
    close_in ic;
    let lines = List.rev !lines in
    let n = max 1 (List.length lines) in
    ensure_capacity buf n;
    List.iteri (fun i l -> buf.lines.(i) <- l) lines;
    for i = n to buf.num_lines - 1 do buf.lines.(i) <- "" done;
    buf.num_lines <- n;
    buf.modified <- false;
    buf.revision <- buf.revision + 1;
    buf.disk_changed <- false;
    buf.undo_stack <- [];
    buf.redo_stack <- [];
    buf.last_edit <- Other;
    (* Keep cursor in bounds *)
    if buf.cur_line >= n then begin
      buf.cur_line <- max 0 (n - 1);
      buf.cur_col <- 0
    end else if buf.cur_col > String.length buf.lines.(buf.cur_line) then
      buf.cur_col <- String.length buf.lines.(buf.cur_line)

let set_text buf text =
  push_undo buf Other;
  let lines = String.split_on_char '\n' text in
  let lines = match List.rev lines with
    | "" :: rest when rest <> [] -> List.rev rest
    | _ -> lines
  in
  let n = max 1 (List.length lines) in
  ensure_capacity buf n;
  List.iteri (fun i l -> buf.lines.(i) <- l) lines;
  for i = n to buf.num_lines - 1 do buf.lines.(i) <- "" done;
  buf.num_lines <- n;
  buf.modified <- true;
  buf.revision <- buf.revision + 1;
  if buf.cur_line >= n then begin
    buf.cur_line <- max 0 (n - 1);
    buf.cur_col <- 0
  end else if buf.cur_col > String.length buf.lines.(buf.cur_line) then
    buf.cur_col <- String.length buf.lines.(buf.cur_line);
  update_desired_vcol buf

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
    buf.disk_changed <- false;
    true

let save_as buf path =
  buf.filename <- Some path;
  ignore (save buf)

let filename buf = buf.filename
let set_filename buf f = buf.filename <- Some f
let modified buf = buf.modified
let disk_changed buf = buf.disk_changed
let set_disk_changed buf v = buf.disk_changed <- v
let revision buf = buf.revision
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

let move_to buf line col =
  buf.cur_line <- max 0 (min line (buf.num_lines - 1));
  buf.cur_col <- min col (String.length buf.lines.(buf.cur_line));
  update_desired_vcol buf

let cursor_byte_offset buf =
  let off = ref 0 in
  for i = 0 to buf.cur_line - 1 do
    off := !off + String.length buf.lines.(i) + 1
  done;
  !off + buf.cur_col

let text buf =
  let parts = Array.to_list (Array.sub buf.lines 0 buf.num_lines) in
  String.concat "\n" parts ^ "\n"

let cut_buffer buf = buf.cut_buf

let text_of_snapshot snap =
  let parts = Array.to_list (Array.sub snap.s_lines 0 snap.s_num_lines) in
  String.concat "\n" parts ^ "\n"

let peek_undo_text buf =
  match buf.undo_stack with
  | [] -> None
  | snap :: _ -> Some (text_of_snapshot snap)

let peek_redo_text buf =
  match buf.redo_stack with
  | [] -> None
  | snap :: _ -> Some (text_of_snapshot snap)

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
    push_undo buf Other;
    let t = text buf in
    let deleted = String.sub t s (e - s) in
    (* Rebuild lines from the text with the selection removed *)
    let new_text = String.sub t 0 s ^ String.sub t e (String.length t - e) in
    let new_lines = String.split_on_char '\n' new_text in
    (* [text buf] always ends in "\n", so the split has a trailing ""
       element representing the terminator. Strip it so we don't record
       a phantom blank line each time delete_selection is called. *)
    let new_lines = match List.rev new_lines with
      | "" :: rest when rest <> [] -> List.rev rest
      | _ -> new_lines
    in
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
  buf.revision <- buf.revision + 1;
    Some deleted

let insert_char buf ch =
  push_undo buf Insert;
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
  buf.modified <- true;
  buf.revision <- buf.revision + 1

let insert_newline buf =
  push_undo buf Newline;
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
  buf.modified <- true;
  buf.revision <- buf.revision + 1

(* Like insert_newline, but prefix the new line with the leading whitespace
   of the line the cursor was on (capped at cursor column, so splitting
   mid-indent doesn't over-indent). *)
let insert_newline_auto_indent buf =
  push_undo buf Newline;
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  let before = String.sub line 0 col in
  let after = String.sub line col (len - col) in
  let ws_end = ref 0 in
  while !ws_end < len &&
        (line.[!ws_end] = ' ' || line.[!ws_end] = '\t') do
    incr ws_end
  done;
  let indent_len = min !ws_end col in
  let indent = String.sub line 0 indent_len in
  ensure_capacity buf (buf.num_lines + 1);
  for i = buf.num_lines downto buf.cur_line + 2 do
    buf.lines.(i) <- buf.lines.(i - 1)
  done;
  buf.lines.(buf.cur_line) <- before;
  buf.lines.(buf.cur_line + 1) <- indent ^ after;
  buf.num_lines <- buf.num_lines + 1;
  buf.cur_line <- buf.cur_line + 1;
  buf.cur_col <- indent_len;
  buf.modified <- true;
  buf.revision <- buf.revision + 1;
  update_desired_vcol buf

(* Range of fully-or-partially selected lines for line-wise operations.
   If the selection ends exactly at column 0 of a line, that line is
   excluded (conventional editor behavior). *)
let selection_line_range buf =
  match buf.anchor with
  | None -> (buf.cur_line, buf.cur_line)
  | Some (al, ac) ->
    let a_off = pos_to_offset buf al ac in
    let c_off = pos_to_offset buf buf.cur_line buf.cur_col in
    let ((sl, _), (el, ec)) =
      if a_off <= c_off then ((al, ac), (buf.cur_line, buf.cur_col))
      else ((buf.cur_line, buf.cur_col), (al, ac))
    in
    let last = if ec = 0 && el > sl then el - 1 else el in
    (sl, last)

let indent_lines buf width =
  let (first, last) = selection_line_range buf in
  push_undo buf Other;
  let pad = String.make width ' ' in
  for i = first to last do
    buf.lines.(i) <- pad ^ buf.lines.(i)
  done;
  let adj (l, c) =
    if l >= first && l <= last && c > 0 then (l, c + width) else (l, c)
  in
  (match buf.anchor with
   | Some (al, ac) ->
     let (al', ac') = adj (al, ac) in
     buf.anchor <- Some (al', ac')
   | None -> ());
  let (cl', cc') = adj (buf.cur_line, buf.cur_col) in
  buf.cur_line <- cl';
  buf.cur_col <- cc';
  update_desired_vcol buf;
  buf.modified <- true;
  buf.revision <- buf.revision + 1

let unindent_lines buf width =
  let (first, last) = selection_line_range buf in
  push_undo buf Other;
  let removed = Array.make (last - first + 1) 0 in
  let any = ref false in
  for i = first to last do
    let line = buf.lines.(i) in
    let len = String.length line in
    let n = ref 0 in
    while !n < width && !n < len && line.[!n] = ' ' do incr n done;
    removed.(i - first) <- !n;
    if !n > 0 then begin
      buf.lines.(i) <- String.sub line !n (len - !n);
      any := true
    end
  done;
  let adj (l, c) =
    if l >= first && l <= last then
      (l, max 0 (c - removed.(l - first)))
    else (l, c)
  in
  (match buf.anchor with
   | Some (al, ac) ->
     let (al', ac') = adj (al, ac) in
     buf.anchor <- Some (al', ac')
   | None -> ());
  let (cl', cc') = adj (buf.cur_line, buf.cur_col) in
  buf.cur_line <- cl';
  buf.cur_col <- cc';
  update_desired_vcol buf;
  if !any then buf.modified <- true;
  buf.revision <- buf.revision + 1

let delete_char_before buf =
  push_undo buf Delete;
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
    buf.modified <- true;
  buf.revision <- buf.revision + 1
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
    buf.modified <- true;
  buf.revision <- buf.revision + 1
  end

let delete_char_at buf =
  push_undo buf Delete;
  let line = buf.lines.(buf.cur_line) in
  let len = String.length line in
  let col = min buf.cur_col len in
  if col < len then begin
    let next_col = Utf8.next line col in
    buf.lines.(buf.cur_line) <-
      String.sub line 0 col
      ^ String.sub line next_col (len - next_col);
    buf.modified <- true;
  buf.revision <- buf.revision + 1
  end else if buf.cur_line < buf.num_lines - 1 then begin
    (* Join with next line *)
    buf.lines.(buf.cur_line) <- line ^ buf.lines.(buf.cur_line + 1);
    for i = buf.cur_line + 1 to buf.num_lines - 2 do
      buf.lines.(i) <- buf.lines.(i + 1)
    done;
    buf.lines.(buf.num_lines - 1) <- "";
    buf.num_lines <- buf.num_lines - 1;
    buf.modified <- true;
  buf.revision <- buf.revision + 1
  end

let cut_line buf =
  (* Reset cut buffer if last action wasn't also a cut *)
  if buf.last_edit <> Cut then buf.cut_buf <- [];
  push_undo buf Cut;
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
  buf.modified <- true;
  buf.revision <- buf.revision + 1

let paste buf =
  match buf.cut_buf with
  | [] -> ()
  | lines ->
    push_undo buf Other;
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
  buf.revision <- buf.revision + 1

(* Rocq identifier chars: ASCII letters/digits/_/'/., plus any non-ASCII
   codepoint (greek letters, math symbols, etc.). Operates on codepoints,
   not bytes, so multi-byte UTF-8 doesn't get split mid-character. *)
let is_ident_codepoint cp =
  (cp >= Char.code 'a' && cp <= Char.code 'z') ||
  (cp >= Char.code 'A' && cp <= Char.code 'Z') ||
  (cp >= Char.code '0' && cp <= Char.code '9') ||
  cp = Char.code '_' || cp = Char.code '\'' || cp = Char.code '.' ||
  cp >= 0x80

let ident_at line col =
  let len = String.length line in
  if col >= len then None
  else
    let (cp, _) = Utf8.decode line col in
    if not (is_ident_codepoint cp) then None
    else begin
      let l = ref col in
      let stop = ref false in
      while not !stop && !l > 0 do
        let p = Utf8.prev line !l in
        let (cp, _) = Utf8.decode line p in
        if is_ident_codepoint cp then l := p else stop := true
      done;
      let r = ref (Utf8.next line col) in
      let stop = ref false in
      while not !stop && !r < len do
        let (cp, _) = Utf8.decode line !r in
        if is_ident_codepoint cp then r := Utf8.next line !r else stop := true
      done;
      Some (!l, !r)
    end

let word_at_cursor buf =
  let line = buf.lines.(buf.cur_line) in
  let col = min buf.cur_col (String.length line) in
  match ident_at line col with
  | None -> None
  | Some (l, r) ->
    let word = String.sub line l (r - l) in
    (* Trim trailing dots (qualified name separator vs sentence end) *)
    let word = if String.length word > 0 && word.[String.length word - 1] = '.'
      then String.sub word 0 (String.length word - 1) else word in
    if word = "" then None else Some word

let select_word_at_cursor buf =
  let line = buf.lines.(buf.cur_line) in
  let col = min buf.cur_col (String.length line) in
  match ident_at line col with
  | None -> ()
  | Some (l, r) ->
    let r = if r > l && line.[r - 1] = '.' then r - 1 else r in
    if r > l then begin
      buf.cur_col <- l;
      buf.anchor <- Some (buf.cur_line, l);
      buf.cur_col <- r;
      update_desired_vcol buf
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

(* Unsafe mutators — only for use by Region_buffer. *)
module Unsafe = struct
  let reload = reload
  let set_text = set_text
  let undo = undo
  let redo = redo
  let insert_char = insert_char
  let insert_newline = insert_newline
  let insert_newline_auto_indent = insert_newline_auto_indent
  let delete_char_before = delete_char_before
  let delete_char_at = delete_char_at
  let delete_selection = delete_selection
  let cut_line = cut_line
  let paste = paste
  let indent_lines = indent_lines
  let unindent_lines = unindent_lines
end
