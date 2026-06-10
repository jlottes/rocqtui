external setlocale : int -> string -> string = "caml_curses_setlocale"

let () =
  (* Must set locale for wcwidth to work *)
  ignore (setlocale 0 "");
  let test s =
    let w = Rocqtui_lib.Utf8.string_width s in
    let bytes = String.length s in
    Printf.printf "%S  bytes=%d  width=%d" s bytes w;
    (* Show per-codepoint widths *)
    let i = ref 0 in
    Printf.printf "  [";
    while !i < bytes do
      let (cp, n) = Rocqtui_lib.Utf8.decode s !i in
      let cw = Rocqtui_lib.Utf8.codepoint_width cp in
      if !i > 0 then Printf.printf ",";
      Printf.printf "U+%04X:%d" cp cw;
      i := !i + n
    done;
    Printf.printf "]\n"
  in
  test "∙";     (* U+2219 *)
  test "⧟";    (* U+29DF *)
  test "⁻";     (* U+207B *)
  test "¹";     (* U+00B9 *)
  test "→";    (* U+2192 *)
  test "∀";    (* U+2200 *)
  test "Ω";    (* U+03A9 *)
  test "λ";    (* U+03BB *)
  test "(∙y)";
  test "(x ∙ y⁻¹)";
  test "abc";
  test "(arewrite_tag_l (injective_iff_simp (∙y) (x ∙ y⁻¹) e)))";

  (* codepoint_width assertions: the cp_class authority (vendored
     char_width.h + emoji_presentation.h) must keep text-presentation
     symbols narrow, widen Emoji_Presentation=Yes codepoints, and not
     misread control codepoints as vterm cell encodings. *)
  let fails = ref 0 in
  let expect cp w =
    let got = Rocqtui_lib.Utf8.codepoint_width cp in
    if got <> w then begin
      Printf.printf "FAIL: U+%04X width %d, expected %d\n" cp got w;
      incr fails
    end
  in
  (* text-presentation status glyphs stay narrow *)
  expect 0x2713 1;  (* ✓ check mark *)
  expect 0x2714 1;  (* ✔ heavy check mark *)
  expect 0x2717 1;  (* ✗ ballot x *)
  expect 0x2718 1;  (* ✘ heavy ballot x *)
  expect 0x26A0 1;  (* ⚠ warning sign *)
  (* Emoji_Presentation=Yes codepoints widen *)
  expect 0x26A1 2;  (* ⚡ high voltage *)
  expect 0x2705 2;  (* ✅ check mark button *)
  expect 0x274C 2;  (* ❌ cross mark *)
  expect 0x2B50 2;  (* ⭐ star *)
  (* emoji block *)
  expect 0x1F600 2; (* 😀 *)
  expect 0x1F3FB 2; (* skin tone modifier, standalone *)
  (* EP=No pictographs in the emoji block stay narrow (9eb45ae) *)
  expect 0x1F321 1; (* 🌡 thermometer *)
  expect 0x1F441 1; (* 👁 eye *)
  expect 0x1F5A5 1; (* 🖥 desktop computer *)
  (* lone regional indicator is wide (EP=Yes; kitty/foot parity) *)
  expect 0x1F1FA 2;
  (* bare EP=No modifier bases stay narrow per UTS #51 — the
     deliberate kitty divergence, handled later by VS injection *)
  expect 0x261D 1;  (* ☝ *)
  expect 0x270C 1;  (* ✌ *)
  expect 0x1F590 1; (* 🖐 *)
  (* zero-width *)
  expect 0x0301 0;  (* combining acute *)
  expect 0x200D 0;  (* ZWJ *)
  expect 0xFE0F 0;  (* VS-16 *)
  (* controls; U+0010 must not pick up ENC_TAB's tab width *)
  expect 0x0009 0;
  expect 0x0010 0;

  (* string_width over display cells: the cluster-aware walker must
     match the gated upstream prescription (cluster_gate) *)
  let expect_sw s w =
    let got = Rocqtui_lib.Utf8.string_width s in
    if got <> w then begin
      Printf.printf "FAIL: string_width %S = %d, expected %d\n" s got w;
      incr fails
    end
  in
  expect_sw "abc" 3;
  expect_sw "e\xcc\x81" 1;                          (* e + acute *)
  expect_sw "\xe2\x9c\x94\xef\xb8\x8f" 2;           (* ✔ + VS16: widens *)
  expect_sw "\xe2\x9c\x93\xef\xb8\x8f" 1;           (* ✓ + VS16: not a VS base *)
  expect_sw "\xe2\x9a\xa1\xef\xb8\x8e" 1;           (* ⚡ + VS15: narrows *)
  expect_sw "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8" 2;   (* RI pair: one flag *)
  expect_sw "\xf0\x9f\x87\xba" 2;                   (* lone RI *)
  expect_sw "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8\xf0\x9f\x87\xba\xf0\x9f\x87\xb8" 4;
                                                    (* two flags *)
  expect_sw "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7" 2;
                                                    (* ZWJ family: one cell *)
  expect_sw "\xe2\x9d\xa4\xe2\x80\x8d\xf0\x9f\x94\xa5" 1;
                                  (* minimally-qualified ❤+ZWJ+🔥: base width *)
  expect_sw "1\xe2\x83\xa3" 1;                      (* bare keycap *)
  expect_sw "1\xef\xb8\x8f\xe2\x83\xa3" 2;          (* full keycap 1+VS16+20E3 *)
  expect_sw "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd" 2;   (* thumbs + skin tone *)
  expect_sw "\xe2\x98\x9d\xf0\x9f\x8f\xbd" 2;       (* ☝ (EMB, w1 bare) + tone *)
  expect_sw "A\xf0\x9f\x8f\xbd" 1;                  (* tone on non-EMB: absorbed *)

  (* column math lands on display-cell boundaries *)
  let expect_c2b s col b =
    let got = Rocqtui_lib.Utf8.col_to_byte s col in
    if got <> b then begin
      Printf.printf "FAIL: col_to_byte %S %d = %d, expected %d\n" s col got b;
      incr fails
    end
  in
  let flag_x = "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8x" in
  expect_c2b flag_x 0 0;
  expect_c2b flag_x 1 0;   (* mid-flag: cell start *)
  expect_c2b flag_x 2 8;   (* after the flag, never between RIs *)
  let e_acute_x = "e\xcc\x81x" in
  expect_c2b e_acute_x 1 3;  (* after the follower, not between e and mark *)
  if !fails > 0 then exit 1;
  print_endline "OK: codepoint_width assertions passed"
