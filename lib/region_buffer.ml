(* RegionBuffer: text mutation gateway. See region_buffer.mli for
   the contract and docs/REGION_INVARIANTS.md for the invariants. *)

type t = {
  buf : Buffer.t;
  mutable session : Session.t option;
  mutable lockedf : bool;
}

type reject_reason =
  | In_verified_region
  | Erodes_boundary
  | In_pending_region

type result = Applied | Rejected of reject_reason

let create buf ~session = { buf; session; lockedf = false }
let buffer t = t.buf

let lock t = t.lockedf <- true
let unlock t = t.lockedf <- false
let locked t = t.lockedf

let bounds t =
  match t.session with
  | None -> (0, 0)
  | Some s -> (Session.verified_end s, Session.pending_end s)

(* Universal pre-flight check. The lock flag is intentionally NOT
   consulted here — the lock is a coarse "external client is driving
   this buffer" hint that callers (editor keystrokes, third-party MCP
   clients) check separately before invoking [try_*]. The lock holder
   itself must be free to mutate.
   [first_inserted = None] means a pure delete (no bytes inserted).
   [first_inserted = Some c] means insertion (or replace) where the
   first byte of the inserted text is [c]. *)
let check t ~start ~old_end ~first_inserted =
  let (vend, pend) = bounds t in
  if start < vend then Rejected In_verified_region
  else if start < pend then Rejected In_pending_region
  else if vend = 0 || start > vend then Applied
  else
    (* start = vend > 0: boundary check applies. *)
    let post_first =
      match first_inserted with
      | Some _ as c -> c
      | None ->
        let pre = Buffer.text t.buf in
        if old_end >= String.length pre then None
        else Some pre.[old_end]
    in
    match post_first with
    | None -> Applied
    | Some c when Sentence.is_space c -> Applied
    | _ -> Rejected Erodes_boundary

(* Helpers *)

let line_start_offset buf line =
  let off = ref 0 in
  for i = 0 to line - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off

(* Per docs/REGION_INVARIANTS.md: an error region is cleared when its
   bytes change OR its byte offsets would shift. Both happen iff the
   edit's start offset is strictly less than the error end. An edit at
   or after err_end leaves the bytes [err_start, err_end) untouched
   and at the same offsets, so the highlight commitment stays valid. *)
let maybe_clear_error t ~start =
  match t.session with
  | Some s ->
    (match Session.error_range s with
     | Some (_, err_end) when start < err_end -> Session.clear_error s
     | _ -> ())
  | None -> ()

(* {1 Cursor-relative atomic edits} *)

let try_insert_char t ch =
  let off = Buffer.cursor_byte_offset t.buf in
  match check t ~start:off ~old_end:off ~first_inserted:(Some ch) with
  | Applied ->
    Buffer.Unsafe.insert_char t.buf ch;
    maybe_clear_error t ~start:off;
    Applied
  | r -> r

let try_insert_newline t =
  let off = Buffer.cursor_byte_offset t.buf in
  match check t ~start:off ~old_end:off ~first_inserted:(Some '\n') with
  | Applied ->
    Buffer.Unsafe.insert_newline t.buf;
    maybe_clear_error t ~start:off;
    Applied
  | r -> r

let try_insert_newline_auto_indent t =
  let off = Buffer.cursor_byte_offset t.buf in
  match check t ~start:off ~old_end:off ~first_inserted:(Some '\n') with
  | Applied ->
    Buffer.Unsafe.insert_newline_auto_indent t.buf;
    maybe_clear_error t ~start:off;
    Applied
  | r -> r

(* For deletes that may or may not have a selection, compute the
   affected byte range. Returns None if the op would be a no-op. *)
let delete_range t ~for_backspace =
  let buf = t.buf in
  match Buffer.selection buf with
  | Some (s, e) -> Some (s, e)
  | None ->
    let off = Buffer.cursor_byte_offset buf in
    let (cl, cc) = Buffer.cursor buf in
    let line = Buffer.get_line buf cl in
    let line_len = String.length line in
    let n = Buffer.line_count buf in
    if for_backspace then
      if off = 0 then None
      else if cc = 0 then
        Some (off - 1, off)  (* deletes preceding newline *)
      else
        let prev_col = Utf8.prev line cc in
        Some (off - (cc - prev_col), off)
    else
      if cc < line_len then
        let next_col = Utf8.next line cc in
        Some (off, off + (next_col - cc))
      else if cl < n - 1 then
        Some (off, off + 1)  (* deletes following newline *)
      else
        None

let try_delete_forward t =
  match delete_range t ~for_backspace:false with
  | None -> Applied  (* nothing to delete; no-op *)
  | Some (s, e) ->
    match check t ~start:s ~old_end:e ~first_inserted:None with
    | Applied ->
      (match Buffer.Unsafe.delete_selection t.buf with
       | Some _ -> ()
       | None -> Buffer.Unsafe.delete_char_at t.buf);
      maybe_clear_error t ~start:s;
      Applied
    | r -> r

