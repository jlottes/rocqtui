open Action

let query_subject (ctx : Editor_context.t) (tab : Tab.t) =
  match ctx.focus with
  | FGoals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
  | FMessages ->
    (match Geom.active_msg_pane_state tab with
     | `Text (sel, cache, _) -> View.pane_selection_text sel cache
     | `Terminal -> None)
  | FFileTree -> None
  | FScript ->
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
      (match query_subject ctx tab with
       | Some word -> run_query session (prefix ^ " " ^ word ^ ".")
       | None -> ()); true
    in
    let handled =
      if c = 'a' then with_subject "About"
      else if c = 'c' then with_subject "Check"
      else if c = 'd' then with_subject "Print"
      else if c = 'l' then with_subject "Locate"
      else if c = 'g' then begin
        (match query_subject ctx tab, session with
         | Some word, Some s -> coercion_filter s word
         | _ -> ()); true
      end
      else if c = 'p' then (run_query session "Show Proof."; true)
      else if c = 'e' then (run_query session "Show Existentials."; true)
      else false
    in
    if handled then Some Continue else None

(* Move the buffer cursor to the active match in [tab], if any. *)
let move_cursor_to_current (ctx : Editor_context.t) (tab : Tab.t) =
  match Editor_context.tab_matches ctx tab with
  | None -> ()
  | Some bm ->
    (match Search.bm_current_match bm with
     | Some m -> Buffer.move_to tab.buf m.start_.line m.start_.col
     | None -> ())

(* Make sure ctx.search_query is allocated. Returns the (now-present)
   query_state. *)
let ensure_search_query (ctx : Editor_context.t) : Search.query_state =
  match ctx.search_query with
  | Some q -> q
  | None ->
    let q = Search.empty_query in
    ctx.search_query <- Some q;
    Editor_context.bump_search_gen ctx;
    q

(* Append text to the focused field; bump the gen so per-tab matches
   refresh on next access; move the cursor to the new current match
   when typing in Find. *)
let append_to_field (ctx : Editor_context.t) (tab : Tab.t) text =
  let q = ensure_search_query ctx in
  let q' = match q.focus with
    | Search.Find -> { q with query = q.query ^ text }
    | Search.Replace -> { q with replacement = q.replacement ^ text }
  in
  ctx.search_query <- Some q';
  Editor_context.bump_search_gen ctx;
  if q.focus = Search.Find then move_cursor_to_current ctx tab

let backspace_focused (ctx : Editor_context.t) (tab : Tab.t) =
  match ctx.search_query with
  | None -> ()
  | Some q ->
    let pop str =
      if str = "" then str
      else String.sub str 0 (Utf8.prev str (String.length str)) in
    let q' = match q.focus with
      | Search.Find -> { q with query = pop q.query }
      | Search.Replace -> { q with replacement = pop q.replacement }
    in
    ctx.search_query <- Some q';
    Editor_context.bump_search_gen ctx;
    if q.focus = Search.Find then move_cursor_to_current ctx tab

(* In-place advance the active tab's [current], then move the buffer
   cursor. Single-file F3/Shift+F3; Phase 3 re-introduces cross-file
   stepping in project mode. *)
let search_advance (ctx : Editor_context.t) (tab : Tab.t) dir =
  match Editor_context.tab_matches ctx tab with
  | None -> ()
  | Some bm ->
    (match dir with
     | `Next -> Search.bm_next bm
     | `Prev -> Search.bm_prev bm);
    move_cursor_to_current ctx tab

(* Restart (or cancel) the project-wide scanner. Reads the query
   from the global ctx.search_query. *)
let project_search_kick (ctx : Editor_context.t) (tab : Tab.t) =
  if not ctx.project_mode then
    Project_search.cancel ctx.project_search
  else
    match Buffer.filename tab.buf with
    | None -> Project_search.cancel ctx.project_search
    | Some fname ->
      (match Project.find_project_file (Filename.dirname fname) with
       | None -> Project_search.cancel ctx.project_search
       | Some (project_dir, project_file) ->
         let (query, flags) = match ctx.search_query with
           | Some q -> q.query, q.flags
           | None -> "", Search.empty_flags
         in
         if query = "" then
           Project_search.cancel ctx.project_search
         else
           Project_search.start ctx.project_search
             ~project_dir ~project_file ~query ~flags)

(* F3 / Shift+F3 dispatcher. In single-file mode walks the active
   tab's matches. In project mode walks the merged-stream
   Search_results.t from Editor_context.search_snapshot; when the
   next match is in a different file, returns Open_file so the
   editor opens (or switches to) that file before jumping. *)
