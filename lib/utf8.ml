(* Codepoint classification — the single display-width authority,
   shared with the embedded terminal and glterm via the vendored
   char_width.h + cluster.h + emoji_props.h (see caml_render_cp_class
   in vterm_stubs.c). Bitmask: bits 0-3 width; 0x10 nonprintable;
   0x20 cluster trigger-extend; 0x40 regional indicator;
   0x80 Extended_Pictographic; 0x100 emoji_vs16_base;
   0x200 emoji_modifier_base; 0x400 emoji_presentation. *)
external cp_class : int -> int = "caml_render_cp_class"

let class_width cl = cl land 0x0f
let class_nonprintable cl = cl land 0x10 <> 0
let class_trigger_extend cl = cl land 0x20 <> 0
let class_ri cl = cl land 0x40 <> 0
let class_pictographic cl = cl land 0x80 <> 0
let class_vs16_base cl = cl land 0x100 <> 0
let class_modifier_base cl = cl land 0x200 <> 0
let class_emoji_presentation cl = cl land 0x400 <> 0

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

(* --- Display-cell walker --------------------------------------------

   Segments a string into display cells the way the terminal stack
   does: an OCaml port of glterm's cluster_step + cluster_gate
   (term.c), driven by the same vendored Unicode predicates via
   [cp_class]. A display cell is a leader (one codepoint, or a
   cluster's worth) plus zero or more zero-width followers.

   Triggers always absorb into the leader (codepoints must
   round-trip); only the WIDTH is gated:
   - VS-16 widens to 2 only on emoji_vs16_base bases;
   - VS-15 narrows to 1 on vs16_base or EP=Yes bases;
   - skin tones widen to 2 only on emoji_modifier_base bases;
   - ZWJ, bare keycap (U+20E3), and tag characters never change it;
   - an RI pair is one width-2 cell; a lone RI is width 2 by itself.
   Presentation (mono vs color) is the rendering terminal's concern —
   we only need columns.

   Unlike vterm, nonprintables are skipped entirely (put_str
   semantics); a skipped codepoint kills clustering, like a control
   byte does in the terminal. *)

type display_cell = {
  cell_off : int;                     (* leader start byte *)
  leader_len : int;                   (* leader byte length *)
  cell_width : int;                   (* 1 or 2 *)
  cell_followers : (int * int) list;  (* (off, len) per zero-width
                                         follower, oldest first *)
}

(* Mirrors CLUSTER_MAX_LEN in cluster.h: clusters longer than this
   stop absorbing and the trigger falls through. *)
let cluster_max_len = 16

type cluster_state = Dead | Leader | Await_second_ri | Await_pict | In_cluster

(* cluster_gate (term.c), width half only. [base_cl] classifies the
   cluster's first codepoint. *)
let gated_width base_cl cp old_w =
  if cp = 0xFE0F then (if class_vs16_base base_cl then 2 else old_w)
  else if cp = 0xFE0E then
    (if class_vs16_base base_cl || class_emoji_presentation base_cl
     then 1 else old_w)
  else if cp >= 0x1F3FB && cp <= 0x1F3FF then
    (if class_modifier_base base_cl then 2 else old_w)
  else old_w

(* Returns (orphans, cells): zero-width codepoints arriving before any
   cell exists (callers attach them to the cell left of the write
   position), and the display cells in order. *)
let display_cells s =
  let len = String.length s in
  let orphans = ref [] and cells = ref [] in
  (* cell under construction; fields of the mutable accumulator *)
  let b_off = ref 0 and b_leader_end = ref 0 and b_width = ref 0 in
  let b_followers = ref [] and b_ncps = ref 0 and b_cl = ref 0 in
  let have = ref false in
  let flush () =
    if !have then begin
      cells := { cell_off = !b_off;
                 leader_len = !b_leader_end - !b_off;
                 cell_width = !b_width;
                 cell_followers = List.rev !b_followers } :: !cells;
      have := false
    end
  in
  let state = ref Dead in
  let i = ref 0 in
  while !i < len do
    let (cp, n) = decode s !i in
    let cl = cp_class cp in
    let trig = class_trigger_extend cl in
    let ri = class_ri cl in
    let pict = class_pictographic cl in
    let absorb width' state' =
      b_leader_end := !i + n;
      b_width := width';
      incr b_ncps;
      state := state'
    in
    let absorbed =
      !have && !b_ncps < cluster_max_len
      && (match !state with
          | Leader | In_cluster when trig ->
            absorb (gated_width !b_cl cp !b_width)
              (if cp = 0x200D then Await_pict else In_cluster);
            true
          | Await_second_ri when ri ->
            absorb 2 Dead;  (* flag pair: one width-2 cell *)
            true
          | Await_pict when pict ->
            absorb !b_width In_cluster;  (* ZWJ continuation *)
            true
          | _ -> false)
    in
    if not absorbed then begin
      if class_nonprintable cl then state := Dead
      else begin
        let w = class_width cl in
        if w = 0 then begin
          (* zero-width, couldn't extend a cluster: follower of the
             current cell, or orphan if there is none *)
          if !have then b_followers := (!i, n) :: !b_followers
          else orphans := (!i, n) :: !orphans;
          state := Dead
        end else begin
          flush ();
          b_off := !i; b_leader_end := !i + n; b_width := w;
          b_followers := []; b_ncps := 1; b_cl := cl; have := true;
          state := if ri then Await_second_ri else Leader
        end
      end
    end;
    i := !i + n
  done;
  flush ();
  (List.rev !orphans, List.rev !cells)

(* Column math is display-cell based so editor cursor positions agree
   with rendered widths. A byte offset inside a cell (between cluster
   codepoints, or before a follower) counts as past the cell. *)
let byte_to_col s byte_off =
  let byte_off = min byte_off (String.length s) in
  let (_, cells) = display_cells s in
  let rec go col = function
    | [] -> col
    | dc :: rest ->
      if dc.cell_off >= byte_off then col
      else go (col + dc.cell_width) rest
  in
  go 0 cells

(* Byte offset of the display cell at [target_col]; cell boundaries
   only, so the result never lands between a cluster's codepoints or
   splits a cell from its followers. A column inside a wide cell maps
   to that cell's start. *)
let col_to_byte s target_col =
  let (_, cells) = display_cells s in
  let rec go col = function
    | [] -> String.length s
    | dc :: rest ->
      if col >= target_col || col + dc.cell_width > target_col then
        dc.cell_off
      else go (col + dc.cell_width) rest
  in
  go 0 cells

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
