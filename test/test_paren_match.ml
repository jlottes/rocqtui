(* Test paren / bracket / brace matching.
   Run: dune exec test/test_paren_match.exe *)

let pass = ref true

let pp = function
  | None -> "None"
  | Some (a, b) -> Printf.sprintf "Some(%d,%d)" a b

let check desc text cursor expected =
  let got = Rocqtui_lib.Paren_match.pair_at_cursor text ~cursor in
  if got = expected then
    Printf.printf "PASS: %s\n" desc
  else begin
    Printf.printf "FAIL: %s (text=%S cursor=%d)\n" desc text cursor;
    Printf.printf "  expected: %s\n" (pp expected);
    Printf.printf "  got:      %s\n" (pp got);
    pass := false
  end

let () =
  check "cursor on open paren"  "f(x)g" 1 (Some (1, 3));
  check "cursor on close paren" "f(x)g" 3 (Some (3, 1));
  check "cursor just past close"
    "f(x)g" 4 (Some (3, 1));
  check "cursor on open bracket" "[a]" 0 (Some (0, 2));
  check "cursor on open brace"   "{a}" 0 (Some (0, 2));
  check "nested outer"  "[(a)]" 0 (Some (0, 4));
  check "nested inner"  "[(a)]" 1 (Some (1, 3));
  check "paren in string"
    {|"("|} 1 None;
  check "paren in comment"
    "(* ( *)" 3 None;
  check "unmatched open"
    "(" 0 None;
  check "type mismatch"
    "(]" 0 None;
  check "multiline match"
    "f(\n  x\n)" 1 (Some (1, 7));
  check "cursor on non-bracket"
    "abc" 1 None;
  check "comment open paren ignored"
    "(* hi *)" 0 None;
  check "doubled-quote string escape"
    {|"""("|} 4 None;  (* the ( is inside a string that contains "" *)
  check "record literal braces"
    "{ x := 1 }" 0 (Some (0, 9));
  check "two pairs side by side, cursor on second open"
    "{a} {b}" 4 (Some (4, 6));
  check "two pairs side by side, cursor on first close"
    "{a} {b}" 2 (Some (2, 0));
  if !pass then exit 0 else exit 1
