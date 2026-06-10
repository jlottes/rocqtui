(* Embedded-terminal transparency: bytes fed to a vterm, rendered into
   a Grid and re-emitted as ANSI, must reproduce the same display when
   fed to a second vterm. vterm is glterm's engine, so vterm B models
   the outer terminal rocqtui runs in.

       bytes -> vterm A -> Terminal.render_vterm -> grid A
                                                      | Grid.emit_all
       grid B <- Terminal.render_vterm <- vterm B <- bytes'

   Pass = grid A and grid B are cell-for-cell equal (text, width,
   attr, followers). This is what makes the forced-cluster-break emit
   rules observable: without them, segmentation the source stream
   created with attr-invisible SGRs fuses in vterm B. *)

open Rocqtui_lib

external setlocale : int -> string -> string = "caml_curses_setlocale"

let w = 20
let h = 4

let make_vterm () =
  Vterm_lib.Vterm_api.create ~backlog:(64 * 1024) ~fwdlog:(64 * 1024)
    ~w ~h ~wrap_mode:1

let render_to_grid vterm =
  let grid = Grid.create h w in
  Terminal.render_vterm vterm grid ~row:0 ~col:0 ~width:w ~height:h;
  grid

let hex s =
  String.concat "" (List.map (fun c -> Printf.sprintf "%02x" (Char.code c))
    (List.init (String.length s) (String.get s)))

let attr_str (a : Grid.attr) =
  let color = function
    | Grid.Default -> "d" | Grid.Basic n -> Printf.sprintf "b%d" n
    | Grid.Color256 n -> Printf.sprintf "c%d" n
    | Grid.TrueColor (r,g,b) -> Printf.sprintf "t%d,%d,%d" r g b
  in
  Printf.sprintf "fg=%s bg=%s%s%s" (color a.fg) (color a.bg)
    (if a.bold then " bold" else "")
    (if a.reverse then " rev" else "")

let cell_str (c : Grid.cell) =
  Printf.sprintf "%S(%s) w=%d %s fol=[%s]" c.text (hex c.text) c.width
    (attr_str c.attr)
    (String.concat "; "
       (List.map (fun (t, a) -> Printf.sprintf "%S %s" t (attr_str a))
          (List.rev c.followers)))

let fails = ref 0

let check name bytes =
  let va = make_vterm () in
  Vterm_lib.Vterm_api.proc va (Bytes.of_string bytes)
    ~off:0 ~len:(String.length bytes);
  ignore (Vterm_lib.Vterm_api.sync va);
  let ga = render_to_grid va in
  let buf = Stdlib.Buffer.create 1024 in
  Grid.emit_all ga buf;
  let emitted = Stdlib.Buffer.contents buf in
  let vb = make_vterm () in
  Vterm_lib.Vterm_api.proc vb (Bytes.of_string emitted)
    ~off:0 ~len:(String.length emitted);
  ignore (Vterm_lib.Vterm_api.sync vb);
  let gb = render_to_grid vb in
  let ok = ref true in
  for r = 0 to h - 1 do
    for c = 0 to w - 1 do
      let ca = ga.cells.(r).(c) and cb = gb.cells.(r).(c) in
      if not (ca.text = cb.text && ca.width = cb.width
              && ca.attr = cb.attr && ca.followers = cb.followers) then begin
        if !ok then begin
          Printf.printf "FAIL: %s\n  emitted: %s\n" name
            (String.concat ""
               (List.map (fun ch ->
                  if ch = '\x1b' then "\\e"
                  else if Char.code ch < 32 then
                    Printf.sprintf "\\x%02x" (Char.code ch)
                  else String.make 1 ch)
                  (List.init (String.length emitted) (String.get emitted))));
          ok := false; incr fails
        end;
        Printf.printf "  (%d,%d): A %s\n         B %s\n"
          r c (cell_str ca) (cell_str cb)
      end
    done
  done;
  if !ok then Printf.printf "OK: %s\n" name

let () =
  ignore (setlocale 0 "");
  (* plain text and ordinary SGR transitions *)
  check "plain text" "hello world";
  check "sgr colors" "a\x1b[31mred\x1b[44mblue-bg\x1b[0mz";
  check "bold reverse" "\x1b[1mB\x1b[7mR\x1b[0mn";
  (* combining marks: same attr, and divergent attr per mark *)
  check "combining same attr" "e\xcc\x81x";
  check "combining divergent attr" "e\x1b[32m\xcc\x81\x1b[0mx";
  check "two divergent marks" "o\x1b[31m\xcc\x81\x1b[34m\xcc\xa7\x1b[0m";
  (* clusters delivered whole: contiguous bytes re-cluster identically *)
  check "vs16 emoji" "\xe2\x9c\x94\xef\xb8\x8f";          (* check+VS16 *)
  check "vs15 text" "\xe2\x9a\xa1\xef\xb8\x8e";           (* voltage+VS15 *)
  check "zwj family"
    "\xf0\x9f\x91\xa8\xe2\x80\x8d\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7";
  check "ri flag pair" "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8";
  check "lone ri" "\xf0\x9f\x87\xba x";
  check "keycap full" "1\xef\xb8\x8f\xe2\x83\xa3";        (* 1+VS16+20E3 *)
  check "keycap bare" "1\xe2\x83\xa3";
  check "skin tone" "\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd";   (* thumbs+tone *)
  (* attr-invisible splits: the forced-break rules must reproduce the
     source segmentation in vterm B *)
  check "noop-sgr split vs16" "\xe2\x9c\x94\x1b[39m\xef\xb8\x8f";
  check "noop-sgr split ri pair"
    "\xf0\x9f\x87\xba\x1b[39m\xf0\x9f\x87\xb8";
  check "noop-sgr split zwj"
    "\xf0\x9f\x91\xa8\xe2\x80\x8d\x1b[39m\xf0\x9f\x91\xa9";
  check "colored-sgr split vs16 (natural break)"
    "\xe2\x9c\x94\x1b[35m\xef\xb8\x8f\x1b[0mx";
  (* geometry *)
  check "tab" "a\tb";
  check "wide char at right edge"
    (String.make (w - 1) 'x' ^ "\xe6\xbc\xa2");           (* CJK at edge *)
  check "cluster at right edge"
    (String.make (w - 2) 'x' ^ "\xf0\x9f\x87\xba\xf0\x9f\x87\xb8");
  check "followers on wide leader"
    "\xe6\xbc\xa2\x1b[31m\xcc\x81\x1b[0mx";               (* CJK + red acute *)
  check "multi line" "line1\r\nli\xe2\x9c\x94ne2\r\n\x1b[33mthree";
  if !fails > 0 then begin
    Printf.printf "%d transparency case(s) failed\n" !fails;
    exit 1
  end;
  print_endline "OK: all transparency cases passed"
