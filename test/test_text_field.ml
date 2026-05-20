(* Unit tests for Text_field — the shared single-line input buffer
   used by the search and rename prompts. *)

open Rocqtui_lib

(* cursor_col uses wcwidth, which only classifies non-ASCII codepoints
   correctly once a UTF-8 locale is in effect. *)
external setlocale : int -> string -> string = "caml_curses_setlocale"
let () = ignore (setlocale 0 "")

let check name cond =
  if cond then Printf.printf "OK: %s\n" name
  else (Printf.printf "FAIL: %s\n" name; exit 1)

let key cp = Input.Key (cp, Input.no_mod)
let special k = Input.Special (k, Input.no_mod)

let test_create_defaults () =
  let f = Text_field.create () in
  check "create: empty contents" (Text_field.contents f = "");
  check "create: cursor = 0" (Text_field.cursor_byte f = 0);
  let f = Text_field.create ~contents:"hello" () in
  check "create: contents set" (Text_field.contents f = "hello");
  check "create: cursor defaults to end" (Text_field.cursor_byte f = 5);
  let f = Text_field.create ~contents:"hello" ~cursor_byte:2 () in
  check "create: explicit cursor honored" (Text_field.cursor_byte f = 2);
  let f = Text_field.create ~contents:"hi" ~cursor_byte:99 () in
  check "create: cursor clamped to len" (Text_field.cursor_byte f = 2)

let test_insert () =
  let f = Text_field.create ~contents:"hello" ~cursor_byte:0 () in
  Text_field.insert f "X";
  check "insert at start: contents" (Text_field.contents f = "Xhello");
  check "insert at start: cursor advanced" (Text_field.cursor_byte f = 1);
  Text_field.set_cursor_byte f 6;
  Text_field.insert f "!";
  check "insert at end: contents" (Text_field.contents f = "Xhello!");
  check "insert at end: cursor advanced" (Text_field.cursor_byte f = 7)

let test_handle_printable () =
  let f = Text_field.create () in
  let consumed = Text_field.handle_key f (key (Char.code 'a')) in
  check "printable: claimed" consumed;
  check "printable: contents" (Text_field.contents f = "a");
  check "printable: cursor = 1" (Text_field.cursor_byte f = 1)

let test_ctrl_not_claimed () =
  let f = Text_field.create ~contents:"abc" () in
  let mods = { Input.no_mod with ctrl = true } in
  let consumed = Text_field.handle_key f (Input.Key (Char.code 'a', mods)) in
  check "ctrl+a: not claimed" (not consumed);
  check "ctrl+a: contents unchanged" (Text_field.contents f = "abc")

let test_backspace () =
  let f = Text_field.create ~contents:"hello" ~cursor_byte:3 () in
  let _ = Text_field.handle_key f (special Input.Backspace) in
  check "backspace mid: contents" (Text_field.contents f = "helo");
  check "backspace mid: cursor decremented" (Text_field.cursor_byte f = 2);
  Text_field.set_cursor_byte f 0;
  let _ = Text_field.handle_key f (special Input.Backspace) in
  check "backspace at 0: no-op" (Text_field.contents f = "helo");
  check "backspace at 0: cursor still 0" (Text_field.cursor_byte f = 0)

let test_delete () =
  let f = Text_field.create ~contents:"hello" ~cursor_byte:2 () in
  let _ = Text_field.handle_key f (special Input.Delete) in
  check "delete mid: contents" (Text_field.contents f = "helo");
  check "delete mid: cursor unchanged" (Text_field.cursor_byte f = 2);
  Text_field.set_cursor_byte f 4;
  let _ = Text_field.handle_key f (special Input.Delete) in
  check "delete at end: no-op" (Text_field.contents f = "helo")

