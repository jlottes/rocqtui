let debug_input = try Sys.getenv "ROCQTUI_DEBUG_INPUT" <> "" with Not_found -> false

type jump_point = Action.jump_point

type action = Action.action =
  | Continue
  | Quit
  | Close_tab
  | Save_prompt
  | Reload
  | Open_file of string
  | Jump_back of jump_point


let init_compose (ctx : Editor_context.t) =
  ctx.compose <- Some (Compose.load ())

let take_jump_target (ctx : Editor_context.t) =
  let v = ctx.jump_target in
  ctx.jump_target <- None;
  v

(* --- Input event handling --- *)

let handle_event (ctx : Editor_context.t) (ev : Input.event) (tab : Tab.t) r =
  (* Record time of any user input event for the AI idle trigger. *)
  ctx.last_input_time <- Unix.gettimeofday ();
  let buf = tab.buf in
  let session = tab.session in
  (* Is a terminal sub-tab currently focused? *)
  let term_focused =
    ctx.focus = FMessages &&
    (match Msg_pane.active_kind () with
     | Msg_pane.Terminal _ -> true
     | _ -> false)
  in
  let active_term () = match Msg_pane.active_kind () with
    | Msg_pane.Terminal t -> Some t
    | _ -> None
  in
  (* Handle compose mode first *)
  let compose_handled = match ctx.compose with
    | Some cs when Compose.active cs ->
      (match Keymatch.codepoint_of_event ev with
       | Some cp ->
         let result = Compose.feed cs cp in
         (match result with
          | Compose.Pending ->
            (* Skip the bottom-bar compose status when SearchPrompt is
               on top — leave the prompt visible. Phase 4 will render
               the compose indicator inline within the prompt. *)
            (match Modal.top ctx.modal with
             | Some Modal.SearchPrompt -> ()
             | _ ->
               Render.set_status r (View.format_compose_status r cs);
               Render.present r)
          | Compose.Composed text ->
            (match Modal.top ctx.modal with
             | Some Modal.SearchPrompt ->
               (* Append composed text to the focused prompt field. *)
               ctx.search_panel_msg <- "";
               Modals.append_to_field ctx tab text
             | _ ->
               if term_focused then begin
                 (match active_term () with
                  | Some term -> Terminal.send term text
                  | None -> ())
               end else if not (Region_buffer.locked tab.rb) then begin
                 ignore (Region_buffer.try_replace_selection tab.rb text)
               end)
          | Compose.NoMatch ->
            (* ESC ESC = "logical ESC": cancel the search prompt (restoring
               cursor) or clear an active search; otherwise fall back to
               the legacy terminal-ESC / restart-compose handling. Other
               keys silently abort compose. *)
            (match ev with
             | Input.Special (Input.Escape, _) ->
               if not (Modals.logical_escape ctx tab) then begin
                 if term_focused then
                   Pty.send_escape tab
                 else begin
                   Compose.start cs;
                   Render.set_status r (View.format_compose_status r cs);
                   Render.present r
                 end
               end
             | _ -> ()));
         true
       | None ->
         (* Non-character event in compose mode -- feed 0 to abort *)
         ignore (Compose.feed cs 0);
         false)
    | _ -> false
  in
  if compose_handled then Continue
  else
  let prompt_action = match Modal.top ctx.modal with
    | Some (Modal.Prompt p) -> Modals.handle_prompt ctx p.handler ev
    | Some Modal.SearchPrompt -> Modals.handle_search_prompt ctx ev tab
    | _ -> None
  in
  match prompt_action with
  | Some a -> a
  | None ->
  match View.get_picker ctx with
  | Some fp -> Modals.handle_picker ctx fp ev
  | None ->
  (* --- Global keys (work in any pane) --- *)
  (* Debug: log non-mouse events to stderr. Enable with ROCQTUI_DEBUG_INPUT=1 *)
  if debug_input then
    (match ev with
     | Input.Mouse _ -> ()
     | _ ->
       let fp = match ctx.focus with
         | FScript -> "Script" | FGoals -> "Goals"
         | FMessages -> "Msgs" | FFileTree -> "FTree" in
       let tf = if term_focused then "T" else "-" in
       let desc = match ev with
         | Input.Key (cp, m) ->
           Printf.sprintf "K(%d%s%s%s)" cp
             (if m.shift then "S" else "") (if m.alt then "A" else "")
             (if m.ctrl then "C" else "")
         | Input.Special (k, m) ->
           let kn = match k with
             | Input.Enter -> "Ent" | Input.Backspace -> "BS"
             | Input.Escape -> "Esc" | Input.Tab -> "Tab"
             | Input.Up -> "Up" | Input.Down -> "Dn"
             | Input.Left -> "Lt" | Input.Right -> "Rt"
             | Input.F n -> Printf.sprintf "F%d" n
             | _ -> "?" in
           Printf.sprintf "S(%s%s%s%s)" kn
             (if m.shift then "S" else "") (if m.alt then "A" else "")
             (if m.ctrl then "C" else "")
         | Input.Paste _ -> "Paste"
         | _ -> "other" in
       let kf = match active_term () with
         | Some term -> Vterm_lib.Vterm_api.kitty_flags (Terminal.vterm term)
         | None -> -1 in
       Printf.eprintf "[%s %s kf=%d] %s\n%!" fp tf kf desc);
  let is_mouse_event = match ev with Input.Mouse _ -> true | _ -> false in
  let handle_global () =
    (* When a terminal is focused and this is a keyboard event, only
       handle essential rocqtui keys. Mouse events always go through
       the normal path so clicking, dragging, tab switching all work. *)
    if term_focused && not is_mouse_event then begin
      if Keymatch.match_binding ev Keys.quit then Some Quit
      else if Keymatch.match_binding ev Keys.close_tab then begin
        (* Ctrl+W on a focused terminal: destroy the terminal and
           pop to the most-recently-used sub-tab. *)
        (match active_term () with
         | Some term ->
           Terminal.destroy term;
           Msg_pane.sync_terminals ();
           (* Switch back to script pane so the user isn't stranded *)
           ctx.focus <- FScript
         | None -> ());
        Some Continue
      end
      else if Keymatch.match_binding ev Keys.cycle_pane then begin
        ctx.focus <- FScript; Some Continue end
      else if Keymatch.match_binding ev Keys.save then Some Save_prompt
      else if Keymatch.match_binding ev Keys.build_menu then begin
        Modal.toggle ctx.modal Modal.BuildMenu; Some Continue end
      else if Keymatch.match_binding ev Keys.help then begin
        Modal.push ctx.modal (Modal.Help { scroll = 0 }); Some Continue end
      else if Keymatch.match_binding ev Keys.copy
              && not (match ev with Input.Key (3, _) -> true
                | Input.Key (99, m) when m.ctrl -> true | _ -> false) then begin
        (* Copy terminal selection (^Y only; ^C goes to terminal) *)
        (match active_term () with
         | Some term ->
           let vt = Terminal.vterm term in
           if Vterm_lib.Vterm_api.has_selection vt then
             (match Vterm_lib.Vterm_api.sel_text vt with
              | Some text ->
                ctx.clipboard <- text;
                Clipboard.copy_to_system text
              | None -> ())
         | None -> ());
        Some Continue
      end
      else if Keymatch.match_binding ev Keys.open_terminal then begin
        Pty.open_tab ctx tab r; Some Continue end
      else if Keymatch.match_binding ev Keys.open_claude then begin
        Pty.open_tab ~cmd:"claude" ctx tab r; Some Continue end
      else if (match ev with Input.Special (Input.Escape, _) -> true | _ -> false) then begin
        (* ESC starts compose mode; double-ESC sends ESC to terminal *)
        (match ctx.compose with
         | Some cs -> Compose.start cs;
           Render.set_status r (View.format_compose_status r cs);
           Render.present r
         | None -> ());
        Some Continue
      end
      else None
    end
    else if Keymatch.match_binding ev Keys.quit then Some Quit
    else if Keymatch.match_binding ev Keys.close_tab then Some Close_tab
    else if Keymatch.match_binding ev Keys.save then Some Save_prompt
    else if Keymatch.match_binding ev Keys.jump_back then begin
      match Jump.pop ctx with
      | Some jp ->
        ctx.jump_target <- Some (jp.jp_line, jp.jp_col);
        Some (Jump_back jp)
      | None ->
        Render.set_status r "No previous location.";
        Some Continue
    end
    else if Keymatch.match_binding ev Keys.open_file then begin
      let filename = Buffer.filename buf in
      let dir = match filename with
        | Some f -> Filename.dirname f
        | None -> Sys.getcwd ()
      in
      (match Project.find_project_file dir with
       | Some (project_dir, project_file) ->
         let fp = File_picker.create ~project_dir ~project_file
           ~open_files:(List.map fst (ctx.open_files ())) in
         Modal.push ctx.modal (Modal.FilePicker fp)
       | None ->
         Render.set_status r "No _RocqProject found.");
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.search then begin
      (* Ensure ctx.search_query exists. Start a fresh search-prompt
         session — discards any prior rollback state and records the
         active tab + its cursor for ESC. Invalidate the active tab's
         buffer_matches cache so the lazy accessor picks up the
         current cursor as saved_cursor too. *)
      if ctx.search_query = None then begin
        ctx.search_query <- Some Search.empty_query;
        Editor_context.bump_search_gen ctx
      end;
      Editor_context.begin_search_session ctx tab;
      tab.search_matches <- None;
      tab.search_matches_gen <- None;
      ignore (Editor_context.tab_matches ctx tab);
      Modal.push ctx.modal Modal.SearchPrompt;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.search_next then begin
      Modals.dispatched_advance ctx tab `Next
    end
    else if Keymatch.match_binding ev Keys.search_prev then begin
      Modals.dispatched_advance ctx tab `Prev
    end
    else if Keymatch.match_binding ev Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_forward then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; tab.rocq_msg.rms_scroll <- 0;
        (match session with
         | Some s ->
           Session.set_user_step_pending s;
           Session.step_forward s
         | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_backward then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; tab.rocq_msg.rms_scroll <- 0;
        (match session with
         | Some s ->
           Session.set_user_step_pending s;
           Session.step_backward s
         | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.go_to_cursor then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; tab.rocq_msg.rms_scroll <- 0;
        (match session with
         | Some s ->
           Session.set_user_step_pending s;
           Session.go_to_cursor s
         | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_to_start then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; tab.rocq_msg.rms_scroll <- 0;
        (match session with
         | Some s ->
           Session.set_user_step_pending s;
           Session.go_to_offset s 0
         | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_to_end then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; tab.rocq_msg.rms_scroll <- 0;
        (match session with
         | Some s ->
           Session.set_user_step_pending s;
           Session.go_to_offset s (String.length (Buffer.text tab.buf))
         | None -> ())
      end;
      Some Continue
    end
    else if (match ev with Input.Special (Input.Escape, _) -> true | _ -> false) then begin
      if View.is_build ctx then
        Modal.pop ctx.modal
      else if View.is_theme ctx then
        Modal.pop ctx.modal
      else if View.is_options ctx then begin
        Modal.pop ctx.modal;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else begin
        match ctx.compose with
        | Some cs ->
          (* Plain Escape -- start compose. Cancelling search needs ESC ESC,
             handled in the compose-NoMatch branch above. *)
          Compose.start cs;
          Render.set_status r (View.format_compose_status r cs);
          Render.present r
        | None ->
          (* Compose disabled: ESC is the logical-cancel key. *)
          if not (Modals.logical_escape ctx tab) then begin
            if term_focused then Pty.send_escape tab
          end
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.toggle_hyps then begin
      tab.show_all_hyps <- not tab.show_all_hyps; Some Continue end
    else if Keymatch.match_binding ev Keys.toggle_gutter then begin
      Config.show_line_numbers := not !Config.show_line_numbers;
      Some Continue end
    else if Keymatch.match_binding ev Keys.options_menu then begin
      if View.is_options ctx then begin
        Modal.pop ctx.modal;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else Modal.push ctx.modal Modal.OptionsMenu;
      Some Continue
    end
    else if View.is_options ctx then Modals.handle_options ctx ev tab
    else if Keymatch.match_binding ev Keys.reload then begin
      Some Reload
    end
    else if Keymatch.match_binding ev Keys.theme_menu then begin
      Modal.toggle ctx.modal Modal.ThemeMenu;
      Some Continue
    end
    else if View.is_theme ctx then Modals.handle_theme ctx ev
    else if Keymatch.match_binding ev Keys.build_menu then begin
      Modal.toggle ctx.modal Modal.BuildMenu;
      Some Continue
    end
    else if View.is_build ctx then Modals.handle_build ctx ev tab r
    else if Keymatch.match_binding ev Keys.toggle_file_tree then begin
      let filename = Buffer.filename buf in
      let dir = match filename with
        | Some f -> Filename.dirname f
        | None -> Sys.getcwd ()
      in
      (match Project.find_project_file dir with
       | None -> Render.set_status r "No _RocqProject found."
       | Some (project_dir, project_file) ->
         let need_new = match ctx.file_tree with
           | None -> true
           | Some ft -> File_tree.project_file ft <> project_file
         in
         if need_new then begin
           ctx.file_tree <-
             Some (File_tree.create ~project_dir ~project_file);
           (* Retarget the project watcher so auto-refresh tracks the
              tree the user is now looking at. *)
           ctx.set_project_dir project_dir
         end;
         let was_visible = Render.file_tree_visible r in
         if not was_visible then begin
           (* Refresh from disk on each show so newly-created files
              appear; then reveal the active tab's file as the initial
              selection ("where am I?"). Both are skipped on a brand-new
              widget — create already enumerates and the selection
              defaults to the root. *)
           (match ctx.file_tree with
            | Some ft when not need_new ->
              File_tree.refresh ft;
              (match Buffer.filename buf with
               | Some path -> File_tree.reveal ft ~path
               | None -> ())
            | Some ft ->
              (* First-time create on this project — reveal too. *)
              (match Buffer.filename buf with
               | Some path -> File_tree.reveal ft ~path
               | None -> ())
            | None -> ());
           Render.set_file_tree_visible r true;
           ctx.focus <- FFileTree
         end
         else if ctx.focus = FFileTree then begin
           Render.set_file_tree_visible r false;
           ctx.focus <- FScript
         end
         else
           ctx.focus <- FFileTree);
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.open_terminal then begin
      Pty.open_tab ctx tab r; Some Continue
    end
    else if Keymatch.match_binding ev Keys.open_claude then begin
      Pty.open_tab ~cmd:"claude" ctx tab r; Some Continue
    end
    else if Keymatch.match_binding ev Keys.query_menu then begin
      Modal.toggle ctx.modal Modal.QueryMenu;
      Some Continue
    end
    else if View.is_query ctx then Modals.handle_query ctx ev tab
    else if Keymatch.match_binding ev Keys.cycle_pane then begin
      let ft_visible = Render.file_tree_visible r in
      ctx.focus <- (match ctx.focus with
        | FFileTree -> FScript
        | FScript -> FGoals
        | FGoals -> FMessages
        | FMessages -> if ft_visible then FFileTree else FScript);
      Some Continue
    end
    else if (match ev with Input.Resize -> true | _ -> false) then begin
      Render.resize r;
      Some Continue
    end
    else if View.is_help ctx then Modals.handle_help ctx ev r
    else if (match ev with Input.Mouse _ -> true | _ -> false) then begin
      let mev = match ev with Input.Mouse m -> m | _ -> assert false in
      (match Mouse.handle ctx mev tab r with
       | Some action -> Some action
       | None -> Some Continue)
    end
    (* Paste event *)
    else if (match ev with Input.Paste _ -> true | _ -> false) then begin
      let text = match ev with Input.Paste t -> Script.normalize_newlines t | _ -> "" in
      if text <> "" && not (Region_buffer.locked tab.rb) then begin
        match Region_buffer.try_replace_selection tab.rb text with
        | Region_buffer.Applied -> ctx.clipboard <- text
        | Region_buffer.Rejected _ -> ()
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.jump_to_def then begin
      let (cl, cc) = Buffer.cursor buf in
      let line = Buffer.get_line buf cl in
      (* Try Require line first *)
      let result = match Locate.parse_require_line line with
        | Some (_, modules) ->
          let modname = Locate.module_at_col modules cc in
          (match modname, session with
           | Some m, Some s ->
             Session.query s ("Locate Library " ^ m ^ ".");
             let msgs = String.concat "\n" (Session.messages s) in
             (match Locate.parse_locate_library msgs with
              | Some vo_path ->
                let v_path = Locate.vo_to_v vo_path in
                if Sys.file_exists v_path then Some (v_path, None)
                else begin
                  Render.set_status r ("Source not found: " ^ v_path);
                  None
                end
              | None ->
                let dir = match Buffer.filename buf with
                  | Some f -> Filename.dirname f | None -> Sys.getcwd () in
                (match Project.find_project_file dir with
                 | Some (_, pf) ->
                   let lps = Project.load_paths pf in
                   (match Project.resolve_module lps m with
                    | Some path -> Some (path, None)
                    | None ->
                      Render.set_status r ("Module not found: " ^ m);
                      None)
                 | None ->
                   Render.set_status r ("Module not found: " ^ m);
                   None))
           | Some m, None ->
             let dir = match Buffer.filename buf with
               | Some f -> Filename.dirname f | None -> Sys.getcwd () in
             (match Project.find_project_file dir with
              | Some (_, pf) ->
                let lps = Project.load_paths pf in
                (match Project.resolve_module lps m with
                 | Some path -> Some (path, None)
                 | None ->
                   Render.set_status r ("Module not found: " ^ m);
                   None)
              | None ->
                Render.set_status r "No session and no project.";
                None)
           | None, _ ->
             Render.set_status r "No module name at cursor.";
             None)
        | None ->
          let word = Modals.query_subject ctx tab in
          (match word, session with
           | Some w, Some s ->
             Session.query s ("Locate " ^ w ^ ".");
             let msgs = String.concat "\n" (Session.messages s) in
             (match Locate.parse_locate msgs with
              | Some (_kind, module_path, def_name) ->
                Session.query s ("Locate Library " ^ module_path ^ ".");
                let msgs2 = String.concat "\n" (Session.messages s) in
                (match Locate.parse_locate_library msgs2 with
                 | Some vo_path ->
                   let v_path = Locate.vo_to_v vo_path in
                   let target_line =
                     if Sys.file_exists v_path then begin
                       let glob_path = Locate.vo_to_glob vo_path in
                       if Sys.file_exists glob_path then
                         let entries = Glob.parse glob_path in
                         match Glob.find_definition entries def_name with
                         | Some e -> Glob.byte_offset_to_line v_path e.bp
                         | None -> None
                       else None
                     end else None
                   in
                   if Sys.file_exists v_path then
                     Some (v_path, target_line)
                   else begin
                     Render.set_status r ("Source not found: " ^ v_path);
                     None
                   end
                 | None ->
                   Render.set_status r ("Cannot locate library for " ^ module_path);
                   None)
              | None ->
                Render.set_status r ("Cannot locate: " ^ msgs);
                None)
           | Some _, None ->
             Render.set_status r "No session.";
             None
           | None, _ ->
             Render.set_status r "No identifier at cursor.";
             None)
      in
      (match result with
       | Some (path, line_opt) ->
         Jump.push ctx tab;
         (match line_opt with
          | Some l -> ctx.jump_target <- Some (l, 0)
          | None -> ctx.jump_target <- None);
         Some (Open_file path)
       | None -> Some Continue)
    end
    else if Keymatch.match_binding ev Keys.next_error
         || Keymatch.match_binding ev Keys.prev_error then begin
      let forward = Keymatch.match_binding ev Keys.next_error in
      match Build_errors.advance ~forward with
      | None ->
        Render.set_status r "No build errors.";
        Some Continue
      | Some (e : Build_errors.entry) ->
        ignore (Msg_pane.ensure Msg_pane.Errors);
        Msg_pane.activate Msg_pane.Errors;
        Jump.push ctx tab;
        ctx.jump_target <- Some (e.line - 1, e.col_start);
        Some (Open_file e.file)
    end
    else if Keymatch.match_binding ev Keys.help then begin
      if View.is_help ctx then begin
        Modal.pop ctx.modal;
        View.set_help_scroll ctx 0
      end else
        Modal.push ctx.modal (Modal.Help { scroll = 0 });
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.minimap then begin
      if Render.minimap_width r > 0 then
        Render.set_minimap_width r 0
      else
        Render.set_minimap_width r Minimap.width;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.about then begin
      (match Modals.query_subject ctx tab, session with
       | Some word, Some s ->
         Session.query s ("About " ^ word ^ ".");
         Msg_pane.activate Msg_pane.Rocq
       | _ -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.print_query then begin
      (match Modals.query_subject ctx tab, session with
       | Some word, Some s ->
         Session.query s ("Print " ^ word ^ ".");
         Msg_pane.activate Msg_pane.Rocq
       | _ -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.copy then begin
      let text = match ctx.focus with
        | FGoals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
        | FMessages ->
          (match Geom.active_msg_pane_state tab with
           | `Text (sel, cache, _) -> View.pane_selection_text sel cache
           | `Terminal -> None)
        | FScript -> Buffer.selected_text buf
        | FFileTree -> None
      in
      (match text with
       | Some t ->
         ctx.clipboard <- t;
         Clipboard.copy_to_system t
       | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.undo then begin
      if not (Region_buffer.locked tab.rb) then
        ignore (Region_buffer.try_undo tab.rb);
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.redo then begin
      if not (Region_buffer.locked tab.rb) then
        ignore (Region_buffer.try_redo tab.rb);
      Some Continue
    end
    else None
  in
  (* --- Scroll keys for Goals/Messages panes --- *)
  let handle_pane_scroll pane_scroll_ref pane =
    match ev with
    | Input.Special (Input.Up, _) ->
      decr pane_scroll_ref; Some Continue
    | Input.Special (Input.Down, _) ->
      incr pane_scroll_ref; Some Continue
    | Input.Special (Input.PageDown, _) ->
      let (rows, _) = Render.pane_dims r pane in
      pane_scroll_ref := !pane_scroll_ref + (rows - 1); Some Continue
    | Input.Special (Input.PageUp, _) ->
      let (rows, _) = Render.pane_dims r pane in
      pane_scroll_ref := max 0 (!pane_scroll_ref - (rows - 1)); Some Continue
    | _ -> None
  in
  let file_tree_event_to_key = function
    | Input.Key (cp, mods) ->
      Some (if mods.ctrl && cp >= 97 && cp <= 122 then cp - 96 else cp)
    | Input.Special (k, _) ->
      (match k with
       | Input.Up -> Some 259 | Input.Down -> Some 258
       | Input.Left -> Some 260 | Input.Right -> Some 261
       | Input.Home -> Some 262 | Input.End -> Some 360
       | Input.PageUp -> Some 339 | Input.PageDown -> Some 338
       | Input.Enter -> Some 13 | Input.Tab -> Some 9
       | Input.Backspace -> Some 127 | Input.Escape -> Some 27
       | _ -> None)
    | _ -> None
  in
  (* Panel-focused dispatch: the panel sees keys first (so ^T toggles
     project/all mode instead of opening a terminal, etc.). Returns
     None for keys the panel doesn't claim, letting globals like ^O /
     ^Q / ^P / F8 fall through.

     "." is intercepted before the panel sees it (outside filter mode)
     to snap the selection to the active tab's file — the panel itself
     has no knowledge of tabs. *)
  let try_file_tree () =
    if ctx.focus <> FFileTree then None
    else match ctx.file_tree with
    | None -> None
    | Some ft ->
      let is_plain_period = match ev with
        | Input.Key (46, mods) ->
          not (mods.shift || mods.alt || mods.ctrl)
        | _ -> false
      in
      if is_plain_period && not (File_tree.in_filter ft) then begin
        (match Buffer.filename buf with
         | Some path -> File_tree.reveal ft ~path
         | None -> ());
        Some Continue
      end
      else
      (match file_tree_event_to_key ev with
       | None -> None
       | Some ch ->
         (match File_tree.handle_key ft r ch with
          | File_tree.TreeOpen path -> Some (Open_file path)
          | File_tree.TreeContinue -> Some Continue
          | File_tree.TreeUnhandled -> None))
  in
  (* AI keystroke short-circuit: handles ^G toggle, Tab accept, Esc
     dismiss. Bails out (returns false) when no AI state is configured,
     when a modal is active, or when the key doesn't match an AI
     binding. *)
  let modal_active = Modal.is_active ctx.modal in
  let ai_consumed =
    Ai.Action.try_handle ~state:ctx.ai ~modal_active ev tab
  in
  let action =
    if ai_consumed then Continue
    else
    match try_file_tree () with
    | Some a -> a
    | None ->
    match handle_global () with
    | Some a -> a
    | None ->
      match ctx.focus with
      | FFileTree ->
        (* Panel is focused but neither it nor any global claimed the
           key — nothing else to dispatch to. *)
        Continue
      | FGoals ->
        let scroll_r = ref tab.goals_scroll in
        let result = handle_pane_scroll scroll_r Render.PGoals in
        tab.goals_scroll <- !scroll_r;
        (match result with Some a -> a | None -> Continue)
      | FMessages ->
        (match Msg_pane.active_kind () with
         | Msg_pane.Terminal term ->
           Pty.forward_event term ev;
           Continue
         | Msg_pane.Rocq ->
           let scroll_r = ref tab.rocq_msg.rms_scroll in
           let result = handle_pane_scroll scroll_r Render.PMessages in
           tab.rocq_msg.rms_scroll <- !scroll_r;
           (match result with Some a -> a | None -> Continue)
         | Msg_pane.Build | Msg_pane.Errors | Msg_pane.Search ->
           let mt = Msg_pane.active_tab () in
           let scroll_r = ref mt.scroll in
           let result = handle_pane_scroll scroll_r Render.PMessages in
           mt.scroll <- !scroll_r;
           (match result with Some a -> a | None -> Continue))
      | FScript ->
        (match Script.handle ctx ev tab r with
         | Some a -> a | None -> Continue)
  in
  action
