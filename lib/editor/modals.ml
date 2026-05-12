open Action

let query_subject (tab : Tab.t) =
  match tab.focused_pane with
  | `Goals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
  | `Messages ->
    (match Geom.active_msg_pane_state tab with
     | `Text (sel, cache, _) -> View.pane_selection_text sel cache
     | `Terminal -> None)
  | `Script ->
    match Buffer.selected_text tab.buf with
    | Some text -> Some text
    | None ->
      match Highlight.qualid_at_cursor tab.buf with
      | Some _ as s -> s
      | None -> Buffer.word_at_cursor tab.buf

let run_query session phrase =
  match session with
  | Some s -> Session.query s phrase; Msg_pane.activate Msg_pane.Rocq
  | None -> ()

let handle_prompt (ctx : Editor_context.t) handler ev =
  match handler ev with
  | Modal.Handled -> Modal.pop ctx.modal; Some Continue
  | Modal.Dismissed -> Modal.pop ctx.modal; None
  | Modal.Ignored -> Some Continue

let handle_picker (ctx : Editor_context.t) fp ev =
  let (_box_top, box_left, box_w, _box_h, visible_rows) =
    File_picker.box_geometry () in
  let act = function
    | File_picker.PickerOpen path -> Modal.pop ctx.modal; Open_file path
    | File_picker.PickerClose -> Modal.pop ctx.modal; Continue
    | File_picker.PickerContinue -> Continue
  in
  match ev with
  | Input.Mouse mev ->
    let b1_click = mev.button = Input.Left in
    let scroll_up = mev.button = Input.ScrollUp in
    let scroll_down = mev.button = Input.ScrollDown in
    if b1_click then
      let (box_top, _, _, _, _) = File_picker.box_geometry () in
      act (File_picker.handle_click fp ~y:mev.y ~x:mev.x ~box_top
             ~box_left ~box_width:box_w ~visible_rows)
    else if scroll_up then
      (File_picker.handle_scroll fp (-1) visible_rows; Continue)
    else if scroll_down then
      (File_picker.handle_scroll fp 1 visible_rows; Continue)
    else Continue
  | Input.Special (Input.Escape, _) -> Modal.pop ctx.modal; Continue
  | Input.Key (cp, mods) ->
    let ch = if mods.ctrl && cp >= 97 && cp <= 122 then cp - 96 else cp in
    act (File_picker.handle_key fp ch visible_rows)
  | Input.Special (key, _mods) ->
    let ch = match key with
      | Input.Up -> 259 | Input.Down -> 258
      | Input.PageUp -> 339 | Input.PageDown -> 338
      | Input.Enter -> 13 | Input.Tab -> 9
      | Input.Backspace -> 127
      | _ -> 0
    in
    if ch <> 0 then act (File_picker.handle_key fp ch visible_rows)
    else Continue
  | _ -> Continue

let close_options (ctx : Editor_context.t) session =
  Modal.pop ctx.modal;
  (match session with Some s -> Session.sync_options_and_refresh s | None -> ())

let handle_options (ctx : Editor_context.t) ev (tab : Tab.t) =
  let session = tab.session in
  match Keymatch.codepoint_of_event ev with
  | Some ch ->
    let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
    (match List.find_opt (fun (e : Printopts.entry) -> e.key = c) Printopts.entries with
     | Some entry ->
       Printopts.toggle entry;
       (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
       Some Continue
     | None -> close_options ctx session; None)
  | None -> close_options ctx session; None

let handle_theme (ctx : Editor_context.t) ev =
  Modal.pop ctx.modal;
  (match Keymatch.codepoint_of_event ev with
   | Some ch ->
     let idx = ch - Char.code '1' in
     let themes = Theme.available in
     if idx >= 0 && idx < List.length themes then begin
       let name = List.nth themes idx in
       let theme = Theme.find name in
       Theme.apply theme;
       ctx.theme_name <- name
     end
   | None -> ());
  Some Continue

let project_dir_of_buf buf =
  let dir = match Buffer.filename buf with
    | Some f -> Filename.dirname f | None -> Sys.getcwd () in
  match Project.find_project_file dir with
  | Some (pd, _) -> Some pd
  | None -> None

let handle_build (ctx : Editor_context.t) ev (tab : Tab.t) r =
  let buf = tab.buf in
  Modal.pop ctx.modal;
  let on_build_started () =
    ignore (Msg_pane.ensure Msg_pane.Build);
    Msg_pane.activate_unless_terminal Msg_pane.Build
  in
  match Keymatch.codepoint_of_event ev with
  | None -> Some Continue
  | Some ch ->
    let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
    if c = 'c' && Build.is_running () then
      (Build.cancel (); Some Continue)
    else if c = 'f' then begin
      (match Buffer.filename buf, project_dir_of_buf buf with
       | Some f, Some pd ->
         if Build.build_file ~project_dir:pd f then on_build_started ()
         else Render.set_status r "Build already running."
       | _, None -> Render.set_status r "No project found."
       | None, _ -> Render.set_status r "No filename.");
      Some Continue
    end
    else if c = 'd' then begin
      (match Buffer.filename buf, project_dir_of_buf buf with
       | Some f, Some pd ->
         if Build.build_deps ~project_dir:pd f then on_build_started ()
         else Render.set_status r "Build already running."
       | _, None -> Render.set_status r "No project found."
       | None, _ -> Render.set_status r "No filename.");
      Some Continue
    end
    else if c = 'a' then begin
      (match project_dir_of_buf buf with
       | Some pd ->
         if Build.build_all ~project_dir:pd then on_build_started ()
         else Render.set_status r "Build already running."
       | None -> Render.set_status r "No project found.");
      Some Continue
    end
    else if c = 'x' then begin
      (match project_dir_of_buf buf with
       | Some pd ->
         if Build.build_clean ~project_dir:pd then on_build_started ()
         else Render.set_status r "Build already running."
       | None -> Render.set_status r "No project found.");
      Some Continue
    end
    else Some Continue

(* Substring search — line contains [needle]. *)
let line_contains needle line =
  let nlen = String.length needle in
  let llen = String.length line in
  let rec scan i =
    if i + nlen > llen then false
    else if String.sub line i nlen = needle then true
    else scan (i + 1)
  in
  scan 0

let coercion_filter session word =
  Session.query session "Print Graph.";
  let all_msgs = Session.messages session in
  let matches line =
    line_contains (" " ^ word ^ " >->") line
    || line_contains (">-> " ^ word) line
    || line_contains ("." ^ word ^ " >->") line
  in
  let filtered = List.concat_map (fun msg ->
    let lines = String.split_on_char '\n' msg in
    List.filter (fun line -> String.length line > 0 && matches line) lines
  ) all_msgs in
  if filtered = [] then
    Session.set_messages session ["No coercions found for " ^ word ^ "."]
  else
    Session.set_messages session filtered;
  Msg_pane.activate Msg_pane.Rocq

let handle_query (ctx : Editor_context.t) ev (tab : Tab.t) =
  let session = tab.session in
  Modal.pop ctx.modal;
  match Keymatch.codepoint_of_event ev with
  | None -> None
  | Some ch ->
    let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
    let with_subject prefix =
      (match query_subject tab with
       | Some word -> run_query session (prefix ^ " " ^ word ^ ".")
       | None -> ()); true
    in
    let handled =
      if c = 'a' then with_subject "About"
      else if c = 'c' then with_subject "Check"
      else if c = 'd' then with_subject "Print"
      else if c = 'l' then with_subject "Locate"
      else if c = 'g' then begin
        (match query_subject tab, session with
         | Some word, Some s -> coercion_filter s word
         | _ -> ()); true
      end
      else if c = 'p' then (run_query session "Show Proof."; true)
      else if c = 'e' then (run_query session "Show Existentials."; true)
      else false
    in
    if handled then Some Continue else None

(* Move the buffer cursor to the current match, if any. Called after
   any operation that changes [current] so the user sees where the
   match is. *)
let move_cursor_to_current (tab : Tab.t) =
  match Tab.search_state tab with
  | Some s ->
    (match Search.current_match s with
     | Some m -> Buffer.move_to tab.buf m.start_.line m.start_.col
     | None -> ())
  | None -> ()

(* Append a string to the search query, recompute matches. Initializes
   a fresh state if search wasn't active. *)
let append_to_query (tab : Tab.t) text =
  let buf = tab.buf in
  let s = match Tab.search_state tab with
    | Some s -> s
    | None -> Search.create buf
  in
  Tab.set_search tab (Some (Search.update_query s buf (s.query ^ text)));
  move_cursor_to_current tab

let search_advance (tab : Tab.t) dir =
  match Tab.search_state tab with
  | Some s ->
    let s' = match dir with
      | `Next -> Search.next s
      | `Prev -> Search.prev s
    in
    Tab.set_search tab (Some s');
    move_cursor_to_current tab
  | None -> ()

let logical_escape (ctx : Editor_context.t) (tab : Tab.t) =
  match Modal.top ctx.modal with
  | Some Modal.SearchPrompt ->
    (match Tab.search_state tab with
     | Some s ->
       Buffer.move_to tab.buf s.saved_cursor.line s.saved_cursor.col
     | None -> ());
    Tab.set_search tab None;
    Modal.pop ctx.modal;
    true
  | _ ->
    (match Tab.search_state tab with
     | Some _ -> Tab.set_search tab None; true
     | None -> false)

let handle_search_prompt (ctx : Editor_context.t) ev (tab : Tab.t) =
  let buf = tab.buf in
  let with_state f =
    (match Tab.search_state tab with
     | Some s -> Tab.set_search tab (Some (f s buf))
     | None -> ());
    move_cursor_to_current tab;
    Some Continue
  in
  match ev with
  | Input.Special (Input.Enter, _) ->
    Modal.pop ctx.modal;
    Some Continue

  | Input.Special (Input.Escape, _) ->
    (* Compose mode: ESC starts compose; ESC ESC drops to the editor's
       compose-NoMatch path which calls [logical_escape]. Without compose:
       ESC cancels here directly. *)
    (match ctx.compose with
     | Some cs -> Compose.start cs
     | None -> ignore (logical_escape ctx tab));
    Some Continue

  | Input.Special (Input.Backspace, _) ->
    with_state (fun s buf ->
      if s.query = "" then s
      else
        let len = String.length s.query in
        let prev_off = Utf8.prev s.query len in
        Search.update_query s buf (String.sub s.query 0 prev_off))

  | ev when Keymatch.match_binding ev Keys.search_toggle_case ->
    with_state Search.toggle_case

  | ev when Keymatch.match_binding ev Keys.search_toggle_regex ->
    with_state Search.toggle_regex

  | ev when Keymatch.match_binding ev Keys.search_next ->
    search_advance tab `Next; Some Continue

  | ev when Keymatch.match_binding ev Keys.search_prev ->
    search_advance tab `Prev; Some Continue

  (* Printable codepoint (ASCII or UTF-8): append to the query. *)
  | Input.Key (cp, m)
    when not m.ctrl && not m.alt && cp >= 32 && cp <> 127 ->
    append_to_query tab (Utf8.encode cp);
    Some Continue

  (* Scroll wheel falls through to the normal mouse path so the user
     can scroll the buffer while the prompt is open. Clicks and other
     mouse events stay absorbed so they don't move the cursor or
     start a selection mid-search. *)
  | Input.Mouse mev
    when mev.button = Input.ScrollUp || mev.button = Input.ScrollDown ->
    None

  | _ -> Some Continue

let handle_help (ctx : Editor_context.t) ev r =
  let (rows, _) = Render.pane_dims r Render.PScript in
  let n = List.length View.help_lines in
  let max_scroll = max 0 (n - rows) in
  let scroll_by delta =
    View.set_help_scroll ctx
      (max 0 (min max_scroll (View.get_help_scroll ctx + delta))) in
  match ev with
  | Input.Special (Input.Up, _) -> scroll_by (-1); Some Continue
  | Input.Special (Input.Down, _) -> scroll_by 1; Some Continue
  | Input.Special (Input.PageUp, _) -> scroll_by (-rows); Some Continue
  | Input.Special (Input.PageDown, _) -> scroll_by rows; Some Continue
  | Input.Special (Input.Home, _) -> View.set_help_scroll ctx 0; Some Continue
  | Input.Special (Input.End, _) -> View.set_help_scroll ctx max_scroll; Some Continue
  | Input.Mouse mev ->
    if mev.button = Input.ScrollUp then scroll_by (-3)
    else if mev.button = Input.ScrollDown then scroll_by 3;
    Some Continue
  | _ ->
    Modal.pop ctx.modal;
    View.set_help_scroll ctx 0;
    Some Continue
