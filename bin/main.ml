open Rocqtui_lib

let () =
  (* Parse command line: rocqtui [-theme NAME] [file1.v file2.v ...] [-- rocq-args...] *)
  let filenames = ref [] in
  let extra_args = ref [] in
  let theme_name = ref None in
  let after_dashdash = ref false in
  let skip_next = ref false in
  Array.iteri (fun i arg ->
    if i = 0 then ()
    else if !skip_next then
      skip_next := false
    else if !after_dashdash then
      extra_args := arg :: !extra_args
    else if arg = "--" then
      after_dashdash := true
    else if arg = "-theme" then begin
      if i + 1 < Array.length Sys.argv then begin
        theme_name := Some Sys.argv.(i + 1);
        skip_next := true
      end
    end
    else
      filenames := arg :: !filenames
  ) Sys.argv;
  let filenames = List.rev !filenames in
  let extra_args = List.rev !extra_args in
  let theme = match !theme_name with
    | Some n -> Theme.find n
    | None -> Theme.default
  in
  Sys.set_signal Sys.sigint Sys.Signal_ignore;
  Sys.set_signal Sys.sigtstp Sys.Signal_ignore;
  let display = Display.init () in
  Theme.apply theme;
  Editor.init_compose ();
  Clipboard.enable_bracketed_paste ();
  Rocq_protocol.set_interrupt_hook (fun t ->
    let ch = Curses.getch () in
    if ch = 3 then
      (try Unix.kill (Rocq_protocol.pid t) Sys.sigint with _ -> ()));
  Printexc.record_backtrace true;
  (* Create tabs *)
  let project_dirs = ref [] in
  let create_tab_for_file filename =
    let (project_dir, project_args) = Project.find_args (Some filename) in
    (match project_dir with
     | Some d ->
       if not (List.mem d !project_dirs) then
         project_dirs := d :: !project_dirs
     | None -> ());
    let all_args = project_args @ extra_args in
    Tab.create_from_file ~args:all_args filename
  in
  let initial_tabs = match filenames with
    | [] -> [Tab.create_blank ()]
    | files -> List.map create_tab_for_file files
  in
  let mgr = Tab.create_manager (List.hd initial_tabs) in
  List.iter (fun tab ->
    if tab != List.hd initial_tabs then Tab.add_tab mgr tab
  ) initial_tabs;
  if Tab.count mgr > 1 then
    Display.set_tab_bar display true;
  (* Tab bar click handler *)
  let needs_render = ref true in
  Editor.set_tab_bar_click_handler (fun x ->
    match Tab.tab_at_x mgr x with
    | Some i -> mgr.active <- i; needs_render := true
    | None -> ());
  (* Start MCP server *)
  let mcp = Mcp_server.create () in
  (* Create MCP socket symlinks in project directories *)
  List.iter (Mcp_server.create_project_symlink mcp) !project_dirs;
  (* Render helper *)
  let render () =
    (* Set MCP status indicator *)
    let active = Tab.active_tab mgr in
    (if Mcp_server.has_clients mcp && Mcp_server.is_tab_active mcp active.id then
       Editor.set_status_extra (Mcp_server.spinner_char mcp ^ " Claude")
     else
       Editor.set_status_extra "");
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      let spinner = if Mcp_server.has_clients mcp then
        Some (Mcp_server.spinner_char mcp) else None in
      let tabs = List.map (fun (t : Tab.t) ->
        let name = match Buffer.filename t.buf with
          | Some f -> Filename.basename f | None -> "[new]"
        in
        let prefix = if Buffer.modified t.buf then "*" else "" in
        let suffix = match spinner with
          | Some s when Mcp_server.is_tab_active mcp t.id -> " " ^ s
          | _ -> ""
        in
        (prefix ^ name ^ suffix, false)
      ) mgr.tabs in
      Display.draw_tab_bar display tabs mgr.active
    end;
    Editor.render_all display tab
  in
  (* Non-blocking getch *)
  Curses.timeout 0;
  let stdin_fd = Unix.stdin in
  let running = ref true in
  let handle_quit () =
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      if Buffer.modified tab.buf then begin
        Display.set_status display "Unsaved changes! ^X again to close, ^O to save.";
        Display.refresh_all display;
        let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
        if List.mem stdin_fd ready then begin
          let ch2 = Curses.getch () in
          if ch2 = 24 then begin
            ignore (Tab.close_active mgr);
            if Tab.count mgr <= 1 then
              Display.set_tab_bar display false;
            needs_render := true
          end else if ch2 = 15 then begin
            (match Buffer.filename tab.buf with
             | Some _ ->
               if Buffer.save tab.buf then
                 Display.set_status display "Saved."
               else
                 Display.set_status display "Error saving file."
             | None ->
               Display.set_status display "No filename.");
            needs_render := true
          end
        end
      end else begin
        ignore (Tab.close_active mgr);
        if Tab.count mgr <= 1 then
          Display.set_tab_bar display false;
        needs_render := true
      end
    end else begin
      if Buffer.modified tab.buf then begin
        Display.set_status display "Unsaved changes! ^X again to quit, ^O to save.";
        Display.refresh_all display;
        let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
        if List.mem stdin_fd ready then begin
          let ch2 = Curses.getch () in
          if ch2 = 24 then running := false
          else if ch2 = 15 then begin
            (match Buffer.filename tab.buf with
             | Some _ ->
               if Buffer.save tab.buf then
                 Display.set_status display "Saved."
               else
                 Display.set_status display "Error saving file."
             | None ->
               Display.set_status display "No filename.");
            needs_render := true
          end else begin
            let t = Tab.active_tab mgr in
            ignore (Editor.handle_key ch2 t display);
            needs_render := true
          end
        end
      end else
        running := false
    end
  in
  (* Main loop *)
  render ();
  while !running do
    let tab = Tab.active_tab mgr in
    let timeout =
      if Session.is_busy_opt tab.session then 0.01 else 0.1
    in
    let mcp_fds = Mcp_server.server_fd mcp :: Mcp_server.client_fds mcp in
    let extra_fds = stdin_fd :: mcp_fds in
    let ready = Main_loop.select_with_watches extra_fds timeout in
    (* Handle MCP connections/messages *)
    if Mcp_server.handle_ready mcp ready mgr then begin
      needs_render := true;
      (* MCP may have opened new tabs *)
      if Tab.count mgr > 1 then
        Display.set_tab_bar display true
    end;
    (* Poll ALL sessions *)
    if Tab.poll_all mgr then begin
      needs_render := true;
      (* Send MCP notifications for state changes driven by session polling *)
      Mcp_server.poll_notifications mcp mgr
    end;
    (* Handle keyboard input *)
    if List.mem stdin_fd ready then begin
      let rec drain () =
        let ch = Curses.getch () in
        if ch <> -1 && !running then begin
          let tab = Tab.active_tab mgr in
          if ch = 2 then begin (* ^B — new blank tab *)
            let active = Tab.active_tab mgr in
            Tab.add_tab mgr (Tab.create_blank ~args:active.session_args ());
            Display.set_tab_bar display true;
            needs_render := true
          end
          else if ch = 552 then begin (* Alt+Left — prev tab *)
            Tab.prev_tab mgr;
            needs_render := true
          end
          else if ch = 567 then begin (* Alt+Right — next tab *)
            Tab.next_tab mgr;
            needs_render := true
          end
          else begin
            match Editor.handle_key ch tab display with
            | Editor.Quit -> handle_quit ()
            | Editor.Save_prompt ->
              (match Buffer.filename tab.buf with
               | Some _ ->
                 if Buffer.save tab.buf then
                   Display.set_status display "Saved."
                 else
                   Display.set_status display "Error saving file."
               | None ->
                 Display.set_status display "No filename.");
              needs_render := true
            | Editor.Continue ->
              needs_render := true
          end;
          if !running then drain ()
        end
      in
      drain ()
    end;
    (* Render once at the end if needed *)
    if !needs_render then begin
      render ();
      needs_render := false
    end
  done;
  Mcp_server.shutdown mcp;
  Clipboard.disable_bracketed_paste ();
  List.iter (fun (tab : Tab.t) ->
    match tab.session with Some s -> Session.quit s | None -> ()
  ) mgr.tabs;
  Display.teardown display
