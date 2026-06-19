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
  (* e + combining acute = é; the mark lands as a follower (with the
     leader's attr), never folded into the leader text *)
  let n = Grid.put_str g ~row:0 ~col:0 "e\xcc\x81" Grid.default_attr in
  assert (n = 1);  (* 1 column consumed *)
  assert (g.cells.(0).(0).text = "e");
  assert (g.cells.(0).(0).followers = [("\xcc\x81", Grid.default_attr)]);
  assert (g.cells.(0).(0).width = 1);
  Printf.printf "OK: combining character\n";

  (* chgat recolors the cell *and* its followers, but must not drop the
     combining mark (regression: verified-region restyling erased "∊̸"). *)
  let recolor = { Grid.default_attr with fg = Grid.Color256 42 } in
  Grid.chgat g ~row:0 ~col:0 ~width:1 recolor;
  assert (g.cells.(0).(0).text = "e");
  assert (g.cells.(0).(0).attr.fg = Grid.Color256 42);
  assert (g.cells.(0).(0).followers = [("\xcc\x81", recolor)]);
  Printf.printf "OK: chgat preserves followers\n";

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

  (* Test rendering the UTF-8 demo file, if available.
     Set ROCQTUI_TEST_UTF8 to point at a UTF-8 sample file to enable. *)
  let demo_path = try Sys.getenv "ROCQTUI_TEST_UTF8" with Not_found -> "" in
  if demo_path <> "" && Sys.file_exists demo_path then begin
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

  (* --- Rect-aware drawing primitives --- *)
  (* A grid wide enough that overrun would be visible *)
  let big = Grid.create 5 20 in
  let rect : Grid.rect = { row = 1; col = 5; height = 2; width = 4 } in

  (* put_str_in_rect: writes "hello" into a 4-wide rect at col 5 — only
     the first 4 cells should land; the 5th must NOT bleed into col 9. *)
  Grid.clear big;
  ignore (Grid.put_str big ~row:1 ~col:9 "Z" Grid.default_attr);  (* sentinel *)
  let n = Grid.put_str_in_rect big rect ~row:0 ~col:0 "hello"
            Grid.default_attr in
  assert (n = 4);
  assert (big.cells.(1).(5).text = "h");
  assert (big.cells.(1).(8).text = "l");
  assert (big.cells.(1).(9).text = "Z");  (* sentinel survived *)
  Printf.printf "OK: put_str_in_rect clips at the rect's right edge\n";

  (* Row out of rect range — no-op, return 0 *)
  let n = Grid.put_str_in_rect big rect ~row:5 ~col:0 "x"
            Grid.default_attr in
  assert (n = 0);
  Printf.printf "OK: put_str_in_rect ignores out-of-rect rows\n";

  (* fill_in_rect: width that overflows the rect right edge gets clipped *)
  Grid.clear big;
  ignore (Grid.put_str big ~row:1 ~col:9 "Z" Grid.default_attr);
  Grid.fill_in_rect big rect ~row:0 ~col:0 ~width:10 '*' Grid.default_attr;
  assert (big.cells.(1).(5).text = "*");
  assert (big.cells.(1).(8).text = "*");
  assert (big.cells.(1).(9).text = "Z");
  Printf.printf "OK: fill_in_rect clips overflow\n";

  (* set_cell_in_rect: writing past the rect is a no-op *)
  Grid.clear big;
  ignore (Grid.put_str big ~row:1 ~col:9 "Z" Grid.default_attr);
  Grid.set_cell_in_rect big rect ~row:0 ~col:5 "X" Grid.default_attr;
  assert (big.cells.(1).(9).text = "Z");  (* out of rect — unchanged *)
  Printf.printf "OK: set_cell_in_rect ignores out-of-rect col\n";

  (* --- Extended SGR emission --- *)
  let emit prev curr =
    let buf = Stdlib.Buffer.create 32 in
    Grid.emit_attr buf prev curr;
    Stdlib.Buffer.contents buf
  in
  let d = Grid.default_attr in
  (* Italic on/off *)
  assert (emit d { d with italic = Grid.Italic_on } = "\x1b[3m");
  (* Strikethrough *)
  assert (emit d { d with strikethrough = true } = "\x1b[9m");
  (* Conceal *)
  assert (emit d { d with conceal = true } = "\x1b[8m");
  (* Overline *)
  assert (emit d { d with overline = true } = "\x1b[53m");
  (* Curly underline + RGB underline color (LSP diagnostic style) *)
  let curly_red = { d with underline = Grid.UL_curly;
                           ul = Grid.TrueColor (255, 0, 0) } in
  assert (emit d curly_red = "\x1b[4:3;58;2;255;0;0m");
  (* Curly red -> default uses reset path (underline turns off) *)
  assert (emit curly_red d = "\x1b[0m");
  (* Blink slow / rapid *)
  assert (emit d { d with blink = Grid.Blink_slow } = "\x1b[5m");
  assert (emit d { d with blink = Grid.Blink_rapid } = "\x1b[6m");
  (* Italic -> Fraktur: both non-none, delta path, just emit the new on-code *)
  assert (emit { d with italic = Grid.Italic_on }
               { d with italic = Grid.Italic_fraktur } = "\x1b[20m");
  (* Underline single -> double: delta path *)
  assert (emit { d with underline = Grid.UL_single }
               { d with underline = Grid.UL_double } = "\x1b[21m");
  Printf.printf "OK: extended SGR emission (italic/strike/curly/ul/blink)\n";

  (* VS-15 injection: a bare EP=No modifier base (☝ U+261D) gets an
     explicit VS-15 appended at emit so kitty doesn't widen it; an
     already-disambiguated cluster (☝ + skin tone, width 2) must not. *)
  let contains hay needle =
    let lh = String.length hay and ln = String.length needle in
    let rec loop i =
      i + ln <= lh && (String.sub hay i ln = needle || loop (i + 1))
    in
    loop 0
  in
  let g2 = Grid.create 1 10 in
  ignore (Grid.put_str g2 ~row:0 ~col:0 "\xe2\x98\x9dz" Grid.default_attr);
  let buf3 = Stdlib.Buffer.create 64 in
  Grid.emit_all g2 buf3;
  assert (contains (Stdlib.Buffer.contents buf3)
            "\xe2\x98\x9d\xef\xb8\x8ez");
  Grid.clear g2;
  ignore (Grid.put_str g2 ~row:0 ~col:0
            "\xe2\x98\x9d\xf0\x9f\x8f\xbd" Grid.default_attr);
  let buf4 = Stdlib.Buffer.create 64 in
  Grid.emit_all g2 buf4;
  assert (not (contains (Stdlib.Buffer.contents buf4) "\xef\xb8\x8e"));
  Printf.printf "OK: VS-15 injection on bare modifier bases\n";

  Printf.printf "All grid tests passed.\n"
