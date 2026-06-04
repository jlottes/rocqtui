let open_tab ?cmd (ctx : Editor_context.t) (tab : Tab.t) r =
  let buf = tab.buf in
  let (h, w) = Render.pane_dims r Render.PMessages in
  let cwd = match ctx.project with
    | Some p -> p.project_dir
    | None ->
      (match Buffer.filename buf with
       | Some f -> Filename.dirname f
       | None -> Sys.getcwd ()) in
  let term = match cmd with
    | Some c -> Terminal.create ~cmd:c ~cwd ~w ~h ()
    | None -> Terminal.create ~cwd ~w ~h ()
  in
  Msg_pane.sync_terminals ();
  Msg_pane.activate (Msg_pane.Terminal term);
  ctx.focus <- Editor_context.FMessages

let send_escape () =
  match Msg_pane.active_kind () with
  | Msg_pane.Terminal term ->
    let vt = Terminal.vterm term in
    let mode = Vterm_lib.Vterm_api.term_mode vt
      land (Vterm_lib.Vterm_api.mode_app_keypad
            lor Vterm_lib.Vterm_api.mode_app_cursor
            lor Vterm_lib.Vterm_api.mode_meta) in
    let seq = Vterm_lib.Vterm_api.kitty_keyseq
      ~key:Vterm_lib.Keys.escape
      ~shifted_key:0 ~modifiers:0 ~mode
      ~kitty_flags:(Vterm_lib.Vterm_api.kitty_flags vt)
      ~event_type:1 ~text:"" in
    (match seq with
     | Some s -> Terminal.send term s
     | None -> Terminal.send term "\x1b")
  | _ -> ()

let encode_utf8 buf cp =
  if cp < 0x80 then
    Stdlib.Buffer.add_char buf (Char.chr cp)
  else if cp < 0x800 then begin
    Stdlib.Buffer.add_char buf (Char.chr (0xC0 lor (cp lsr 6)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end else if cp < 0x10000 then begin
    Stdlib.Buffer.add_char buf (Char.chr (0xE0 lor (cp lsr 12)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end else begin
    Stdlib.Buffer.add_char buf (Char.chr (0xF0 lor (cp lsr 18)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Stdlib.Buffer.add_char buf (Char.chr (0x80 lor (cp land 0x3F)))
  end

let input_mod (m : Input.modifier) =
  (if m.shift then 1 else 0)
  lor (if m.alt then 2 else 0)
  lor (if m.ctrl then 4 else 0)

let forward_event term (ev : Input.event) =
  let vt = Terminal.vterm term in
  let mode = Vterm_lib.Vterm_api.term_mode vt
    land (Vterm_lib.Vterm_api.mode_app_keypad
          lor Vterm_lib.Vterm_api.mode_app_cursor
          lor Vterm_lib.Vterm_api.mode_meta) in
  let kitty_fl = Vterm_lib.Vterm_api.kitty_flags vt in
  let write_pty s = Terminal.send term s in
  let send_key ~key ?(shifted_key=0) ~mods ?(text="") () =
    let seq =
      if kitty_fl > 0 then
        Vterm_lib.Vterm_api.kitty_keyseq ~key ~shifted_key
          ~modifiers:mods ~mode ~kitty_flags:kitty_fl
          ~event_type:1 ~text
      else
        Vterm_lib.Vterm_api.keyseq ~key ~modifiers:mods
          ~mode ~event_type:0
    in
    match seq with
    | Some s -> write_pty s
    | None ->
      (* Fallback: basic keys that keyseq doesn't handle *)
      let fallback =
        if key = Vterm_lib.Keys.enter then Some "\r"
        else if key = Vterm_lib.Keys.backspace then Some "\x7f"
        else if key = Vterm_lib.Keys.tab then Some "\t"
        else if key = Vterm_lib.Keys.escape then Some "\x1b"
        else if key < 0x100 && mods = 0 then
          (* ASCII-range text key, no modifiers *)
          Some (String.make 1 (Char.chr key))
        else None
      in
      (match fallback with
       | Some s -> write_pty s
       | None -> ())
  in
  match ev with
  | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
    let buf = Stdlib.Buffer.create 4 in
    encode_utf8 buf cp;
    write_pty (Stdlib.Buffer.contents buf)
  | Input.Key (cp, mods) when cp < 32 && mods.ctrl ->
    (* Ctrl+letter: codepoint is 1-26 (ETX etc.), send raw byte *)
    write_pty (String.make 1 (Char.chr cp))
  | Input.Key (cp, mods) when mods.ctrl && cp >= 64 && cp <= 127 ->
    (* Ctrl+letter via Kitty: cp is the letter (e.g. 99='c'),
       convert to control byte (cp land 0x1f) *)
    let ctrl_byte = cp land 0x1f in
    if mods.alt then
      write_pty (Printf.sprintf "\x1b%c" (Char.chr ctrl_byte))
    else
      write_pty (String.make 1 (Char.chr ctrl_byte))
  | Input.Key (cp, mods) when mods.alt && not mods.ctrl && cp < 128 ->
    write_pty (Printf.sprintf "\x1b%c" (Char.chr cp))
  | Input.Key (cp, mods) ->
    send_key ~key:cp ~mods:(input_mod mods) ()
  | Input.Special (key, mods) ->
    let k = match key with
      | Input.Up -> Vterm_lib.Keys.up
      | Input.Down -> Vterm_lib.Keys.down
      | Input.Left -> Vterm_lib.Keys.left
      | Input.Right -> Vterm_lib.Keys.right
      | Input.Home -> Vterm_lib.Keys.home
      | Input.End -> Vterm_lib.Keys.end_
      | Input.PageUp -> Vterm_lib.Keys.page_up
      | Input.PageDown -> Vterm_lib.Keys.page_down
      | Input.Insert -> Vterm_lib.Keys.insert
      | Input.Delete -> Vterm_lib.Keys.delete
      | Input.Backspace -> Vterm_lib.Keys.backspace
      | Input.Tab -> Vterm_lib.Keys.tab
      | Input.Enter -> Vterm_lib.Keys.enter
      | Input.Escape -> Vterm_lib.Keys.escape
      | Input.F n -> Vterm_lib.Keys.f1 + (n - 1)
    in
    send_key ~key:k ~mods:(input_mod mods) ()
  | Input.Paste text ->
    if Vterm_lib.Vterm_api.bracketed_paste vt then begin
      write_pty "\027[200~";
      write_pty text;
      write_pty "\027[201~"
    end else
      write_pty text
  | _ -> ()
