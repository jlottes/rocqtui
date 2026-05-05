open Action

let normalize_newlines s =
  let len = String.length s in
  let buf = Stdlib.Buffer.create len in
  let i = ref 0 in
  while !i < len do
    if s.[!i] = '\r' then begin
      Stdlib.Buffer.add_char buf '\n';
      if !i + 1 < len && s.[!i + 1] = '\n' then incr i;
      incr i
    end else begin
      Stdlib.Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Stdlib.Buffer.contents buf

(* User-keystroke text insertion. Yields to a held lock — the bridge
   uses the lock to make compound ops appear atomic from the user's
   perspective, so user keystrokes (compose output, etc.) must not
   slip in mid-sequence. *)
let insert_string (tab : Tab.t) s =
  if not (Region_buffer.locked tab.rb) then
    ignore (Region_buffer.try_replace_selection tab.rb s)

let encode_codepoint cp =
  if cp < 128 then String.make 1 (Char.chr cp)
  else if cp < 0x800 then
    let b = Bytes.create 2 in
    Bytes.set b 0 (Char.chr (0xC0 lor (cp lsr 6)));
    Bytes.set b 1 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b
  else if cp < 0x10000 then
    let b = Bytes.create 3 in
    Bytes.set b 0 (Char.chr (0xE0 lor (cp lsr 12)));
    Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.set b 2 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b
  else
    let b = Bytes.create 4 in
    Bytes.set b 0 (Char.chr (0xF0 lor (cp lsr 18)));
    Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Bytes.set b 2 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.set b 3 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b

let handle (ctx : Editor_context.t) (ev : Input.event) (tab : Tab.t) r =
  let buf = tab.buf in
  let session = tab.session in
  match ev with
  (* Navigation with selection (shift+arrows) *)
  | Input.Special (Input.Left, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_left buf; Some Continue
  | Input.Special (Input.Right, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_right buf; Some Continue
  | Input.Special (Input.Up, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_up buf; Some Continue
  | Input.Special (Input.Down, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_down buf; Some Continue
  | Input.Special (Input.Home, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_home buf; Some Continue
  | Input.Special (Input.End, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    Buffer.move_end buf; Some Continue
  | Input.Special (Input.PageUp, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    let (rows, _) = Render.pane_dims r Render.PScript in
    Buffer.move_page_up buf (rows - 1); Some Continue
  | Input.Special (Input.PageDown, m) when m.shift ->
    if Buffer.selection buf = None then Buffer.set_anchor buf;
    let (rows, _) = Render.pane_dims r Render.PScript in
    Buffer.move_page_down buf (rows - 1); Some Continue
  (* Navigation without selection *)
  | Input.Special (Input.Up, _) ->
    Buffer.clear_selection buf; Buffer.move_up buf; Some Continue
  | Input.Special (Input.Down, _) ->
    Buffer.clear_selection buf; Buffer.move_down buf; Some Continue
  | Input.Special (Input.Left, _) ->
    Buffer.clear_selection buf; Buffer.move_left buf; Some Continue
  | Input.Special (Input.Right, _) ->
    Buffer.clear_selection buf; Buffer.move_right buf; Some Continue
  | Input.Special (Input.Home, _) ->
    Buffer.clear_selection buf; Buffer.move_home buf; Some Continue
  | Input.Special (Input.End, _) ->
    Buffer.clear_selection buf; Buffer.move_end buf; Some Continue
  | Input.Special (Input.PageDown, _) ->
    Buffer.clear_selection buf;
    let (rows, _) = Render.pane_dims r Render.PScript in
    Buffer.move_page_down buf (rows - 1); Some Continue
  | Input.Special (Input.PageUp, _) ->
    Buffer.clear_selection buf;
    let (rows, _) = Render.pane_dims r Render.PScript in
    Buffer.move_page_up buf (rows - 1); Some Continue
  (* Edit ops below: gated on the buffer lock so user keystrokes
     yield while an MCP client is driving this tab. The lock is the
     bridge's "appear atomic from the user's perspective" mechanism;
     [Region_buffer.try_*] does not check it (the lock holder must be
     able to mutate). *)
  | _ when Region_buffer.locked tab.rb && (
      Keymatch.match_binding ev Keys.cut
      || Keymatch.match_binding ev Keys.paste
      || (match ev with
          | Input.Special ((Input.Delete | Input.Backspace
                          | Input.Enter | Input.Tab), _) -> true
          | Input.Key (cp, mods) when cp >= 32
              && not mods.ctrl && not mods.alt -> true
          | _ -> false)) ->
    Some Continue
  (* Clipboard *)
  | _ when Keymatch.match_binding ev Keys.cut ->
    let captured = Buffer.selected_text buf in
    let result = match captured with
      | Some _ -> Region_buffer.try_replace_selection tab.rb ""
      | None -> Region_buffer.try_cut_line tab.rb
    in
    (match result with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ());
       (match captured with
        | Some t -> ctx.clipboard <- t; Clipboard.copy_to_system t
        | None -> ctx.clipboard <- "")
     | Region_buffer.Rejected _ -> ());
    Some Continue
  | _ when Keymatch.match_binding ev Keys.paste ->
    let result =
      if ctx.clipboard <> "" then
        Region_buffer.try_replace_selection tab.rb ctx.clipboard
      else
        Region_buffer.try_paste tab.rb
    in
    (match result with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  (* Delete *)
  | Input.Special (Input.Delete, _) ->
    (match Region_buffer.try_delete_forward tab.rb with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  (* Backspace *)
  | Input.Special (Input.Backspace, _) ->
    (match Region_buffer.try_delete_backward tab.rb with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  (* Enter *)
  | Input.Special (Input.Enter, _) ->
    (match Region_buffer.try_enter tab.rb with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  (* Tab / Shift+Tab: indent or unindent. With a multi-line selection,
     always indents/unindents the covered lines. With no selection or a
     single-line selection, Tab inserts spaces at the cursor and
     Shift+Tab unindents the current line. *)
  | Input.Special (Input.Tab, m) ->
    let width = !Config.indent_width in
    let multiline_sel =
      match Buffer.selection buf with
      | None -> false
      | Some _ ->
        match Buffer.selected_text buf with
        | Some s -> String.contains s '\n'
        | None -> false
    in
    let result =
      if m.shift then Region_buffer.try_unindent_lines tab.rb width
      else if multiline_sel then Region_buffer.try_indent_lines tab.rb width
      else Region_buffer.try_replace_selection tab.rb (String.make width ' ')
    in
    (match result with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  (* Printable character *)
  | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
    let inserted_text =
      if cp < 128 then String.make 1 (Char.chr cp)
      else encode_codepoint cp
    in
    (match Region_buffer.try_replace_selection tab.rb inserted_text with
     | Region_buffer.Applied ->
       (match session with Some s -> Session.clear_error s | None -> ())
     | Region_buffer.Rejected _ -> ());
    Some Continue
  | _ -> None