let dispatched_advance (ctx : Editor_context.t) (tab : Tab.t) dir
  : Action.action option =
  if not ctx.project_mode then begin
    search_advance ctx tab dir;
    Some Action.Continue
  end
  else
    match Editor_context.search_snapshot ctx tab with
    | None -> Some Action.Continue
    | Some sr ->
      let forward = (dir = `Next) in
      match Search_results.advance sr ~forward with
      | None -> Some Action.Continue
      | Some (path, m) ->
        let target_line = m.ml_line - 1 in
        let target_col = m.ml_col_start in
        let active_path = Buffer.filename tab.buf in
        if Some path = active_path then begin
          (* Same tab: move cursor and update tab.buffer_matches.current
             to match the new global position. *)
          Buffer.move_to tab.buf target_line target_col;
          (match Editor_context.tab_matches ctx tab,
                 Search_results.current sr with
           | Some bm, Some (_, idx) when idx >= 0
                                         && idx < Array.length bm.matches ->
             Search.bm_set_current bm idx
           | _ -> ());
          Some Action.Continue
        end
        else begin
          (* Cross-file. If the destination is already open as a tab,
             save its pre-search cursor for ESC rollback before we
             clobber it via jump_target. *)
          List.iter (fun (other : Tab.t) ->
            if Buffer.filename other.buf = Some path then
              Editor_context.touch_tab_for_session ctx other
          ) (ctx.tabs ());
          Jump.push ctx tab;
          ctx.jump_target <- Some (target_line, target_col);
          Some (Action.Open_file path)
        end

(* Byte offset of (line, col) within [Buffer.text buf]. *)
let pos_to_byte (buf : Buffer.t) (p : Search.pos) =
  let off = ref 0 in
  for i = 0 to p.line - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + p.col

(* Compute the replacement text for [m] under the active query. *)
let substitute_for_match (q : Search.query_state) (buf : Buffer.t)
    (m : Search.match_) =
  let start = pos_to_byte buf m.start_ in
  let old_end = pos_to_byte buf m.end_ in
  let matched = String.sub (Buffer.text buf) start (old_end - start) in
  let new_text = Search.substitute
    ~query:q.query ~flags:q.flags
    ~replacement:q.replacement ~matched in
  (start, old_end, new_text)

(* Replace the current match and advance to the next. Skip-advances on
   region-invariant rejection. *)
let replace_current (ctx : Editor_context.t) (tab : Tab.t) =
  match ctx.search_query, Editor_context.tab_matches ctx tab with
  | Some q, Some bm ->
    (match Search.bm_current_match bm with
     | None -> ()
     | Some m ->
       let (start, old_end, new_text) = substitute_for_match q tab.buf m in
       (match Region_buffer.try_replace tab.rb ~start ~old_end new_text with
        | Region_buffer.Applied ->
          (* Buffer revision changed; lazy accessor refreshes. Advance
             past the replacement so a self-matching replacement (e.g.
             "foo" → "foofoo") doesn't pin the cursor. *)
          (match Editor_context.tab_matches ctx tab with
           | Some bm' -> Search.bm_next bm'
           | None -> ());
          move_cursor_to_current ctx tab
        | Region_buffer.Rejected _ ->
          search_advance ctx tab `Next))
  | _ -> ()

