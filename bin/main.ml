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
  Term.init ();
  let r = Render.create () in
  Theme.apply theme;
  Rocq_protocol.set_interrupt_hook (fun t ->
    (* Read input event to check for ^C *)
    match Input.read_event ~timeout:0.0 Unix.stdin with
    | Some (Input.Key (99, m)) when m.ctrl ->  (* ctrl+c = codepoint 99 *)
      (try Unix.kill (Rocq_protocol.pid t) Sys.sigint with _ -> ())
    | Some (Input.Key (3, _)) ->  (* raw ctrl+c = 3 *)
      (try Unix.kill (Rocq_protocol.pid t) Sys.sigint with _ -> ())
    | _ -> ());
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
    Render.set_tab_bar r true;
  (* Editor context *)
  let ctx = Editor_context.create
    ~switch_tab:(fun x ->
      match Tab.tab_at_x mgr x with
      | Some i -> mgr.active <- i; Render_need.request ()
      | None -> ())
    ~open_files:(fun () ->
      List.filter_map (fun (t : Tab.t) -> Buffer.filename t.buf) mgr.tabs)
    () in
  ctx.theme_name <- theme.Theme.name;
  Editor.init_compose ctx;
  (* Start MCP server *)
  let mcp = Mcp_server.create () in
  (* Create MCP socket symlinks in project directories *)
  List.iter (Mcp_server.create_project_symlink mcp) !project_dirs;
  (* File manager *)
  let fm = File_manager.create () in
  List.iter (fun (t : Tab.t) ->
    match Buffer.filename t.buf with
    | Some f -> File_manager.add_watch fm f
    | None -> ()
  ) mgr.tabs;
  (* Render helper *)
  let render ?(force=false) () =
    (* Set MCP status indicator *)
    let active = Tab.active_tab mgr in
    (if Mcp_server.has_clients mcp && Mcp_server.is_tab_active mcp active.id then
       ctx.status_extra <- Mcp_server.spinner_char mcp ^ " Claude"
     else
       ctx.status_extra <- "");
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
          (if Buffer.disk_changed t.buf then "\xe2\x9f\xb3" (* U+27F3 *) else "") in
        let suffix = match spinner with
          | Some s when Mcp_server.is_tab_active mcp t.id -> " " ^ s
          | _ -> ""
        in
        (prefix ^ name ^ suffix, false)
      ) mgr.tabs in
      Render.draw_tab_bar r tabs mgr.active
    end;
    View.render_all ctx r tab;
    Render.present ~force r
  in
  let stdin_fd = Unix.stdin in
  let running = ref true in
  (* Blocking event read helper for prompts *)
  let is_ctrl_key ev cp =
    match ev with
    | Input.Key (c, m) when c = cp && m.ctrl -> true
    | _ -> false in
  let match_binding_input (ev : Input.event) (b : Keys.binding) =
    match ev with
    | Input.Key (cp, mods) ->
      if mods.Input.ctrl && not mods.alt then
        let ctrl_code = if cp >= 97 && cp <= 122 then cp - 96 else cp in
        List.mem ctrl_code b.Keys.codes
      else if not mods.ctrl && not mods.alt && not mods.shift then
        List.mem cp b.codes
      else false
    | Input.Special (key, _) ->
      let code = match key with
        | Input.F n -> Some (264 + n)
        | _ -> None in
      (match code with Some c -> List.mem c b.codes | None -> false)
    | _ -> false
  in
  let make_unsaved_prompt msg confirm_binding on_confirm =
    let save_and_report () =
      let tab = Tab.active_tab mgr in
      (match Buffer.filename tab.buf with
       | Some _ ->
         if Buffer.save tab.buf then
           Render.set_status r "Saved."
         else
           Render.set_status r "Error saving file."
       | None ->
         Render.set_status r "No filename.");
      Render_need.request ()
    in
    Modal.Prompt {
      message = msg;
      handler = (fun ev ->
        if match_binding_input ev confirm_binding then
          (on_confirm (); Modal.Handled)
        else if is_ctrl_key ev 115 || is_ctrl_key ev 19 then
          (save_and_report (); Modal.Handled)
        else Modal.Dismissed)
    }
  in
  let handle_close_tab () =
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      if Buffer.modified tab.buf then
        Modal.push ctx.modal
          (make_unsaved_prompt "Unsaved changes! ^W again to close, ^S to save."
             Keys.close_tab
             (fun () ->
               ignore (Tab.close_active mgr);
               if Tab.count mgr <= 1 then
                 Render.set_tab_bar r false;
               Render_need.request ()))
      else begin
        ignore (Tab.close_active mgr);
        if Tab.count mgr <= 1 then
          Render.set_tab_bar r false;
        Render_need.request ()
      end
    end else begin
      if Buffer.modified tab.buf then
        Modal.push ctx.modal
          (make_unsaved_prompt "Unsaved changes! ^W again to quit, ^S to save."
             Keys.close_tab
             (fun () -> running := false))
      else
        running := false
    end
  in
  let handle_quit () =
    let any_unsaved = List.exists (fun (t : Tab.t) ->
      Buffer.modified t.buf) mgr.tabs in
    if any_unsaved then
      Modal.push ctx.modal
        (make_unsaved_prompt "Unsaved changes! ^X again to quit, ^S to save."
           Keys.quit
           (fun () -> running := false))
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
    let watch_fds = [File_manager.watch_fd fm] in
    let extra_fds = stdin_fd :: mcp_fds @ build_fds @ watch_fds in
    let ready = Main_loop.select_with_watches extra_fds timeout in
    (* Handle MCP connections/messages *)
    if Mcp_server.handle_ready mcp ready mgr then begin
      Render_need.request ();
      if Tab.count mgr > 1 then
        Render.set_tab_bar r true
    end;
    (* Poll build subprocess *)
    if Build.poll () then Render_need.request ();
    (* Poll file manager *)
    List.iter (fun ev ->
      let msg = match ev with
        | File_manager.Reloaded p ->
          Printf.sprintf "%s reloaded" (Filename.basename p)
        | File_manager.DiskChanged p ->
          Printf.sprintf "%s changed on disk (buffer has unsaved changes)"
            (Filename.basename p)
        | File_manager.VerifiedAffected p ->
          Printf.sprintf "%s changed on disk (verified region affected)"
            (Filename.basename p)
      in
      Render.set_status r msg;
      Render_need.request ()
    ) (File_manager.poll fm mgr.Tab.tabs);
    (* Poll ALL sessions *)
    if Tab.poll_all mgr then begin
      Render_need.request ();
      Mcp_server.poll_notifications mcp mgr
    end;
    (* Handle keyboard input *)
    if List.mem stdin_fd ready then begin
      let rec drain () =
        match Input.read_event ~timeout:0.0 stdin_fd with
        | None -> ()
        | Some ev when not !running -> ignore ev
        | Some ev ->
          let tab = Tab.active_tab mgr in
          (* Resize and refresh — handled here so we can set FullRender *)
          if (match ev with Input.Resize -> true | _ -> false) then begin
            Render.resize r;
            Render_need.request_full ()
          end
          else if (match ev with
              | Input.Special (Input.F 12, _) -> true | _ -> false) then
            Render_need.request_full ()
          (* Tab management keys *)
          else if (match ev with
              | Input.Key (110, m) when m.ctrl -> true  (* ^N *)
              | Input.Key (14, _) -> true | _ -> false) then begin
            let active = Tab.active_tab mgr in
            Tab.add_tab mgr (Tab.create_blank ~args:active.session_args ());
            Render.set_tab_bar r true;
            Render_need.request ()
          end
          else if (match ev with
              | Input.Special (Input.Left, m) when m.alt -> true
              | _ -> false) then begin
            Tab.prev_tab mgr;
            Render_need.request ()
          end
          else if (match ev with
              | Input.Special (Input.Right, m) when m.alt -> true
              | _ -> false) then begin
            Tab.next_tab mgr;
            Render_need.request ()
          end
          else begin
            match Editor.handle_event ctx ev tab r with
            | Editor.Quit -> handle_quit (); Render_need.request ()
            | Editor.Close_tab -> handle_close_tab (); Render_need.request ()
            | Editor.Reload ->
              let tab = Tab.active_tab mgr in
              (match Buffer.filename tab.buf with
               | Some path ->
                 let do_reload () =
                   File_manager.reload_tab fm tab path;
                   Render.set_status r
                     (Printf.sprintf "%s reloaded" (Filename.basename path));
                   Render_need.request ()
                 in
                 if Buffer.modified tab.buf then
                   Modal.push ctx.modal (Modal.Prompt {
                     message = "Buffer has unsaved changes! F4 again to discard and reload.";
                     handler = (fun ev ->
                       match ev with
                       | Input.Special (Input.F 4, _) ->
                         do_reload (); Modal.Handled
                       | _ -> Modal.Dismissed)
                   })
                 else
                   do_reload ()
               | None ->
                 Render.set_status r "No filename.");
              Render_need.request ()
            | Editor.Save_prompt ->
              (match Buffer.filename tab.buf with
               | Some _ ->
                 if Buffer.disk_changed tab.buf then
                   Modal.push ctx.modal (Modal.Prompt {
                     message = "File changed on disk! ^S again to overwrite, ^R to reload.";
                     handler = (fun ev ->
                       if is_ctrl_key ev 115 || is_ctrl_key ev 19 then begin
                         if Buffer.save tab.buf then
                           Render.set_status r "Saved (overwritten)."
                         else
                           Render.set_status r "Error saving file.";
                         Modal.Handled
                       end else if is_ctrl_key ev 114 || is_ctrl_key ev 18 then begin
                         (match Buffer.filename tab.buf with
                          | Some f -> File_manager.reload_tab fm tab f
                          | None -> ());
                         Render.set_status r "Reloaded from disk.";
                         Modal.Handled
                       end else Modal.Dismissed)
                   })
                 else begin
                   if Buffer.save tab.buf then
                     Render.set_status r "Saved."
                   else
                     Render.set_status r "Error saving file."
                 end
               | None ->
                 Render.set_status r "No filename.");
              Render_need.request ()
            | Editor.Jump_back jp ->
              let found = Tab.switch_to_id mgr jp.jp_tab_id in
              if not found && jp.jp_file <> "" then begin
                let (_, created) = Tab.open_or_switch mgr
                  ~extra_args jp.jp_file in
                if created then begin
                  File_manager.add_watch fm jp.jp_file;
                  if Tab.count mgr > 1 then Render.set_tab_bar r true
                end
              end;
              let active = Tab.active_tab mgr in
              Buffer.move_to active.buf jp.jp_line jp.jp_col;
              Render_need.request ()
            | Editor.Open_file path ->
              let jump = Editor.take_jump_target ctx in
              let (_, created) = Tab.open_or_switch mgr
                ~extra_args path in
              if created then begin
                File_manager.add_watch fm path;
                if Tab.count mgr > 1 then Render.set_tab_bar r true
              end;
              (match jump with
               | Some (line, col) ->
                 let active = Tab.active_tab mgr in
                 Buffer.move_to active.buf line col
               | None -> ());
              Render_need.request ()
            | Editor.Continue ->
              Render_need.request ()
          end;
          if !running then drain ()
      in
      drain ()
    end;
    (* Render once at the end if needed *)
    (match Render_need.take () with
     | Render_need.No -> ()
     | Render_need.Yes -> render ()
     | Render_need.Full -> render ~force:true ())
  done;
  Mcp_server.shutdown mcp;
  File_manager.close fm;
  List.iter (fun (tab : Tab.t) ->
    match tab.session with Some s -> Session.quit s | None -> ()
  ) mgr.tabs;
  Term.teardown ()
