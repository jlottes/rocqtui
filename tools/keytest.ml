(* keytest: walk through every rocqtui keybinding and verify the terminal
   delivers the expected event.  Useful for diagnosing terminals (iTerm2,
   etc.) where some sequences go missing or arrive misencoded.

   Terminal setup matches lib/term.ml so the parse path is identical to
   what rocqtui sees at runtime: raw mode + Kitty keyboard protocol
   level 1.  Events are parsed by Input.read_event; binding match is
   inlined below (the editor's Keymatch module is not exposed in the
   library's public signature — keep this in sync with
   lib/editor/keymatch.ml). *)

open Rocqtui_lib

(* Inlined from lib/editor/keymatch.ml — Editor.Keymatch is not part of
   the public library signature.  Keep in sync. *)
let match_binding (ev : Input.event) (b : Keys.binding) =
  match ev with
  | Input.Key (cp, mods) ->
    let kitty_match () =
      let modifier = 1
        + (if mods.shift then 1 else 0)
        + (if mods.alt then 2 else 0)
        + (if mods.ctrl then 4 else 0) in
      List.exists (fun (kc, m) -> kc = cp && m = modifier) b.Keys.kitty_codes
    in
    if mods.ctrl && not mods.alt && not mods.shift then begin
      let ctrl_code =
        if cp >= 97 && cp <= 122 then cp - 96
        else if cp >= 65 && cp <= 90 then cp - 64
        else -1 in
      if ctrl_code > 0 then List.mem ctrl_code b.Keys.codes || kitty_match ()
      else List.mem cp b.Keys.codes || kitty_match ()
    end
    else if not mods.ctrl && not mods.alt && not mods.shift then
      List.mem cp b.Keys.codes
    else kitty_match ()
  | Input.Special (key, mods) ->
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
      | Input.F n -> Some (264 + n)
      | Input.Backspace -> Some 127
      | Input.Tab -> Some 9
      | Input.Enter -> Some 13
      | Input.Escape -> None
    in
    (match base_code with
     | Some code ->
       if modifier = 1 then List.mem code b.Keys.codes
       else
         List.exists (fun (kc, m) ->
           kc = code && m = modifier) b.Keys.kitty_codes
     | None -> false)
  | _ -> false

let groups : (string * Keys.binding list) list = [
  "Files / tabs", [
    Keys.save; Keys.open_file; Keys.new_tab; Keys.close_tab;
    Keys.prev_tab; Keys.next_tab; Keys.quit;
  ];
  "Editing", [
    Keys.cut; Keys.paste; Keys.copy; Keys.undo; Keys.redo;
  ];
  "Rocq navigation", [
    Keys.step_forward; Keys.step_backward;
    Keys.go_to_cursor; Keys.step_to_start; Keys.step_to_end;
    Keys.interrupt; Keys.jump_back; Keys.jump_to_def;
  ];
  "Queries / display", [
    Keys.about; Keys.print_query; Keys.query_menu;
    Keys.options_menu; Keys.toggle_hyps; Keys.toggle_gutter;
    Keys.help; Keys.minimap; Keys.theme_menu; Keys.reload;
    Keys.build_menu; Keys.toggle_file_tree; Keys.refresh_screen;
    Keys.open_terminal; Keys.open_claude;
  ];
  "Panes / search", [
    Keys.cycle_pane; Keys.search; Keys.search_next; Keys.search_prev;
    Keys.search_toggle_case; Keys.search_toggle_regex;
    Keys.search_field_toggle; Keys.search_replace_one;
    Keys.search_replace_all; Keys.search_toggle_project;
    Keys.next_error; Keys.prev_error;
  ];
]

type outcome =
  | Pass of Input.event
  | Wrong of Input.event
  | Timeout
  | Skipped

let setup_terminal () =
  let tio = Unix.tcgetattr Unix.stdin in
  let raw = { tio with
    Unix.c_icanon = false;
    c_echo = false;
    c_isig = false;
    c_ixon = false;
    c_icrnl = false;
    c_vmin = 0;
    c_vtime = 0;
  } in
  Unix.tcsetattr Unix.stdin Unix.TCSANOW raw;
  let write s =
    ignore (Unix.write_substring Unix.stdout s 0 (String.length s))
  in
  write "\x1b[>1u";   (* Kitty keyboard protocol level 1 — see lib/term.ml *)
  at_exit (fun () ->
    write "\x1b[<u";
    try Unix.tcsetattr Unix.stdin Unix.TCSANOW tio with _ -> ())

exception Quit

