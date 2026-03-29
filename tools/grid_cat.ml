(* Interactive file viewer using the cell grid, Term, and Input modules.
   Scroll with arrow keys, PgUp/PgDn, Home/End. q to quit.
   Usage: grid_cat [-color] file *)

let () =
  let use_color = ref false in
  let filename = ref "" in
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | "-color" :: rest -> use_color := true; parse rest
    | [f] -> filename := f
    | [] -> ()
    | _ -> Printf.eprintf "Usage: grid_cat [-color] file\n"; exit 1
  in
  parse args;
  if !filename = "" then begin
    Printf.eprintf "Usage: grid_cat [-color] file\n"; exit 1
  end;

  (* Read file into lines *)
  let ic = open_in !filename in
  let lines = ref [] in
  (try while true do lines := input_line ic :: !lines done
   with End_of_file -> ());
  close_in ic;
  let lines = Array.of_list (List.rev !lines) in
  let num_lines = Array.length lines in

  let open Rocqtui_lib in

  Term.init ();
  let term_h = ref 0 in
  let term_w = ref 0 in
  let prev = ref (Grid.create 1 1) in
  let curr = ref (Grid.create 1 1) in
  let scroll = ref 0 in

  let do_resize () =
    let (h, w) = Term.size () in
    term_h := h; term_w := w;
    prev := Grid.create h w;
    curr := Grid.create h w;
    (* Force full redraw by clearing prev *)
    Grid.clear !prev
  in
  do_resize ();

  let starts_with s prefix =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix in

  let render () =
    let th = !term_h and tw = !term_w in
    let g = !curr and p = !prev in
    Grid.clear g;
    let content_h = th - 2 in

    (* Header *)
    let header_attr = { Grid.default_attr with reverse = true; bold = true } in
    Grid.fill g ~row:0 ~col:0 ~width:tw ' ' header_attr;
    ignore (Grid.put_str g ~row:0 ~col:0
      (Printf.sprintf " %s  [%d/%d]  %dx%d"
         (Filename.basename !filename) (!scroll + 1) num_lines tw th)
      header_attr);

    (* Content *)
    for i = 0 to content_h - 1 do
      let line_idx = !scroll + i in
      if line_idx < num_lines then begin
        let line = lines.(line_idx) in
        if !use_color then begin
          let trimmed = String.trim line in
          let attr =
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
            else
              Grid.default_attr
          in
          ignore (Grid.put_str g ~row:(i + 1) ~col:0 line attr)
        end else
          ignore (Grid.put_str g ~row:(i + 1) ~col:0 line Grid.default_attr)
      end
    done;

    (* Status bar *)
    let status_attr = { Grid.default_attr with
      fg = Grid.Color256 0; bg = Grid.Color256 250 } in
    Grid.fill g ~row:(th - 1) ~col:0 ~width:tw ' ' status_attr;
    let pct = if num_lines <= content_h then 100
              else !scroll * 100 / (max 1 (num_lines - content_h)) in
    ignore (Grid.put_str g ~row:(th - 1) ~col:0
      (Printf.sprintf " \xe2\x86\x91\xe2\x86\x93:scroll  PgUp/PgDn  q:quit  %d%%  %d lines" pct num_lines)
      status_attr);

    (* Diff and output *)
    let buf = Stdlib.Buffer.create 4096 in
    Grid.diff ~prev:p ~curr:g buf;
    Stdlib.Buffer.add_string buf "\x1b[0m";
    Term.write_stdout (Stdlib.Buffer.contents buf);

    Grid.copy ~src:g ~dst:p
  in

  render ();

  let max_scroll () = max 0 (num_lines - (!term_h - 2)) in
  let running = ref true in
  while !running do
    match Input.read_event ~timeout:1.0 Unix.stdin with
    | None -> ()
    | Some ev ->
      (match ev with
       | Input.Key (113, m) when not m.ctrl && not m.alt ->  (* 'q' *)
         running := false
       | Input.Resize ->
         do_resize ();
         Term.clear_screen ();
         scroll := min !scroll (max_scroll ());
         render ()
       | Input.Special (Input.Up, _) ->
         if !scroll > 0 then (decr scroll; render ())
       | Input.Special (Input.Down, _) ->
         if !scroll < max_scroll () then (incr scroll; render ())
       | Input.Special (Input.PageUp, _) ->
         scroll := max 0 (!scroll - (!term_h - 2));
         render ()
       | Input.Special (Input.PageDown, _) ->
         scroll := min (max_scroll ()) (!scroll + (!term_h - 2));
         render ()
       | Input.Special (Input.Home, _) ->
         scroll := 0; render ()
       | Input.Special (Input.End, _) ->
         scroll := max_scroll (); render ()
       | Input.Mouse mev ->
         (match mev.button with
          | Input.ScrollUp ->
            if !scroll > 0 then begin
              scroll := max 0 (!scroll - 3);
              render ()
            end
          | Input.ScrollDown ->
            if !scroll < max_scroll () then begin
              scroll := min (max_scroll ()) (!scroll + 3);
              render ()
            end
          | _ -> ())
       | _ -> ())
  done;

  Term.teardown ()
