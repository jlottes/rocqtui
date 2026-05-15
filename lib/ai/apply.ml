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
