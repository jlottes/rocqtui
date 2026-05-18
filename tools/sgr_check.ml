(* Trace what vterm gives us for a multi-line sgrtest.py-style output. *)

open Rocqtui_lib

let[@warning "-32"] escape_str s =
  let b = Stdlib.Buffer.create (String.length s + 16) in
  String.iter (fun c ->
    if c = '\x1b' then Stdlib.Buffer.add_string b "\\e"
    else if c < ' ' then Stdlib.Buffer.add_string b (Printf.sprintf "\\x%02x" (Char.code c))
    else Stdlib.Buffer.add_char b c
  ) s;
  Stdlib.Buffer.contents b

let ul_str = function
  | Grid.UL_none -> "n" | UL_single -> "1" | UL_double -> "2"
  | UL_curly -> "c" | UL_dotted -> "." | UL_dashed -> "-"

let[@warning "-32"] dump_row vt y w =
  let cells = Vterm_lib.Vterm_api.get_row vt y in
  let sentinel = Vterm_lib.Vterm_api.get_row_sentinel vt y in
  Printf.printf "  row %d: %d cells; " y (Array.length cells);
  (match sentinel with
   | Some (a, end_col, _) ->
     let a = (Obj.magic a : Grid.attr) in
     Printf.printf "sentinel end_col=%d ul=%s bold=%b\n"
       end_col (ul_str a.underline) a.bold
   | None -> Printf.printf "no sentinel\n");
  (* Show all cells with their underline status *)
  let buf = Stdlib.Buffer.create w in
  let attr_marks = Stdlib.Buffer.create w in
  Array.iter (fun (cell : Vterm_lib.Vterm_api.row_cell) ->
    if cell.width = 0 then ()
    else begin
      Stdlib.Buffer.add_string buf cell.text;
      let a = (Obj.magic cell.attr : Grid.attr) in
      let mark = if a.underline <> UL_none then '_'
                 else if a.bold then 'B'
                 else if a.italic <> Italic_none then 'i'
                 else if a.strikethrough then 'S'
                 else '.' in
      Stdlib.Buffer.add_char attr_marks mark
    end
  ) cells;
  Printf.printf "    text: |%s|\n" (Stdlib.Buffer.contents buf);
  Printf.printf "    attr: |%s|\n" (Stdlib.Buffer.contents attr_marks)

(* Feed one SGR sequence + text + reset on its own line, then dump the
   cell attrs vterm produced. Lets us see exactly how the CSI parser
   interpreted the colon-subparam form. *)
let probe label sgr text =
  let w = 60 in
  let vt = Vterm_lib.Vterm_api.create ~backlog:10 ~fwdlog:10 ~w ~h:4
    ~wrap_mode:1 in
  let s = Printf.sprintf "\x1b[%sm%s\x1b[0m" sgr text in
  let b = Bytes.of_string s in
  Vterm_lib.Vterm_api.proc vt b ~off:0 ~len:(Bytes.length b);
  let _ = Vterm_lib.Vterm_api.sync vt in
  let _ = Vterm_lib.Vterm_api.prepare_rows vt in
  let cells = Vterm_lib.Vterm_api.get_row vt 0 in
  let a = if Array.length cells > 0
          then (Obj.magic cells.(0).attr : Grid.attr)
          else Grid.default_attr in
  let ul = ul_str a.underline in
  let fg_str = match a.fg with
    | Grid.Default -> "def"
    | Basic n -> Printf.sprintf "b%d" n
    | Color256 n -> Printf.sprintf "c%d" n
    | TrueColor (r, g, b) -> Printf.sprintf "rgb(%d,%d,%d)" r g b in
  let ul_clr_str = match a.ul with
    | Grid.Default -> "def"
    | Basic n -> Printf.sprintf "b%d" n
    | Color256 n -> Printf.sprintf "c%d" n
    | TrueColor (r, g, b) -> Printf.sprintf "rgb(%d,%d,%d)" r g b in
  Printf.printf "  %-28s SGR %-20s -> ul=%s fg=%s ul_color=%s italic=%s\n"
    label sgr ul fg_str ul_clr_str
    (match a.italic with Italic_none -> "n" | Italic_on -> "i"
                       | Italic_fraktur -> "f")

let () =
  Printf.printf "Probe of vterm CSI parser for colon-subparam SGRs:\n";
  Printf.printf "  (expected: 4:3 -> ul=c (curly), 58:5:1 -> ul_color=c1, etc.)\n\n";
  probe "single underline"     "4"              "abc";
  probe "double underline"     "21"             "abc";
  probe "italic"               "3"              "abc";
  probe "fg red 256"            "38;5;1"        "abc";
  probe "fg red 256 (colon)"    "38:5:1"        "abc";
  probe "fg RGB (semis)"        "38;2;255;0;0"  "abc";
  probe "fg RGB (colons)"       "38:2::255:0:0" "abc";
  probe "curly underline"       "4:3"           "abc";
  probe "dotted underline"      "4:4"           "abc";
  probe "dashed underline"      "4:5"           "abc";
  probe "underline reset 4:0"   "4:0"           "abc";
  probe "curly + ul red"        "4:3;58:5:1"    "abc";
  probe "curly + ul RGB orange" "4:3;58:2::255:128:0" "abc";
  probe "ul color reset"        "4;58:5:1;59"   "abc"
