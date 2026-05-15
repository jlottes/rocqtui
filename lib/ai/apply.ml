(* Buffer mutation for AI acceptances. All writes go through
   Region_buffer.try_replace so the region invariants are enforced. *)

(* Accept the entire ghost text at the current cursor.
   Returns true if applied, false if rejected (e.g. cursor moved into
   the verified region while the ghost was visible).

   [Region_buffer.try_replace] leaves the inserted span selected
   (it's a useful affordance for MCP, where seeing the highlighted
   change is desirable). For AI acceptance the selection is
   counterproductive — the next keystroke would replace the just-
   accepted text — so we explicitly drop it. *)
let accept_all (tab : Tab.t) ~text =
  let off = Buffer.cursor_byte_offset tab.buf in
  match Region_buffer.try_replace tab.rb ~start:off ~old_end:off text with
  | Region_buffer.Applied ->
    Buffer.clear_selection tab.buf;
    true
  | Region_buffer.Rejected _ -> false

(* First-chunk extraction for accept-word.
   - If the text starts with whitespace (space/tab/newline), take the
     run of whitespace.
   - Otherwise take the run of non-whitespace.
   This lets multiple Alt+W presses walk through the suggestion
   alternating word / interword runs. *)
let first_chunk (s : string) : string =
  let n = String.length s in
  if n = 0 then ""
  else
    let is_ws c = c = ' ' || c = '\t' || c = '\n' in
    let i = ref 0 in
    if is_ws s.[0] then
      while !i < n && is_ws s.[!i] do incr i done
    else
      while !i < n && not (is_ws s.[!i]) do incr i done;
    String.sub s 0 !i

(* Accept the first chunk (word or whitespace run) of [text] at the
   cursor. Returns the number of bytes consumed on success, [None]
   when the insertion was rejected. *)
let accept_word (tab : Tab.t) ~text : int option =
  let chunk = first_chunk text in
  if String.length chunk = 0 then None
  else
    let off = Buffer.cursor_byte_offset tab.buf in
    match Region_buffer.try_replace tab.rb ~start:off ~old_end:off chunk with
    | Region_buffer.Applied ->
      Buffer.clear_selection tab.buf;
      Some (String.length chunk)
    | Region_buffer.Rejected _ -> None

(* Convert a (line, col) byte position to a buffer-wide byte offset
   without mutating the cursor. [col] is interpreted as the byte
   column within the line. *)
let line_col_to_offset buf line col =
  let off = ref 0 in
  for i = 0 to line - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + col

(* Apply one predicted edit. Returns [true] on success, [false] on
   rejection (e.g. overlaps the verified region). *)
let accept_edit (tab : Tab.t) (c : Per_tab.edit_change) : bool =
  let buf = tab.buf in
  let s = line_col_to_offset buf c.start_line c.start_col in
  let e = line_col_to_offset buf c.end_line c.end_col in
  match Region_buffer.try_replace tab.rb ~start:s ~old_end:e c.replacement with
  | Region_buffer.Applied ->
    Buffer.clear_selection tab.buf;
    true
  | Region_buffer.Rejected _ -> false

(* Apply all predicted edits in one pass, in reverse byte order so
   earlier offsets remain valid as we mutate. Returns the count of
   successfully applied changes. *)
let accept_all_edits (tab : Tab.t) (changes : Per_tab.edit_change list) : int =
  let sorted =
    List.sort (fun (a : Per_tab.edit_change) b ->
      compare (b.start_line, b.start_col) (a.start_line, a.start_col)
    ) changes
  in
  List.fold_left (fun n c ->
    if accept_edit tab c then n + 1 else n
  ) 0 sorted
