(* Tests for the push-based input parser (lib/input.ml).
   Focus: sequences split across [feed] boundaries must parse identically
   to arriving in one chunk — the property the pull parser lacked.
   Run: dune exec test/test_input.exe *)

module Input = Rocqtui_lib.Input

let pass = ref true

let check desc cond =
  if cond then Printf.printf "PASS: %s\n" desc
  else (Printf.printf "FAIL: %s\n" desc; pass := false)

let feed_str p s = Input.feed p (Bytes.of_string s) ~off:0 ~len:(String.length s)

let drain p =
  let rec go acc =
    match Input.next_event p with
    | Some e -> go (e :: acc)
    | None -> List.rev acc
  in go []

(* Feed [chunks] in order into a fresh parser, return all events. *)
let run chunks =
  let p = Input.create () in
  List.iter (feed_str p) chunks;
  drain p

let ctrl = { Input.no_mod with ctrl = true }

let () =
  (* --- Plain text and control bytes --- *)
  check "plain ascii"
    (run ["abc"] = [Input.Key (97, Input.no_mod);
                    Input.Key (98, Input.no_mod);
                    Input.Key (99, Input.no_mod)]);
  check "ctrl-A legacy byte" (run ["\x01"] = [Input.Key (97, ctrl)]);
  check "CR is Enter" (run ["\r"] = [Input.Special (Input.Enter, Input.no_mod)]);

  (* --- Bracketed paste split across feed boundaries --- *)
  let payload = "hello\nworld" in
  let paste_whole = "\x1b[200~" ^ payload ^ "\x1b[201~" in
  check "paste in one chunk" (run [paste_whole] = [Input.Paste payload]);
  check "paste split mid-marker and mid-body"
    (run ["\x1b[20"; "0~hel"; "lo\nwor"; "ld\x1b[2"; "01~"] = [Input.Paste payload]);
  check "paste: newline stays in payload, no Enter event"
    (List.for_all (function Input.Special (Input.Enter, _) -> false | _ -> true)
       (run [paste_whole]));

  (* --- UTF-8 split across feed boundaries --- *)
  (* "é" = 0xC3 0xA9 -> codepoint 0xE9 *)
  check "utf-8 split across feeds"
    (run ["\xc3"; "\xa9"] = [Input.Key (0xE9, Input.no_mod)]);
  check "utf-8 whole"
    (run ["\xc3\xa9"] = [Input.Key (0xE9, Input.no_mod)]);

  (* --- Lone ESC vs. escape sequence --- *)
  (* ESC alone, then flush -> Escape. *)
  let p = Input.create () in
  feed_str p "\x1b";
  check "lone ESC pending, no event yet" (drain p = [] && Input.pending p);
  Input.flush p;
  check "flush resolves lone ESC"
    (drain p = [Input.Special (Input.Escape, Input.no_mod)] && not (Input.pending p));

  (* ESC then [A in separate feeds (no flush) -> Up, never Escape. *)
  let p = Input.create () in
  feed_str p "\x1b";
  ignore (drain p);
  feed_str p "[A";
  check "ESC then [A across feeds is Up (not Escape)"
    (drain p = [Input.Special (Input.Up, Input.no_mod)] && not (Input.pending p));

  (* --- Arrows / CSI split --- *)
  check "arrow split ESC[ | C"
    (run ["\x1b["; "C"] = [Input.Special (Input.Right, Input.no_mod)]);
  check "modified arrow CSI 1;5A -> Ctrl+Up"
    (run ["\x1b[1;5A"] = [Input.Special (Input.Up, ctrl)]);

  (* --- Kitty CSI u --- *)
  check "kitty ESC[27u -> Escape"
    (run ["\x1b[27u"] = [Input.Special (Input.Escape, Input.no_mod)]);
  check "kitty ESC[92;5u -> Ctrl+backslash"
    (run ["\x1b[92;5u"] = [Input.Key (92, ctrl)]);

  (* --- SGR mouse, split --- *)
  check "SGR mouse press split"
    (run ["\x1b[<0;"; "10;20M"] =
       [Input.Mouse { button = Input.Left; x = 9; y = 19;
                      mods = Input.no_mod }]);

  if !pass then print_string "All tests passed.\n"
  else (print_string "SOME TESTS FAILED.\n"; exit 1)
