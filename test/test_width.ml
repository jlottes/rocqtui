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
  test "(arewrite_tag_l (injective_iff_simp (∙y) (x ∙ y⁻¹) e)))"
