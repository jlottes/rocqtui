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
