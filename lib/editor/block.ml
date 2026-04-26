let cursor_byte_offset buf =
  let (cl, cc) = Buffer.cursor buf in
  let off = ref 0 in
  for i = 0 to cl - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + cc

let cursor_in_target ?(for_backspace=false) (tab : Tab.t) =
  match tab.session with
  | None -> false
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then false
    else
      let off = cursor_byte_offset tab.buf in
      if for_backspace then off <= tend
      else off < tend

let edit_blocked ?(for_backspace=false) (tab : Tab.t) =
  tab.locked || cursor_in_target ~for_backspace tab

let rewind_if_needed (tab : Tab.t) =
  match tab.session with
  | None -> ()
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then ()
    else
      let cursor_off = cursor_byte_offset tab.buf in
      if cursor_off < tend then
        Session.go_to_cursor sess
