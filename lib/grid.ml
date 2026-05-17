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
}

let empty_cell () = { text = " "; width = 1; attr = default_attr }

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
      cell.attr <- attr
    done
  done

let clear_region g ~row ~col ~height ~width ~attr =
  for r = row to min (row + height - 1) (g.rows - 1) do
    for c = col to min (col + width - 1) (g.cols - 1) do
      let cell = g.cells.(r).(c) in
      cell.text <- " ";
      cell.width <- 1;
      cell.attr <- attr
    done
  done

(* Get the display width of a Unicode codepoint using wcwidth *)
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

(* Set a single cell. Handles wide characters by marking the next cell
   as a continuation (width=0). Clears any previous wide char that
   this cell was part of. *)
let set_cell g ~row ~col text attr =
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
    (* Determine display width *)
    let (cp, _) = decode_utf8 text 0 in
    let w = wcwidth cp in
    let w = if w < 0 then 1 else w in
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

(* Append a combining character to the cell at (row, col).
   The combining character is added to the cell's text. *)
let append_combining g ~row ~col text =
  if row >= 0 && row < g.rows && col >= 0 && col < g.cols then begin
    let cell = g.cells.(row).(col) in
    cell.text <- cell.text ^ text
  end

(* Write a UTF-8 string starting at (row, col).
   Returns the number of columns consumed. *)
let put_str g ~row ~col s attr =
  if row < 0 || row >= g.rows then 0
  else begin
    let len = String.length s in
    let c = ref col in
    let i = ref 0 in
    while !i < len && !c < g.cols do
      let (cp, nbytes) = decode_utf8 s !i in
      let char_str = String.sub s !i nbytes in
      let w = wcwidth cp in
      if w < 0 then begin
        (* Non-printable — skip *)
        i := !i + nbytes
      end
      else if w = 0 then begin
        (* Combining character — append to previous cell *)
        if !c > col then
          append_combining g ~row ~col:(!c - 1) char_str
        else if col > 0 then
          append_combining g ~row ~col:(col - 1) char_str;
        i := !i + nbytes
      end
      else begin
        (* Normal or wide character *)
        if !c >= 0 && !c + w - 1 < g.cols then
          set_cell g ~row ~col:!c char_str attr;
        c := !c + w;
        i := !i + nbytes
      end
    done;
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
      cell.attr <- attr
    end
  done

(* Change attributes of a row region without touching text. *)
let chgat g ~row ~col ~width attr =
  if row >= 0 && row < g.rows then
    for c = max 0 col to min (col + width - 1) (g.cols - 1) do
      g.cells.(row).(c).attr <- attr
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
      let len = String.length s in
      let c = ref start in
      let i = ref 0 in
      while !i < len && !c < stop_col do
        let (cp, nbytes) = decode_utf8 s !i in
        let char_str = String.sub s !i nbytes in
        let w = wcwidth cp in
        if w < 0 then
          i := !i + nbytes
        else if w = 0 then begin
          if !c > start && !c - 1 >= left_bound then
            append_combining g ~row:abs_row ~col:(!c - 1) char_str
          else if start > left_bound then
            append_combining g ~row:abs_row ~col:(start - 1) char_str;
          i := !i + nbytes
        end
        else begin
          if !c >= left_bound && !c + w - 1 < stop_col then
            set_cell g ~row:abs_row ~col:!c char_str attr;
          c := !c + w;
          i := !i + nbytes
        end
      done;
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

let clear_rect g rect ~attr =
  clear_region g ~row:rect.row ~col:rect.col
    ~height:rect.height ~width:rect.width ~attr

(* Compare two cells for equality. Polymorphic [=] hits a pointer-equality
   shortcut when attr records are shared (the common case — cells with the
   same rendition share the same attr block). *)
let cell_eq a b =
  a.text = b.text && a.width = b.width && a.attr = b.attr

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
      d.attr <- s.attr
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
  if n <= 0 || n > 9 then None
  else Some (string_of_int (10 + n))

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

(* Generate ANSI output for all cells (full redraw). *)
let emit_all curr buf =
  let cur_attr = ref default_attr in
  Stdlib.Buffer.add_string buf "\x1b[H";  (* home cursor *)
  for r = 0 to curr.rows - 1 do
    if r > 0 then
      Stdlib.Buffer.add_string buf (Printf.sprintf "\x1b[%d;1H" (r + 1));
    for c = 0 to curr.cols - 1 do
      let cell = curr.cells.(r).(c) in
      if cell.width = 0 then ()  (* skip continuation *)
      else begin
        emit_attr buf !cur_attr cell.attr;
        cur_attr := cell.attr;
        Stdlib.Buffer.add_string buf cell.text
      end
    done
  done;
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"

(* Generate ANSI output for changed cells. *)
let diff ~prev ~curr buf =
  let cur_row = ref (-1) in
  let cur_col = ref (-1) in
  let cur_attr = ref default_attr in
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
            cur_col := c
          end;
          (* Set attributes *)
          emit_attr buf !cur_attr cell.attr;
          cur_attr := cell.attr;
          (* Write text *)
          Stdlib.Buffer.add_string buf cell.text;
          cur_col := !cur_col + (max 1 cell.width)
        end
      end
    done
  done;
  (* Reset attributes at end *)
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"
