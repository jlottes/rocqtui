open Rocqtui_lib

let () =
  (* Parse command line: rocqtui [-theme NAME] [file.v] [-- rocq-args...] *)
  let filename = ref None in
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
      (* Next arg is the theme name *)
      if i + 1 < Array.length Sys.argv then begin
        theme_name := Some Sys.argv.(i + 1);
        skip_next := true
      end
    end
    else if !filename = None then
      filename := Some arg
    else
      extra_args := arg :: !extra_args
  ) Sys.argv;
  let filename = !filename in
  let extra_args = List.rev !extra_args in
  let theme = match !theme_name with
    | Some n -> Theme.find n
    | None -> Theme.default
  in
  let buf = match filename with
    | Some f when Sys.file_exists f -> Buffer.load_file f
    | Some f ->
      let b = Buffer.create () in
      Buffer.set_filename b f;
      b
    | None -> Buffer.create ()
  in
  (* Ignore signals that conflict with keybindings *)
  Sys.set_signal Sys.sigint Sys.Signal_ignore;   (* ^C — we forward to rocqtop *)
  Sys.set_signal Sys.sigtstp Sys.Signal_ignore;  (* ^Z — we use for undo *)
  let display = Display.init () in
  Theme.apply theme;
  Editor.init_compose ();
  Clipboard.enable_bracketed_paste ();
  (* Allow ^C to interrupt blocking Rocq calls *)
  Rocq_protocol.set_interrupt_hook (fun t ->
    let ch = Curses.getch () in
    if ch = 3 then
      (try Unix.kill (Rocq_protocol.pid t) Sys.sigint with _ -> ()));
  (* Find project file args and start Rocq session *)
  let (_project_dir, project_args) = Project.find_args filename in
  let all_args = project_args @ extra_args in
  Printexc.record_backtrace true;
  let session =
    try Some (Session.create ~args:all_args buf)
    with exn ->
      let bt = Printexc.get_backtrace () in
      let msg = Printf.sprintf "Failed to start Rocq: %s\n%s\nArgs: %s"
        (Printexc.to_string exn) bt
        (String.concat " " all_args) in
      Editor.set_init_error msg;
      None
  in
  (* Initial render *)
  Editor.handle_key (-1) buf display session |> ignore;
  (* Non-blocking getch — we drive input via select *)
  Curses.timeout 0;
  let stdin_fd = Unix.stdin in
  (* Main loop: select on stdin + rocqtop fd, dispatch both *)
  let running = ref true in
  let needs_render = ref false in
  let handle_quit () =
    if Buffer.modified buf then begin
      Display.set_status display "Unsaved changes! ^X again to quit, ^O to save.";
      Display.refresh_all display;
      (* Block for user response *)
      let ready = Main_loop.select_with_watches [stdin_fd] (-1.0) in
      if List.mem stdin_fd ready then begin
        let ch2 = Curses.getch () in
        if ch2 = 24 (* ^X *) then
          running := false
        else if ch2 = 15 (* ^O *) then begin
          (match Buffer.filename buf with
           | Some _ ->
             if Buffer.save buf then
               Display.set_status display "Saved."
             else
               Display.set_status display "Error saving file."
           | None ->
             Display.set_status display "No filename. Use: rocqtui <file>");
          Display.refresh_all display
        end else begin
          Display.set_status display "";
          Editor.handle_key ch2 buf display session |> ignore
        end
      end
    end else
      running := false
  in
  while !running do
    let timeout = if (match session with
      | Some s -> Session.is_busy s | None -> false)
      then 0.01 else 0.1
    in
    let ready = Main_loop.select_with_watches [stdin_fd] timeout in
    (match session with
     | Some s ->
       if Session.poll s then needs_render := true
     | None -> ());
    (* Handle keyboard input *)
    if List.mem stdin_fd ready then begin
      let rec drain () =
        let ch = Curses.getch () in
        if ch <> -1 then begin
          match Editor.handle_key ch buf display session with
          | Editor.Quit -> handle_quit ()
          | Editor.Save_prompt ->
            (match Buffer.filename buf with
             | Some _ ->
               if Buffer.save buf then
                 Display.set_status display "Saved."
               else
                 Display.set_status display "Error saving file."
             | None ->
               Display.set_status display "No filename. Use: rocqtui <file>");
            Display.refresh_all display
          | Editor.Continue -> ();
          (* Drain any remaining buffered keys *)
          if !running then drain ()
        end
      in
      drain ();
      needs_render := false  (* handle_key already rendered *)
    end;
    (* Re-render if async state changed *)
    if !needs_render then begin
      Editor.handle_key (-1) buf display session |> ignore;
      needs_render := false
    end
  done;
  Clipboard.disable_bracketed_paste ();
  (match session with Some s -> Session.quit s | None -> ());
  Display.teardown display
