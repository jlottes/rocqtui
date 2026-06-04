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

let handle_build (ctx : Editor_context.t) ev (tab : Tab.t) r =
  let buf = tab.buf in
  Modal.pop ctx.modal;
  let on_build_started () =
    ignore (Msg_pane.ensure Msg_pane.Build);
    Msg_pane.activate_unless_terminal Msg_pane.Build
  in
  let project_dir = match ctx.project with
    | Some p -> Some p.Project.project_dir
    | None -> None
  in
  match Keymatch.codepoint_of_event ev with
  | None -> Some Continue
  | Some ch ->
    let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
    if c = 'c' && Build.is_running () then
      (Build.cancel (); Some Continue)
    else if c = 'f' then begin
      (match Buffer.filename buf, project_dir with
       | Some f, Some pd ->
         if Build.build_file ~project_dir:pd f then on_build_started ()
         else Render.set_status r "Build already running."
       | _, None -> Render.set_status r "No project."
       | None, _ -> Render.set_status r "No filename.");
      Some Continue
    end
    else if c = 'd' then begin
      (match Buffer.filename buf, project_dir with
       | Some f, Some pd ->
         if Build.build_deps ~project_dir:pd f then on_build_started ()
         else Render.set_status r "Build already running."
       | _, None -> Render.set_status r "No project."
       | None, _ -> Render.set_status r "No filename.");
      Some Continue
    end
    else if c = 'a' then begin
      (match project_dir with
       | Some pd ->
         if Build.build_all ~project_dir:pd then on_build_started ()
         else Render.set_status r "Build already running."
       | None -> Render.set_status r "No project.");
      Some Continue
    end
    else if c = 'x' then begin
      (match project_dir with
       | Some pd ->
         if Build.build_clean ~project_dir:pd then on_build_started ()
         else Render.set_status r "Build already running."
       | None -> Render.set_status r "No project.");
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
  Msg_pane.activate Msg_pane.Rocq;
  Session.query session "Print Graph." ~on_done:(fun pps ->
    let all_msgs = List.map Session.string_of_pp pps in
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
      Session.set_messages session filtered)

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
    let q = Search.empty_query () in
    ctx.search_query <- Some q;
    Editor_context.bump_search_gen ctx;
    q

(* Field corresponding to the current focus. *)
let focused_field (q : Search.query_state) =
  match q.focus with
  | Search.Find -> q.query
  | Search.Replace -> q.replacement

(* Append text to the focused field; bump the gen so per-tab matches
   refresh on next access; move the cursor to the new current match
   when typing in Find. *)
let append_to_field (ctx : Editor_context.t) (tab : Tab.t) text =
  let q = ensure_search_query ctx in
  Text_field.insert (focused_field q) text;
  Editor_context.bump_search_gen ctx;
  if q.focus = Search.Find then move_cursor_to_current ctx tab

(* Dispatch an arbitrary text-edit event to the focused field. Returns
   true if [Text_field] claimed it. *)
let dispatch_to_focused (ctx : Editor_context.t) (tab : Tab.t) ev =
  match ctx.search_query with
  | None -> false
  | Some q ->
    if Text_field.handle_key (focused_field q) ev then begin
      Editor_context.bump_search_gen ctx;
      if q.focus = Search.Find then move_cursor_to_current ctx tab;
      true
    end else false

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
let project_search_kick (ctx : Editor_context.t) (_tab : Tab.t) =
  if not ctx.project_mode then
    Project_search.cancel ctx.project_search
  else
    match ctx.project with
    | None -> Project_search.cancel ctx.project_search
    | Some p ->
      let (query, flags) = match ctx.search_query with
        | Some q -> Text_field.contents q.query, q.flags
        | None -> "", Search.empty_flags
      in
      if query = "" then
        Project_search.cancel ctx.project_search
      else
        Project_search.start ctx.project_search
          ~project_dir:p.project_dir ~project_file:p.path
          ~query ~flags

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
    ~query:(Text_field.contents q.query) ~flags:q.flags
    ~replacement:(Text_field.contents q.replacement) ~matched in
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

  (* Mouse events fall through to the normal handler so the user can
     scroll, click match rows in the Search tab, switch sub-tabs in
     the messages pane, etc. while the prompt is open. *)
  | Input.Mouse _ ->
    None

  (* Text-field edits (printable chars, Backspace/Delete, Left/Right,
     Home/End). Anything Text_field doesn't claim falls through to
     [Some Continue], which absorbs the event so we don't accidentally
     trigger global hotkeys (modifier combos, etc.) while the prompt
     is open. *)
  | ev ->
    if dispatch_to_focused ctx tab ev then
      project_search_kick ctx tab;
    Some Continue

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

