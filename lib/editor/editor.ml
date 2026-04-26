let debug_input = try Sys.getenv "ROCQTUI_DEBUG_INPUT" <> "" with Not_found -> false

type jump_point = Editor_context.jump_point

type action =
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

(* Get the subject for a query from whichever pane is focused *)
let query_subject (tab : Tab.t) =
  let buf = tab.buf in
  match tab.focused_pane with
  | `Goals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
  | `Messages -> View.pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
  | `Script ->
    match Buffer.selected_text buf with
    | Some text -> Some text
    | None -> Buffer.word_at_cursor buf

let run_query session phrase =
  match session with
  | Some s -> Session.query s phrase
  | None -> ()

(* Normalize \r\n and \r to \n — terminals send \r in bracketed paste *)
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

(* --- Input event handling --- *)

let rec handle_event (ctx : Editor_context.t) (ev : Input.event) (tab : Tab.t) r =
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
            Render.set_status r (View.format_compose_status r cs);
            Render.present r
          | Compose.Composed text ->
            if term_focused then begin
              (* Send composed text to terminal *)
              let active_mt = Tab.active_msg_tab tab.msg in
              (match active_mt.mt_terminal with
               | Some term -> Terminal.send term text
               | None -> ())
            end else begin
              ignore (Buffer.delete_selection buf);
              insert_string tab text
            end
          | Compose.NoMatch ->
            if term_focused then begin
              (* Double-ESC: send ESC to terminal *)
              match ev with
              | Input.Special (Input.Escape, _) ->
                Pty.send_escape tab
              | _ -> ()
            end else begin
              (* If the key that broke compose was Escape, restart compose *)
              (match ev with
               | Input.Special (Input.Escape, _) ->
                 Compose.start cs;
                 Render.set_status r (View.format_compose_status r cs);
                 Render.present r
               | _ -> ())
            end);
         true
       | None ->
         (* Non-character event in compose mode -- feed 0 to abort *)
         ignore (Compose.feed cs 0);
         false)
    | _ -> false
  in
  if compose_handled then
    Continue
  else begin match Modal.top ctx.modal with
  | Some (Modal.Prompt p) ->
    let result = p.handler ev in
    (match result with
     | Modal.Handled -> Modal.pop ctx.modal; Continue
     | Modal.Dismissed -> Modal.pop ctx.modal;
       (* Re-process the event now that prompt is dismissed *)
       handle_event ctx ev tab r
     | Modal.Ignored -> Continue)
  | _ ->
  match View.get_picker ctx with
  | Some fp ->
    let (_box_top, box_left, box_w, _box_h, visible_rows) =
      File_picker.box_geometry () in
    let handle_picker_action = function
      | File_picker.PickerOpen path ->
        Modal.pop ctx.modal; Open_file path
      | File_picker.PickerClose ->
        Modal.pop ctx.modal; Continue
      | File_picker.PickerContinue -> Continue
    in
    (match ev with
    | Input.Mouse mev ->
      let b1_click = mev.button = Input.Left in
      let scroll_up = mev.button = Input.ScrollUp in
      let scroll_down = mev.button = Input.ScrollDown in
      if b1_click then begin
        let (box_top, _, _, _, _) = File_picker.box_geometry () in
        handle_picker_action
          (File_picker.handle_click fp ~y:mev.y ~x:mev.x ~box_top ~box_left
             ~box_width:box_w ~visible_rows)
      end
      else if scroll_up then
        (File_picker.handle_scroll fp (-1) visible_rows; Continue)
      else if scroll_down then
        (File_picker.handle_scroll fp 1 visible_rows; Continue)
      else Continue
    | Input.Special (Input.Escape, _) ->
      Modal.pop ctx.modal; Continue
    | Input.Key (cp, mods) ->
      let ch = if mods.ctrl && cp >= 97 && cp <= 122 then cp - 96 else cp in
      handle_picker_action (File_picker.handle_key fp ch visible_rows)
    | Input.Special (key, _mods) ->
      let ch = match key with
        | Input.Up -> 259 | Input.Down -> 258
        | Input.PageUp -> 339 | Input.PageDown -> 338
        | Input.Enter -> 13 | Input.Tab -> 9
        | Input.Backspace -> 127
        | _ -> 0
      in
      if ch <> 0 then
        handle_picker_action (File_picker.handle_key fp ch visible_rows)
      else Continue
    | _ -> Continue)
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
    else if Keymatch.match_binding ev Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_forward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_forward s | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.step_backward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_backward s | None -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.go_to_cursor then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.go_to_cursor s | None -> ());
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
          (* Plain Escape -- start compose *)
          Compose.start cs;
          Render.set_status r (View.format_compose_status r cs);
          Render.present r
        | None ->
          (* Compose disabled: forward Escape to terminal if focused *)
          if term_focused then Pty.send_escape tab
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
    else if View.is_options ctx then begin
      let ch_opt = Keymatch.codepoint_of_event ev in
      match ch_opt with
      | Some ch ->
        let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
        (match List.find_opt (fun (e : Printopts.entry) -> e.key = c) Printopts.entries with
         | Some entry ->
           Printopts.toggle entry;
           (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
           Some Continue
         | None ->
           Modal.pop ctx.modal;
           (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
           None)
      | None ->
        Modal.pop ctx.modal;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ());
        None
    end
    else if Keymatch.match_binding ev Keys.reload then begin
      Some Reload
    end
    else if Keymatch.match_binding ev Keys.theme_menu then begin
      Modal.toggle ctx.modal Modal.ThemeMenu;
      Some Continue
    end
    else if View.is_theme ctx then begin
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
    end
    else if Keymatch.match_binding ev Keys.build_menu then begin
      Modal.toggle ctx.modal Modal.BuildMenu;
      Some Continue
    end
    else if View.is_build ctx then begin
      Modal.pop ctx.modal;
      (match Keymatch.codepoint_of_event ev with
       | Some ch ->
         let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
         let project_info () =
           let filename = Buffer.filename buf in
           let dir = match filename with
             | Some f -> Filename.dirname f | None -> Sys.getcwd () in
           match Project.find_project_file dir with
           | Some (pd, _) -> Some pd
           | None -> None
         in
         if c = 'c' && Build.is_running () then begin
           Build.cancel ();
           Some Continue
         end
         else if c = 'f' then begin
           (match Buffer.filename buf, project_info () with
            | Some f, Some pd ->
              if Build.build_file ~project_dir:pd f then ()
              else Render.set_status r "Build already running."
            | _, None ->
              Render.set_status r "No project found."
            | None, _ ->
              Render.set_status r "No filename.");
           Some Continue
         end
         else if c = 'd' then begin
           (match Buffer.filename buf, project_info () with
            | Some f, Some pd ->
              if Build.build_deps ~project_dir:pd f then ()
              else Render.set_status r "Build already running."
            | _, None ->
              Render.set_status r "No project found."
            | None, _ ->
              Render.set_status r "No filename.");
           Some Continue
         end
         else if c = 'a' then begin
           (match project_info () with
            | Some pd ->
              if Build.build_all ~project_dir:pd then ()
              else Render.set_status r "Build already running."
            | None ->
              Render.set_status r "No project found.");
           Some Continue
         end
         else if c = 'x' then begin
           (match project_info () with
            | Some pd ->
              if Build.build_clean ~project_dir:pd then ()
              else Render.set_status r "Build already running."
            | None ->
              Render.set_status r "No project found.");
           Some Continue
         end
         else
           (Some Continue)
       | None -> Some Continue)
    end
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
    else if View.is_query ctx then begin
      Modal.pop ctx.modal;
      match Keymatch.codepoint_of_event ev with
      | Some ch ->
        let c = Char.lowercase_ascii (Char.chr (ch land 0xFF)) in
        let handled =
          if c = 'a' then begin
            let subject = query_subject tab in
            (match subject with
             | Some word -> run_query session ("About " ^ word ^ ".")
             | None -> ()); true
          end else if c = 'c' then begin
            let subject = query_subject tab in
            (match subject with
             | Some word -> run_query session ("Check " ^ word ^ ".")
             | None -> ()); true
          end else if c = 'd' then begin
            let subject = query_subject tab in
            (match subject with
             | Some word -> run_query session ("Print " ^ word ^ ".")
             | None -> ()); true
          end else if c = 'l' then begin
            let subject = query_subject tab in
            (match subject with
             | Some word -> run_query session ("Locate " ^ word ^ ".")
             | None -> ()); true
          end else if c = 'g' then begin
            let subject = query_subject tab in
            (match subject, session with
             | Some word, Some s ->
               Session.query s "Print Graph.";
               let all_msgs = Session.messages s in
               let line_has s line =
                 let slen = String.length s in
                 let llen = String.length line in
                 let rec check i =
                   if i + slen > llen then false
                   else if String.sub line i slen = s then true
                   else check (i + 1)
                 in check 0
               in
               let matches_word line =
                 line_has (" " ^ word ^ " >->") line
                 || line_has (">-> " ^ word) line
                 || line_has ("." ^ word ^ " >->") line
               in
               let filtered = List.concat_map (fun msg ->
                 let lines = String.split_on_char '\n' msg in
                 List.filter (fun line ->
                   String.length line > 0 && matches_word line
                 ) lines
               ) all_msgs in
               if filtered = [] then
                 Session.set_messages s ["No coercions found for " ^ word ^ "."]
               else
                 Session.set_messages s filtered
             | _, None -> ()
             | None, _ -> ()); true
          end else if c = 'p' then begin
            run_query session "Show Proof."; true
          end else if c = 'e' then begin
            run_query session "Show Existentials."; true
          end else false
        in
        if handled then Some Continue
        else None  (* fall through to normal handling *)
      | None -> None
    end
    else if Keymatch.match_binding ev Keys.cycle_pane then begin
      tab.focused_pane <- (match tab.focused_pane with
        | `Script -> `Goals | `Goals -> `Messages | `Messages -> `Script);
      Some Continue
    end
    else if (match ev with Input.Resize -> true | _ -> false) then begin
      Render.resize r;
      Some Continue
    end
    else if View.is_help ctx then begin
      let (rows, _) = Render.pane_dims r Render.PScript in
      let n = List.length View.help_lines in
      let max_scroll = max 0 (n - rows) in
      let scroll_by delta =
        View.set_help_scroll ctx (max 0 (min max_scroll (View.get_help_scroll ctx + delta))) in
      (match ev with
       | Input.Special (Input.Up, _) ->
         scroll_by (-1); Some Continue
       | Input.Special (Input.Down, _) ->
         scroll_by 1; Some Continue
       | Input.Special (Input.PageUp, _) ->
         scroll_by (-rows); Some Continue
       | Input.Special (Input.PageDown, _) ->
         scroll_by rows; Some Continue
       | Input.Special (Input.Home, _) ->
         View.set_help_scroll ctx 0; Some Continue
       | Input.Special (Input.End, _) ->
         View.set_help_scroll ctx max_scroll; Some Continue
       | Input.Mouse mev ->
         if mev.button = Input.ScrollUp then scroll_by (-3)
         else if mev.button = Input.ScrollDown then scroll_by 3;
         Some Continue
       | _ ->
         Modal.pop ctx.modal;
         View.set_help_scroll ctx 0;
         Some Continue)
    end
    else if (match ev with Input.Mouse _ -> true | _ -> false) then begin
      let mev = match ev with Input.Mouse m -> m | _ -> assert false in
      let x = mev.x in
      let y = mev.y in
      let is_release = mev.button = Input.Release in
      let is_left = mev.button = Input.Left in
      let is_middle = mev.button = Input.Middle in
      let is_scroll_up = mev.button = Input.ScrollUp in
      let is_scroll_down = mev.button = Input.ScrollDown in
      let has_shift = mev.mods.shift in
      let has_cmd = mev.mods.ctrl in  (* Ctrl acts as Cmd on most terminals *)
      (* Terminal mouse: handle release and drag for reported buttons *)
      let term_mouse_handled = ref false in
      let active_mt = Tab.active_msg_tab tab.msg in
      (match active_mt.mt_terminal with
       | Some term when Terminal.reported_buttons term <> 0 ->
         let vt = Terminal.vterm term in
         let mm = Vterm_lib.Vterm_api.mouse_mode vt in
         let mf = Vterm_lib.Vterm_api.mouse_flags vt in
         let rect = Render.pane_rect r Render.PMessages in
         let cx = x - rect.col + 1 in
         let cy = y - rect.row + 1 in
         let mods_i = (if has_shift then 1 else 0)
           lor (if mev.mods.alt then 2 else 0)
           lor (if has_cmd then 4 else 0) in
         if is_release then begin
           (* Send release for all reported buttons *)
           for button = 1 to 5 do
             if Terminal.reported_buttons term land (1 lsl button) <> 0 then begin
               let seq = Vterm_lib.Vterm_api.mouseseq ~button ~modifiers:mods_i
                 ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_release ~mode:mm ~flags:mf in
               Terminal.send term seq
             end
           done;
           Terminal.set_reported_buttons term 0;
           term_mouse_handled := true
         end else if not is_scroll_up && not is_scroll_down then begin
           (* Drag/motion *)
           if mm >= Vterm_lib.Vterm_api.mouse_mode_btn then begin
             let seq = Vterm_lib.Vterm_api.mouseseq ~button:1 ~modifiers:mods_i
               ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_motion ~mode:mm ~flags:mf in
             Terminal.send term seq
           end;
           term_mouse_handled := true
         end
       | _ -> ());
      if not !term_mouse_handled then
      if ctx.dragging <> Editor_context.NoDrag then begin
        (* Active border drag. Terminal resize happens on next render. *)
        (match ctx.dragging with
         | Editor_context.DragV -> Render.move_split_v r x
         | Editor_context.DragH -> Render.move_split_h r y
         | Editor_context.DragBoth ->
           Render.move_split_v r x; Render.move_split_h r y
         | Editor_context.DragMinimap -> Render.move_minimap_border r x
         | Editor_context.DragMinimapScroll ->
           let mm_rect = Render.pane_rect r Render.PMinimap in
           let mm_row = y - mm_rect.row in
           if mm_row >= 0 && mm_row < mm_rect.height then begin
             let num_lines = Buffer.line_count buf in
             let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rect.height in
             let target_line = mm_row * ypc in
             let (srows, _) = Render.pane_dims r Render.PScript in
             let target_scroll = max 0 (target_line - srows / 2) in
             let max_scroll = max 0 (num_lines - srows) in
             Buffer.set_scroll_top buf (min target_scroll max_scroll)
           end
         | Editor_context.NoDrag -> ());
        if is_release then ctx.dragging <- Editor_context.NoDrag
      end
      else if tab.mouse_selecting then begin
        (* Active text selection drag *)
        let pane = Render.pane_at r ~x ~y in
        let term_in_msgs = if pane = Render.PMessages then
          (Tab.active_msg_tab tab.msg).mt_terminal
        else None in
        (match term_in_msgs with
         | Some term ->
           let vt = Terminal.vterm term in
           let rect = Render.pane_rect r Render.PMessages in
           let vy = y - rect.row in
           let vx = x - rect.col in
           let (line, col) = Vterm_lib.Vterm_api.hit_test vt ~row:vy ~col:vx in
           Vterm_lib.Vterm_api.sel_extend vt ~line ~col
         | None ->
           if pane = Render.PScript then begin
             match Geom.screen_to_buffer_pos r buf ~x ~y with
             | Some (line, byte_col) -> Buffer.move_to buf line byte_col
             | None -> ()
           end else if pane = Render.PGoals || pane = Render.PMessages then begin
             let (ps, pane_id) =
               if pane = Render.PGoals then (tab.goals_sel, `Goals)
               else ((Tab.active_msg_tab tab.msg).mt_sel, `Messages)
             in
             (match Geom.screen_to_pane_pos tab r ~x ~y pane_id with
              | Some (row, byte_col) ->
                ps.ps_cursor_line <- row;
                ps.ps_cursor_col <- byte_col
              | None -> ())
           end);
        if is_release then begin
          tab.mouse_selecting <- false;
          if Buffer.selection buf = None then
            Buffer.clear_selection buf
        end
      end
      else begin
        let pane = Render.pane_at r ~x ~y in
        if is_scroll_up || is_scroll_down then begin
          let delta = if is_scroll_up then -3 else 3 in
          match pane with
          | Render.PScript ->
            let (rows, _) = Render.pane_dims r Render.PScript in
            let max_scroll = max 0 (Buffer.line_count buf - rows) in
            Buffer.set_scroll_top buf (max 0 (min max_scroll (Buffer.scroll_top buf + delta)))
          | Render.PGoals ->
            tab.goals_scroll <- max 0 (tab.goals_scroll + delta)
          | Render.PMessages ->
            let active_mt = Tab.active_msg_tab tab.msg in
            (match active_mt.mt_terminal with
             | Some term ->
               let vt = Terminal.vterm term in
               let mm = Vterm_lib.Vterm_api.mouse_mode vt in
               let mf = Vterm_lib.Vterm_api.mouse_flags vt in
               let alt = Vterm_lib.Vterm_api.alt_screen vt in
               let mouse_active = mm <> 0 && not has_shift in
               let handled = ref false in
               if not mouse_active then begin
                 if alt && (mf land Vterm_lib.Vterm_api.mouse_alt_scroll <> 0) then begin
                   (* Alt screen + ALT_SCROLL: send cursor keys *)
                   let mode = Vterm_lib.Vterm_api.term_mode vt in
                   let seq = if mode land Vterm_lib.Vterm_api.mode_app_cursor <> 0
                     then (if is_scroll_up then "\027OA" else "\027OB")
                     else (if is_scroll_up then "\027[A" else "\027[B") in
                   Terminal.send term seq;
                   handled := true
                 end else if mm = 0 || not alt then begin
                   (* No mouse mode, or shift on normal screen: scroll history *)
                   ignore (Vterm_lib.Vterm_api.scroll vt
                     (if is_scroll_up then -3 else 3));
                   handled := true
                 end
               end;
               (* If not handled locally, forward to terminal if mouse reporting on *)
               if not !handled && mm <> 0 then begin
                 let rect = Render.pane_rect r Render.PMessages in
                 let cx = x - rect.col + 1 in
                 let cy = y - rect.row + 1 in
                 let button = if is_scroll_up then 4 else 5 in
                 let mods_i = (if has_shift then 1 else 0)
                   lor (if mev.mods.alt then 2 else 0)
                   lor (if has_cmd then 4 else 0) in
                 let seq = Vterm_lib.Vterm_api.mouseseq ~button ~modifiers:mods_i
                   ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_press ~mode:mm ~flags:mf in
                 Terminal.send term seq
               end
             | None ->
               active_mt.mt_scroll <- max 0 (active_mt.mt_scroll + delta))
          | _ -> ()
        end
        else if pane = Render.PTabBar && is_left then begin
          ctx.switch_tab x
        end
        else if pane = Render.PBorderH && is_left then begin
          let tab_names = List.map Tab.msg_tab_display_name
                            tab.msg.mt_tabs in
          match Render.msg_tab_at_x r ~x ~tab_names with
          | Some i ->
            tab.msg.mt_active <- i;
            let clicked = Tab.active_msg_tab tab.msg in
            if clicked.mt_terminal = None then
              Tab.set_sticky_terminal None
            else
              Tab.set_sticky_terminal clicked.mt_terminal
          | None ->
            ctx.dragging <- Editor_context.DragH
        end
        else if pane = Render.PBorderBoth && is_left then
          ctx.dragging <- Editor_context.DragBoth
        else if (pane = Render.PBorderV || pane = Render.PBorderMinimap)
                && is_left then
          ctx.dragging <- (match pane with
            | Render.PBorderMinimap -> Editor_context.DragMinimap
            | _ -> Editor_context.DragV)
        else if (pane = Render.PGoals || pane = Render.PMessages)
                && is_left then begin
          tab.focused_pane <- (if pane = Render.PGoals then `Goals else `Messages);
          (* Check if we should forward to terminal *)
          let forwarded = if pane = Render.PMessages then
            let active_mt = Tab.active_msg_tab tab.msg in
            match active_mt.mt_terminal with
            | Some term ->
              let vt = Terminal.vterm term in
              let mm = Vterm_lib.Vterm_api.mouse_mode vt in
              if mm <> 0 && not has_shift then begin
                let mf = Vterm_lib.Vterm_api.mouse_flags vt in
                let rect = Render.pane_rect r Render.PMessages in
                let cx = x - rect.col + 1 in
                let cy = y - rect.row + 1 in
                let mods_i = (if has_shift then 1 else 0)
                  lor (if mev.mods.alt then 2 else 0)
                  lor (if has_cmd then 4 else 0) in
                let seq = Vterm_lib.Vterm_api.mouseseq ~button:1 ~modifiers:mods_i
                  ~cx ~cy ~ev:Vterm_lib.Vterm_api.mouse_ev_press ~mode:mm ~flags:mf in
                Terminal.send term seq;
                Terminal.set_reported_buttons term
                  (Terminal.reported_buttons term lor (1 lsl 1));
                true
              end else false
            | None -> false
          else false in
          if not forwarded then begin
            (* If terminal is active but not forwarding (mouse off or
               shift held), use vterm's local selection. *)
            let term_sel = if pane = Render.PMessages then
              let active_mt = Tab.active_msg_tab tab.msg in
              active_mt.mt_terminal
            else None in
            match term_sel with
            | Some term ->
              let vt = Terminal.vterm term in
              let rect = Render.pane_rect r Render.PMessages in
              let vy = y - rect.row in
              let vx = x - rect.col in
              let (line, col) = Vterm_lib.Vterm_api.hit_test vt ~row:vy ~col:vx in
              if has_shift && Vterm_lib.Vterm_api.has_selection vt then
                Vterm_lib.Vterm_api.sel_extend vt ~line ~col
              else
                Vterm_lib.Vterm_api.sel_start vt ~line ~col;
              tab.mouse_selecting <- true
            | None ->
              let (ps, lines_cache, _scroll_ref, pane_id) =
                if pane = Render.PGoals then
                  (tab.goals_sel, tab.goals_lines_cache, tab.goals_scroll, `Goals)
                else
                  ((Tab.active_msg_tab tab.msg).mt_sel, (Tab.active_msg_tab tab.msg).mt_lines_cache, (Tab.active_msg_tab tab.msg).mt_scroll, `Messages)
              in
              match Geom.screen_to_pane_pos tab r ~x ~y pane_id with
              | Some (row, byte_col) ->
                View.clear_pane_selection ps;
                ps.ps_anchor_line <- row;
                ps.ps_anchor_col <- byte_col;
                ps.ps_cursor_line <- row;
                ps.ps_cursor_col <- byte_col;
                ps.ps_active <- true;
                tab.mouse_selecting <- true;
                ignore lines_cache
              | None -> ()
          end
        end
        else if pane = Render.PMessages && is_middle then begin
          (* Middle click: paste clipboard to terminal *)
          let active_mt = Tab.active_msg_tab tab.msg in
          (match active_mt.mt_terminal with
           | Some term when ctx.clipboard <> "" ->
             let vt = Terminal.vterm term in
             if Vterm_lib.Vterm_api.bracketed_paste vt then
               Terminal.send term
                 ("\x1b[200~" ^ ctx.clipboard ^ "\x1b[201~")
             else
               Terminal.send term ctx.clipboard
           | _ -> ())
        end
        else if pane = Render.PMinimap && is_left then begin
          let mm_rect = Render.pane_rect r Render.PMinimap in
          let mm_row = y - mm_rect.row in
          if mm_row >= 0 && mm_row < mm_rect.height then begin
            let num_lines = Buffer.line_count buf in
            let ypc = Minimap.y_per_cell ~num_lines ~available_rows:mm_rect.height in
            let target_line = mm_row * ypc in
            let (srows, _) = Render.pane_dims r Render.PScript in
            let target_scroll = max 0 (target_line - srows / 2) in
            let max_scroll = max 0 (num_lines - srows) in
            Buffer.set_scroll_top buf (min target_scroll max_scroll)
          end;
          ctx.dragging <- Editor_context.DragMinimapScroll
        end
        else if pane = Render.PScript && is_left then begin
          tab.focused_pane <- `Script;
          View.clear_pane_selection tab.goals_sel;
          View.clear_pane_selection (Tab.active_msg_tab tab.msg).mt_sel;
          if has_cmd then begin
            match Geom.screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.move_to buf line byte_col;
              (match session with
               | Some s -> Session.go_to_cursor s
               | None -> ())
            | None -> ()
          end
          else if has_shift then begin
            match Geom.screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              if Buffer.selection buf = None then Buffer.set_anchor buf;
              Buffer.move_to buf line byte_col
            | None -> ()
          end
          else begin
            (* Click — position cursor; set anchor for potential drag *)
            match Geom.screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.clear_selection buf;
              Buffer.move_to buf line byte_col;
              (* Anchor is set for drag, but cleared on release if no drag occurred *)
              Buffer.set_anchor buf;
              tab.mouse_selecting <- true
            | None -> ()
          end
        end
      end;
      Some Continue
    end
    (* Paste event *)
    else if (match ev with Input.Paste _ -> true | _ -> false) then begin
      let text = match ev with Input.Paste t -> normalize_newlines t | _ -> "" in
      if text <> "" && not (Block.edit_blocked tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        insert_string tab text;
        ctx.clipboard <- text
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
          let word = match Buffer.selected_text buf with
            | Some t -> Some t | None -> Buffer.word_at_cursor buf in
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
      let subject = match tab.focused_pane with
        | `Goals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> View.pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script ->
          match Buffer.selected_text buf with
          | Some text -> Some text | None -> Buffer.word_at_cursor buf
      in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("About " ^ word ^ ".")       | _ -> ());
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.print_query then begin
      let subject = match tab.focused_pane with
        | `Goals -> View.pane_selection_text tab.goals_sel tab.goals_lines_cache
        | `Messages -> View.pane_selection_text (Tab.active_msg_tab tab.msg).mt_sel (Tab.active_msg_tab tab.msg).mt_lines_cache
        | `Script ->
          match Buffer.selected_text buf with
          | Some text -> Some text | None -> Buffer.word_at_cursor buf
      in
      (match subject, session with
       | Some word, Some s ->
         Session.query s ("Print " ^ word ^ ".")       | _ -> ());
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
      Buffer.undo buf;
      Block.rewind_if_needed tab;
      Some Continue
    end
    else if Keymatch.match_binding ev Keys.redo then begin
      Buffer.redo buf;
      Block.rewind_if_needed tab;
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
  (* --- Script pane keys --- *)
  let handle_script () =
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
        (* Encode codepoint as UTF-8 and insert *)
        if cp < 128 then
          Buffer.insert_char buf (Char.chr cp)
        else begin
          let s =
            if cp < 0x800 then
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
          in
          insert_string tab s
        end
      end;
      Some Continue
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
        (match handle_script () with
         | Some a -> a | None -> Continue)
  in
  action
  end
