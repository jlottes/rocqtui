(* Test line wrapping logic *)

(* Copy of wrap_lines from editor.ml for testing *)
let wrap_lines width lines_list =
  let result = ref [] in
  List.iter (fun line ->
    let line_w = Rocqtui_lib.Utf8.string_width line in
    let avail = width - 2 in
    if avail <= 0 || line_w <= avail then
      result := line :: !result
    else begin
      let len = String.length line in
      let i = ref 0 in
      while !i < len do
        let start = !i in
        let col = ref 0 in
        while !i < len && !col < avail do
          let (cp, n) = Rocqtui_lib.Utf8.decode line !i in
          let w = Rocqtui_lib.Utf8.codepoint_width cp in
          if !col + w > avail then ()
          else begin col := !col + w; i := !i + n end
        done;
        result := String.sub line start (!i - start) :: !result
      done
    end
  ) lines_list;
  List.rev !result

let pass = ref true

let check desc width input expected =
  let result = wrap_lines width input in
  if result = expected then
    Printf.printf "PASS: %s\n" desc
  else begin
    Printf.printf "FAIL: %s\n" desc;
    Printf.printf "  expected: [%s]\n"
      (String.concat "; " (List.map (Printf.sprintf "%S") expected));
    Printf.printf "  got:      [%s]\n"
      (String.concat "; " (List.map (Printf.sprintf "%S") result));
    pass := false
  end

let () =
  (* width=20 means avail=18 after 1-col margins *)
  check "short line no wrap" 20
    ["hello"]
    ["hello"];

  check "empty line" 20
    [""]
    [""];

  check "exact fit" 20
    ["abcdefghijklmnopqr"]  (* 18 chars = avail *)
    ["abcdefghijklmnopqr"];

  check "one char over" 20
    ["abcdefghijklmnopqrs"]  (* 19 chars, wraps *)
    ["abcdefghijklmnopqr"; "s"];

  check "multiple wraps" 20
    [String.make 40 'x']  (* 40 chars -> 18+18+4 *)
    [String.make 18 'x'; String.make 18 'x'; String.make 4 'x'];

  check "multiple lines" 20
    ["short"; "also short"]
    ["short"; "also short"];

  check "mixed short and long" 20
    ["short"; String.make 20 'a'; "end"]
    ["short"; String.make 18 'a'; "aa"; "end"];

  check "empty input" 20 [] [];

  (* Test that very narrow width doesn't infinite loop *)
  check "width=3 (avail=1)" 3
    ["abc"]
    ["a"; "b"; "c"];

  (* Simulate a real scenario: scroll through wrapped lines *)
  let lines = wrap_lines 40  (* avail=38 *)
    ["This is a short line";
     "This is a much longer line that should definitely wrap around because it exceeds thirty-eight characters wide";
     "Another short one"] in
  Printf.printf "\nWrapped lines for scroll test:\n";
  List.iteri (fun i l -> Printf.printf "  [%d] %S\n" i l) lines;
  let n = List.length lines in
  Printf.printf "  Total wrapped lines: %d\n" n;

  Printf.printf "\n";
  if !pass then
    Printf.printf "All checks passed!\n"
  else begin
    Printf.printf "Some checks FAILED!\n";
    exit 1
  end
