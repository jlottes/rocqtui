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
  Editor.set_current_theme theme.name;
  Editor.init_compose ();
  Clipboard.enable_bracketed_paste ();
  Keys.enable_kitty ();
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
  (* Wire up open files callback for file picker *)
  Editor.set_open_files_fn (fun () ->
    List.filter_map (fun (t : Tab.t) -> Buffer.filename t.buf) mgr.tabs);
  (* File watcher *)
  let watcher = File_watch.create () in
  (* Watch all initial files *)
  List.iter (fun (t : Tab.t) ->
    match Buffer.filename t.buf with
    | Some f -> File_watch.add_watch watcher f
    | None -> ()
  ) mgr.tabs;
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
      let dnames = Tab.display_names mgr in
      let tabs = List.map (fun (t : Tab.t) ->
        let name = match List.assoc_opt t.id dnames with
          | Some n -> n | None -> "[?]"
        in
        let prefix =
          (if Buffer.modified t.buf then "*" else "") ^
          (if Buffer.disk_changed t.buf then "\xe2\x9f\xb3" (* ⟳ *) else "") in
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
  let prompt_unsaved msg confirm_key on_confirm =
    let tab = Tab.active_tab mgr in
    Display.set_status display msg;
    Display.refresh_all display;
    let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
    if List.mem stdin_fd ready then begin
      let ch2 = Curses.getch () in
      if ch2 = confirm_key then
        on_confirm ()
      else if ch2 = 19 then begin (* ^S — save *)
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
  in
  let handle_close_tab () =
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      if Buffer.modified tab.buf then
        prompt_unsaved "Unsaved changes! ^W again to close, ^S to save." 23
          (fun () ->
            ignore (Tab.close_active mgr);
            if Tab.count mgr <= 1 then
              Display.set_tab_bar display false;
            needs_render := true)
      else begin
        ignore (Tab.close_active mgr);
        if Tab.count mgr <= 1 then
          Display.set_tab_bar display false;
        needs_render := true
      end
    end else begin
      (* Last tab — same as quit *)
      if Buffer.modified tab.buf then
        prompt_unsaved "Unsaved changes! ^W again to quit, ^S to save." 23
          (fun () -> running := false)
      else
        running := false
    end
  in
  let handle_quit () =
    (* Check if any tab has unsaved changes *)
    let any_unsaved = List.exists (fun (t : Tab.t) ->
      Buffer.modified t.buf) mgr.tabs in
    if any_unsaved then
      prompt_unsaved "Unsaved changes! ^X again to quit, ^S to save." 24
        (fun () -> running := false)
    else
      running := false
  in
  (* Main loop *)
  render ();
  while !running do
    let tab = Tab.active_tab mgr in
    let timeout =
      if Session.is_busy_opt tab.session then 0.01 else 0.1
    in
    let mcp_fds = Mcp_server.server_fd mcp :: Mcp_server.client_fds mcp in
    let build_fds = match Build.watch_fd () with
      | Some fd -> [fd] | None -> [] in
    let watch_fds = [File_watch.watch_fd watcher] in
    let extra_fds = stdin_fd :: mcp_fds @ build_fds @ watch_fds in
    let ready = Main_loop.select_with_watches extra_fds timeout in
    (* Handle MCP connections/messages *)
    if Mcp_server.handle_ready mcp ready mgr then begin
      needs_render := true;
      (* MCP may have opened new tabs *)
      if Tab.count mgr > 1 then
        Display.set_tab_bar display true
    end;
    (* Poll build subprocess *)
    if Build.poll () then needs_render := true;
    (* Poll file watcher *)
    if File_watch.poll watcher then begin
      let changed = File_watch.take_changed watcher in
      List.iter (fun path ->
        List.iter (fun (t : Tab.t) ->
          match Buffer.filename t.buf with
          | Some f when f = path ->
            Buffer.set_disk_changed t.buf true;
            let vend = match t.session with
              | Some s -> Session.verified_end s | None -> 0 in
            if Buffer.modified t.buf then begin
              (* Dirty buffer — just notify, don't reload *)
              Display.set_status display
                (Printf.sprintf "%s changed on disk (buffer has unsaved changes)"
                   (Filename.basename path));
              needs_render := true
            end else if vend > 0 then begin
              (* Clean buffer but has verified region — check if change
                 is within the verified region *)
              let old_text = Buffer.text t.buf in
              let new_text = try
                let ic = open_in path in
                let s = In_channel.input_all ic in
                close_in ic; s
              with _ -> old_text in
              (* Find first differing byte *)
              let min_len = min (String.length old_text) (String.length new_text) in
              let diff_at = ref min_len in
              (try for i = 0 to min_len - 1 do
                 if old_text.[i] <> new_text.[i] then begin
                   diff_at := i; raise Exit
                 end
               done with Exit -> ());
              if !diff_at < vend then begin
                (* Change is within verified region — don't auto-reload *)
                Display.set_status display
                  (Printf.sprintf "%s changed on disk (verified region affected)"
                     (Filename.basename path));
                needs_render := true
              end else begin
                (* Change is after verified region — safe to reload *)
                Buffer.reload t.buf;
                Buffer.set_disk_changed t.buf false;
                File_watch.add_watch watcher path;
                Display.set_status display
                  (Printf.sprintf "%s reloaded" (Filename.basename path));
                needs_render := true
              end
            end else begin
              (* Clean buffer, no verified region — safe to reload *)
              Buffer.reload t.buf;
              Buffer.set_disk_changed t.buf false;
              File_watch.add_watch watcher path;
              Display.set_status display
                (Printf.sprintf "%s reloaded" (Filename.basename path));
              needs_render := true
            end
          | _ -> ()
        ) mgr.Tab.tabs
      ) changed
    end;
    (* Poll ALL sessions *)
    if Tab.poll_all mgr then begin
      needs_render := true;
      (* Send MCP notifications for state changes driven by session polling *)
      Mcp_server.poll_notifications mcp mgr
    end;
    (* Handle keyboard input *)
    if List.mem stdin_fd ready then begin
      let peek timeout =
        let ready = Main_loop.select_with_watches [stdin_fd] timeout in
        if List.mem stdin_fd ready then Curses.getch () else -1 in
      let block () =
        let rec wait () =
          let ready = Main_loop.select_with_watches [stdin_fd] 1.0 in
          if List.mem stdin_fd ready then
            let c = Curses.getch () in
            if c = -1 then wait () else c
          else wait ()
        in wait () in
      let rec drain () =
        let ev = Keys.read_key_event ~peek ~block ~getch:Curses.getch () in
        match ev with
        | None -> ()
        | Some ev when not !running -> ignore ev
        | Some ev ->
          let tab = Tab.active_tab mgr in
          if Keys.match_event ev Keys.new_tab then begin
            let active = Tab.active_tab mgr in
            Tab.add_tab mgr (Tab.create_blank ~args:active.session_args ());
            Display.set_tab_bar display true;
            needs_render := true
          end
          else if Keys.match_event ev Keys.prev_tab then begin
            Tab.prev_tab mgr;
            needs_render := true
          end
          else if Keys.match_event ev Keys.next_tab then begin
            Tab.next_tab mgr;
            needs_render := true
          end
          else begin
            match Editor.handle_key_event ev tab display with
            | Editor.Quit -> handle_quit ()
            | Editor.Close_tab -> handle_close_tab ()
            | Editor.Reload ->
              let tab = Tab.active_tab mgr in
              (match Buffer.filename tab.buf with
               | Some path ->
                 let do_reload () =
                   (* Rewind session before reload *)
                   (match tab.session with
                    | Some s -> Session.go_to_offset s 0
                    | None -> ());
                   Buffer.reload tab.buf;
                   File_watch.add_watch watcher path;
                   Display.set_status display
                     (Printf.sprintf "%s reloaded" (Filename.basename path));
                   needs_render := true
                 in
                 if Buffer.modified tab.buf then begin
                   Display.set_status display
                     "Buffer has unsaved changes! F4 again to discard and reload.";
                   Display.refresh_all display;
                   let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
                   if List.mem stdin_fd ready then begin
                     let ch2 = Curses.getch () in
                     if ch2 = Curses.Key.f 4 then
                       do_reload ()
                     else
                       needs_render := true
                   end
                 end else
                   do_reload ()
               | None ->
                 Display.set_status display "No filename.");
              needs_render := true
            | Editor.Save_prompt ->
              (match Buffer.filename tab.buf with
               | Some _ ->
                 if Buffer.disk_changed tab.buf then begin
                   (* File changed on disk — confirm overwrite *)
                   Display.set_status display
                     "File changed on disk! ^S again to overwrite, ^R to reload.";
                   Display.refresh_all display;
                   let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
                   if List.mem stdin_fd ready then begin
                     let ch2 = Curses.getch () in
                     if ch2 = 19 then begin (* ^S — force save *)
                       if Buffer.save tab.buf then
                         Display.set_status display "Saved (overwritten)."
                       else
                         Display.set_status display "Error saving file."
                     end else if ch2 = 18 then begin (* ^R — reload *)
                       Buffer.reload tab.buf;
                       File_watch.add_watch watcher
                         (match Buffer.filename tab.buf with
                          | Some f -> f | None -> "");
                       Display.set_status display "Reloaded from disk."
                     end
                     (* else: cancelled *)
                   end
                 end else begin
                   if Buffer.save tab.buf then
                     Display.set_status display "Saved."
                   else
                     Display.set_status display "Error saving file."
                 end
               | None ->
                 Display.set_status display "No filename.");
              needs_render := true
            | Editor.Jump_back jp ->
              (* Try tab ID first, fall back to filename *)
              let found = match Tab.find_by_id mgr jp.jp_tab_id with
                | Some _ ->
                  (match Tab.index_of_id mgr jp.jp_tab_id with
                   | Some idx -> mgr.active <- idx; true
                   | None -> false)
                | None -> false
              in
              if not found && jp.jp_file <> "" then begin
                (* Fall back to filename *)
                let existing = List.find_opt (fun (t : Tab.t) ->
                  Buffer.filename t.buf = Some jp.jp_file
                ) mgr.tabs in
                (match existing with
                 | Some t ->
                   (match Tab.index_of_id mgr t.id with
                    | Some idx -> mgr.active <- idx
                    | None -> ())
                 | None ->
                   let (_pd, pargs) = Project.find_args (Some jp.jp_file) in
                   let new_tab = Tab.create_from_file
                                   ~args:(pargs @ extra_args) jp.jp_file in
                   Tab.add_tab mgr new_tab;
                   Display.set_tab_bar display true)
              end;
              let active = Tab.active_tab mgr in
              Buffer.move_to active.buf jp.jp_line jp.jp_col;
              needs_render := true
            | Editor.Open_file path ->
              let jump = Editor.take_jump_target () in
              (* Check if already open *)
              let existing = List.find_opt (fun (t : Tab.t) ->
                Buffer.filename t.buf = Some path
              ) mgr.tabs in
              (match existing with
               | Some t ->
                 (match Tab.index_of_id mgr t.id with
                  | Some idx -> mgr.active <- idx
                  | None -> ())
               | None ->
                 let (_pd, pargs) = Project.find_args (Some path) in
                 let new_tab = Tab.create_from_file ~args:(pargs @ extra_args) path in
                 Tab.add_tab mgr new_tab;
                 File_watch.add_watch watcher path;
                 Display.set_tab_bar display true);
              (* Jump to position if requested *)
              (match jump with
               | Some (line, col) ->
                 let active = Tab.active_tab mgr in
                 Buffer.move_to active.buf line col
               | None -> ());
              needs_render := true
            | Editor.Continue ->
              needs_render := true
          end;
          if !running then drain ()
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
  File_watch.close watcher;
  Keys.disable_kitty ();
  Clipboard.disable_bracketed_paste ();
  List.iter (fun (tab : Tab.t) ->
    match tab.session with Some s -> Session.quit s | None -> ()
  ) mgr.tabs;
  Display.teardown display
