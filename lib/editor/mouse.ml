let handle (ctx : Editor_context.t) (mev : Input.mouse_event) (tab : Tab.t) r
  : Action.action option =
  let buf = tab.buf in
  let session = tab.session in
  let x = mev.x in
  let y = mev.y in
  let is_release = mev.button = Input.Release in
  let is_left = mev.button = Input.Left in
  let is_middle = mev.button = Input.Middle in
  let is_scroll_up = mev.button = Input.ScrollUp in
  let is_scroll_down = mev.button = Input.ScrollDown in
  let has_shift = mev.mods.shift in
  let has_cmd = mev.mods.ctrl in  (* Ctrl acts as Cmd on most terminals *)
  let result : Action.action option ref = ref None in
  (* Terminal mouse: handle release and drag for reported buttons *)
  let term_mouse_handled = ref false in
  let active_term () = match Msg_pane.active_kind () with
    | Msg_pane.Terminal t -> Some t
    | _ -> None
  in
  (match active_term () with
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
     | Editor_context.DragFileTree -> Render.move_file_tree_border r x
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
    let term_in_msgs = if pane = Render.PMessages then active_term ()
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
           else (Geom.active_msg_pane_sel tab, `Messages)
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
      | Render.PFileTree ->
        (match ctx.file_tree with
         | Some ft -> File_tree.handle_scroll ft r (if is_scroll_up then -1 else 1)
         | None -> ())
      | Render.PMessages ->
        (match Msg_pane.active_kind () with
         | Msg_pane.Terminal term ->
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
         | Msg_pane.Rocq ->
           tab.rocq_msg.rms_scroll <-
             max 0 (tab.rocq_msg.rms_scroll + delta)
         | Msg_pane.Build | Msg_pane.Errors | Msg_pane.Search ->
           let mt = Msg_pane.active_tab () in
           mt.scroll <- max 0 (mt.scroll + delta))
      | _ -> ()
    end
    else if pane = Render.PTabBar && is_left then begin
      ctx.switch_tab x
    end
    else if pane = Render.PBorderH && is_left then begin
      let mp = Msg_pane.state () in
      let tab_names = List.map Msg_pane.display_name mp.tabs in
      match Render.msg_tab_at_x r ~x ~tab_names with
      | Some i ->
        if i >= 0 && i < List.length mp.tabs then
          Msg_pane.activate (List.nth mp.tabs i).kind
      | None ->
        ctx.dragging <- Editor_context.DragH
    end
    else if pane = Render.PBorderBoth && is_left then
      ctx.dragging <- Editor_context.DragBoth
    else if pane = Render.PBorderFileTree && is_left then
      ctx.dragging <- Editor_context.DragFileTree
    else if (pane = Render.PBorderV || pane = Render.PBorderMinimap)
            && is_left then
      ctx.dragging <- (match pane with
        | Render.PBorderMinimap -> Editor_context.DragMinimap
        | _ -> Editor_context.DragV)
    else if (pane = Render.PGoals || pane = Render.PMessages)
            && is_left then begin
      ctx.focus <-
        (if pane = Render.PGoals then Editor_context.FGoals
         else Editor_context.FMessages);
      (* Build / Errors / Search tab click → jump to entry *)
      let jumped_to_error =
        if pane = Render.PMessages then begin
          match Msg_pane.active_kind () with
          | Msg_pane.Terminal _ | Msg_pane.Rocq -> false
          | Msg_pane.Search ->
            (match Geom.screen_to_pane_pos tab r ~x ~y `Messages with
             | None -> false
             | Some (row, _col) ->
               (match Search_tab.lookup_tab_row row with
                | None -> false
                | Some (path, idx) ->
                  let active_path = Buffer.filename tab.buf in
                  if Some path = active_path then begin
                    (* In-tab click: update buffer_matches.current
                       and move cursor. *)
                    match Editor_context.tab_matches ctx tab with
                    | Some bm when idx >= 0
                                   && idx < Array.length bm.matches ->
                      Search.bm_set_current bm idx;
                      let m = bm.matches.(idx) in
                      Buffer.move_to tab.buf m.start_.line m.start_.col;
                      true
                    | _ -> false
                  end
                  else begin
                    (* Cross-file click (project mode): we have the
                       match coordinates from the rendered snapshot.
                       Look them up to get the line/col. *)
                    match Editor_context.search_snapshot ctx tab with
                    | None -> false
                    | Some sr ->
                      (match Search_results.find_match sr path idx with
                       | None -> false
                       | Some m ->
                         Search_results.set_current sr
                           (Some (path, idx));
                         Jump.push ctx tab;
                         ctx.jump_target <-
                           Some (m.ml_line - 1, m.ml_col_start);
                         result := Some (Action.Open_file path);
                         true)
                  end))
          | Msg_pane.Build | Msg_pane.Errors as ak ->
            (match Geom.screen_to_pane_pos tab r ~x ~y `Messages with
             | None -> false
             | Some (row, _col) ->
               let entry_opt = match ak with
                 | Msg_pane.Build -> Build_errors.lookup_by_output_row row
                 | Msg_pane.Errors -> Build_errors.lookup_errors_tab_row row
                 | _ -> None
               in
               (match entry_opt with
                | None -> false
                | Some (e : Build_errors.entry) ->
                  Build_errors.set_current e;
                  Jump.push ctx tab;
                  ctx.jump_target <- Some (e.line - 1, e.col_start);
                  result := Some (Action.Open_file e.file);
                  true))
        end else false
      in
      if jumped_to_error then
        (* A click that jumps to a match / error is a "go there"
           gesture — focus should end up in the script pane where
           the cursor now is, not in the messages tab we clicked. *)
        ctx.focus <- Editor_context.FScript
      else
      (* Check if we should forward to terminal *)
      let forwarded = if pane = Render.PMessages then
        match active_term () with
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
        let term_sel = if pane = Render.PMessages then active_term ()
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
          let (ps, pane_id) =
            if pane = Render.PGoals then
              (tab.goals_sel, `Goals)
            else
              (Geom.active_msg_pane_sel tab, `Messages)
          in
          match Geom.screen_to_pane_pos tab r ~x ~y pane_id with
          | Some (row, byte_col) ->
            View.clear_pane_selection ps;
            ps.ps_anchor_line <- row;
            ps.ps_anchor_col <- byte_col;
            ps.ps_cursor_line <- row;
            ps.ps_cursor_col <- byte_col;
            ps.ps_active <- true;
            tab.mouse_selecting <- true
          | None -> ()
      end
    end
    else if pane = Render.PMessages && is_middle then begin
      (* Middle click: paste clipboard to terminal *)
      (match active_term () with
       | Some term when ctx.clipboard <> "" ->
         let vt = Terminal.vterm term in
         if Vterm_lib.Vterm_api.bracketed_paste vt then
           Terminal.send term
             ("\x1b[200~" ^ ctx.clipboard ^ "\x1b[201~")
         else
           Terminal.send term ctx.clipboard
       | _ -> ())
    end
    else if pane = Render.PFileTree && is_left then begin
      ctx.focus <- Editor_context.FFileTree;
      (match ctx.file_tree with
       | Some ft ->
         (match File_tree.handle_click ft r ~y with
          | File_tree.TreeOpen path -> result := Some (Action.Open_file path)
          | File_tree.TreeContinue | File_tree.TreeUnhandled -> ())
       | None -> ())
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
      ctx.focus <- Editor_context.FScript;
      View.clear_pane_selection tab.goals_sel;
      View.clear_pane_selection (Geom.active_msg_pane_sel tab);
      if has_cmd then begin
        match Geom.screen_to_buffer_pos r buf ~x ~y with
        | Some (line, byte_col) ->
          Buffer.move_to buf line byte_col;
          (match session with
           | Some s when not (Region_buffer.locked tab.rb) ->
             Session.set_user_step_pending s;
             Session.go_to_cursor s
           | _ -> ())
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
  !result
