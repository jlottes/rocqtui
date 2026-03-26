(* System clipboard integration via terminal escape sequences.
   OSC 52 for copy, bracketed paste for paste. *)

let write_raw s =
  let fd = Unix.stdout in
  ignore (Unix.write_substring fd s 0 (String.length s))

let base64_encode s =
  let tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let len = String.length s in
  let buf = Stdlib.Buffer.create (len * 4 / 3 + 4) in
  let i = ref 0 in
  while !i < len do
    let b0 = Char.code s.[!i] in
    let b1 = if !i + 1 < len then Char.code s.[!i + 1] else 0 in
    let b2 = if !i + 2 < len then Char.code s.[!i + 2] else 0 in
    let n = (b0 lsl 16) lor (b1 lsl 8) lor b2 in
    Stdlib.Buffer.add_char buf tbl.[(n lsr 18) land 63];
    Stdlib.Buffer.add_char buf tbl.[(n lsr 12) land 63];
    if !i + 1 < len then
      Stdlib.Buffer.add_char buf tbl.[(n lsr 6) land 63]
    else
      Stdlib.Buffer.add_char buf '=';
    if !i + 2 < len then
      Stdlib.Buffer.add_char buf tbl.[n land 63]
    else
      Stdlib.Buffer.add_char buf '=';
    i := !i + 3
  done;
  Stdlib.Buffer.contents buf

let copy_to_system text =
  let encoded = base64_encode text in
  write_raw (Printf.sprintf "\x1b]52;c;%s\x07" encoded)

let enable_bracketed_paste () =
  write_raw "\x1b[?2004h"

let disable_bracketed_paste () =
  write_raw "\x1b[?2004l"
