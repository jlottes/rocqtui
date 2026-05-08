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
  let buf = tab.buf in
  let session = tab.session in
  (* Is a terminal sub-tab currently focused? *)
  let term_focused =
    tab.focused_pane = `Messages &&
    (Tab.active_msg_tab tab.msg).mt_terminal <> None
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
               (* Append composed text to the search query. *)
               let s = match Tab.search_state tab with
                 | Some s -> s
                 | None -> Search.create tab.buf in
               Tab.set_search tab
                 (Some (Search.update_query s tab.buf (s.query ^ text)))
             | _ ->
               if term_focused then begin
                 let active_mt = Tab.active_msg_tab tab.msg in
                 (match active_mt.mt_terminal with
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
       let fp = match tab.focused_pane with
         | `Script -> "Script" | `Goals -> "Goals" | `Messages -> "Msgs" in
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
       let kf = match (Tab.active_msg_tab tab.msg).mt_terminal with
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
        (* Ctrl+W on a focused terminal: destroy the terminal *)
        let active_mt = Tab.active_msg_tab tab.msg in
        (match active_mt.mt_terminal with
         | Some term ->
           Terminal.destroy term;
           Tab.set_sticky_terminal None;
           (* Clean up stale terminal sub-tab from msg_tabs and
              reset active index to Rocq. *)
           tab.msg.mt_active <- 0;
           Tab.sync_terminals tab.msg;
           Tab.activate_msg_tab tab.msg "Rocq";
           (* Switch back to script pane so the user isn't stranded *)
           tab.focused_pane <- `Script
         | None -> ());
        Some Continue
      end
      else if Keymatch.match_binding ev Keys.cycle_pane then begin
        tab.focused_pane <- `Script; Some Continue end
      else if Keymatch.match_binding ev Keys.save then Some Save_prompt
      else if Keymatch.match_binding ev Keys.build_menu then begin
        Modal.toggle ctx.modal Modal.BuildMenu; Some Continue end
      else if Keymatch.match_binding ev Keys.help then begin
        Modal.push ctx.modal (Modal.Help { scroll = 0 }); Some Continue end
      else if Keymatch.match_binding ev Keys.copy
              && not (match ev with Input.Key (3, _) -> true
                | Input.Key (99, m) when m.ctrl -> true | _ -> false) then begin
        (* Copy terminal selection (^Y only; ^C goes to terminal) *)
        let active_mt = Tab.active_msg_tab tab.msg in
        (match active_mt.mt_terminal with
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
        Pty.open_tab tab r; Some Continue end
      else if Keymatch.match_binding ev Keys.open_claude then begin
        Pty.open_tab ~cmd:"claude" tab r; Some Continue end
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
           ~open_files:(ctx.open_files ()) in
         Modal.push ctx.modal (Modal.FilePicker fp)
       | None ->
         Render.set_status r "No _RocqProject found.");
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.search then begin
      (* Re-save the cursor on every prompt-open so cancel restores to the
         pre-prompt position, not the position before search first opened. *)
      (match Tab.search_state tab with
       | None -> Tab.set_search tab (Some (Search.create tab.buf))
       | Some s -> Tab.set_search tab (Some (Search.resave_cursor s tab.buf)));
      Modal.push ctx.modal Modal.SearchPrompt;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.search_next then begin
      Modals.search_advance tab `Next; Some Continue
    end
    else if Keymatch.match_binding ev Keys.search_prev then begin
      Modals.search_advance tab `Prev; Some Continue
    end
    else if Keymatch.match_binding ev Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_forward then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
        (match session with Some s -> Session.step_forward s | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_backward then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
        (match session with Some s -> Session.step_backward s | None -> ())
      end;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.go_to_cursor then begin
      if not (Region_buffer.locked tab.rb) then begin
        tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
        (match session with Some s -> Session.go_to_cursor s | None -> ())
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
    else if Keymatch.match_binding ev Keys.open_terminal then begin
      Pty.open_tab tab r; Some Continue
    end
    else if Keymatch.match_binding ev Keys.open_claude then begin
      Pty.open_tab ~cmd:"claude" tab r; Some Continue
    end
    else if Keymatch.match_binding ev Keys.query_menu then begin
      Modal.toggle ctx.modal Modal.QueryMenu;
      Some Continue
    end
    else if View.is_query ctx then Modals.handle_query ctx ev tab
    else if Keymatch.match_binding ev Keys.cycle_pane then begin
      tab.focused_pane <- (match tab.focused_pane with
        | `Script -> `Goals | `Goals -> `Messages | `Messages -> `Script);
      Some Continue
    end
    else if (match ev with Input.Resize -> true | _ -> false) then begin
      Render.resize r;
      Some Continue
    end
    else if View.is_help ctx then Modals.handle_help ctx ev r
    else if (match ev with Input.Mouse _ -> true | _ -> false) then begin
      let mev = match ev with Input.Mouse m -> m | _ -> assert false in
      Mouse.handle ctx mev tab r;
      Some Continue
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
          let word = Modals.query_subject tab in
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
      (match Modals.query_subject tab, session with
       | Some word, Some s -> Session.query s ("About " ^ word ^ ".")
       | _ -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.print_query then begin
      (match Modals.query_subject tab, session with
       | Some word, Some s -> Session.query s ("Print " ^ word ^ ".")
       | _ -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.copy then begin
      let text = match tab.focused_pane with
        | `Goals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> View.pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script -> Buffer.selected_text buf
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
  let action =
    match handle_global () with
    | Some a -> a
    | None ->
      match tab.focused_pane with
      | `Goals ->
        let scroll_r = ref tab.goals_scroll in
        let result = handle_pane_scroll scroll_r Render.PGoals in
        tab.goals_scroll <- !scroll_r;
        (match result with Some a -> a | None -> Continue)
      | `Messages ->
        let active_mt = Tab.active_msg_tab tab.msg in
        (match active_mt.mt_terminal with
         | Some term ->
           Pty.forward_event term ev;
           Continue
         | None ->
           let scroll_r = ref active_mt.mt_scroll in
           let result = handle_pane_scroll scroll_r Render.PMessages in
           active_mt.mt_scroll <- !scroll_r;
           (match result with Some a -> a | None -> Continue))
      | `Script ->
        (match Script.handle ctx ev tab r with
         | Some a -> a | None -> Continue)
  in
  action
