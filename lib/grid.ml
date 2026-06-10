(* Cell grid for terminal rendering.
   Each cell holds a UTF-8 string (possibly with combining characters),
   a display width, and visual attributes. *)

type color =
  | Default
  | Basic of int          (* 0..15 — full 16-color palette *)
  | Color256 of int       (* 0..255 *)
  | TrueColor of int * int * int

type underline_style =
  | UL_none
  | UL_single
  | UL_double
  | UL_curly
  | UL_dotted
  | UL_dashed

type italic_style = Italic_none | Italic_on | Italic_fraktur
type blink_style  = Blink_none  | Blink_slow | Blink_rapid
type frame_style  = Frame_none  | Frame_box  | Frame_circle
type script_style = Script_none | Script_super | Script_sub

type attr = {
  fg : color;
  bg : color;
  ul : color;
  bold : bool;
  dim : bool;
  italic : italic_style;
  underline : underline_style;
  reverse : bool;
  strikethrough : bool;
  conceal : bool;
  overline : bool;
  blink : blink_style;
  frame : frame_style;
  script : script_style;
  font : int;
  spacing : bool;
}

let default_attr = {
  fg = Default; bg = Default; ul = Default;
  bold = false; dim = false;
  italic = Italic_none;
  underline = UL_none;
  reverse = false;
  strikethrough = false;
  conceal = false;
  overline = false;
  blink = Blink_none;
  frame = Frame_none;
  script = Script_none;
  font = 0;
  spacing = false;
}

