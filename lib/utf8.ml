(* Codepoint classification — the single display-width authority,
   shared with the embedded terminal and glterm via the vendored
   char_width.h + cluster.h (see caml_render_cp_class in
   vterm_stubs.c). Bitmask: bits 0-3 width; 0x10 nonprintable;
   0x20 cluster trigger-extend; 0x40 regional indicator;
   0x80 pictographic. *)
external cp_class : int -> int = "caml_render_cp_class"

let class_width cl = cl land 0x0f
let class_nonprintable cl = cl land 0x10 <> 0
let class_trigger_extend cl = cl land 0x20 <> 0
let class_ri cl = cl land 0x40 <> 0
let class_pictographic cl = cl land 0x80 <> 0

let codepoint_len s i =
  if i >= String.length s then 0
  else
    let c = Char.code s.[i] in
    if c land 0x80 = 0 then 1
    else if c land 0xE0 = 0xC0 then 2
    else if c land 0xF0 = 0xE0 then 3
    else if c land 0xF8 = 0xF0 then 4
    else 1  (* invalid byte, treat as 1 *)

let decode s i =
  let len = String.length s in
  if i >= len then (0, 0)
  else
    let b0 = Char.code s.[i] in
    if b0 land 0x80 = 0 then
      (b0, 1)
    else if b0 land 0xE0 = 0xC0 && i + 1 < len then
      let cp = ((b0 land 0x1F) lsl 6)
               lor (Char.code s.[i+1] land 0x3F) in
      (cp, 2)
    else if b0 land 0xF0 = 0xE0 && i + 2 < len then
      let cp = ((b0 land 0x0F) lsl 12)
               lor ((Char.code s.[i+1] land 0x3F) lsl 6)
               lor (Char.code s.[i+2] land 0x3F) in
      (cp, 3)
    else if b0 land 0xF8 = 0xF0 && i + 3 < len then
      let cp = ((b0 land 0x07) lsl 18)
               lor ((Char.code s.[i+1] land 0x3F) lsl 12)
               lor ((Char.code s.[i+2] land 0x3F) lsl 6)
               lor (Char.code s.[i+3] land 0x3F) in
      (cp, 4)
    else
      (0xFFFD, 1)  (* replacement character for invalid *)

let codepoint_width cp =
  (* Nonprintable (controls, default-ignorables wcwidth rejects) count
     as 0 columns; everything else takes char_width's answer, which
     includes the emoji-presentation widening glterm renders with. *)
  let cl = cp_class cp in
  if class_nonprintable cl then 0 else class_width cl

let next s i =
  let len = String.length s in
  if i >= len then len
  else i + codepoint_len s i

let prev s i =
  if i <= 0 then 0
  else
    (* Walk back over continuation bytes (10xxxxxx) *)
    let j = ref (i - 1) in
    while !j > 0 && Char.code s.[!j] land 0xC0 = 0x80 do
      decr j
    done;
    !j

let byte_to_col s byte_off =
  let len = String.length s in
  let byte_off = min byte_off len in
  let col = ref 0 in
  let i = ref 0 in
  while !i < byte_off do
    let (cp, n) = decode s !i in
    col := !col + codepoint_width cp;
    i := !i + n
  done;
  !col

let col_to_byte s target_col =
  let len = String.length s in
  let col = ref 0 in
  let i = ref 0 in
  let stop = ref false in
  while !i < len && !col < target_col && not !stop do
    let (cp, n) = decode s !i in
    let w = codepoint_width cp in
    if w > 0 && !col + w > target_col then
      stop := true  (* target is in the middle of a wide char *)
    else begin
      col := !col + w;
      i := !i + n
    end
  done;
  !i

let string_width s =
  byte_to_col s (String.length s)

let encode cp =
  if cp < 0x80 then String.make 1 (Char.chr cp)
  else if cp < 0x800 then
    let b = Bytes.create 2 in
    Bytes.set b 0 (Char.chr (0xC0 lor (cp lsr 6)));
    Bytes.set b 1 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b
  else if cp < 0x10000 then
    let b = Bytes.create 3 in
    Bytes.set b 0 (Char.chr (0xE0 lor (cp lsr 12)));
    Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.set b 2 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b
  else
    let b = Bytes.create 4 in
    Bytes.set b 0 (Char.chr (0xF0 lor (cp lsr 18)));
    Bytes.set b 1 (Char.chr (0x80 lor ((cp lsr 12) land 0x3F)));
    Bytes.set b 2 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.set b 3 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string b
