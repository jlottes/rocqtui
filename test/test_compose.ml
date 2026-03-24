let () =
  let cs = Rocqtui_lib.Compose.load () in
  let test desc keys expected =
    Rocqtui_lib.Compose.start cs;
    let result = ref Rocqtui_lib.Compose.Pending in
    List.iter (fun k ->
      if !result = Rocqtui_lib.Compose.Pending then
        result := Rocqtui_lib.Compose.feed cs k
    ) keys;
    match !result with
    | Rocqtui_lib.Compose.Composed text ->
      if text = expected then Printf.printf "PASS: %s -> %S\n" desc text
      else Printf.printf "FAIL: %s -> got %S, expected %S\n" desc text expected
    | Rocqtui_lib.Compose.Pending ->
      Printf.printf "FAIL: %s -> still pending\n" desc
    | Rocqtui_lib.Compose.NoMatch ->
      Printf.printf "FAIL: %s -> no match\n" desc
  in
  test "minus greater -> arrow" [Char.code '-'; Char.code '>'] "\xe2\x86\x92";
  test "period period -> bullet" [Char.code '.'; Char.code '.'] "\xe2\x88\x99";
  test "bar minus -> turnstile" [Char.code '|'; Char.code '-'] "\xe2\x8a\xa2";
  test "f a -> forall" [Char.code 'f'; Char.code 'a'] "\xe2\x88\x80";
  test "e x -> exists" [Char.code 'e'; Char.code 'x'] "\xe2\x88\x83";
  test "minus o -> lollipop" [Char.code '-'; Char.code 'o'] "\xe2\x8a\xb8";
  test "a ESC -> alpha" [Char.code 'a'; 27] "\xce\xb1";
  test "o ESC -> compose" [Char.code 'o'; 27] "\xe2\x88\x98";
  test "o minus o -> lollipop-like" [Char.code 'o'; Char.code '-'; Char.code 'o'] "\xe2\xa7\x9f";
  (* o minus followed by space should give o-macron since space doesn't continue *)
  test "o minus space -> o-macron" [Char.code 'o'; Char.code '-'; Char.code ' '] "\xc5\x8d";
  ()