let test_arrows_home_end () =
  let f = Text_field.create ~contents:"abc" ~cursor_byte:0 () in
  let _ = Text_field.handle_key f (special Input.Right) in
  check "right: cursor advances" (Text_field.cursor_byte f = 1);
  let _ = Text_field.handle_key f (special Input.End) in
  check "end: cursor at len" (Text_field.cursor_byte f = 3);
  let _ = Text_field.handle_key f (special Input.Right) in
  check "right at end: no-op" (Text_field.cursor_byte f = 3);
  let _ = Text_field.handle_key f (special Input.Left) in
  check "left: cursor steps back" (Text_field.cursor_byte f = 2);
  let _ = Text_field.handle_key f (special Input.Home) in
  check "home: cursor at 0" (Text_field.cursor_byte f = 0);
  let _ = Text_field.handle_key f (special Input.Left) in
  check "left at 0: no-op" (Text_field.cursor_byte f = 0)

let test_utf8_codepoint_boundaries () =
  (* "a∀b" — codepoint ∀ is 3 bytes in UTF-8. Total length: 5 bytes. *)
  let forall = Utf8.encode 0x2200 in
  let s = "a" ^ forall ^ "b" in
  check "utf8: total length" (String.length s = 5);
  let f = Text_field.create ~contents:s ~cursor_byte:5 () in
  let _ = Text_field.handle_key f (special Input.Backspace) in
  check "utf8 backspace: drops 'b'" (Text_field.contents f = "a" ^ forall);
  check "utf8 backspace: cursor at 4" (Text_field.cursor_byte f = 4);
  let _ = Text_field.handle_key f (special Input.Backspace) in
  check "utf8 backspace: drops whole ∀ (3 bytes)"
    (Text_field.contents f = "a");
  check "utf8 backspace: cursor at 1" (Text_field.cursor_byte f = 1);
  (* Cursor motion respects codepoint boundaries too. *)
  let f = Text_field.create ~contents:s ~cursor_byte:1 () in
  let _ = Text_field.handle_key f (special Input.Right) in
  check "utf8 right: skips full ∀ codepoint"
    (Text_field.cursor_byte f = 4);
  let _ = Text_field.handle_key f (special Input.Left) in
  check "utf8 left: steps back over ∀" (Text_field.cursor_byte f = 1)

let test_insert_multibyte () =
  let forall = Utf8.encode 0x2200 in
  let f = Text_field.create ~contents:"a" () in
  Text_field.insert f forall;
  check "insert utf8: contents" (Text_field.contents f = "a" ^ forall);
  check "insert utf8: cursor past the codepoint"
    (Text_field.cursor_byte f = 4)

let test_cursor_col () =
  (* "a∀b" — bytes [0; 1; 4; 5]; columns [0; 1; 2; 3]. *)
  let forall = Utf8.encode 0x2200 in
  let s = "a" ^ forall ^ "b" in
  let f = Text_field.create ~contents:s ~cursor_byte:0 () in
  check "col: start" (Text_field.cursor_col f = 0);
  Text_field.set_cursor_byte f 1;
  check "col: after ASCII" (Text_field.cursor_col f = 1);
  Text_field.set_cursor_byte f 4;
  check "col: after 3-byte ∀ (1 col wide)" (Text_field.cursor_col f = 2);
  Text_field.set_cursor_byte f 5;
  check "col: at end" (Text_field.cursor_col f = 3);
  (* After typing the composed codepoint via handle_key the column
     should advance by exactly its width, not its byte length. *)
  let f = Text_field.create () in
  let _ = Text_field.handle_key f (key 0x2200) in
  check "col: typed ∀ advances col by 1"
    (Text_field.cursor_col f = 1 && Text_field.cursor_byte f = 3)

let () =
  test_create_defaults ();
  test_insert ();
  test_handle_printable ();
  test_ctrl_not_claimed ();
  test_backspace ();
  test_delete ();
  test_arrows_home_end ();
  test_utf8_codepoint_boundaries ();
  test_insert_multibyte ();
  test_cursor_col ();
  print_endline "All tests passed."