(* --- Rename prompt --- *)

(* Normalize a path by collapsing "." and "..". Returns the canonical
   form, or [None] if the path escapes its root (more ".." segments
   than directories). *)
let normalize_segments segs =
  let rec walk acc = function
    | [] -> Some (List.rev acc)
    | "" :: rest -> walk acc rest          (* "/foo//bar" → drop empties *)
    | "." :: rest -> walk acc rest
    | ".." :: rest ->
      (match acc with
       | [] -> None                        (* escapes root *)
       | _ :: tl -> walk tl rest)
    | seg :: rest -> walk (seg :: acc) rest
  in
  walk [] segs

let resolve_in_project ~project_dir rel =
  match normalize_segments (String.split_on_char '/' rel) with
  | None -> Error "target escapes the project root"
  | Some [] -> Error "empty filename"
  | Some parts ->
    let rel = String.concat "/" parts in
    Ok (Filename.concat project_dir rel, rel)

let rec mkdir_p path =
  if Sys.file_exists path then ()
  else begin
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then
      mkdir_p parent;
    try Unix.mkdir path 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Carry out the rename: Sys.rename, update any open tab pointing at
   [old_path], update [_RocqProject] if the file was listed, and add
   a fresh inotify watch on the new path (the old watch self-cleans
   via [IN_IGNORED]). Sets a status message describing the result. *)
let rel_under_project ~(project : Project.t) abs =
  let prefix = project.project_dir ^ "/" in
  let plen = String.length prefix in
  if String.length abs > plen
     && String.sub abs 0 plen = prefix
  then String.sub abs plen (String.length abs - plen)
  else abs

let execute_rename (ctx : Editor_context.t) r ~old_path ~new_path =
  match Sys.rename old_path new_path with
  | exception Sys_error msg ->
    Render.set_status r (Printf.sprintf "Rename failed: %s" msg)
  | () ->
    List.iter (fun (tab : Tab.t) ->
      match Buffer.filename tab.buf with
      | Some f when f = old_path ->
        Buffer.set_filename tab.buf new_path;
        ctx.add_file_watch new_path
      | _ -> ()
    ) (ctx.tabs ());
    (match ctx.project with
     | None ->
       Render.set_status r
         (Printf.sprintf "Renamed %s \xe2\x86\x92 %s" old_path new_path)
     | Some p ->
       let project = Project.read p.path in
       let old_rel = rel_under_project ~project old_path in
       let new_rel = rel_under_project ~project new_path in
       let _ = Project.rename_member project ~old_rel ~new_rel in
       let verb =
         if Filename.dirname old_rel = Filename.dirname new_rel
         then "Renamed" else "Moved" in
       Render.set_status r
         (Printf.sprintf "%s %s \xe2\x86\x92 %s" verb old_rel new_rel))

(* Validate the input + dispatch. Either:
   - reject with a status message (prompt stays open),
   - swap to a Modal.Prompt confirmation when the target's parent dir
     doesn't exist,
   - or execute the rename inline. *)
let commit_rename_prompt (ctx : Editor_context.t) (rp : Modal.rename_state) r =
  let project_dir = match ctx.project with
    | Some p -> p.Project.project_dir
    | None -> Filename.dirname rp.old_path
  in
  let final_rel = Text_field.contents rp.field ^ rp.extension in
  match resolve_in_project ~project_dir final_rel with
  | Error msg ->
    Render.set_status r (Printf.sprintf "Rename: %s" msg)
  | Ok (new_path, new_rel) ->
    if new_path = rp.old_path then begin
      Modal.pop ctx.modal;
      Render.set_status r "Rename: unchanged"
    end
    else if Sys.file_exists new_path then
      Render.set_status r
        (Printf.sprintf "Rename: %s already exists" new_rel)
    else
      let parent = Filename.dirname new_path in
      if Sys.file_exists parent then begin
        Modal.pop ctx.modal;
        execute_rename ctx r ~old_path:rp.old_path ~new_path
      end
      else begin
        (* Confirm before creating intermediate directories. *)
        Modal.pop ctx.modal;
        let parent_rel =
          let prefix = project_dir ^ "/" in
          let plen = String.length prefix in
          if String.length parent > plen
             && String.sub parent 0 plen = prefix
          then String.sub parent plen (String.length parent - plen)
          else parent
        in
        let old_path = rp.old_path in
        Modal.push ctx.modal (Modal.Prompt {
          message = Printf.sprintf
            "Create directory %s/ ? r to confirm, ESC to cancel."
            parent_rel;
          handler = (fun ev ->
            match ev with
            | Input.Key (114, mods)
              when not (mods.alt || mods.ctrl || mods.super) ->
              (try mkdir_p parent with Unix.Unix_error (e, _, _) ->
                 Render.set_status r
                   (Printf.sprintf "mkdir: %s" (Unix.error_message e)));
              if Sys.file_exists parent then
                execute_rename ctx r ~old_path ~new_path;
              Modal.Handled
            | _ -> Modal.Dismissed)
        })
      end

