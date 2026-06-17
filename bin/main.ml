open Rocqtui_lib

(* Positional CLI arg, classified as either an existing directory or
   anything else (treated as a file path even if it doesn't exist). *)
type positional = Dir of string | File of string

let classify_positional arg =
  try if Sys.is_directory arg then Dir arg else File arg
  with Sys_error _ -> File arg

let to_abs p =
  if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p

(* Outcome of init-time project resolution. [Found] means a
   _RocqProject was located. [Missing dir] means none was found and
   the startup prompt should offer to create one at [dir]. *)
type init_project = Found of Project.t | Missing of string

let resolve_initial_project ~dir_arg ~file_args =
  match dir_arg with
  | Some d ->
    let d_abs = to_abs d in
    (match Project.find d_abs with
     | Some p -> Found p
     | None -> Missing d_abs)
  | None ->
    let from = match file_args with
      | [] -> Project.find_for ()
      | f :: _ -> Project.find_for ~filename:f ()
    in
    (match from with
     | Some p -> Found p
     | None ->
       let dir = match file_args with
         | [] -> Sys.getcwd ()
         | f :: _ -> Filename.dirname (to_abs f)
       in
       Missing dir)

let build_initial_state ~file_args ~project ~extra_args =
  let project_args = match project with
    | Some (p : Project.t) -> p.args
    | None -> []
  in
  let all_args = project_args @ extra_args in
  let initial_tabs = match file_args with
    | [] -> [Tab.create_blank ~args:all_args ()]
    | files -> List.map (Tab.create_from_file ~args:all_args) files
  in
  let mgr = Tab.create_manager (List.hd initial_tabs) in
  List.iter (fun tab ->
    if tab != List.hd initial_tabs then Tab.add_tab mgr tab
  ) initial_tabs;
  mgr

(* Headless loop: no terminal, no rendering, no stdin input. Just runs
   the MCP server and drives Rocq sessions so that an external client
   (typically the rocqtui_mcp bridge) can exercise the API end-to-end. *)
let run_headless ~file_args ~extra_args ~socket_path =
  Printexc.record_backtrace true;
  let project = match resolve_initial_project ~dir_arg:None ~file_args with
    | Found p -> Some p
    | Missing _ -> None
  in
  let mgr = build_initial_state ~file_args ~project ~extra_args in
  let mcp = Mcp_server.create ?socket_path () in
  (match project with
   | Some p -> Mcp_server.create_project_symlink mcp p.project_dir
   | None -> ());
  let fm = File_manager.create () in
  List.iter (fun (t : Tab.t) ->
    match Buffer.filename t.buf with
    | Some f -> File_manager.add_watch fm f
    | None -> ()
  ) mgr.tabs;
  let running = ref true in
  let stop _ = running := false in
  Sys.set_signal Sys.sigint  (Sys.Signal_handle stop);
  Sys.set_signal Sys.sigterm (Sys.Signal_handle stop);
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Printf.printf "rocqtui headless: socket=%s pid=%d\n%!"
    (Mcp_server.socket_path mcp) (Unix.getpid ());
  while !running do
    let tab = Tab.active_tab mgr in
    let timeout =
      if Session.is_busy_opt tab.session then 0.01 else 0.1
    in
    let mcp_fds = Mcp_server.server_fd mcp :: Mcp_server.client_fds mcp in
    let watch_fds = [File_manager.watch_fd fm] in
    let extra_fds = mcp_fds @ watch_fds in
    let ready =
      try Main_loop.select_with_watches extra_fds timeout
      with Unix.Unix_error (Unix.EINTR, _, _) -> []
    in
    ignore (Mcp_server.handle_ready mcp ready mgr);
    ignore (File_manager.poll fm mgr.Tab.tabs);
    if Tab.poll_all mgr then
      Mcp_server.poll_notifications mcp mgr
  done;
  Mcp_server.shutdown mcp;
  File_manager.close fm;
  List.iter (fun (tab : Tab.t) ->
    match tab.session with Some s -> Session.quit s | None -> ()
  ) mgr.tabs

let () =
  (* Parse command line: rocqtui [-theme NAME] [--headless] [--socket-path P]
     [file1.v file2.v ...] [-- rocq-args...] *)
  let filenames = ref [] in
  let extra_args = ref [] in
  let theme_name = ref None in
  let xcompose = ref false in
  let headless = ref false in
  let socket_path = ref None in
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
    else if arg = "-xcompose" || arg = "--xcompose" then
      xcompose := true
    else if arg = "--headless" then
      headless := true
    else if arg = "--socket-path" then begin
      if i + 1 < Array.length Sys.argv then begin
        socket_path := Some Sys.argv.(i + 1);
        skip_next := true
      end
    end
    else
      filenames := arg :: !filenames
  ) Sys.argv;
  let positionals = List.rev !filenames in
  let extra_args = List.rev !extra_args in
  (* Split positionals into at most one directory and the rest as
     file paths. The dir arg is the new "open this project" entry
     point (`rocqtui ~/path/to/project`). *)
  let dir_arg = ref None in
  let file_args = ref [] in
  List.iter (fun arg ->
    match classify_positional arg with
    | Dir d ->
      (match !dir_arg with
       | None -> dir_arg := Some d
       | Some _ ->
         Printf.eprintf "rocqtui: only one directory argument allowed\n%!";
         exit 2)
    | File f -> file_args := f :: !file_args
  ) positionals;
  let dir_arg = !dir_arg in
  let file_args = List.rev !file_args in
  if !headless then
    run_headless ~file_args ~extra_args ~socket_path:!socket_path
  else
  let theme = match !theme_name with
    | Some n -> Theme.find n
    | None -> Theme.default
  in
  Sys.set_signal Sys.sigint Sys.Signal_ignore;
  Sys.set_signal Sys.sigtstp Sys.Signal_ignore;
  (* Writes to a dead child (crashed rocqtop, exited terminal PTY, build
     pipe) must surface as EPIPE, not kill the process with the terminal
     still in the alternate screen. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Term.init ();
  (* Restore the terminal on every exit path. [Term.teardown] is
     idempotent; at_exit covers plain [exit], and the uncaught-exception
     handler tears down *before* printing so the error lands on the main
     screen instead of vanishing with the alternate one. *)
  at_exit Term.teardown;
  Printexc.set_uncaught_exception_handler (fun e bt ->
    Term.teardown ();
    Printf.eprintf "Fatal error: exception %s\n%s%!"
      (Printexc.to_string e) (Printexc.raw_backtrace_to_string bt));
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
  (* Msg_pane no longer auto-creates the Rocq sub-tab on module load;
     rocqtui ensures it here so the bordered tab strip always has a
     Rocq entry. tterm doesn't make this call — it lives entirely on
     Terminal sub-tabs. *)
  ignore (Msg_pane.ensure Msg_pane.Rocq);
  let init_proj = resolve_initial_project ~dir_arg ~file_args in
  let initial_project = match init_proj with
    | Found p -> Some p
    | Missing _ -> None
  in
  let mgr = build_initial_state
    ~file_args ~project:initial_project ~extra_args in
  if Tab.count mgr > 1 then
    Render.set_tab_bar r true;
  (* Editor context *)
  let fm = File_manager.create () in
  let dr = Dep_runner.create () in
  (* Forward ref: ctx is constructed below but the side-effect
     callback we plumb into it needs to read [ctx.project]. *)
  let ctx_ref : Editor_context.t option ref = ref None in
  let project_dir () = match !ctx_ref with
    | Some ctx ->
      (match ctx.Editor_context.project with
       | Some p -> Some p.Project.project_dir
       | None -> None)
    | None -> None
  in
  let refresh_dep_runner_for_dir dir =
    match Project.find dir with
    | Some p -> Dep_runner.refresh dr ~project_file:p.path
    | None -> ()
  in
  let refresh_build_status () =
    match project_dir (), Dep_runner.graph dr with
    | Some pd, Some g ->
      let error_files = Build_errors.error_files ~project_dir:pd in
      Build_status.refresh ~project_dir:pd ~graph:g ~error_files
    | _ -> ()
  in
  (* Saves bump the .v mtime — flip the tree marker to Stale right
     away rather than waiting for the next build to surface it. *)
  Buffer.on_save (fun _ ->
    refresh_build_status ();
    Render_need.request ());
  let ctx = Editor_context.create
    ~switch_tab:(fun x ->
      match Tab.tab_at_x mgr x with
      | Some i -> mgr.active <- i; Render_need.request ()
      | None -> ())
    ~switch_to_tab_id:(fun id ->
      if Tab.switch_to_id mgr id then Render_need.request ())
    ~open_files:(fun () ->
      List.filter_map (fun (t : Tab.t) ->
        match Buffer.filename t.buf with
        | None -> None
        | Some path ->
          Some (path, File_tree.{
            modified = Buffer.modified t.buf;
            disk_changed = Buffer.disk_changed t.buf;
          })
      ) mgr.tabs)
    ~tabs:(fun () -> mgr.tabs)
    ~set_project_dir:(fun dir ->
      Build_errors.clear ();
      File_manager.set_project_dir fm dir;
      refresh_dep_runner_for_dir dir)
    ~add_file_watch:(fun p -> File_manager.add_watch fm p)
    ~dep_state:(fun () -> (Dep_runner.graph dr, Dep_runner.running dr))
    ~refresh_build_status
    () in
  ctx_ref := Some ctx;
  Editor_context.set_project ctx initial_project;
  ctx.theme_name <- theme.Theme.name;
  if !xcompose then begin
    Editor.init_compose ctx;
    (* Pick up edits to ~/.XCompose immediately — no restart needed. *)
    let xc_path =
      let home = try Sys.getenv "HOME" with Not_found -> "." in
      Filename.concat home ".XCompose" in
    File_manager.register_file_callback fm
      ~path:xc_path
      ~on_change:(fun () ->
        ctx.compose <- Some (Compose.load ());
        Render_need.request ())
  end;
  (* Wire terminal clipboard hook to editor context *)
  Terminal.set_clipboard_hook (fun text ->
    ctx.clipboard <- text;
    Clipboard.copy_to_system text);
  (* Start MCP server *)
  let mcp = Mcp_server.create () in
  (* Create MCP socket symlink in the project directory (if any).
     Editor_context.set_project already wired up File_manager and
     the dep runner via ctx.set_project_dir. *)
  (match initial_project with
   | Some p -> Mcp_server.create_project_symlink mcp p.project_dir
   | None -> ());
  (* File manager: per-tab content watches. *)
  List.iter (fun (t : Tab.t) ->
    match Buffer.filename t.buf with
    | Some f -> File_manager.add_watch fm f
    | None -> ()
  ) mgr.tabs;
  let open_file_tree_for (p : Project.t) =
    ctx.file_tree <- Some (File_tree.create
      ~project_dir:p.project_dir ~project_file:p.path);
    Render.set_file_tree_visible r true;
    ctx.focus <- Editor_context.FFileTree
  in
  (* `rocqtui <dir>` with no file args: open the file tree so the
     directory arg is a natural "open this project" entry point. *)
  if dir_arg <> None && file_args = [] then
    (match initial_project with
     | Some p -> open_file_tree_for p
     | None -> ());
  (* Missing-_RocqProject startup prompt. Sits on top of whatever
     initial layout the positional args produced. Confirm creates an
     empty _RocqProject at [dir] and adopts it as the session
     project; ESC dismisses without creating one (project-dependent
     features remain unavailable for this session). *)
  (match init_proj with
   | Found _ -> ()
   | Missing dir ->
     let project_file = Filename.concat dir "_RocqProject" in
     let msg = Printf.sprintf
       "No _RocqProject found in %s. Create one? Enter to create, ESC to skip."
       dir in
     let needs_tree = dir_arg <> None && file_args = [] in
     Modal.push ctx.modal (Modal.Prompt {
       message = msg;
       handler = (fun ev ->
         match ev with
         | Input.Special (Input.Enter, _) ->
           (try
              let oc = open_out project_file in
              close_out oc;
              let p = Project.read project_file in
              Editor_context.set_project ctx (Some p);
              Mcp_server.create_project_symlink mcp p.project_dir;
              if needs_tree then open_file_tree_for p;
              Render.set_status r
                (Printf.sprintf "Created %s" project_file)
            with Sys_error e ->
              Render.set_status r
                (Printf.sprintf "Create _RocqProject: %s" e));
           Modal.Handled
         | _ -> Modal.Dismissed)
     }));
  (* Render helper *)
  let render ?(force=false) () =
    (* Set MCP status indicator. While a client is connected we always
       reserve the same width ("<glyph> Claude") so the status bar
       doesn't flicker as activity toggles — the glyph animates when
       active and is a static dot when idle. *)
    let active = Tab.active_tab mgr in
    let mcp_indicator =
      if Mcp_server.has_clients mcp then
        let glyph =
          if Mcp_server.is_tab_active mcp active.id then
            Mcp_server.spinner_char mcp
          else "\xc2\xb7"  (* U+00B7 middle dot *)
        in
        glyph ^ " Claude"
      else ""
    in
    let build_indicator = Build.status_indicator () in
    ctx.status_extra <-
      (match mcp_indicator, build_indicator with
       | "", "" -> ""
       | a, "" | "", a -> a
       | a, b -> a ^ "  " ^ b);
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      let dnames = Tab.display_names mgr in
      let tabs = List.map (fun (t : Tab.t) ->
        let name = match List.assoc_opt t.id dnames with
          | Some n -> n | None -> "[?]"
        in
        let prefix =
          (if Buffer.modified t.buf then "*" else "") ^
          (if Buffer.disk_changed t.buf then "\xe2\x9f\xb3" (* U+27F3 *) else "") in
        (prefix ^ name, false)
      ) mgr.tabs in
      Render.draw_tab_bar r tabs mgr.active
    end;
    View.render_all ctx r tab;
    Render.present ~force r
  in
  let project_args () = match ctx.project with
    | Some p -> p.Project.args
    | None -> []
  in
  let do_open_file path =
    let jump = Editor.take_jump_target ctx in
    let (_, created) = Tab.open_or_switch mgr
      ~project_args:(project_args ()) ~extra_args path in
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
  in
  let stdin_fd = Unix.stdin in
  let running = ref true in
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
  let make_unsaved_prompt verb confirm_binding on_confirm =
    let msg = Printf.sprintf "Unsaved changes! %s again to %s, %s to save."
      confirm_binding.Keys.display verb Keys.save.Keys.display in
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
        else if match_binding_input ev Keys.save then
          (save_and_report (); Modal.Handled)
        else Modal.Dismissed)
    }
  in
  let handle_close_tab () =
    let tab = Tab.active_tab mgr in
    if Tab.count mgr > 1 then begin
      if Buffer.modified tab.buf then
        Modal.push ctx.modal
          (make_unsaved_prompt "close"
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
          (make_unsaved_prompt "quit"
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
        (make_unsaved_prompt "quit"
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
    let dep_fds = match Dep_runner.watch_fd dr with
      | Some fd -> [fd] | None -> [] in
    let term_fds = Terminal.fds () in
    let extra_fds = stdin_fd :: mcp_fds @ build_fds @ watch_fds
      @ dep_fds @ List.map fst term_fds in
    let ready = Main_loop.select_with_watches extra_fds timeout in
    (* Poll terminals *)
    List.iter (fun (fd, term) ->
      if List.mem fd ready then begin
        if Terminal.poll term then
          Render_need.request ()
      end
    ) term_fds;
    (* Flush terminal write buffers *)
    List.iter (fun (_, term) ->
      let pty = Terminal.pty term in
      if Vterm_lib.Pty.has_buffered pty then
        Vterm_lib.Pty.flush_write pty
    ) term_fds;
    (* Handle MCP connections/messages *)
    if Mcp_server.handle_ready mcp ready mgr then begin
      Render_need.request ();
      if Tab.count mgr > 1 then
        Render.set_tab_bar r true
    end;
    (* Poll build subprocess *)
    let was_building = Build.is_running () in
    if Build.poll () then Render_need.request ();
    if was_building && not (Build.is_running ()) then begin
      (* Build just finished — refresh parsed errors so the file-tree
         marker reflects the new state, sweep slots whose .vo advanced
         (the file got rebuilt clean), then recompute per-file
         build_status. *)
      (match project_dir () with
       | Some pd -> Build_errors.refresh ~project_dir:pd (Build.output ())
       | None -> ());
      ignore (Build_errors.recheck_vo ());
      refresh_build_status ()
    end;
    (* Keep redrawing while the build spinner / result indicator is live. *)
    if Build.needs_repaint () then Render_need.request ();
    (* Poll the dep runner; a fresh graph triggers a re-render so the
       panel header transitions from "computing…" to the new state. *)
    if Dep_runner.poll dr then begin
      refresh_build_status ();
      Render_need.request ()
    end;
    (* Step the project-wide search scanner. Cheap when idle. *)
    if Project_search.step ctx.project_search then Render_need.request ();
    (* Poll file manager *)
    List.iter (fun ev ->
      match ev with
      | File_manager.ProjectChanged ->
        (* Refresh File_tree so newly created / deleted files appear
           immediately. Cheap when the panel is hidden — refresh just
           re-enumerates from disk, no rendering. *)
        (match ctx.Editor_context.file_tree with
         | Some ft -> File_tree.refresh ft
         | None -> ());
        Render_need.request ()
      | File_manager.SourcesChanged ->
        (* A .v or the project file changed in a way that could shift
           Require / search-path edges. Rerun rocq dep — its kill-and-
           restart semantics self-throttle bursty events like git
           checkouts. *)
        Dep_runner.refresh_last dr;
        Render_need.request ()
      | File_manager.BuildArtifactChanged ->
        (* A .vo (or external .v save) landed inside the project.
           Refresh per-file build status so the file-tree marker
           updates incrementally during long builds, and also catches
           external [make]/[dune]/[rocqc] invocations. Sweep .vo
           mtimes so a file that finished cleanly drops its prior
           errors even though the current build's output never
           mentioned it. *)
        (match project_dir () with
         | Some pd -> Build_errors.refresh ~project_dir:pd (Build.output ())
         | None -> ());
        ignore (Build_errors.recheck_vo ());
        refresh_build_status ();
        Render_need.request ()
      | _ ->
        let msg = match ev with
          | File_manager.Reloaded p ->
            Printf.sprintf "%s reloaded" (Filename.basename p)
          | File_manager.DiskChanged p ->
            Printf.sprintf "%s changed on disk (buffer has unsaved changes)"
              (Filename.basename p)
          | File_manager.VerifiedAffected p ->
            Printf.sprintf "%s changed on disk (verified region affected)"
              (Filename.basename p)
          | File_manager.ProjectChanged
          | File_manager.SourcesChanged
          | File_manager.BuildArtifactChanged -> ""  (* handled above *)
        in
        Render.set_status r msg;
        Render_need.request ()
    ) (File_manager.poll fm mgr.Tab.tabs);
    (* Poll ALL sessions *)
    if Tab.poll_all mgr then begin
      Render_need.request ();
      Mcp_server.poll_notifications mcp mgr
    end;
    (* Drain any deferred Open_file action queued by an async on_done
       callback (e.g. jump-to-definition's Locate/Locate-Library chain). *)
    (match Editor.take_pending_open ctx with
     | Some path -> do_open_file path
     | None -> ());
    (* User step settled? Activate Rocq sub-tab on error (unless on
       Terminal). Run every frame regardless of poll_all return so we
       catch the transition even when other state didn't change. *)
    (match (Tab.active_tab mgr).session with
     | Some s ->
       (match Session.consume_user_step_result s with
        | Some `Error ->
          Msg_pane.activate_unless_terminal Msg_pane.Rocq
        | Some `Ok | None -> ())
     | None -> ());
    (* Check for terminal resize (SIGWINCH may have fired during select).
       Embedded terminals get resized on next render. *)
    if Term.check_resize () then begin
      Render.resize r;
      Render_need.request_full ()
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
            let args = project_args () @ extra_args in
            Tab.add_tab mgr (Tab.create_blank ~args ());
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
                   ignore (File_manager.reload_tab fm tab path);
                   Render.set_status r
                     (Printf.sprintf "%s reloaded" (Filename.basename path));
                   Render_need.request ()
                 in
                 if Buffer.modified tab.buf then
                   Modal.push ctx.modal (Modal.Prompt {
                     message = Printf.sprintf
                       "Buffer has unsaved changes! %s again to discard and reload."
                       Keys.reload.Keys.display;
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
                     message = Printf.sprintf
                       "File changed on disk! %s again to overwrite, %s to reload."
                       Keys.save.Keys.display Keys.reload.Keys.display;
                     handler = (fun ev ->
                       if match_binding_input ev Keys.save then begin
                         if Buffer.save tab.buf then
                           Render.set_status r "Saved (overwritten)."
                         else
                           Render.set_status r "Error saving file.";
                         Modal.Handled
                       end else if match_binding_input ev Keys.reload then begin
                         (match Buffer.filename tab.buf with
                          | Some f -> ignore (File_manager.reload_tab fm tab f)
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
                 (* New / unfiled tab: open the Save As prompt.
                    Anchored at the session project (read at commit
                    time). When no project is set, the commit
                    handler falls back to cwd. *)
                 Modal.push ctx.modal (Modal.SaveAsPrompt {
                   tab_id = tab.id;
                   extension = ".v";
                   field = Text_field.create ();
                 }));
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
            | Editor.Open_file path -> do_open_file path
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
  (* Best-effort shutdown: a dead child (e.g. crashed rocqtop raising
     EPIPE from Session.quit) must not abort the rest, and above all
     must not skip the terminal teardown. *)
  let safely f = try f () with _ -> () in
  safely (fun () -> Mcp_server.shutdown mcp);
  safely (fun () -> File_manager.close fm);
  safely (fun () -> Dep_runner.close dr);
  List.iter (fun (tab : Tab.t) ->
    match tab.session with
    | Some s -> safely (fun () -> Session.quit s)
    | None -> ()
  ) mgr.tabs;
  Term.teardown ()
