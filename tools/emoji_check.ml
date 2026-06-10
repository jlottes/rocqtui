(* Probe how vterm + Terminal renderer handle multi-codepoint emoji
   clusters (ZWJ joins, RI flag pairs, keycap, skin-tone, subdivision
   flag). Dumps the vterm_cell stream and the resulting Grid row so we
   can confirm cluster cont cells get appended to the leader's text and
   the column count stays correct. *)

open Rocqtui_lib

external setlocale : int -> string -> string = "caml_curses_setlocale"
let () = ignore (setlocale 0 "")  (* LC_ALL — char_width.h relies on wcwidth *)

let hexcode s =
  let b = Stdlib.Buffer.create 32 in
  let i = ref 0 in
  let n = String.length s in
  while !i < n do
    let c = Char.code s.[!i] in
    let cp, adv =
      if c < 0x80 then c, 1
      else if c < 0xc0 then c, 1
      else if c < 0xe0 && !i + 1 < n then
        ((c land 0x1f) lsl 6) lor (Char.code s.[!i + 1] land 0x3f), 2
      else if c < 0xf0 && !i + 2 < n then
        ((c land 0x0f) lsl 12)
        lor ((Char.code s.[!i + 1] land 0x3f) lsl 6)
        lor (Char.code s.[!i + 2] land 0x3f), 3
      else if !i + 3 < n then
        ((c land 0x07) lsl 18)
        lor ((Char.code s.[!i + 1] land 0x3f) lsl 12)
        lor ((Char.code s.[!i + 2] land 0x3f) lsl 6)
        lor (Char.code s.[!i + 3] land 0x3f), 4
      else c, 1
    in
    if Stdlib.Buffer.length b > 0 then Stdlib.Buffer.add_char b ' ';
    Stdlib.Buffer.add_string b (Printf.sprintf "U+%04X" cp);
    i := !i + adv
  done;
  Stdlib.Buffer.contents b

let probe label text =
  let w = 20 in
  let vt = Vterm_lib.Vterm_api.create ~backlog:10 ~fwdlog:10 ~w ~h:2
    ~wrap_mode:1 in
  let b = Bytes.of_string text in
  Vterm_lib.Vterm_api.proc vt b ~off:0 ~len:(Bytes.length b);
  let _ = Vterm_lib.Vterm_api.sync vt in
  let _ = Vterm_lib.Vterm_api.prepare_rows vt in
  let cells = Vterm_lib.Vterm_api.get_row vt 0 in
  Printf.printf "=== %s ===\n" label;
  Printf.printf "  input bytes: %d, codepoints: %s\n"
    (String.length text) (hexcode text);
  Printf.printf "  vterm cell stream (%d cells):\n" (Array.length cells);
  let total_w = ref 0 in
  Array.iteri (fun i (cell : Vterm_lib.Vterm_api.row_cell) ->
    Printf.printf "    [%d] %s  w=%d\n" i (hexcode cell.text) cell.width;
    total_w := !total_w + cell.width
  ) cells;
  Printf.printf "  vterm total width: %d cols\n" !total_w;
  let g = Grid.create 1 w in
  let tmp_term = () in
  ignore tmp_term;
  (* simulate Terminal.render: we re-implement the inner row loop here
     to bypass needing a Terminal handle (which owns its own vterm) *)
  let leader_gc = ref (-1) in
  let x = ref 0 in
  let col = 0 in
  Array.iter (fun (cell : Vterm_lib.Vterm_api.row_cell) ->
    let gc = col + !x in
    if cell.width = 0 then begin
      let target = if !leader_gc >= 0 then !leader_gc else gc - 1 in
      if target >= col && target < g.cols then
        Grid.append_combining g ~row:0 ~col:target ~attr:Grid.default_attr cell.text
    end else if gc < g.cols then begin
      let gc_cell = g.cells.(0).(gc) in
      gc_cell.text <- cell.text;
      gc_cell.width <- cell.width;
      gc_cell.attr <- Grid.default_attr;
      gc_cell.followers <- [];
      if cell.width = 2 && gc + 1 < g.cols then begin
        let next = g.cells.(0).(gc + 1) in
        next.text <- "";
        next.width <- 0;
        next.attr <- Grid.default_attr;
        next.followers <- []
      end;
      leader_gc := gc;
      x := !x + cell.width
    end
  ) cells;
  Printf.printf "  grid row 0 (after render):\n";
  for c = 0 to min 6 (g.cols - 1) do
    let cell = g.cells.(0).(c) in
    if cell.width > 0 || String.length cell.text > 0 || cell.followers <> [] then begin
      let combs_str = String.concat "," (List.map (fun (t, _) -> hexcode t)
        (List.rev cell.followers)) in
      Printf.printf "    col %d: text=%s w=%d followers=[%s]\n"
        c (hexcode cell.text) cell.width combs_str
    end
  done;
  Printf.printf "\n"

let () =
  (* family ZWJ sequence: 👨 ZWJ 👩 ZWJ 👧 *)
  probe "family ZWJ (man+woman+girl)"
    "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
  (* US flag: RI U + RI S *)
  probe "US flag"
    "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8";
  (* US + UK flags concatenated *)
  probe "US + UK flags"
    "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7";
  (* keycap: 1 + VS16 + combining keycap U+20E3 *)
  probe "keycap 1"
    "1\xEF\xB8\x8F\xE2\x83\xA3";
  (* skin tone modifier: waving hand + dark skin tone *)
  probe "waving hand + skin tone"
    "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBF";
  (* subdivision flag: England (black flag + tag-g b e n g + cancel) *)
  probe "England subdivision flag"
    "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xA5\xF3\xA0\x81\xAE\xF3\xA0\x81\xA7\xF3\xA0\x81\xBF";
  (* plain wide CJK + combining mark (should also work via leader_gc) *)
  probe "CJK + combining voiced mark"
    "\xE3\x82\xB5\xE3\x82\x99";
  (* mixed run: ASCII text then a cluster then more ASCII — check that
     leader_gc reset cleanly between runs *)
  probe "ASCII + family + ASCII"
    "hi \xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7 ok";
  ()
