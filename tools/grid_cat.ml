(* Interactive file viewer using Render + Grid + Term + Input.
   Demonstrates the full ncurses-free rendering stack.
   Usage: grid_cat [-color] file *)

let () =
  let use_color = ref false in
  let debug = ref false in
  let filename = ref "" in
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | "-color" :: rest -> use_color := true; parse rest
    | "-debug" :: rest -> debug := true; parse rest
    | [f] -> filename := f
    | [] -> ()
    | _ -> Printf.eprintf "Usage: grid_cat [-color] [-debug] file\n"; exit 1
  in
  parse args;
  if !filename = "" then begin
    Printf.eprintf "Usage: grid_cat [-color] file\n"; exit 1
  end;

  let ic = open_in !filename in
  let lines = ref [] in
  (try while true do lines := input_line ic :: !lines done
   with End_of_file -> ());
  close_in ic;
  let lines = Array.of_list (List.rev !lines) in
  let num_lines = Array.length lines in

  let open Rocqtui_lib in

  Term.init ();
  let r = Render.create () in
  let scroll = ref 0 in

  let starts_with s prefix =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix in

  let last_event = ref "" in
  let last_raw = ref "" in
  let log_oc = if !debug then Some (open_out "/tmp/grid_cat_debug.log") else None in
  let log msg = match log_oc with
    | Some oc -> output_string oc (msg ^ "\n"); Stdlib.flush oc
    | None -> () in

  if !debug then Input.set_debug_log log;

  let render () =
    let g = Render.curr r in
    Grid.clear g;
    let (th, tw) = Term.size () in

    (* Header *)
    let header_attr = { Grid.default_attr with reverse = true; bold = true } in
    Grid.fill g ~row:0 ~col:0 ~width:tw ' ' header_attr;
    ignore (Grid.put_str g ~row:0 ~col:0
      (Printf.sprintf " %s  [%d/%d]  %dx%d"
         (Filename.basename !filename) (!scroll + 1) num_lines tw th)
      header_attr);

    let content_h = th - 2 in

    (* Content *)
    for i = 0 to content_h - 1 do
      let line_idx = !scroll + i in
      if line_idx < num_lines then begin
        let line = lines.(line_idx) in
        let attr = if !use_color then begin
          let trimmed = String.trim line in
          if String.length trimmed = 0 then Grid.default_attr
          else if starts_with trimmed "(*" then
            { Grid.default_attr with fg = Grid.Color256 65 }
          else if starts_with trimmed "Require" || starts_with trimmed "From"
               || starts_with trimmed "Import" || starts_with trimmed "Export" then
            { Grid.default_attr with fg = Grid.Color256 33; bold = true }
          else if starts_with trimmed "Lemma" || starts_with trimmed "Theorem"
               || starts_with trimmed "Definition" || starts_with trimmed "Fixpoint"
               || starts_with trimmed "Inductive" || starts_with trimmed "Section"
               || starts_with trimmed "End" || starts_with trimmed "Class"
               || starts_with trimmed "Instance" || starts_with trimmed "Context" then
            { Grid.default_attr with fg = Grid.Color256 33; bold = true }
          else if starts_with trimmed "Proof" || starts_with trimmed "Qed"
               || starts_with trimmed "Admitted" || starts_with trimmed "Defined" then
            { Grid.default_attr with fg = Grid.Color256 136 }
          else if String.length trimmed >= 1
               && (trimmed.[0] = '-' || trimmed.[0] = '+' || trimmed.[0] = '*'
                   || trimmed.[0] = '{' || trimmed.[0] = '}') then
            { Grid.default_attr with fg = Grid.Color256 160; bold = true }
          else if String.length trimmed >= 2
               && (let c = trimmed.[0] in c >= 'a' && c <= 'z')
               && String.contains trimmed '.' then
            { Grid.default_attr with fg = Grid.Color256 37 }
          else Grid.default_attr
        end else Grid.default_attr in
        ignore (Grid.put_str g ~row:(i + 1) ~col:0 line attr)
      end
    done;

    (* Status bar *)
    let status_attr = { Grid.default_attr with
      fg = Grid.Color256 0; bg = Grid.Color256 250 } in
    Grid.fill g ~row:(th - 1) ~col:0 ~width:tw ' ' status_attr;
    let max_s = max 1 (num_lines - content_h) in
    let pct = if num_lines <= content_h then 100
              else !scroll * 100 / max_s in
    let debug_info = if !debug && !last_event <> "" then
      "  | " ^ !last_event else "" in
    ignore (Grid.put_str g ~row:(th - 1) ~col:0
      (Printf.sprintf " \xe2\x86\x91\xe2\x86\x93:scroll  q:quit  %d%%  %d lines%s" pct num_lines debug_info)
      status_attr);

    Render.present r
  in

  render ();

  let running = ref true in
  let parser = Input.create () in
  while !running do
    match Input.read_event ~timeout:1.0 parser Unix.stdin with
    | None -> ()
    | Some ev ->
      let ev_str = Input.show_event ev in
      last_event := ev_str;
      log (Printf.sprintf "event: %s" ev_str);
      let (th, _) = Term.size () in
      let content_h = th - 2 in
      let max_scroll = max 0 (num_lines - content_h) in
      (match ev with
       | Input.Key (113, m) when not m.ctrl && not m.alt -> running := false
       | Input.Special (Input.Escape, _) -> running := false
       | Input.Resize ->
         Render.resize r;
         Term.clear_screen ();
         scroll := min !scroll max_scroll;
         render ()
       | Input.Special (Input.Up, _) ->
         if !scroll > 0 then (decr scroll; render ())
       | Input.Special (Input.Down, _) ->
         if !scroll < max_scroll then (incr scroll; render ())
       | Input.Special (Input.PageUp, _) ->
         scroll := max 0 (!scroll - content_h); render ()
       | Input.Special (Input.PageDown, _) ->
         scroll := min max_scroll (!scroll + content_h); render ()
       | Input.Special (Input.Home, _) ->
         scroll := 0; render ()
       | Input.Special (Input.End, _) ->
         scroll := max_scroll; render ()
       | Input.Mouse mev ->
         (match mev.button with
          | Input.ScrollUp ->
            scroll := max 0 (!scroll - 3); render ()
          | Input.ScrollDown ->
            scroll := min max_scroll (!scroll + 3); render ()
          | _ -> ())
       | _ -> ())
  done;

  (match log_oc with Some oc -> close_out oc | None -> ());
  ignore last_raw;
  Term.teardown ()
