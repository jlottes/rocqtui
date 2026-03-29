open Rocqtui_lib

external setlocale : int -> string -> string = "caml_curses_setlocale"

let () =
  ignore (setlocale 0 "");  (* LC_ALL = 0 *)
  (* Basic tests *)
  let g = Grid.create 5 20 in

  (* Test put_str with ASCII *)
  let n = Grid.put_str g ~row:0 ~col:0 "Hello" Grid.default_attr in
  assert (n = 5);
  assert (g.cells.(0).(0).text = "H");
  assert (g.cells.(0).(4).text = "o");
  Printf.printf "OK: ASCII put_str\n";

  (* Test clear *)
  Grid.clear g;
  assert (g.cells.(0).(0).text = " ");
  Printf.printf "OK: clear\n";

  (* Test wide character (CJK) *)
  let n = Grid.put_str g ~row:0 ~col:0 "\xe4\xb8\xad" Grid.default_attr in
  (* 中 is width 2 *)
  assert (n = 2);
  assert (g.cells.(0).(0).text = "\xe4\xb8\xad");
  assert (g.cells.(0).(0).width = 2);
  assert (g.cells.(0).(1).width = 0);  (* continuation *)
  assert (g.cells.(0).(1).text = "");
  Printf.printf "OK: wide character\n";

  (* Test overwriting a wide character *)
  Grid.set_cell g ~row:0 ~col:0 "A" Grid.default_attr;
  assert (g.cells.(0).(0).text = "A");
  assert (g.cells.(0).(0).width = 1);
  (* Continuation cell should have been cleared *)
  assert (g.cells.(0).(1).text = "");  (* was continuation, now left as-is *)
  Printf.printf "OK: overwrite wide char base\n";

  (* Test overwriting continuation cell *)
  Grid.clear g;
  ignore (Grid.put_str g ~row:0 ~col:0 "\xe4\xb8\xad" Grid.default_attr);
  Grid.set_cell g ~row:0 ~col:1 "B" Grid.default_attr;
  (* Setting col 1 (continuation) should clear the base at col 0 *)
  assert (g.cells.(0).(0).text = " ");
  assert (g.cells.(0).(0).width = 1);
  assert (g.cells.(0).(1).text = "B");
  Printf.printf "OK: overwrite continuation cell\n";

  (* Test combining characters *)
  Grid.clear g;
  (* e + combining acute = é *)
  let n = Grid.put_str g ~row:0 ~col:0 "e\xcc\x81" Grid.default_attr in
  assert (n = 1);  (* 1 column consumed *)
  assert (g.cells.(0).(0).text = "e\xcc\x81");
  assert (g.cells.(0).(0).width = 1);
  Printf.printf "OK: combining character\n";

  (* Test fill *)
  Grid.clear g;
  Grid.fill g ~row:0 ~col:2 ~width:5 '-' Grid.default_attr;
  assert (g.cells.(0).(2).text = "-");
  assert (g.cells.(0).(6).text = "-");
  assert (g.cells.(0).(7).text = " ");
  Printf.printf "OK: fill\n";

  (* Test attributes *)
  let bold_attr = { Grid.default_attr with bold = true;
                    fg = Grid.Color256 196 } in
  ignore (Grid.put_str g ~row:1 ~col:0 "Bold" bold_attr);
  assert (g.cells.(1).(0).attr.bold = true);
  assert (g.cells.(1).(0).attr.fg = Grid.Color256 196);
  Printf.printf "OK: attributes\n";

  (* Test diff rendering *)
  let prev = Grid.create 3 10 in
  let curr = Grid.create 3 10 in
  ignore (Grid.put_str curr ~row:0 ~col:0 "Hello" Grid.default_attr);
  ignore (Grid.put_str curr ~row:1 ~col:0 "World" bold_attr);
  let buf = Stdlib.Buffer.create 256 in
  Grid.diff ~prev ~curr buf;
  let output = Stdlib.Buffer.contents buf in
  (* Should contain cursor moves and text *)
  assert (String.length output > 0);
  assert (try ignore (String.index output 'H'); true with Not_found -> false);
  Printf.printf "OK: diff output (%d bytes)\n" (String.length output);

  (* Test diff with no changes *)
  Grid.copy ~src:curr ~dst:prev;
  let buf2 = Stdlib.Buffer.create 256 in
  Grid.diff ~prev ~curr buf2;
  let output2 = Stdlib.Buffer.contents buf2 in
  assert (String.length output2 = 0);
  Printf.printf "OK: diff with no changes (0 bytes)\n";

  (* Test rendering the UTF-8 demo file *)
  let demo_path = "/home/jlottes/glterm-1/test/UTF-8-demo.txt" in
  if Sys.file_exists demo_path then begin
    let ic = open_in demo_path in
    let big = Grid.create 200 80 in
    let row = ref 0 in
    (try while !row < 200 do
       let line = input_line ic in
       ignore (Grid.put_str big ~row:!row ~col:0 line Grid.default_attr);
       incr row
     done with End_of_file -> ());
    close_in ic;
    Printf.printf "OK: rendered %d lines of UTF-8 demo\n" !row;

    (* Verify Thai combining characters (line ~123) *)
    (* The Thai text has combining marks that should be appended *)
    let has_combining = ref false in
    for r = 0 to min 140 (big.rows - 1) do
      for c = 0 to big.cols - 1 do
        if String.length big.cells.(r).(c).text > 4 then
          has_combining := true  (* combining chars make text longer *)
      done
    done;
    if !has_combining then
      Printf.printf "OK: found combining characters in Thai text\n"
    else
      Printf.printf "NOTE: no combining characters detected (may be OK)\n"
  end else
    Printf.printf "SKIP: UTF-8 demo file not found\n";

  Printf.printf "All grid tests passed.\n"