let handle_rename_prompt (ctx : Editor_context.t) ev r =
  match Modal.top ctx.modal with
  | Some (Modal.RenamePrompt rp) ->
    if Text_field.handle_key rp.field ev then Some Continue
    else (match ev with
     | Input.Special (Input.Escape, _) ->
       Modal.pop ctx.modal;
       Some Continue
     | Input.Special (Input.Enter, _) ->
       commit_rename_prompt ctx rp r;
       Some Continue
     | _ -> Some Continue)
  | _ -> None

(* --- Save-as prompt --- *)

let tab_by_id (ctx : Editor_context.t) id =
  List.find_opt (fun (t : Tab.t) -> t.id = id) (ctx.tabs ())

let execute_save_as (ctx : Editor_context.t) r ~tab_id ~new_path =
  match tab_by_id ctx tab_id with
  | None ->
    Render.set_status r "Save as: tab no longer exists"
  | Some tab ->
    Buffer.set_filename tab.buf new_path;
    if Buffer.save tab.buf then begin
      ctx.add_file_watch new_path;
      Render.set_status r
        (Printf.sprintf "Saved to %s" (Filename.basename new_path))
    end
    else
      Render.set_status r "Error saving file."

let commit_save_as_prompt (ctx : Editor_context.t)
    (sp : Modal.save_as_state) r =
  let project_dir = match ctx.project with
    | Some p -> p.Project.project_dir
    | None -> Sys.getcwd ()
  in
  let final_rel = Text_field.contents sp.field ^ sp.extension in
  match resolve_in_project ~project_dir final_rel with
  | Error msg ->
    Render.set_status r (Printf.sprintf "Save as: %s" msg)
  | Ok (new_path, new_rel) ->
    if Sys.file_exists new_path then
      Render.set_status r
        (Printf.sprintf "Save as: %s already exists" new_rel)
    else
      let parent = Filename.dirname new_path in
      if Sys.file_exists parent then begin
        Modal.pop ctx.modal;
        execute_save_as ctx r ~tab_id:sp.tab_id ~new_path
      end
      else begin
        Modal.pop ctx.modal;
        let parent_rel =
          let prefix = project_dir ^ "/" in
          let plen = String.length prefix in
          if String.length parent > plen
             && String.sub parent 0 plen = prefix
          then String.sub parent plen (String.length parent - plen)
          else parent
        in
        let tab_id = sp.tab_id in
        Modal.push ctx.modal (Modal.Prompt {
          message = Printf.sprintf
            "Create directory %s/ ? %s to confirm, ESC to cancel."
            parent_rel Keys.save.Keys.display;
          handler = (fun ev ->
            if Keymatch.match_binding ev Keys.save then begin
              (try mkdir_p parent with Unix.Unix_error (e, _, _) ->
                 Render.set_status r
                   (Printf.sprintf "mkdir: %s" (Unix.error_message e)));
              if Sys.file_exists parent then
                execute_save_as ctx r ~tab_id ~new_path;
              Modal.Handled
            end
            else Modal.Dismissed)
        })
      end

let handle_save_as_prompt (ctx : Editor_context.t) ev r =
  match Modal.top ctx.modal with
  | Some (Modal.SaveAsPrompt sp) ->
    if Text_field.handle_key sp.field ev then Some Continue
    else (match ev with
     | Input.Special (Input.Escape, _) ->
       Modal.pop ctx.modal;
       Some Continue
     | Input.Special (Input.Enter, _) ->
       commit_save_as_prompt ctx sp r;
       Some Continue
     | _ -> Some Continue)
  | _ -> None
