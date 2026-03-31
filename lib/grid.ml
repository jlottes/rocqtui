(* Cell grid for terminal rendering.
   Each cell holds a UTF-8 string (possibly with combining characters),
   a display width, and visual attributes. *)

type color =
  | Default
  | Basic of int          (* 0-7 standard, 8-15 bright *)
  | Color256 of int       (* 0-255 *)
  | TrueColor of int * int * int

type attr = {
  fg : color;
  bg : color;
  bold : bool;
  dim : bool;
  reverse : bool;
  underline : bool;
}

let default_attr = {
  fg = Default; bg = Default;
  bold = false; dim = false; reverse = false; underline = false;
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

(* Compare two cells for equality *)
let cell_eq a b =
  a.text = b.text && a.width = b.width
  && a.attr.fg = b.attr.fg && a.attr.bg = b.attr.bg
  && a.attr.bold = b.attr.bold && a.attr.dim = b.attr.dim
  && a.attr.reverse = b.attr.reverse && a.attr.underline = b.attr.underline

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

(* Emit SGR sequence for an attribute change *)
let emit_attr buf prev_attr attr =
  if prev_attr = attr then ()
  else begin
    let parts = ref [] in
    (* Reset if any attribute was turned off *)
    let needs_reset =
      (prev_attr.bold && not attr.bold)
      || (prev_attr.dim && not attr.dim)
      || (prev_attr.reverse && not attr.reverse)
      || (prev_attr.underline && not attr.underline)
    in
    if needs_reset then begin
      parts := ["0"];
      (* After reset, re-emit everything that's on *)
      if attr.bold then parts := "1" :: !parts;
      if attr.dim then parts := "2" :: !parts;
      if attr.underline then parts := "4" :: !parts;
      if attr.reverse then parts := "7" :: !parts;
      if attr.fg <> Default then parts := sgr_of_color true attr.fg :: !parts;
      if attr.bg <> Default then parts := sgr_of_color false attr.bg :: !parts;
    end else begin
      if attr.bold && not prev_attr.bold then parts := "1" :: !parts;
      if attr.dim && not prev_attr.dim then parts := "2" :: !parts;
      if attr.underline && not prev_attr.underline then parts := "4" :: !parts;
      if attr.reverse && not prev_attr.reverse then parts := "7" :: !parts;
      if attr.fg <> prev_attr.fg then
        parts := sgr_of_color true attr.fg :: !parts;
      if attr.bg <> prev_attr.bg then
        parts := sgr_of_color false attr.bg :: !parts;
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
    done;
    (* Clear any trailing content beyond what we wrote *)
    Stdlib.Buffer.add_string buf "\x1b[K"
  done;
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"

(* Generate ANSI output for changed cells. *)
let diff ~prev ~curr buf =
  let cur_row = ref (-1) in
  let cur_col = ref (-1) in
  let cur_attr = ref default_attr in
  for r = 0 to curr.rows - 1 do
    let last_written_col = ref (-1) in
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
          cur_col := !cur_col + (max 1 cell.width);
          last_written_col := c + (max 1 cell.width) - 1
        end
      end
    done;
    (* Clear trailing content if we wrote near the end of the row.
       This ensures terminals with dynamic line widths (like glterm)
       don't show stale content beyond the last column. *)
    if !last_written_col >= curr.cols - 1 then
      Stdlib.Buffer.add_string buf "\x1b[K"
  done;
  (* Reset attributes at end *)
  if !cur_attr <> default_attr then
    Stdlib.Buffer.add_string buf "\x1b[0m"
