(* tterm_keytest: walk through tterm's keybindings and verify the
   terminal delivers the expected event. Sibling of [tools/keytest.ml].

   Terminal setup matches lib/term.ml so the parse path is identical
   to what tterm sees at runtime: raw mode + Kitty keyboard protocol
   level 1. Binding match uses [Keymatch] from the public library. *)

open Rocqtui_lib

let groups : (string * Keys.binding list) list = [
  "Window / focus", [
    Keys.quit;
    Keys.close_tab;
  ];
  "Tabs", [
    Keys.open_terminal;
    Keys.copy;
  ];
  "Splits (requires kitty keyboard protocol)", [
    Keys.split_vertical;
    Keys.split_horizontal;
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

let format_press display =
  match String.split_on_char '/' display with
  | [single] -> single
  | first :: rest ->
    Printf.sprintf "%s  (or %s)" first (String.concat ", " rest)
  | [] -> display

let print_prefix (b : Keys.binding) =
  let press = format_press b.Keys.display in
  Printf.printf "  %-22s  %-42s  " press b.description;
  flush stdout

let is_quit_key (ev : Input.event) =
  match ev with
  (* Plain q — not a tterm binding. *)
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
    if Keymatch.match_binding ev b then
      (Printf.printf "OK    %s\n%!" ev_s; Pass ev)
    else
      (Printf.printf "WRONG got %s\n%!" ev_s; Wrong ev)

(* Did the wrong event match some OTHER binding? Helps diagnose terminals
   that route a key to the wrong destination (e.g. ^Sh+T arriving as
   plain ^T because the kitty protocol isn't engaging). *)
let identify_other (ev : Input.event) =
  let all = List.concat_map snd groups in
  List.find_opt (fun b -> Keymatch.match_binding ev b) all

let () =
  setup_terminal ();
  Printf.printf "\n";
  Printf.printf "  tterm_keytest — verifies each tterm keybinding\n";
  Printf.printf "  terminal config matches lib/term.ml (Kitty keyboard protocol level 1)\n\n";
  Printf.printf "  Press each binding when prompted.  10s timeout per key.\n";
  Printf.printf "  Space = skip current.   q or Esc = quit (prints partial summary).\n";
  Printf.printf "\n";
  Printf.printf "  NOTE: split keys (^Sh+T / ^Sh+S) require the kitty keyboard\n";
  Printf.printf "  protocol to deliver the shift bit. If they come through as\n";
  Printf.printf "  plain ^T / ^S the diagnostic will say so.\n\n";
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
