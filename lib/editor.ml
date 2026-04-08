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



let push_jump (ctx : Editor_context.t) (tab : Tab.t) =
  let (line, col) = Buffer.cursor tab.buf in
  let file = match Buffer.filename tab.buf with
    | Some f -> f | None -> "" in
  ctx.jump_stack <- { Editor_context.jp_tab_id = tab.id; jp_file = file;
                      jp_line = line; jp_col = col } :: ctx.jump_stack

let pop_jump (ctx : Editor_context.t) =
  match ctx.jump_stack with
  | [] -> None
  | jp :: rest ->
    ctx.jump_stack <- rest;
    Some jp

(* Check if cursor is in the verified region. *)
let cursor_byte_offset buf =
  let (cl, cc) = Buffer.cursor buf in
  let off = ref 0 in
  for i = 0 to cl - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + cc

let cursor_in_target ?(for_backspace=false) (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  match session with
  | None -> false
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then false
    else
      let off = cursor_byte_offset buf in
      if for_backspace then off <= tend
      else off < tend

(* Check if editing is blocked (cursor in target region, or buffer locked by MCP). *)
let edit_blocked ?(for_backspace=false) (tab : Tab.t) =
  tab.locked || cursor_in_target ~for_backspace tab

(* After undo/redo, retract target if the edit is inside the target region *)
let rewind_if_needed (tab : Tab.t) =
  let buf = tab.buf in
  let session = tab.session in
  match session with
  | None -> ()
  | Some sess ->
    let tend = Session.pending_end sess in
    if tend = 0 then ()
    else begin
      let cursor_off = cursor_byte_offset buf in
      if cursor_off < tend then
        Session.go_to_cursor sess
    end

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

let insert_string (tab : Tab.t) s =
  if not (edit_blocked tab) then
    let buf = tab.buf in
    String.iter (fun c ->
      if c = '\n' then Buffer.insert_newline buf
      else Buffer.insert_char buf c
    ) s

(* Convert screen coordinates to buffer (line, byte_col) position.
   Returns None if the coordinates are outside the script pane content. *)
let screen_to_buffer_pos r buf ~x ~y =
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let script_rect = Render.pane_rect r Render.PScript in
  let row = y - script_rect.row in
  let col = x - script_rect.col in
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let line_idx = scroll + row in
    if line_idx >= Buffer.line_count buf then None
    else begin
      let line = Buffer.get_line buf line_idx in
      let vcol = hscroll + col in
      let byte_col = Utf8.col_to_byte line vcol in
      Some (line_idx, byte_col)
    end
  end

(* Convert screen coords to a right-pane (line, byte_col) relative to the pane *)
let screen_to_pane_pos (tab : Tab.t) r ~x ~y pane_id =
  let pane = match pane_id with
    | `Goals -> Render.PGoals
    | `Messages -> Render.PMessages
  in
  let rect = Render.pane_rect r pane in
  let (rows, cols) = Render.pane_dims r pane in
  let row = y - rect.row in
  let col = x - rect.col - 1 in (* -1 for margin *)
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let scroll, lines_cache = match pane_id with
      | `Goals -> (tab.goals_scroll, tab.goals_lines_cache)
      | `Messages -> ((Tab.active_msg_tab tab.msg).mt_scroll, (Tab.active_msg_tab tab.msg).mt_lines_cache)
    in
    let line_idx = scroll + row in
    let lines = lines_cache in
    let n = List.length lines in
    if line_idx >= n then None
    else begin
      let line = List.nth lines line_idx in
      let byte_col = Utf8.col_to_byte line (max 0 col) in
      Some (line_idx, byte_col)
    end
  end

(* Select word at position in a pane's cached lines *)
let [@warning "-32"] pane_select_word (ps : Tab.pane_selection) lines_cache line_idx byte_col =
  let lines = lines_cache in
  if line_idx >= List.length lines then ()
  else begin
    let line = List.nth lines line_idx in
    let len = String.length line in
    let col = min byte_col len in
    let is_id c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c = '_' || c = '\'' || c = '.' in
    if col < len && is_id line.[col] then begin
      let l = ref col in
      while !l > 0 && is_id line.[!l - 1] do decr l done;
      let r = ref col in
      while !r < len && is_id line.[!r] do incr r done;
      if !r > !l && line.[!r - 1] = '.' then decr r;
      if !r > !l then begin
        ps.ps_anchor_line <- line_idx;
        ps.ps_anchor_col <- !l;
        ps.ps_cursor_line <- line_idx;
        ps.ps_cursor_col <- !r;
        ps.ps_active <- true
      end
    end
  end

(* --- Input event handling --- *)

(* Helper: match an Input.event against a Keys.binding *)
let match_binding (ev : Input.event) (b : Keys.binding) =
  match ev with
  | Input.Key (cp, mods) ->
    (* Ctrl+letter: cp is the letter, mods.ctrl is true *)
    if mods.ctrl && not mods.alt && not mods.shift then begin
      let ctrl_code = if cp >= 97 && cp <= 122 then cp - 96
                      else if cp >= 65 && cp <= 90 then cp - 64
                      else -1 in
      if ctrl_code > 0 then List.mem ctrl_code b.codes
      else List.mem cp b.codes
    end
    else if not mods.ctrl && not mods.alt && not mods.shift then
      List.mem cp b.codes
    else
      (* Try kitty codes for modified keys *)
      let modifier = 1
        + (if mods.shift then 1 else 0)
        + (if mods.alt then 2 else 0)
        + (if mods.ctrl then 4 else 0) in
      List.exists (fun (kc, m) -> kc = cp && m = modifier) b.kitty_codes
  | Input.Special (key, mods) ->
    (* Map special keys to legacy codes for binding matching *)
    let modifier = 1
      + (if mods.shift then 1 else 0)
      + (if mods.alt then 2 else 0)
      + (if mods.ctrl then 4 else 0) in
    let base_code = match key with
      | Input.Up -> Some 259 | Input.Down -> Some 258
      | Input.Right -> Some 261 | Input.Left -> Some 260
      | Input.Home -> Some 262 | Input.End -> Some 360
      | Input.PageUp -> Some 339 | Input.PageDown -> Some 338
      | Input.Insert -> Some 331 | Input.Delete -> Some 330
      | Input.F n -> Some (264 + n)  (* F1=265, F2=266 etc. *)
      | Input.Backspace -> Some 127
      | Input.Tab -> Some 9
      | Input.Enter -> Some 13
      | Input.Escape -> None  (* Escape handled separately *)
    in
    (match base_code with
     | Some code ->
       if modifier = 1 then
         List.mem code b.codes
       else begin
         (* Modified special keys: try kitty_codes, then legacy shift/alt/ctrl codes *)
         let has_kitty = List.exists (fun (kc, m) ->
           kc = code && m = modifier) b.kitty_codes in
         if has_kitty then true
         else begin
           (* Map modified arrows to legacy ncurses codes *)
           let has_alt = mods.alt in
           let has_ctrl = mods.ctrl in
           let has_shift = mods.shift in
           (* Map modified arrows to ALL legacy ncurses code variants *)
           let mapped = match key with
             | Input.Up ->
               if has_alt then [564; 567; 573; 558]
               else if has_ctrl then [567; 573; 558]
               else if has_shift then [337] else []
             | Input.Down ->
               if has_alt then [523; 526; 532; 517]
               else if has_ctrl then [526; 532; 517]
               else if has_shift then [336] else []
             | Input.Right ->
               if has_alt then [558; 561] else if has_ctrl then [561]
               else if has_shift then [402] else []
             | Input.Left ->
               if has_alt then [543; 546; 552]
               else if has_ctrl then [546]
               else if has_shift then [393] else []
             | _ -> []
           in
           List.exists (fun c -> List.mem c b.codes) mapped
         end
       end
     | None -> false)
  | _ -> false

(* Extract codepoint from event for compose feeding *)
let codepoint_of_event = function
  | Input.Key (cp, _) -> Some cp
  | Input.Special (Input.Tab, _) -> Some 9
  | Input.Special (Input.Enter, _) -> Some 13
  | Input.Special (Input.Backspace, _) -> Some 127
  | Input.Special (Input.Escape, _) -> Some 27
  | _ -> None

let rec handle_event (ctx : Editor_context.t) (ev : Input.event) (tab : Tab.t) r =
  let buf = tab.buf in
  let session = tab.session in
  (* Handle compose mode first *)
  let compose_handled = match ctx.compose with
    | Some cs when Compose.active cs ->
      (match codepoint_of_event ev with
       | Some cp ->
         let result = Compose.feed cs cp in
         (match result with
          | Compose.Pending ->
            Render.set_status r (View.format_compose_status r cs);
            Render.present r
          | Compose.Composed text ->
            ignore (Buffer.delete_selection buf);
            insert_string tab text
          | Compose.NoMatch ->
            (* If the key that broke compose was Escape, restart compose *)
            (match ev with
             | Input.Special (Input.Escape, _) ->
               Compose.start cs;
               Render.set_status r (View.format_compose_status r cs);
               Render.present r
             | _ -> ()));
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
  let handle_global () =
    if match_binding ev Keys.quit then Some Quit
    else if match_binding ev Keys.close_tab then Some Close_tab
    else if match_binding ev Keys.save then Some Save_prompt
    else if match_binding ev Keys.jump_back then begin
      match pop_jump ctx with
      | Some jp ->
        ctx.jump_target <- Some (jp.jp_line, jp.jp_col);
        Some (Jump_back jp)
      | None ->
        Render.set_status r "No previous location.";
        Some Continue
    end
    else if match_binding ev Keys.open_file then begin
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
    else if match_binding ev Keys.interrupt then begin
      (match session with
       | Some s -> (try Unix.kill (Session.pid s) Sys.sigint with _ -> ())
       | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.step_forward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_forward s | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.step_backward then begin
      tab.goals_scroll <- 0; (Tab.ensure_msg_tab tab.msg "Rocq").mt_scroll <- 0;
      (match session with Some s -> Session.step_backward s | None -> ());
      Some Continue
    end
    else if match_binding ev Keys.go_to_cursor then begin
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
        (* Plain Escape -- start compose *)
        match ctx.compose with
        | Some cs ->
          Compose.start cs;
          Render.set_status r (View.format_compose_status r cs);
          Render.present r
        | None -> ()
      end;
      Some Continue
    end
    else if match_binding ev Keys.toggle_hyps then begin
      tab.show_all_hyps <- not tab.show_all_hyps; Some Continue end
    else if match_binding ev Keys.options_menu then begin
      if View.is_options ctx then begin
        Modal.pop ctx.modal;
        (match session with Some s -> Session.sync_options_and_refresh s | None -> ())
      end else Modal.push ctx.modal Modal.OptionsMenu;
      Some Continue
    end
    else if View.is_options ctx then begin
      let ch_opt = codepoint_of_event ev in
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
    else if match_binding ev Keys.reload then begin
      Some Reload
    end
    else if match_binding ev Keys.theme_menu then begin
      Modal.toggle ctx.modal Modal.ThemeMenu;
      Some Continue
    end
    else if View.is_theme ctx then begin
      Modal.pop ctx.modal;
      (match codepoint_of_event ev with
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
    else if match_binding ev Keys.build_menu then begin
      Modal.toggle ctx.modal Modal.BuildMenu;
      Some Continue
    end
    else if View.is_build ctx then begin
      Modal.pop ctx.modal;
      (match codepoint_of_event ev with
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
         else if c = 't' then begin
           let (h, w) = Render.pane_dims r Render.PMessages in
           let _term = Terminal.create ~w ~h () in
           Tab.sync_terminals tab.msg;
           let n = List.length tab.msg.mt_tabs in
           tab.msg.mt_active <- n - 1;
           tab.focused_pane <- `Messages;
           Some Continue
         end
         else if c = 'l' then begin
           let (h, w) = Render.pane_dims r Render.PMessages in
           let _term = Terminal.create ~cmd:"claude" ~args:["--chat"] ~w ~h () in
           Tab.sync_terminals tab.msg;
           let n = List.length tab.msg.mt_tabs in
           tab.msg.mt_active <- n - 1;
           tab.focused_pane <- `Messages;
           Some Continue
         end
         else
           (Some Continue)
       | None -> Some Continue)
    end
    else if match_binding ev Keys.query_menu then begin
      Modal.toggle ctx.modal Modal.QueryMenu;
      Some Continue
    end
    else if View.is_query ctx then begin
      Modal.pop ctx.modal;
      match codepoint_of_event ev with
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
    else if match_binding ev Keys.cycle_pane then begin
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
      let is_scroll_up = mev.button = Input.ScrollUp in
      let is_scroll_down = mev.button = Input.ScrollDown in
      let has_shift = mev.mods.shift in
      let has_cmd = mev.mods.ctrl in  (* Ctrl acts as Cmd on most terminals *)
      if ctx.dragging <> Editor_context.NoDrag then begin
        (* Active border drag *)
        (match ctx.dragging with
         | Editor_context.DragV -> Render.move_split_v r x
         | Editor_context.DragH -> Render.move_split_h r y
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
             Buffer.set_scroll_top buf (min target_scroll max_scroll);
             tab.suppress_ensure_visible <- true
           end
         | Editor_context.NoDrag -> ());
        if is_release then ctx.dragging <- Editor_context.NoDrag
      end
      else if tab.mouse_selecting then begin
        (* Active text selection drag *)
        let pane = Render.pane_at r ~x ~y in
        if pane = Render.PScript then begin
          match screen_to_buffer_pos r buf ~x ~y with
          | Some (line, byte_col) -> Buffer.move_to buf line byte_col
          | None -> ()
        end else if pane = Render.PGoals || pane = Render.PMessages then begin
          let (ps, pane_id) =
            if pane = Render.PGoals then (tab.goals_sel, `Goals)
            else ((Tab.active_msg_tab tab.msg).mt_sel, `Messages)
          in
          (match screen_to_pane_pos tab r ~x ~y pane_id with
           | Some (row, byte_col) ->
             ps.ps_cursor_line <- row;
             ps.ps_cursor_col <- byte_col
           | None -> ())
        end;
        if is_release then begin
          tab.mouse_selecting <- false;
          (* If no actual drag occurred (anchor == cursor), clear selection *)
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
            Buffer.set_scroll_top buf (max 0 (min max_scroll (Buffer.scroll_top buf + delta)));
            tab.suppress_ensure_visible <- true
          | Render.PGoals ->
            tab.goals_scroll <- max 0 (tab.goals_scroll + delta)
          | Render.PMessages ->
            (Tab.active_msg_tab tab.msg).mt_scroll <- max 0 ((Tab.active_msg_tab tab.msg).mt_scroll + delta)
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
            tab.msg.mt_active <- i
          | None ->
            ctx.dragging <- Editor_context.DragH
        end
        else if (pane = Render.PBorderV || pane = Render.PBorderMinimap)
                && is_left then
          ctx.dragging <- (match pane with
            | Render.PBorderMinimap -> Editor_context.DragMinimap
            | _ -> Editor_context.DragV)
        else if (pane = Render.PGoals || pane = Render.PMessages)
                && is_left then begin
          tab.focused_pane <- (if pane = Render.PGoals then `Goals else `Messages);
          let (ps, lines_cache, _scroll_ref, pane_id) =
            if pane = Render.PGoals then
              (tab.goals_sel, tab.goals_lines_cache, tab.goals_scroll, `Goals)
            else
              ((Tab.active_msg_tab tab.msg).mt_sel, (Tab.active_msg_tab tab.msg).mt_lines_cache, (Tab.active_msg_tab tab.msg).mt_scroll, `Messages)
          in
          (* For now, treat all Left clicks as single click *)
          match screen_to_pane_pos tab r ~x ~y pane_id with
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
            Buffer.set_scroll_top buf (min target_scroll max_scroll);
            tab.suppress_ensure_visible <- true
          end;
          ctx.dragging <- Editor_context.DragMinimapScroll
        end
        else if pane = Render.PScript && is_left then begin
          tab.focused_pane <- `Script;
          View.clear_pane_selection tab.goals_sel;
          View.clear_pane_selection (Tab.active_msg_tab tab.msg).mt_sel;
          if has_cmd then begin
            match screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              Buffer.move_to buf line byte_col;
              (match session with
               | Some s -> Session.go_to_cursor s
               | None -> ())
            | None -> ()
          end
          else if has_shift then begin
            match screen_to_buffer_pos r buf ~x ~y with
            | Some (line, byte_col) ->
              if Buffer.selection buf = None then Buffer.set_anchor buf;
              Buffer.move_to buf line byte_col
            | None -> ()
          end
          else begin
            (* Click — position cursor; set anchor for potential drag *)
            match screen_to_buffer_pos r buf ~x ~y with
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
      let text = match ev with Input.Paste t -> t | _ -> "" in
      if text <> "" && not (edit_blocked tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        insert_string tab text;
        ctx.clipboard <- text
      end;
      Some Continue
    end
    else if match_binding ev Keys.jump_to_def then begin
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
         push_jump ctx tab;
         (match line_opt with
          | Some l -> ctx.jump_target <- Some (l, 0)
          | None -> ctx.jump_target <- None);
         Some (Open_file path)
       | None -> Some Continue)
    end
    else if match_binding ev Keys.help then begin
      if View.is_help ctx then begin
        Modal.pop ctx.modal;
        View.set_help_scroll ctx 0
      end else
        Modal.push ctx.modal (Modal.Help { scroll = 0 });
      Some Continue
    end
    else if match_binding ev Keys.minimap then begin
      if Render.minimap_width r > 0 then
        Render.set_minimap_width r 0
      else
        Render.set_minimap_width r Minimap.width;
      Some Continue
    end
    else if match_binding ev Keys.about then begin
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
    else if match_binding ev Keys.print_query then begin
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
    else if match_binding ev Keys.copy then begin
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
    else if match_binding ev Keys.undo then begin
      Buffer.undo buf;
      rewind_if_needed tab;
      Some Continue
    end
    else if match_binding ev Keys.redo then begin
      Buffer.redo buf;
      rewind_if_needed tab;
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
    | _ when match_binding ev Keys.cut ->
      if not (edit_blocked tab) then begin
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
    | _ when match_binding ev Keys.paste ->
      if not (edit_blocked tab) then begin
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
      if not (edit_blocked tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_at buf)
      end;
      Some Continue
    (* Backspace *)
    | Input.Special (Input.Backspace, _) ->
      if not (edit_blocked ~for_backspace:true tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        (match Buffer.delete_selection buf with
         | Some _ -> () | None -> Buffer.delete_char_before buf)
      end;
      Some Continue
    (* Enter *)
    | Input.Special (Input.Enter, _) ->
      if not (edit_blocked tab) then begin
        (match session with Some s -> Session.clear_error s | None -> ());
        ignore (Buffer.delete_selection buf);
        Buffer.insert_newline buf
      end;
      Some Continue
    (* Printable character *)
    | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
      if not (edit_blocked tab) then begin
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
           (* Terminal sub-tab is focused: route input to PTY *)
           let vt = Terminal.vterm term in
           let pty = Terminal.pty term in
           let mode = Vterm_lib.Vterm_api.term_mode vt
             land (Vterm_lib.Vterm_api.mode_app_keypad
                   lor Vterm_lib.Vterm_api.mode_app_cursor
                   lor Vterm_lib.Vterm_api.mode_meta) in
           let kitty_fl = Vterm_lib.Vterm_api.kitty_flags vt in
           let write_pty s = Vterm_lib.Pty.write pty s in
           let send_key ~keysym ?(base_keysym=keysym) ~mods ?(text="") () =
             let seq =
               if kitty_fl > 0 then
                 Vterm_lib.Vterm_api.kitty_keyseq ~keysym ~base_keysym
                   ~modifiers:mods ~mode ~kitty_flags:kitty_fl
                   ~event_type:1 ~text
               else
                 Vterm_lib.Vterm_api.keyseq ~keysym ~modifiers:mods
                   ~mode ~event_type:0
             in
             match seq with
             | Some s -> write_pty s
             | None ->
               (* Fallback: basic keys that keyseq doesn't handle *)
               let fallback = match keysym with
                 | 0xff0d -> Some "\r"        (* Return *)
                 | 0xff08 -> Some "\x7f"      (* Backspace *)
                 | 0xff09 -> Some "\t"        (* Tab *)
                 | 0xff1b -> Some "\x1b"      (* Escape *)
                 | ks when ks < 0x100 && mods = 0 ->
                   (* ASCII-range keysym, no modifiers *)
                   let s = String.make 1 (Char.chr ks) in
                   Some s
                 | _ -> None
               in
               (match fallback with
                | Some s -> write_pty s
                | None -> ())
           in
           let input_mod (m : Input.modifier) =
             (if m.shift then 1 else 0)
             lor (if m.alt then 2 else 0)
             lor (if m.ctrl then 4 else 0)
           in
           (match ev with
            | Input.Key (cp, mods) when cp >= 32 && not mods.ctrl && not mods.alt ->
              (* Plain printable character *)
              let buf = Stdlib.Buffer.create 4 in
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
              in
              encode_utf8 buf cp;
              write_pty (Stdlib.Buffer.contents buf)
            | Input.Key (cp, mods) ->
              (* Ctrl/Alt modified key *)
              let mods_i = input_mod mods in
              send_key ~keysym:cp ~mods:mods_i ()
            | Input.Special (key, mods) ->
              let mods_i = input_mod mods in
              (* Map Input.special_key to X11 keysyms *)
              let keysym = match key with
                | Input.Up -> 0xff52 | Input.Down -> 0xff54
                | Input.Left -> 0xff51 | Input.Right -> 0xff53
                | Input.Home -> 0xff50 | Input.End -> 0xff57
                | Input.PageUp -> 0xff55 | Input.PageDown -> 0xff56
                | Input.Insert -> 0xff63 | Input.Delete -> 0xffff
                | Input.Backspace -> 0xff08
                | Input.Tab -> 0xff09 | Input.Enter -> 0xff0d
                | Input.Escape -> 0xff1b
                | Input.F n -> 0xffbd + n  (* F1=0xffbe, F2=0xffbf, etc. *)
              in
              send_key ~keysym ~mods:mods_i ()
            | Input.Paste text ->
              if Vterm_lib.Vterm_api.bracketed_paste vt then begin
                write_pty "\027[200~";
                write_pty text;
                write_pty "\027[201~"
              end else
                write_pty text
            | _ -> ());
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
