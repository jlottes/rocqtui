(* Contract tests for the key-encoding the terminal forwarder
   (lib/editor/pty.ml forward_event) depends on. These pin the wire bytes
   so a change in the vterm encoder or the modifier convention is caught.
   Run: dune exec test/test_keyseq.exe *)

module V = Vterm_lib.Vterm_api
module K = Vterm_lib.Keys

let pass = ref true

let check desc got expected =
  let s = function Some x -> Printf.sprintf "%S" x | None -> "None" in
  if got = expected then Printf.printf "PASS: %s\n" desc
  else begin
    Printf.printf "FAIL: %s\n  expected %s\n  got      %s\n"
      desc (s expected) (s got);
    pass := false
  end

let kitty ~key ?(mods=0) ~flags () =
  V.kitty_keyseq ~key ~shifted_key:0 ~modifiers:mods ~mode:0
    ~kitty_flags:flags ~event_type:1 ~text:""

let legacy ~key ?(mods=0) () =
  V.keyseq ~key ~modifiers:mods ~mode:0 ~event_type:0

let () =
  (* Modifier convention: input_mod's ctrl bit must equal the vterm's. *)
  check "mod_ctrl bit" (Some (string_of_int V.mod_ctrl)) (Some "4");

  (* --- Kitty active (disambiguate, flag 0b1) --- *)
  (* ESC is always disambiguated -> CSI 27 u. *)
  check "kitty ESC -> CSI 27u" (kitty ~key:K.escape ~flags:1 ()) (Some "\x1b[27u");
  (* Ctrl+A (key 'a'=97, ctrl) -> CSI 97 ; 5 u. *)
  check "kitty Ctrl+A -> CSI 97;5u"
    (kitty ~key:97 ~mods:V.mod_ctrl ~flags:1 ()) (Some "\x1b[97;5u");
  (* Ctrl+\ (key '\\'=92, ctrl) -> CSI 92 ; 5 u — the field-report case. *)
  check "kitty Ctrl+backslash -> CSI 92;5u"
    (kitty ~key:92 ~mods:V.mod_ctrl ~flags:1 ()) (Some "\x1b[92;5u");
  (* Plain unmodified letter is NOT escalated — encoder defers to text. *)
  check "kitty plain 'a' -> None (sent as text)"
    (kitty ~key:97 ~flags:1 ()) None;

  (* --- Kitty inactive (legacy): forward_event's fallback supplies bytes --- *)
  (* keyseq returns None for text keys and ESC, so the OCaml fallback in
     forward_event is what produces \x1b / 0x01 etc. Pin that None here. *)
  check "legacy ESC -> None (fallback emits \\x1b)" (legacy ~key:K.escape ()) None;
  check "legacy Ctrl+A -> None (fallback emits 0x01)"
    (legacy ~key:97 ~mods:V.mod_ctrl ()) None;
  check "kitty disabled (flags=0) Ctrl+A -> None"
    (kitty ~key:97 ~mods:V.mod_ctrl ~flags:0 ()) None;

  if !pass then print_string "All tests passed.\n"
  else (print_string "SOME TESTS FAILED.\n"; exit 1)
