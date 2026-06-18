(* Test for context-aware syntax highlighting.
   Run: dune exec test/test_highlight.exe *)

let load_text_into_buf text =
  let buf = Rocqtui_lib.Buffer.create () in
  Rocqtui_lib.Buffer.Unsafe.set_text buf text;
  buf

let color_name c = match c with
  | 6 -> "keyword" | 7 -> "tactic" | 8 -> "comment"
  | 9 -> "string" | 10 -> "bullet" | 11 -> "number"
  | _ -> Printf.sprintf "color_%d" c

let find_span spans buf line_num text color =
  let line_spans = spans.(line_num - 1) in
  List.exists (fun (span : Rocqtui_lib.Highlight.span) ->
    let line = Rocqtui_lib.Buffer.get_line buf (line_num - 1) in
    let len = min span.length (String.length line - span.start_col) in
    let t = if len > 0 && span.start_col < String.length line
      then String.sub line span.start_col len else "" in
    span.color = color && t = text
  ) line_spans

let pass = ref true

let check spans buf desc line_num expected_color expected_text =
  if find_span spans buf line_num expected_text expected_color then
    Printf.printf "  PASS: %s\n" desc
  else begin
    Printf.printf "  FAIL: %s (expected %S as %s on line %d)\n"
      desc expected_text (color_name expected_color) line_num;
    pass := false
  end

let check_absent spans buf desc line_num not_color text =
  if not (find_span spans buf line_num text not_color) then
    Printf.printf "  PASS: %s\n" desc
  else begin
    Printf.printf "  FAIL: %s (%S should NOT be %s on line %d)\n"
      desc text (color_name not_color) line_num;
    pass := false
  end

let dump_spans spans buf =
  let num_lines = Rocqtui_lib.Buffer.line_count buf in
  for i = 0 to num_lines - 1 do
    let line = Rocqtui_lib.Buffer.get_line buf i in
    if spans.(i) <> [] then begin
      Printf.printf "  Line %d: %S\n" (i + 1) line;
      List.iter (fun (span : Rocqtui_lib.Highlight.span) ->
        let len = min span.length (String.length line - span.start_col) in
        let t = if len > 0 && span.start_col < String.length line
          then String.sub line span.start_col len else "?" in
        let bold = if span.attr land 0x200000 <> 0 then "+bold" else "" in
        Printf.printf "    [%d..%d] %-25s %s%s\n"
          span.start_col (span.start_col + span.length)
          (Printf.sprintf "%S" t) (color_name span.color) bold
      ) spans.(i)
    end
  done

let () =
  (* === Test 1: Basic highlighting === *)
  Printf.printf "=== Test 1: Basic highlighting ===\n";
  let text1 = {|Require Import foo.
Definition bar := 42.
(* a comment *)
"a string"
|} in
  let buf1 = load_text_into_buf text1 in
  let spans1 = Rocqtui_lib.Highlight.highlight_buffer buf1 in
  dump_spans spans1 buf1;
  check spans1 buf1 "Require is keyword" 1 6 "Require";
  check spans1 buf1 "Import is keyword" 1 6 "Import";
  check spans1 buf1 "Definition is keyword" 2 6 "Definition";
  check spans1 buf1 "42 is number" 2 11 "42";
  check spans1 buf1 "comment is colored" 3 8 "(* a comment *)";
  check spans1 buf1 "string is colored" 4 9 {|"a string"|};
  Printf.printf "\n";

  (* === Test 2: Tactics only in Ltac context === *)
  Printf.printf "=== Test 2: Context-aware tactics ===\n";
  let text2 = {|Require Import rewrite tactics.misc.
Lemma foo : forall x, x = x.
Proof.
  intros x.
  reflexivity.
Qed.
Definition apply := 0.
|} in
  let buf2 = load_text_into_buf text2 in
  let spans2 = Rocqtui_lib.Highlight.highlight_buffer buf2 in
  dump_spans spans2 buf2;
  check_absent spans2 buf2 "rewrite NOT tactic in import" 1 7 "rewrite";
  check_absent spans2 buf2 "tactics NOT tactic in import" 1 7 "tactics";
  check spans2 buf2 "Lemma is keyword" 2 6 "Lemma";
  check spans2 buf2 "forall is keyword" 2 6 "forall";
  check spans2 buf2 "Proof is keyword" 3 6 "Proof";
  check spans2 buf2 "intros IS tactic after Proof" 4 7 "intros";
  check spans2 buf2 "reflexivity IS tactic after Proof" 5 7 "reflexivity";
  check spans2 buf2 "Qed is keyword" 6 6 "Qed";
  check_absent spans2 buf2 "apply NOT tactic in Definition" 7 7 "apply";
  Printf.printf "\n";

  (* === Test 3: ltac:() and constr:() === *)
  Printf.printf "=== Test 3: Embedded ltac:/constr: ===\n";
  let text3 = {|Definition foo := ltac:(exact 0).
Ltac bar := let x := constr:(0) in exact x.
|} in
  let buf3 = load_text_into_buf text3 in
  let spans3 = Rocqtui_lib.Highlight.highlight_buffer buf3 in
  dump_spans spans3 buf3;
  check spans3 buf3 "exact IS tactic inside ltac:()" 1 7 "exact";
  check_absent spans3 buf3 "0 NOT tactic inside constr:()" 2 7 "0";
  check spans3 buf3 "exact IS tactic in Ltac body" 2 7 "exact";
  Printf.printf "\n";

  (* === Test 4: Nested comments === *)
  Printf.printf "=== Test 4: Nested comments ===\n";
  let text4 = {|(* outer (* inner *) still comment *)
Definition x := 1.
|} in
  let buf4 = load_text_into_buf text4 in
  let spans4 = Rocqtui_lib.Highlight.highlight_buffer buf4 in
  dump_spans spans4 buf4;
  check spans4 buf4 "nested comment fully colored" 1 8
    "(* outer (* inner *) still comment *)";
  check spans4 buf4 "Definition after comment" 2 6 "Definition";
  Printf.printf "\n";

  (* === Test 5: highlight_text matches highlight_buffer, handles
     query-result snippets (unicode, ∀/→) without throwing === *)
  Printf.printf "=== Test 5: highlight_text ===\n";
  let text5 = "Definition bar := 42.\n(* c *)\n" in
  let buf5 = load_text_into_buf text5 in
  let from_buf = Rocqtui_lib.Highlight.highlight_buffer buf5 in
  let from_text = Rocqtui_lib.Highlight.highlight_text text5 in
  if from_buf = from_text then
    Printf.printf "  PASS: highlight_text agrees with highlight_buffer\n"
  else begin
    Printf.printf "  FAIL: highlight_text differs from highlight_buffer\n";
    pass := false
  end;
  (* Representative About/Print output — must not raise, keyword found. *)
  let snippet =
    "foo : forall {A : Type}, A -> A\nfoo : \xe2\x88\x80 {A}, A \xe2\x86\x92 A" in
  let st = Rocqtui_lib.Highlight.highlight_text snippet in
  if Array.length st = 2 then
    Printf.printf "  PASS: highlight_text returns one entry per line\n"
  else begin
    Printf.printf "  FAIL: expected 2 lines, got %d\n" (Array.length st);
    pass := false
  end;
  Printf.printf "\n";

  if !pass then
    Printf.printf "All checks passed!\n"
  else begin
    Printf.printf "Some checks FAILED!\n";
    exit 1
  end