(* Replace every match in the current tab's match list. *)
let replace_all (ctx : Editor_context.t) (tab : Tab.t) =
  match ctx.search_query, Editor_context.tab_matches ctx tab with
  | Some q, Some bm ->
    let applied = ref 0 in
    let skipped = ref 0 in
    let n = Array.length bm.matches in
    for i = n - 1 downto 0 do
      let (start, old_end, new_text) =
        substitute_for_match q tab.buf bm.matches.(i) in
      (match Region_buffer.try_replace tab.rb ~start ~old_end new_text with
       | Region_buffer.Applied -> incr applied
       | Region_buffer.Rejected _ -> incr skipped)
    done;
    ignore (Editor_context.tab_matches ctx tab);  (* trigger refresh *)
    (!applied, !skipped)
  | _ -> (0, 0)

let logical_escape (ctx : Editor_context.t) (tab : Tab.t) =
  let _ = tab in
  match Modal.top ctx.modal with
  | Some Modal.SearchPrompt ->
    ignore (Editor_context.rollback_search_session ctx);
    Editor_context.clear_search ctx;
    Modal.pop ctx.modal;
    true
  | _ ->
    (match ctx.search_query with
     | Some _ ->
       (* Out-of-prompt ESC with an active search: rollback any
          session state (rare — usually the session ends when the
          prompt is dismissed) and clear. *)
       ignore (Editor_context.rollback_search_session ctx);
       Editor_context.clear_search ctx;
       true
     | None -> false)

let handle_search_prompt (ctx : Editor_context.t) ev (tab : Tab.t) =
  (* Toggle a query-state flag in-place: mutate ctx.search_query, bump
     the gen, kick project search if active, move cursor to the (new)
     current match. *)
  let toggle_flag f =
    let q = ensure_search_query ctx in
    let new_flags = f q.flags in
    ctx.search_query <- Some { q with flags = new_flags };
    Editor_context.bump_search_gen ctx;
    project_search_kick ctx tab;
    move_cursor_to_current ctx tab;
    Some Continue
  in
  let toggle_case (fs : Search.flags) : Search.flags =
    let case = match fs.case with
      | Search.Smart -> Search.Sensitive
      | Search.Sensitive -> Search.Smart in
    { fs with case }
  in
  let toggle_regex (fs : Search.flags) : Search.flags =
    { fs with regex = not fs.regex }
  in
  (* Any user interaction (other than passthrough scroll) clears the
     transient panel message. The replace paths re-set it afterwards. *)
  (match ev with
   | Input.Mouse mev
     when mev.button = Input.ScrollUp || mev.button = Input.ScrollDown -> ()
   | _ -> ctx.search_panel_msg <- "");
  match ev with
  | Input.Special (Input.Enter, _) ->
    (* Accept the search: keep ctx.search_query and per-tab matches
       so F3 outside the prompt still works, but drop the
       ESC-rollback session — user is committing to the new cursor
       positions. *)
    Editor_context.drop_search_session ctx;
    Modal.pop ctx.modal;
    Some Continue

  | Input.Special (Input.Escape, _) ->
    (match ctx.compose with
     | Some cs -> Compose.start cs
     | None -> ignore (logical_escape ctx tab));
    Some Continue

  | Input.Special (Input.Backspace, _) ->
    backspace_focused ctx tab;
    project_search_kick ctx tab;
    Some Continue

  | ev when Keymatch.match_binding ev Keys.search_toggle_case ->
    toggle_flag toggle_case

  | ev when Keymatch.match_binding ev Keys.search_toggle_regex ->
    toggle_flag toggle_regex

  | ev when Keymatch.match_binding ev Keys.search_toggle_project ->
    ctx.project_mode <- not ctx.project_mode;
    if ctx.project_mode then begin
      project_search_kick ctx tab;
      Msg_pane.activate_unless_terminal Msg_pane.Search
    end
    else
      Project_search.cancel ctx.project_search;
    Some Continue

  | ev when Keymatch.match_binding ev Keys.search_field_toggle ->
    (match ctx.search_query with
     | Some q ->
       let other = match q.focus with
         | Search.Find -> Search.Replace
         | Search.Replace -> Search.Find in
       ctx.search_query <- Some { q with focus = other }
     | None -> ());
    Some Continue

  | ev when Keymatch.match_binding ev Keys.search_replace_one ->
    replace_current ctx tab;
    Some Continue

  | ev when Keymatch.match_binding ev Keys.search_replace_all ->
    let (applied, skipped) = replace_all ctx tab in
    ctx.search_panel_msg <-
      (if applied = 0 && skipped = 0 then "No matches to replace"
       else if skipped > 0 then
         Printf.sprintf "Replaced %d (%d skipped — verified region)"
           applied skipped
       else
         Printf.sprintf "Replaced %d occurrence%s" applied
           (if applied = 1 then "" else "s"));
    Some Continue

  | ev when Keymatch.match_binding ev Keys.search_next ->
    dispatched_advance ctx tab `Next

  | ev when Keymatch.match_binding ev Keys.search_prev ->
    dispatched_advance ctx tab `Prev

  (* Printable codepoint (ASCII or UTF-8): append to the focused field. *)
  | Input.Key (cp, m)
    when not m.ctrl && not m.alt && cp >= 32 && cp <> 127 ->
    append_to_field ctx tab (Utf8.encode cp);
    project_search_kick ctx tab;
    Some Continue

  (* Mouse events fall through to the normal handler so the user can
     scroll, click match rows in the Search tab, switch sub-tabs in
     the messages pane, etc. while the prompt is open. *)
  | Input.Mouse _ ->
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
