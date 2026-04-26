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

let insert_string (tab : Tab.t) s =
  if not (Block.edit_blocked tab) then
    let buf = tab.buf in
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline buf
      else Buffer.insert_char buf c
    ) s

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
  (* Clipboard *)
  | _ when Keymatch.match_binding ev Keys.cut ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      match Buffer.delete_selection buf with
      | Some text ->
        ctx.clipboard <- text;
        Clipboard.copy_to_system text
      | None ->
        ctx.clipboard <- "";
        Buffer.cut_line buf
    end;
    Some Continue
  | _ when Keymatch.match_binding ev Keys.paste ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      ignore (Buffer.delete_selection buf);
      if ctx.clipboard <> "" then
        String.iter (fun c ->
          if c = '\n' then Buffer.insert_newline buf
          else Buffer.insert_char buf c
        ) ctx.clipboard
      else Buffer.paste buf
    end;
    Some Continue
  (* Delete *)
  | Input.Special (Input.Delete, _) ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      (match Buffer.delete_selection buf with
       | Some _ -> () | None -> Buffer.delete_char_at buf)
    end;
    Some Continue
  (* Backspace *)
  | Input.Special (Input.Backspace, _) ->
    if not (Block.edit_blocked ~for_backspace:true tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      (match Buffer.delete_selection buf with
       | Some _ -> () | None -> Buffer.delete_char_before buf)
    end;
    Some Continue
  (* Enter *)
  | Input.Special (Input.Enter, _) ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      ignore (Buffer.delete_selection buf);
      Buffer.insert_newline_auto_indent buf
    end;
    Some Continue
  (* Tab / Shift+Tab: indent or unindent. With a multi-line selection,
     always indents/unindents the covered lines. With no selection or a
     single-line selection, Tab inserts spaces at the cursor and
     Shift+Tab unindents the current line. *)
  | Input.Special (Input.Tab, m) ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      let width = !Config.indent_width in
      let multiline_sel =
        match Buffer.selection buf with
        | None -> false
        | Some _ ->
          match Buffer.selected_text buf with
          | Some s -> String.contains s '\n'
          | None -> false
      in
      if m.shift then
        Buffer.unindent_lines buf width
      else if multiline_sel then
        Buffer.indent_lines buf width
      else begin
        ignore (Buffer.delete_selection buf);
        for _ = 1 to width do Buffer.insert_char buf ' ' done
      end
    end;
    Some Continue
  (* Printable character *)
  | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
    if not (Block.edit_blocked tab) then begin
      (match session with Some s -> Session.clear_error s | None -> ());
      ignore (Buffer.delete_selection buf);
      if cp < 128 then
        Buffer.insert_char buf (Char.chr cp)
      else
        insert_string tab (encode_codepoint cp)
    end;
    Some Continue
  | _ -> None
