open Rocqtui_lib

let load text =
  let tmp = Filename.temp_file "qa" ".v" in
  let oc = open_out tmp in
  output_string oc text;
  close_out oc;
  let buf = Buffer.load_file tmp in
  Sys.remove tmp;
  buf

let check label text ~line ~col ~expected =
  let buf = load text in
  Buffer.move_to buf line col;
  let got = Highlight.qualid_at_cursor buf in
  let show = function None -> "<none>" | Some s -> Printf.sprintf "%S" s in
  if got = expected then
    Printf.printf "OK   %s -> %s\n" label (show got)
  else begin
    Printf.printf "FAIL %s -> %s (expected %s)\n" label (show got) (show expected);
    exit 1
  end

let () =
  check "ASCII ident at start"
    "Lemma foo : True." ~line:0 ~col:6 ~expected:(Some "foo");
  check "Greek single letter (cursor on first byte)"
    "Lemma α : True." ~line:0 ~col:6 ~expected:(Some "α");
  check "Greek single letter (cursor on continuation byte)"
    "Lemma α : True." ~line:0 ~col:7 ~expected:(Some "α");
  check "Greek mixed identifier"
    "Lemma αβγ_test : True." ~line:0 ~col:6 ~expected:(Some "αβγ_test");
  check "Cursor in middle of multi-byte ident"
    "Lemma αβγ_test : True." ~line:0 ~col:8 ~expected:(Some "αβγ_test");
  check "Qualified name from start (sentence-end dot stripped)"
    "Check Foo.Bar.baz." ~line:0 ~col:6 ~expected:(Some "Foo.Bar.baz");
  check "Qualified name, cursor on middle component"
    "Check Foo.Bar.baz." ~line:0 ~col:10 ~expected:(Some "Foo.Bar.baz");
  check "Qualified name, cursor on tail component"
    "Check Foo.Bar.baz." ~line:0 ~col:14 ~expected:(Some "Foo.Bar.baz");
  check "Qualified name with greek tail"
    "Check Foo.α." ~line:0 ~col:10 ~expected:(Some "Foo.α");
  (* Cursor right after a token claims that token (matches RocqIDE). *)
  check "Cursor immediately after ident returns it"
    "Lemma foo : True." ~line:0 ~col:5 ~expected:(Some "Lemma");
  check "Cursor on space between two idents picks the left one"
    "foo bar" ~line:0 ~col:3 ~expected:(Some "foo");
  check "Math letter ℕ"
    "Definition x : ℕ := 0." ~line:0 ~col:15 ~expected:(Some "ℕ");
  check "ident inside ltac:() quotation"
    "Goal True. ltac:(foo x y z)." ~line:0 ~col:17 ~expected:(Some "foo");
  check "operator does not bridge two idents"
    "Check (x+y)." ~line:0 ~col:7 ~expected:(Some "x");
  check "ident next to colon does not absorb colon"
    "ltac:(foo)" ~line:0 ~col:0 ~expected:(Some "ltac");
  Printf.printf "All qualid tests passed.\n"
