(* Test sentence splitting.
   Run: dune exec test/test_sentence.exe *)

let pass = ref true

let check desc text expected =
  let result = Rocqtui_lib.Sentence.split text in
  let texts = List.map (fun (s, e) -> String.sub text s (e - s)) result in
  if texts = expected then
    Printf.printf "PASS: %s\n" desc
  else begin
    Printf.printf "FAIL: %s\n" desc;
    Printf.printf "  expected: %s\n"
      (String.concat " | " (List.map (Printf.sprintf "%S") expected));
    Printf.printf "  got:      %s\n"
      (String.concat " | " (List.map (Printf.sprintf "%S") texts));
    pass := false
  end

let () =
  check "simple sentence"
    "Check nat."
    ["Check nat."];

  check "two sentences"
    "Check nat. Check bool."
    ["Check nat."; "Check bool."];

  check "sentence with newline"
    "Check nat.\nCheck bool."
    ["Check nat."; "Check bool."];

  check "dot in qualified name"
    "Require Import Foo.Bar."
    ["Require Import Foo.Bar."];

  check "comment skipped"
    "Check (* hello *) nat."
    ["Check (* hello *) nat."];

  check "dot inside comment"
    "Check (* a.b *) nat."
    ["Check (* a.b *) nat."];

  check "nested comment"
    "Check (* (* nested *) *) nat."
    ["Check (* (* nested *) *) nat."];

  check "string skipped"
    {|Check "hello.world".|}
    [{|Check "hello.world".|}];

  check "double dot not sentence end"
    "Check (1..3). Check nat."
    ["Check (1..3)."; "Check nat."];

  check "triple dot"
    "Check ... . Check nat."
    ["Check ..."; "."; "Check nat."];

  check "bullet dash"
    "Proof.\n  - intros.\n  - auto."
    ["Proof."; "-"; "intros."; "-"; "auto."];

  check "bullet plus"
    "+ auto.\n+ exact I."
    ["+"; "auto."; "+"; "exact I."];

  check "bullet star"
    "* auto.\n* exact I."
    ["*"; "auto."; "*"; "exact I."];

  check "brace open"
    "{ auto. }"
    ["{"; "auto."; "}"];

  check "incomplete sentence ignored"
    "Check nat. Lemma foo"
    ["Check nat."];

  check "empty input"
    ""
    [];

  check "whitespace only"
    "  \n  "
    [];

  Printf.printf "\n";
  if !pass then
    Printf.printf "All checks passed!\n"
  else begin
    Printf.printf "Some checks FAILED!\n";
    exit 1
  end