type cell = {
  mutable text : string;
  mutable width : int;    (* 0 = continuation of wide char, 1 = normal, 2 = wide *)
  mutable attr : attr;
  (* Zero-width codepoints following the leader, each with its own
     attr, newest first (reversed at emit). Kept structurally distinct
     from [text] even when the attr matches the leader's: the
     boundary is what lets emit reproduce the terminal's cluster
     segmentation (see emit_cell_payload). [text] holds only the
     leader's codepoints (a cluster when more than one). *)
  mutable followers : (string * attr) list;
}

let empty_cell () =
  { text = " "; width = 1; attr = default_attr; followers = [] }

type t = {
  mutable cells : cell array array;
  mutable rows : int;
  mutable cols : int;
}

type rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

let create rows cols =
  let cells = Array.init rows (fun _ ->
    Array.init cols (fun _ -> empty_cell ())
  ) in
  { cells; rows; cols }

let resize g rows cols =
  let new_cells = Array.init rows (fun r ->
    Array.init cols (fun c ->
      if r < g.rows && c < g.cols then g.cells.(r).(c)
      else empty_cell ()
    )
  ) in
  g.cells <- new_cells;
  g.rows <- rows;
  g.cols <- cols

let clear ?(attr=default_attr) g =
  for r = 0 to g.rows - 1 do
    for c = 0 to g.cols - 1 do
      let cell = g.cells.(r).(c) in
      cell.text <- " ";
      cell.width <- 1;
      cell.attr <- attr;
      cell.followers <- []
    done
  done

let clear_region g ~row ~col ~height ~width ~attr =
  for r = row to min (row + height - 1) (g.rows - 1) do
    for c = col to min (col + width - 1) (g.cols - 1) do
      let cell = g.cells.(r).(c) in
      cell.text <- " ";
      cell.width <- 1;
      cell.attr <- attr;
      cell.followers <- []
    done
  done

(* Raw libc wcwidth. Layout in this module goes through Utf8.cp_class
   (the vendored char_width + cluster classification) instead; this
   binding remains for external consumers (glterm's fontvis). *)
external wcwidth : int -> int = "caml_wcwidth"

(* Decode one UTF-8 codepoint from a string at byte offset.
   Returns (codepoint, bytes_consumed). *)
let decode_utf8 s i =
  let len = String.length s in
  if i >= len then (0, 0)
  else
    let b0 = Char.code s.[i] in
    if b0 < 0x80 then (b0, 1)
    else if b0 < 0xC0 then (0xFFFD, 1)  (* invalid *)
    else if b0 < 0xE0 then begin
      if i + 1 >= len then (0xFFFD, 1)
      else
        let b1 = Char.code s.[i+1] in
        ((b0 land 0x1F) lsl 6) lor (b1 land 0x3F), 2
    end
    else if b0 < 0xF0 then begin
      if i + 2 >= len then (0xFFFD, 1)
      else
        let b1 = Char.code s.[i+1] in
        let b2 = Char.code s.[i+2] in
        ((b0 land 0x0F) lsl 12) lor ((b1 land 0x3F) lsl 6)
        lor (b2 land 0x3F), 3
    end
    else begin
      if i + 3 >= len then (0xFFFD, 1)
      else
        let b1 = Char.code s.[i+1] in
        let b2 = Char.code s.[i+2] in
        let b3 = Char.code s.[i+3] in
        ((b0 land 0x07) lsl 18) lor ((b1 land 0x3F) lsl 12)
        lor ((b2 land 0x3F) lsl 6) lor (b3 land 0x3F), 4
    end

(* Place a cell with a caller-supplied width (a cluster leader's width
   is a property of the whole sequence, not its first codepoint).
   Marks the continuation cell for width 2 and clears any wide char
   this cell overlaps. *)
let set_cell_w g ~row ~col text attr ~w =
  if row < 0 || row >= g.rows || col < 0 || col >= g.cols then ()
  else begin
    (* If this cell is a continuation of a wide char, clear the base cell *)
    if col > 0 && g.cells.(row).(col).width = 0 then begin
      g.cells.(row).(col - 1).text <- " ";
      g.cells.(row).(col - 1).width <- 1
    end;
    let cell = g.cells.(row).(col) in
    cell.text <- text;
    cell.attr <- attr;
    cell.followers <- [];
    cell.width <- (if w = 2 then 2 else 1);
    (* If wide char, mark continuation cell *)
    if w = 2 && col + 1 < g.cols then begin
      let next = g.cells.(row).(col + 1) in
      (* If next cell is a base of a wide char, clear it *)
      if next.width = 2 && col + 2 < g.cols then begin
        g.cells.(row).(col + 2).width <- 1;
        g.cells.(row).(col + 2).text <- " "
      end;
      next.text <- "";
      next.width <- 0;
      next.attr <- attr
    end
  end

(* Set a single cell; width derived from the first codepoint. *)
let set_cell g ~row ~col text attr =
  let (cp, _) = decode_utf8 text 0 in
  let w = Utf8.class_width (Utf8.cp_class cp) in
  set_cell_w g ~row ~col text attr ~w

(* Append a zero-width codepoint as a follower of the cell at
   (row, col), with its own attr ([?attr] defaults to the cell's).
   Always a distinct follower entry, never folded into [cell.text]:
   the leader/follower boundary is load-bearing — emit uses it to
   reproduce the source terminal's cluster segmentation. *)
let append_combining g ~row ~col ?attr text =
  if row >= 0 && row < g.rows && col >= 0 && col < g.cols then begin
    let cell = g.cells.(row).(col) in
    let a = match attr with Some a -> a | None -> cell.attr in
    cell.followers <- (text, a) :: cell.followers
  end

(* Write a UTF-8 string starting at (row, col), one display cell at a
   time (Utf8.display_cells — the cluster-aware segmentation shared
   with the terminal stack). Returns the number of columns consumed. *)
let put_str g ~row ~col s attr =
  if row < 0 || row >= g.rows then 0
  else begin
    let (orphans, dcells) = Utf8.display_cells s in
    (* Zero-width codepoints before any cell attach to the cell left
       of the write position. *)
    if col > 0 then
      List.iter (fun (off, len) ->
        append_combining g ~row ~col:(col - 1) (String.sub s off len)
      ) orphans;
    let c = ref col in
    List.iter (fun (dc : Utf8.display_cell) ->
      if !c < g.cols then begin
        let w = dc.cell_width in
        if !c >= 0 && !c + w - 1 < g.cols then begin
          set_cell_w g ~row ~col:!c
            (String.sub s dc.cell_off dc.leader_len) attr ~w;
          List.iter (fun (off, len) ->
            append_combining g ~row ~col:!c (String.sub s off len)
          ) dc.cell_followers
        end;
        c := !c + w
      end
    ) dcells;
    !c - col
  end

(* Fill a row region with a character. *)
let fill g ~row ~col ~width ch attr =
  let s = String.make 1 ch in
  for c = col to min (col + width - 1) (g.cols - 1) do
    if c >= 0 && c < g.cols && row >= 0 && row < g.rows then begin
      let cell = g.cells.(row).(c) in
      cell.text <- s;
      cell.width <- 1;
      cell.attr <- attr;
      cell.followers <- []
    end
  done

(* Change attributes of a row region without touching text. Resets followers:
   chgat is meant to recolor the column, and we don't want lingering followers
   with stale attrs to override that. *)
let chgat g ~row ~col ~width attr =
  if row >= 0 && row < g.rows then
    for c = max 0 col to min (col + width - 1) (g.cols - 1) do
      let cell = g.cells.(row).(c) in
      cell.attr <- attr;
      cell.followers <- []
    done

(* Overlay just the underline style and underline color on a row region,
   leaving every other attribute slot (fg/bg/bold/italic/...) alone. *)
let set_underline g ~row ~col ~width ~style ~color =
  if row >= 0 && row < g.rows then
    for c = max 0 col to min (col + width - 1) (g.cols - 1) do
      let cell = g.cells.(row).(c) in
      cell.attr <- { cell.attr with underline = style; ul = color }
    done

(* --- Rect-aware drawing primitives --- *)

(* All [_in_rect] functions take rect-relative coordinates and clip
   writes to [rect]. Cells outside the rect (including those past the
   right edge of a wide character) are silently skipped. Use these
   when the caller has a pane / panel / overlay rect and doesn't want
   to bleed into neighbours. *)

let put_str_in_rect g rect ~row ~col s attr =
  if row < 0 || row >= rect.height then 0
  else
    let abs_row = rect.row + row in
    if abs_row < 0 || abs_row >= g.rows then 0
    else begin
      let start = rect.col + col in
      let stop_col = min (rect.col + rect.width) g.cols in
      let left_bound = max 0 rect.col in
      let (orphans, dcells) = Utf8.display_cells s in
      if start > left_bound then
        List.iter (fun (off, len) ->
          append_combining g ~row:abs_row ~col:(start - 1)
            (String.sub s off len)
        ) orphans;
      let c = ref start in
      List.iter (fun (dc : Utf8.display_cell) ->
        if !c < stop_col then begin
          let w = dc.cell_width in
          if !c >= left_bound && !c + w - 1 < stop_col then begin
            set_cell_w g ~row:abs_row ~col:!c
              (String.sub s dc.cell_off dc.leader_len) attr ~w;
            List.iter (fun (off, len) ->
              append_combining g ~row:abs_row ~col:!c
                (String.sub s off len)
            ) dc.cell_followers
          end;
          c := !c + w
        end
      ) dcells;
      !c - start
    end

let set_cell_in_rect g rect ~row ~col text attr =
  if row >= 0 && row < rect.height
     && col >= 0 && col < rect.width then
    set_cell g ~row:(rect.row + row) ~col:(rect.col + col) text attr

let fill_in_rect g rect ~row ~col ~width ch attr =
  if row >= 0 && row < rect.height then
    let abs_row = rect.row + row in
    let abs_col_start = max (rect.col + col) rect.col in
    let abs_col_end =
      min (rect.col + col + width - 1) (rect.col + rect.width - 1) in
    if abs_col_start <= abs_col_end then
      fill g ~row:abs_row ~col:abs_col_start
        ~width:(abs_col_end - abs_col_start + 1) ch attr

let chgat_in_rect g rect ~row ~col ~width attr =
  if row >= 0 && row < rect.height then
    let abs_row = rect.row + row in
    let abs_col_start = max (rect.col + col) rect.col in
    let abs_col_end =
      min (rect.col + col + width - 1) (rect.col + rect.width - 1) in
    if abs_col_start <= abs_col_end then
      chgat g ~row:abs_row ~col:abs_col_start
        ~width:(abs_col_end - abs_col_start + 1) attr

let set_underline_in_rect g rect ~row ~col ~width ~style ~color =
  if row >= 0 && row < rect.height then
    let abs_row = rect.row + row in
    let abs_col_start = max (rect.col + col) rect.col in
    let abs_col_end =
      min (rect.col + col + width - 1) (rect.col + rect.width - 1) in
    if abs_col_start <= abs_col_end then
      set_underline g ~row:abs_row ~col:abs_col_start
        ~width:(abs_col_end - abs_col_start + 1) ~style ~color

let clear_rect g rect ~attr =
  clear_region g ~row:rect.row ~col:rect.col
    ~height:rect.height ~width:rect.width ~attr

(* Compare two cells for equality. Polymorphic [=] hits a pointer-equality
   shortcut when attr records are shared (the common case — cells with the
   same rendition share the same attr block). *)
let cell_eq a b =
  a.text = b.text && a.width = b.width && a.attr = b.attr
  && a.followers = b.followers

(* Copy contents of src into dst *)
let copy ~src ~dst =
  let rows = min src.rows dst.rows in
  let cols = min src.cols dst.cols in
  for r = 0 to rows - 1 do
    for c = 0 to cols - 1 do
      let s = src.cells.(r).(c) in
      let d = dst.cells.(r).(c) in
      d.text <- s.text;
      d.width <- s.width;
      d.attr <- s.attr;
      d.followers <- s.followers
    done
  done

(* --- ANSI output --- *)

let sgr_of_color is_fg = function
  | Default -> if is_fg then "39" else "49"
  | Basic n ->
    if is_fg then
      (if n < 8 then string_of_int (30 + n) else string_of_int (90 + n - 8))
    else
      (if n < 8 then string_of_int (40 + n) else string_of_int (100 + n - 8))
  | Color256 n ->
    if is_fg then Printf.sprintf "38;5;%d" n
    else Printf.sprintf "48;5;%d" n
  | TrueColor (r, g, b) ->
    if is_fg then Printf.sprintf "38;2;%d;%d;%d" r g b
    else Printf.sprintf "48;2;%d;%d;%d" r g b

(* Underline color uses SGR 58 (256-color via 58;5;n, RGB via 58;2;r;g;b)
   and SGR 59 for reset. There is no 16-color variant of SGR 58, so we
   promote [Basic n] into the first 16 entries of the 256-color palette,
   which match the 16-color palette by convention. *)
let sgr_of_ul_color = function
  | Default -> "59"
  | Basic n -> Printf.sprintf "58;5;%d" n
  | Color256 n -> Printf.sprintf "58;5;%d" n
  | TrueColor (r, g, b) -> Printf.sprintf "58;2;%d;%d;%d" r g b

(* Per-slot "turn on" SGRs. None means the slot is at its default state
   (off / none / 0) — no SGR needed to set it from a fresh-reset baseline.
   Curly / dotted / dashed underline use the colon-syntax sub-parameter
   form; there is no semicolon-only fallback for these. *)
let sgr_italic_on = function
  | Italic_none -> None
  | Italic_on -> Some "3"
  | Italic_fraktur -> Some "20"

let sgr_underline_on = function
  | UL_none -> None
  | UL_single -> Some "4"
  | UL_double -> Some "21"
  | UL_curly -> Some "4:3"
  | UL_dotted -> Some "4:4"
  | UL_dashed -> Some "4:5"

let sgr_blink_on = function
  | Blink_none -> None
  | Blink_slow -> Some "5"
  | Blink_rapid -> Some "6"

let sgr_frame_on = function
  | Frame_none -> None
  | Frame_box -> Some "51"
  | Frame_circle -> Some "52"

let sgr_script_on = function
  | Script_none -> None
  | Script_super -> Some "73"
  | Script_sub -> Some "74"

let sgr_font_on n =
  if n <= 0 then None
  else if n <= 9 then Some (string_of_int (10 + n))      (* SGR 11..19, xterm-compat *)
  else if n <= 255 then Some (Printf.sprintf "10:%d" n)  (* SGR 10:n, slots 10..255 *)
  else None

(* Workaround for mosh dropping SGR 2 (dim): substitute a darker fg.
   Default and palette fgs collapse to a fixed mid-gray since we can't
   introspect the user's terminal palette; TrueColor scales properly. *)
let mosh_dim_color = function
  | Default | Basic _ | Color256 _ -> Color256 244
  | TrueColor (r, g, b) ->
    let scale x = (x * 55) / 100 in
    TrueColor (scale r, scale g, scale b)

let effective_attr attr =
  if attr.dim && Mosh.is_active () then
    { attr with dim = false; fg = mosh_dim_color attr.fg }
  else attr

(* Emit SGR sequence for an attribute change.

   Strategy: if any slot transitioned to its "off" state we emit a full
   reset (\e[0m) and re-emit everything that's on. Otherwise we emit
   only the deltas. Reset-and-rebuild is more verbose but avoids the
   tangle of off-codes that share bits — e.g. SGR 22 turns off both
   bold and dim. *)
let emit_attr buf prev_attr attr =
  let prev_attr = effective_attr prev_attr in
  let attr = effective_attr attr in
  if prev_attr = attr then ()
  else begin
    let parts = ref [] in
    let push s = parts := s :: !parts in
    let push_opt = function Some s -> push s | None -> () in
    (* Any slot transitioning to its "off" state requires a reset *)
    let needs_reset =
      (prev_attr.bold && not attr.bold)
      || (prev_attr.dim && not attr.dim)
      || (prev_attr.reverse && not attr.reverse)
      || (prev_attr.strikethrough && not attr.strikethrough)
      || (prev_attr.conceal && not attr.conceal)
      || (prev_attr.overline && not attr.overline)
      || (prev_attr.spacing && not attr.spacing)
      || (prev_attr.italic <> Italic_none && attr.italic = Italic_none)
      || (prev_attr.underline <> UL_none && attr.underline = UL_none)
      || (prev_attr.blink <> Blink_none && attr.blink = Blink_none)
      || (prev_attr.frame <> Frame_none && attr.frame = Frame_none)
      || (prev_attr.script <> Script_none && attr.script = Script_none)
      || (prev_attr.font <> 0 && attr.font = 0)
    in
    if needs_reset then begin
      push "0";
      if attr.bold then push "1";
      if attr.dim then push "2";
      push_opt (sgr_italic_on attr.italic);
      push_opt (sgr_underline_on attr.underline);
      if attr.reverse then push "7";
      if attr.conceal then push "8";
      if attr.strikethrough then push "9";
      push_opt (sgr_blink_on attr.blink);
      push_opt (sgr_frame_on attr.frame);
      if attr.overline then push "53";
      push_opt (sgr_script_on attr.script);
      push_opt (sgr_font_on attr.font);
      if attr.spacing then push "26";
      if attr.fg <> Default then push (sgr_of_color true attr.fg);
      if attr.bg <> Default then push (sgr_of_color false attr.bg);
      if attr.ul <> Default then push (sgr_of_ul_color attr.ul);
    end else begin
      if attr.bold && not prev_attr.bold then push "1";
      if attr.dim && not prev_attr.dim then push "2";
      if attr.italic <> prev_attr.italic then
        push_opt (sgr_italic_on attr.italic);
      if attr.underline <> prev_attr.underline then
        push_opt (sgr_underline_on attr.underline);
      if attr.reverse && not prev_attr.reverse then push "7";
      if attr.conceal && not prev_attr.conceal then push "8";
      if attr.strikethrough && not prev_attr.strikethrough then push "9";
      if attr.blink <> prev_attr.blink then
        push_opt (sgr_blink_on attr.blink);
      if attr.frame <> prev_attr.frame then
        push_opt (sgr_frame_on attr.frame);
      if attr.overline && not prev_attr.overline then push "53";
      if attr.script <> prev_attr.script then
        push_opt (sgr_script_on attr.script);
      if attr.font <> prev_attr.font then
        push_opt (sgr_font_on attr.font);
      if attr.spacing && not prev_attr.spacing then push "26";
      if attr.fg <> prev_attr.fg then push (sgr_of_color true attr.fg);
      if attr.bg <> prev_attr.bg then push (sgr_of_color false attr.bg);
      if attr.ul <> prev_attr.ul then push (sgr_of_ul_color attr.ul);
    end;
    if !parts <> [] then begin
      Stdlib.Buffer.add_string buf "\x1b[";
      Stdlib.Buffer.add_string buf (String.concat ";" (List.rev !parts));
      Stdlib.Buffer.add_char buf 'm'
    end
  end

(* Forced cluster break: an SGR command that changes no attribute
   (re-asserts the current effective fg). Any control byte resets the
   receiving terminal's cluster parser (term.c proc: cluster_state :=
   CPS_DEAD on non-graphic bytes), so this reproduces a segmentation
   boundary the source terminal had — without disturbing attrs. *)
let emit_forced_break buf cur_attr =
  Stdlib.Buffer.add_string buf "\x1b[";
  Stdlib.Buffer.add_string buf
    (sgr_of_color true (effective_attr !cur_attr).fg);
  Stdlib.Buffer.add_char buf 'm'

(* Cross-cell cluster hazards. Cells the source terminal kept separate
   (an attr-invisible SGR or cursor event between them) must not fuse
   in the receiving terminal when emitted contiguously. After each
   cell, record whether its trailing codepoint leaves the receiver's
   cluster parser able to absorb the next cell's leader. *)
type emit_hazard =
  | Hazard_none
  | Hazard_lone_ri  (* cell was a single regional indicator: a
                       following RI leader would pair into a flag *)
  | Hazard_zwj      (* last codepoint emitted was ZWJ: a following
                       pictographic leader would join the cluster *)

let last_cp s =
  if s = "" then 0
  else fst (decode_utf8 s (Utf8.prev s (String.length s)))

let hazard_of_cell cell =
  match cell.followers with
  | (text, _) :: _ ->
    if last_cp text = 0x200D then Hazard_zwj else Hazard_none
  | [] ->
    if last_cp cell.text = 0x200D then Hazard_zwj
    else
      let (cp, n) = decode_utf8 cell.text 0 in
      if n = String.length cell.text
         && Utf8.class_ri (Utf8.cp_class cp) then Hazard_lone_ri
      else Hazard_none

(* Emit a cell's payload: leader text under its attr, then each
   follower with its own SGR transition. [cur_attr] is updated to the
   trailing attr so callers keep diffing from there; [hazard] carries
   cluster-boundary state between contiguously emitted cells (callers
   reset it to Hazard_none whenever they reposition the cursor — a
   cursor move already resets the receiver's cluster parser).

   Forced breaks fire in two cold places (real traffic never needs
   them — they reproduce splits that only an attr-invisible event in
   the source stream can create):
   - before a follower whose first codepoint is a cluster trigger or
     RI and whose attr equals the running attr (the source terminal
     split there; an equal attr emits no SGR, so force one);
   - between cells when the previous cell's hazard pairs with this
     leader (lone RI then RI; trailing ZWJ then pictographic). *)
let emit_cell_payload buf cur_attr hazard cell =
  let joins =
    match !hazard with
    | Hazard_none -> false
    | Hazard_lone_ri ->
      Utf8.class_ri (Utf8.cp_class (fst (decode_utf8 cell.text 0)))
    | Hazard_zwj ->
      Utf8.class_pictographic
        (Utf8.cp_class (fst (decode_utf8 cell.text 0)))
  in
  if joins && effective_attr cell.attr = effective_attr !cur_attr then
    emit_forced_break buf cur_attr;
  emit_attr buf !cur_attr cell.attr;
  cur_attr := cell.attr;
  Stdlib.Buffer.add_string buf cell.text;
  (* Presentation disambiguation: kitty widens bare EP=No modifier
     bases (☝ ✌ ⛹ ✍ 🏋 🏌 🕴 🕵 🖐) that the prescription — and
     glterm, glibc, iTerm2 — keep narrow. An explicit VS-15 pins
     narrow text presentation everywhere kitty included, and is a
     rendering no-op in terminals that already agree. Only a single
     bare codepoint qualifies: clusters already carry their own VS.
     (The 3-byte guard skips ASCII/Latin cells without classifying:
     all nine codepoints are 3-4 bytes in UTF-8.) *)
  if cell.width = 1 && String.length cell.text >= 3 then begin
    let (cp, n) = decode_utf8 cell.text 0 in
    if n = String.length cell.text then begin
      let cl = Utf8.cp_class cp in
      if Utf8.class_modifier_base cl
         && not (Utf8.class_emoji_presentation cl) then
        Stdlib.Buffer.add_string buf "\xef\xb8\x8e"  (* U+FE0E VS-15 *)
    end
  end;
  List.iter (fun (text, attr) ->
    if effective_attr attr <> effective_attr !cur_attr then begin
      emit_attr buf !cur_attr attr;
      cur_attr := attr
    end else begin
      let cl = Utf8.cp_class (fst (decode_utf8 text 0)) in
      if Utf8.class_trigger_extend cl || Utf8.class_ri cl then
        emit_forced_break buf cur_attr
    end;
    Stdlib.Buffer.add_string buf text
  ) (List.rev cell.followers);
  hazard := hazard_of_cell cell

(* Generate ANSI output for all cells (full redraw). *)
let emit_all curr buf =
  let cur_attr = ref default_attr in
  let hazard = ref Hazard_none in
  Stdlib.Buffer.add_string buf "\x1b[H";  (* home cursor *)
  for r = 0 to curr.rows - 1 do
    if r > 0 then
      Stdlib.Buffer.add_string buf (Printf.sprintf "\x1b[%d;1H" (r + 1));
    hazard := Hazard_none;  (* cursor move resets the cluster parser *)
    for c = 0 to curr.cols - 1 do
      let cell = curr.cells.(r).(c) in
      if cell.width = 0 then ()  (* skip continuation *)
      else emit_cell_payload buf cur_attr hazard cell
    done
  done;
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"

(* Generate ANSI output for changed cells. *)
let diff ~prev ~curr buf =
  let cur_row = ref (-1) in
  let cur_col = ref (-1) in
  let cur_attr = ref default_attr in
  let hazard = ref Hazard_none in
  for r = 0 to curr.rows - 1 do
    for c = 0 to curr.cols - 1 do
      let cell = curr.cells.(r).(c) in
      if cell.width = 0 then ()  (* skip continuation cells *)
      else begin
        let prev_cell =
          if r < prev.rows && c < prev.cols then prev.cells.(r).(c)
          else empty_cell ()
        in
        if not (cell_eq cell prev_cell) then begin
          (* Move cursor if needed *)
          if r <> !cur_row || c <> !cur_col then begin
            Stdlib.Buffer.add_string buf
              (Printf.sprintf "\x1b[%d;%dH" (r + 1) (c + 1));
            cur_row := r;
            cur_col := c;
            hazard := Hazard_none  (* cursor move resets the parser *)
          end;
          emit_cell_payload buf cur_attr hazard cell;
          cur_col := !cur_col + (max 1 cell.width)
        end
      end
    done
  done;
  (* Reset attributes at end *)
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"
