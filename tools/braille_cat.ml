(* Render a file as braille characters.

   Each braille cell is a 2-wide × 4-tall dot grid (Unicode U+2800-U+28FF).
   Dot numbering:
     0 3
     1 4
     2 5
     6 7

   Usage: braille_cat [-x N] [-y N] file
     -x N  horizontal compression: N source columns per braille column (default 2)
     -y N  vertical compression: N source lines per braille row (default 4)
*)

let xcomp = ref 2
let ycomp = ref 4
let filename = ref ""

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | "-x" :: n :: rest -> xcomp := int_of_string n; parse rest
    | "-y" :: n :: rest -> ycomp := int_of_string n; parse rest
    | [f] -> filename := f
    | [] -> ()
    | _ -> Printf.eprintf "Usage: braille_cat [-x N] [-y N] file\n"; exit 1
  in
  parse args;
  if !filename = "" then begin
    Printf.eprintf "Usage: braille_cat [-x N] [-y N] file\n"; exit 1
  end

(* Read file into lines *)
let read_lines path =
  let ic = open_in path in
  let lines = ref [] in
  (try while true do
     lines := input_line ic :: !lines
   done with End_of_file -> ());
  close_in ic;
  Array.of_list (List.rev !lines)

(* Check if a character position has a visible character *)
let has_char lines row col =
  if row < 0 || row >= Array.length lines then false
  else
    let line = lines.(row) in
    col >= 0 && col < String.length line && line.[col] <> ' '

(* Encode a 2x4 grid into a braille codepoint.
   grid.(r).(c) where r=0..3, c=0..1
   Braille dot bits:
     col0: rows 0,1,2 = bits 0,1,2; row 3 = bit 6
     col1: rows 0,1,2 = bits 3,4,5; row 3 = bit 7
*)
let encode_braille grid =
  let v = ref 0 in
  for c = 0 to 1 do
    for r = 0 to 3 do
      if grid.(r).(c) then begin
        let bit = match c, r with
          | 0, 0 -> 0 | 0, 1 -> 1 | 0, 2 -> 2 | 0, 3 -> 6
          | 1, 0 -> 3 | 1, 1 -> 4 | 1, 2 -> 5 | 1, 3 -> 7
          | _ -> assert false
        in
        v := !v lor (1 lsl bit)
      end
    done
  done;
  0x2800 + !v

(* Encode a Unicode codepoint as UTF-8 *)
let utf8_of_codepoint cp =
  if cp < 0x80 then
    String.make 1 (Char.chr cp)
  else if cp < 0x800 then
    let b0 = 0xC0 lor (cp lsr 6) in
    let b1 = 0x80 lor (cp land 0x3F) in
    let s = Bytes.create 2 in
    Bytes.set s 0 (Char.chr b0);
    Bytes.set s 1 (Char.chr b1);
    Bytes.to_string s
  else if cp < 0x10000 then
    let b0 = 0xE0 lor (cp lsr 12) in
    let b1 = 0x80 lor ((cp lsr 6) land 0x3F) in
    let b2 = 0x80 lor (cp land 0x3F) in
    let s = Bytes.create 3 in
    Bytes.set s 0 (Char.chr b0);
    Bytes.set s 1 (Char.chr b1);
    Bytes.set s 2 (Char.chr b2);
    Bytes.to_string s
  else
    "?"

let () =
  let lines = read_lines !filename in
  let num_lines = Array.length lines in
  let max_cols = Array.fold_left (fun acc l -> max acc (String.length l)) 0 lines in

  let xc = !xcomp in
  let yc = !ycomp in

  (* Each braille char covers xc*2 source columns and yc source lines.
     But within each braille cell, we sample a 2x4 sub-grid.
     So we need to map 2 braille dots horizontally across xc source columns,
     and 4 braille dots vertically across yc source lines. *)

  let braille_rows = (num_lines + yc - 1) / yc in
  let braille_cols = (max_cols + xc * 2 - 1) / (xc * 2) in

  for br = 0 to braille_rows - 1 do
    for bc = 0 to braille_cols - 1 do
      let grid = Array.init 4 (fun _ -> Array.make 2 false) in
      for dr = 0 to 3 do
        for dc = 0 to 1 do
          (* This dot covers a rectangle of source characters.
             Vertically: source rows [br*yc + dr*yc/4 .. br*yc + (dr+1)*yc/4)
             Horizontally: source cols [bc*xc*2 + dc*xc .. bc*xc*2 + (dc+1)*xc) *)
          let sr_start = br * yc + dr * yc / 4 in
          let sr_end = br * yc + (dr + 1) * yc / 4 in
          let sc_start = bc * xc * 2 + dc * xc in
          let sc_end = bc * xc * 2 + (dc + 1) * xc in
          let found = ref false in
          for sr = sr_start to sr_end - 1 do
            for sc = sc_start to sc_end - 1 do
              if has_char lines sr sc then found := true
            done
          done;
          grid.(dr).(dc) <- !found
        done
      done;
      let cp = encode_braille grid in
      print_string (utf8_of_codepoint cp)
    done;
    print_char '\n'
  done
