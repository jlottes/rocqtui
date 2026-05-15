(* Tests for the recent-edits ring on Region_buffer. *)

open Rocqtui_lib

let make_rb () =
  let buf = Buffer.create () in
  Region_buffer.create buf ~session:None

let check_applied = function
  | Region_buffer.Applied -> ()
  | Region_buffer.Rejected _ -> assert false

let () =
  (* Empty ring on a fresh buffer *)
  let rb = make_rb () in
  assert (Region_buffer.recent_edits rb = []);

  (* Insert chars: each goes through the ring *)
  let rb = make_rb () in
  check_applied (Region_buffer.try_insert_char rb 'a');
  check_applied (Region_buffer.try_insert_char rb 'b');
  check_applied (Region_buffer.try_insert_char rb 'c');
  let edits = Region_buffer.recent_edits rb in
  assert (List.length edits = 3);
  let last = List.nth edits 2 in
  assert (last.Region_buffer.before = "");
  assert (last.Region_buffer.after = "c");

  (* Delete picks up before, empty after *)
  let rb = make_rb () in
  check_applied (Region_buffer.try_insert_char rb 'x');
  check_applied (Region_buffer.try_delete_backward rb);
  let edits = Region_buffer.recent_edits rb in
  assert (List.length edits = 2);
  let del = List.nth edits 1 in
  assert (del.Region_buffer.before = "x");
  assert (del.Region_buffer.after = "");

  (* Ring is bounded by ring_size *)
  let rb = make_rb () in
  for _ = 1 to Region_buffer.ring_size + 4 do
    check_applied (Region_buffer.try_insert_char rb 'z')
  done;
  let edits = Region_buffer.recent_edits rb in
  assert (List.length edits = Region_buffer.ring_size);

  (* Rejected edits do NOT enter the ring *)
  let rb = make_rb () in
  check_applied (Region_buffer.try_insert_char rb 'h');
  (* a no-op delete on an empty position returns Applied without recording
     because diff_replace_range yields None; verify a *real* edit followed
     by a backspace at start-of-buffer (also no-op) keeps just the one entry *)
  check_applied (Region_buffer.try_delete_backward rb);
  let edits_before = Region_buffer.recent_edits rb in
  check_applied (Region_buffer.try_delete_backward rb);
  let edits_after = Region_buffer.recent_edits rb in
  assert (List.length edits_before = List.length edits_after);

  (* try_replace explicit range records before/after correctly *)
  let rb = make_rb () in
  String.iter (fun c -> check_applied (Region_buffer.try_insert_char rb c)) "hello";
  check_applied (Region_buffer.try_replace rb ~start:1 ~old_end:4 "ELL");
  let edits = Region_buffer.recent_edits rb in
  let last = List.nth edits (List.length edits - 1) in
  assert (last.Region_buffer.before = "ell");
  assert (last.Region_buffer.after = "ELL");

  print_endline "test_region_buffer: ok"