let try_delete_backward t =
  match delete_range t ~for_backspace:true with
  | None -> Applied
  | Some (s, e) ->
    match check t ~start:s ~old_end:e ~first_inserted:None with
    | Applied ->
      (match Buffer.Unsafe.delete_selection t.buf with
       | Some _ -> ()
       | None -> Buffer.Unsafe.delete_char_before t.buf);
      maybe_clear_error t ~start:s;
      Applied
    | r -> r

let try_paste t =
  let buf = t.buf in
  let cut = Buffer.cut_buffer buf in
  match cut with
  | [] -> Applied
  | first_line :: _ ->
    (* Affected range covers both the (optional) selection delete and
       the line-paste insert. Buffer.Unsafe.paste inserts at the start of the
       line containing the cursor *post-delete*, which in pre-edit
       coordinates is the line containing the selection's start (or
       the cursor if no selection). *)
    let (first_sel_line, _) = Buffer.selection_line_range buf in
    let start = line_start_offset buf first_sel_line in
    let sel_e = match Buffer.selection buf with
      | Some (_, e) -> e
      | None -> start
    in
    let first_inserted =
      if String.length first_line > 0 then Some first_line.[0]
      else Some '\n'
    in
    match check t ~start ~old_end:sel_e ~first_inserted with
    | Applied ->
      ignore (Buffer.Unsafe.delete_selection buf);
      Buffer.Unsafe.paste buf;
      maybe_clear_error t ~start;
      Applied
    | r -> r

let try_cut_line t =
  let buf = t.buf in
  let (cl, _) = Buffer.cursor buf in
  let line_start = line_start_offset buf cl in
  let line = Buffer.get_line buf cl in
  let line_len = String.length line in
  let n = Buffer.line_count buf in
  let (s, e) =
    if n > 1 then
      (line_start, line_start + line_len + 1)  (* include newline *)
    else
      (line_start, line_start + line_len)  (* single-line: just empty contents *)
  in
  match check t ~start:s ~old_end:e ~first_inserted:None with
  | Applied ->
    Buffer.Unsafe.cut_line t.buf;
    maybe_clear_error t ~start:s;
    Applied
  | r -> r

let try_enter t =
  let buf = t.buf in
  let (s, e) = match Buffer.selection buf with
    | Some r -> r
    | None ->
      let off = Buffer.cursor_byte_offset buf in
      (off, off)
  in
  match check t ~start:s ~old_end:e ~first_inserted:(Some '\n') with
  | Applied ->
    ignore (Buffer.Unsafe.delete_selection buf);
    Buffer.Unsafe.insert_newline_auto_indent buf;
    maybe_clear_error t ~start:s;
    Applied
  | r -> r

let try_indent_lines t width =
  let (first, _) = Buffer.selection_line_range t.buf in
  let off = line_start_offset t.buf first in
  match check t ~start:off ~old_end:off ~first_inserted:(Some ' ') with
  | Applied ->
    Buffer.Unsafe.indent_lines t.buf width;
    maybe_clear_error t ~start:off;
    Applied
  | r -> r

let try_unindent_lines t width =
  let (first, _) = Buffer.selection_line_range t.buf in
  let off = line_start_offset t.buf first in
  (* unindent removes leading spaces from each line in the range.
     The lowest affected byte is [off]; the right-bound deletion is
     up to [width] spaces from there. For invariant 1 it's enough
     that off >= vend; the boundary check applies if off = vend. *)
  match check t ~start:off ~old_end:(off + width) ~first_inserted:None with
  | Applied ->
    Buffer.Unsafe.unindent_lines t.buf width;
    maybe_clear_error t ~start:off;
    Applied
  | r -> r

(* {1 Replace selection (or insert at cursor)} *)

let apply_replace_at_cursor t text =
  ignore (Buffer.Unsafe.delete_selection t.buf);
  String.iter (fun c ->
    if c = '\n' then Buffer.Unsafe.insert_newline t.buf
    else Buffer.Unsafe.insert_char t.buf c
  ) text

let try_replace_selection t text =
  let buf = t.buf in
  let (s, e) = match Buffer.selection buf with
    | Some r -> r
    | None ->
      let off = Buffer.cursor_byte_offset buf in
      (off, off)
  in
  let first_inserted =
    if String.length text = 0 then None
    else Some text.[0]
  in
  match check t ~start:s ~old_end:e ~first_inserted with
  | Applied ->
    apply_replace_at_cursor t text;
    maybe_clear_error t ~start:s;
    Applied
  | r -> r

(* {1 Explicit-range replace (for MCP)} *)