(* Disambiguate displays like "^X/^K" or "^E/Alt+E": ask for the first
   alternative, list the rest in parens.  Matcher accepts any. *)
let format_press display =
  match String.split_on_char '/' display with
  | [single] -> single
  | first :: rest ->
    Printf.sprintf "%s  (or %s)" first (String.concat ", " rest)
  | [] -> display

let print_prefix (b : Keys.binding) =
  let press = format_press b.Keys.display in
  Printf.printf "  %-22s  %-38s  " press b.description;
  flush stdout

let is_quit_key (ev : Input.event) =
  match ev with
  (* Plain q — no Global/Script binding uses bare q. *)
  | Input.Key (113, m) when not m.Input.ctrl && not m.alt && not m.shift -> true
  (* Esc — not a tested binding. *)
  | Input.Special (Input.Escape, _) -> true
  (* Ctrl+\ in either encoding (kitty: 92+ctrl; legacy \x1c → 124+ctrl). *)
  | Input.Key (92, m) when m.Input.ctrl -> true
  | Input.Key (124, m) when m.Input.ctrl -> true
  | _ -> false

let test_one (b : Keys.binding) =
  print_prefix b;
  match Input.read_event ~timeout:10.0 Unix.stdin with
  | None ->
    Printf.printf "TIMEOUT (no key received)\n%!";
    Timeout
  | Some ev when is_quit_key ev ->
    Printf.printf "(quit)\n%!";
    raise Quit
  | Some (Input.Key (32, m))
    when not m.Input.ctrl && not m.alt && not m.shift ->
    Printf.printf "(skipped)\n%!";
    Skipped
  | Some ev ->
    let ev_s = Input.show_event ev in
    if match_binding ev b then
      (Printf.printf "OK    %s\n%!" ev_s; Pass ev)
    else
      (Printf.printf "WRONG got %s\n%!" ev_s; Wrong ev)

(* Did the wrong event match some OTHER binding?  Helps diagnose terminals
   that route a key to the wrong destination. *)
let identify_other (ev : Input.event) =
  let all = List.concat_map snd groups in
  List.find_opt (fun b -> match_binding ev b) all

let () =
  setup_terminal ();
  Printf.printf "\n";
  Printf.printf "  keytest — verifies each rocqtui keybinding\n";
  Printf.printf "  terminal config matches lib/term.ml (Kitty keyboard protocol level 1)\n\n";
  Printf.printf "  Press each binding when prompted.  10s timeout per key.\n";
  Printf.printf "  Space = skip current.   q or Esc = quit (prints partial summary).\n\n";
  let results = ref [] in
  (try
    List.iter (fun (group, bs) ->
      Printf.printf "  ── %s ──\n" group;
      List.iter (fun b ->
        let r = test_one b in
        results := (b, r) :: !results
      ) bs;
      Printf.printf "\n"
    ) groups
  with Quit -> Printf.printf "\n");
  let results = List.rev !results in
  let n = List.length results in
  let passed = List.filter (fun (_, r) ->
    match r with Pass _ -> true | _ -> false) results in
  let wrong = List.filter (fun (_, r) ->
    match r with Wrong _ -> true | _ -> false) results in
  let timeout = List.filter (fun (_, r) -> r = Timeout) results in
  let skipped = List.filter (fun (_, r) -> r = Skipped) results in
  Printf.printf "  ── Summary ──\n";
  Printf.printf "    Tested:   %d\n" n;
  Printf.printf "    Passed:   %d\n" (List.length passed);
  Printf.printf "    Wrong:    %d\n" (List.length wrong);
  Printf.printf "    Timeout:  %d\n" (List.length timeout);
  Printf.printf "    Skipped:  %d\n" (List.length skipped);
  if wrong <> [] then begin
    Printf.printf "\n  Wrong key received:\n";
    List.iter (fun (b, r) ->
      match r with
      | Wrong ev ->
        let got = Input.show_event ev in
        let other = match identify_other ev with
          | Some b' when b'.Keys.name <> b.Keys.name ->
            Printf.sprintf " (matches: %s)" b'.display
          | _ -> "" in
        Printf.printf "    %-14s  expected, got %s%s\n"
          b.Keys.display got other
      | _ -> ()
    ) wrong
  end;
  if timeout <> [] then begin
    Printf.printf "\n  Timed out (terminal sent nothing):\n";
    List.iter (fun (b, _) ->
      Printf.printf "    %-14s  %s\n" b.Keys.display b.Keys.description
    ) timeout
  end;
  Printf.printf "\n"