let try_replace t ~start ~old_end new_text =
  let first_inserted =
    if String.length new_text = 0 then None
    else Some new_text.[0]
  in
  match check t ~start ~old_end ~first_inserted with
  | Applied ->
    Buffer.move_to_byte_offset t.buf start;
    Buffer.set_anchor t.buf;
    Buffer.move_to_byte_offset t.buf old_end;
    ignore (Buffer.Unsafe.delete_selection t.buf);
    String.iter (fun c ->
      if c = '\n' then Buffer.Unsafe.insert_newline t.buf
      else Buffer.Unsafe.insert_char t.buf c
    ) new_text;
    maybe_clear_error t ~start;
    Applied
  | r -> r

(* {1 Wholesale text replacement} *)

(* Diff [old_text] and [new_text] into a single replace-range. Returns
   None if the texts are identical. Used by wholesale-replace and
   undo/redo to find the byte range an edit actually touched. *)
let diff_replace_range ~old_text ~new_text =
  let ol = String.length old_text in
  let nl = String.length new_text in
  let m = min ol nl in
  let i = ref 0 in
  while !i < m && old_text.[!i] = new_text.[!i] do incr i done;
  let suf = ref 0 in
  while !suf < (ol - !i) && !suf < (nl - !i)
        && old_text.[ol - 1 - !suf] = new_text.[nl - 1 - !suf] do
    incr suf
  done;
  let start = !i in
  let old_end = ol - !suf in
  let new_end = nl - !suf in
  if start = old_end && start = new_end then None
  else
    let first_inserted =
      if new_end > start then Some new_text.[start] else None
    in
    Some (start, old_end, first_inserted)

(* For wholesale replacement we run a different check: the verified
   prefix and the pending prefix must match the new text byte-for-byte,
   and the boundary byte must be preserved. *)
let check_wholesale t ~new_text =
  let (vend, pend) = bounds t in
  let new_len = String.length new_text in
  let pre = Buffer.text t.buf in
  let mismatch_at_or_before n =
    n > new_len ||
    (let limit = min n (String.length pre) in
     let ok = ref true in
     (try for i = 0 to limit - 1 do
        if pre.[i] <> new_text.[i] then begin ok := false; raise Exit end
      done with Exit -> ());
     not !ok || limit < n)
  in
  if mismatch_at_or_before vend then Rejected In_verified_region
  else if mismatch_at_or_before pend then Rejected In_pending_region
  else if vend = 0 then Applied
  else if vend >= new_len then Applied  (* boundary at EOF *)
  else if Sentence.is_space new_text.[vend] then Applied
  else Rejected Erodes_boundary

let try_load_text t new_text =
  match check_wholesale t ~new_text with
  | Applied ->
    let old_text = Buffer.text t.buf in
    Buffer.Unsafe.set_text t.buf new_text;
    (match diff_replace_range ~old_text ~new_text with
     | Some (start, _, _) -> maybe_clear_error t ~start
     | None -> ());
    Applied
  | r -> r

let try_reload_from_disk t =
  match Buffer.filename t.buf with
  | None -> Applied  (* no filename, nothing to reload *)
  | Some path when not (Sys.file_exists path) -> Applied  (* nothing to do *)
  | Some path ->
    let new_text =
      try
        let ic = open_in path in
        let s = In_channel.input_all ic in
        close_in ic;
        s
      with _ -> Buffer.text t.buf
    in
    match check_wholesale t ~new_text with
    | Applied ->
      let old_text = Buffer.text t.buf in
      Buffer.Unsafe.reload t.buf;
      (match diff_replace_range ~old_text ~new_text with
       | Some (start, _, _) -> maybe_clear_error t ~start
       | None -> ());
      Applied
    | r -> r

(* {1 Undo / redo}

   Undo and redo are subject to the same invariants as forward edits:
   they must not alter the verified region, erode the boundary, or
   overlap the pending region. We use [peek_undo_text]/[peek_redo_text]
   to compute the post-edit text without committing, diff it against
   the current text to find the affected byte range, and run that
   range through [check]. *)

let try_undo t =
  match Buffer.peek_undo_text t.buf with
  | None -> Applied  (* nothing to undo *)
  | Some new_text ->
    match diff_replace_range ~old_text:(Buffer.text t.buf) ~new_text with
    | None -> Applied  (* undo is a no-op *)
    | Some (start, old_end, first_inserted) ->
      match check t ~start ~old_end ~first_inserted with
      | Applied ->
        Buffer.Unsafe.undo t.buf;
        maybe_clear_error t ~start;
        Applied
      | r -> r

let try_redo t =
  match Buffer.peek_redo_text t.buf with
  | None -> Applied
  | Some new_text ->
    match diff_replace_range ~old_text:(Buffer.text t.buf) ~new_text with
    | None -> Applied
    | Some (start, old_end, first_inserted) ->
      match check t ~start ~old_end ~first_inserted with
      | Applied ->
        Buffer.Unsafe.redo t.buf;
        maybe_clear_error t ~start;
        Applied
      | r -> r
