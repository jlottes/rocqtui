(* Braille minimap rendering.

   Each braille character (U+2800-U+28FF) is a 2×4 dot grid.
   We map source text onto this grid: a dot is lit if the corresponding
   source region contains a non-whitespace character.

   Dot bit layout:
     col0: rows 0,1,2,3 = bits 0,1,2,6
     col1: rows 0,1,2,3 = bits 3,4,5,7
*)

(* Default width of the minimap in terminal columns (each = one braille char) *)
let width = 3

(* Compute source columns per braille dot to fit the max line width *)
let x_per_dot ~max_line_width ~braille_cols =
  (* Each braille char has 2 dots horizontally, so total dots = braille_cols * 2 *)
  let total_dots = braille_cols * 2 in
  if total_dots <= 0 then 1
  else max 1 ((max_line_width + total_dots - 1) / total_dots)

(* Compute source lines per braille cell to fit the file in available rows *)
let y_per_cell ~num_lines ~available_rows =
  let min_ypc = 1 in
  if available_rows <= 0 then min_ypc
  else max min_ypc ((num_lines + available_rows - 1) / available_rows)

(* Region status for coloring *)
type region_status = RDefault | RVerified | RProcessing | RError

type cell = {
  braille : string;  (* UTF-8 braille character *)
  color : int;       (* legacy color pair -- kept for compat *)
  status : region_status;  (* region status for Grid attr lookup *)
}

type row = cell array

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

let utf8_of_codepoint cp =
  if cp < 0x80 then
    String.make 1 (Char.chr cp)
  else if cp < 0x800 then
    let s = Bytes.create 2 in
    Bytes.set s 0 (Char.chr (0xC0 lor (cp lsr 6)));
    Bytes.set s 1 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string s
  else
    let s = Bytes.create 3 in
    Bytes.set s 0 (Char.chr (0xE0 lor (cp lsr 12)));
    Bytes.set s 1 (Char.chr (0x80 lor ((cp lsr 6) land 0x3F)));
    Bytes.set s 2 (Char.chr (0x80 lor (cp land 0x3F)));
    Bytes.to_string s

(* Check if a source position has a non-whitespace character *)
let has_char lines num_lines row col =
  if row < 0 || row >= num_lines then false
  else
    let line = lines.(row) in
    col >= 0 && col < String.length line
    && line.[col] <> ' ' && line.[col] <> '\t'

(* Determine the dominant status for a source line range. *)
let region_status ~verified_end ~pending_end ~error_range
    line_start_offset line_end_offset =
  (* Check error first *)
  match error_range with
  | Some (es, ee) when line_end_offset > es && line_start_offset < ee ->
    RError
  | _ ->
    if line_end_offset <= verified_end then
      RVerified
    else if line_end_offset <= pending_end then
      RProcessing
    else
      RDefault

(* Compute line byte offsets: offset.(i) = byte offset of start of line i *)
let compute_line_offsets lines num_lines =
  let offsets = Array.make (num_lines + 1) 0 in
  for i = 0 to num_lines - 1 do
    offsets.(i + 1) <- offsets.(i) + String.length lines.(i) + 1
  done;
  offsets

(* Render the minimap for the full file.
   Returns an array of rows, each row is an array of cells. *)
let render ~lines ~num_lines ~verified_end ~pending_end ~error_range ~ypc ~cols =
  let line_offsets = compute_line_offsets lines num_lines in
  let max_lw = Array.fold_left (fun acc l -> max acc (String.length l)) 0 lines in
  let xpd = x_per_dot ~max_line_width:max_lw ~braille_cols:cols in
  let braille_rows = (num_lines + ypc - 1) / ypc in
  Array.init braille_rows (fun br ->
    Array.init cols (fun bc ->
      let grid = Array.init 4 (fun _ -> Array.make 2 false) in
      let first_line = br * ypc in
      let last_line = min num_lines ((br + 1) * ypc) - 1 in
      let status =
        if first_line < num_lines then
          region_status ~verified_end ~pending_end ~error_range
            line_offsets.(first_line)
            line_offsets.(min num_lines (last_line + 1))
        else RDefault
      in
      let color = match status with
        | RDefault -> 0 | RVerified -> 1 | RProcessing -> 2 | RError -> 3
      in
      for dr = 0 to 3 do
        for dc = 0 to 1 do
          let sr_start = br * ypc + dr * ypc / 4 in
          let sr_end = br * ypc + (dr + 1) * ypc / 4 in
          let sr_end = max (sr_start + 1) sr_end in (* at least 1 line *)
          let sc_start = bc * xpd * 2 + dc * xpd in
          let sc_end = sc_start + xpd in
          let found = ref false in
          for sr = sr_start to sr_end - 1 do
            if not !found then
              for sc = sc_start to sc_end - 1 do
                if has_char lines num_lines sr sc then found := true
              done
          done;
          grid.(dr).(dc) <- !found
        done
      done;
      let cp = encode_braille grid in
      { braille = utf8_of_codepoint cp; color; status }
    ))

(* Draw the minimap into a curses window at a given column offset.
   [scroll] is the viewport's first visible source line.
   [visible_lines] is how many source lines are visible.
   The viewport region is drawn with reverse video. *)
(* UTF-8 encoding for box-drawing chars used in the separator *)
let char_vline = "\xe2\x94\x82"       (* │ U+2502 *)
let char_round_top = "\xe2\x95\xad"   (* ╭ U+256D *)
let char_round_bot = "\xe2\x95\xb0"   (* ╰ U+2570 *)

let grid_attr_of_status status =
  let a = Theme.attrs () in
  match status with
  | RDefault -> Grid.default_attr
  | RVerified -> a.ga_verified
  | RProcessing -> a.ga_processing
  | RError -> a.ga_error

let draw grid ~base_row ~base_col ~sep_col ~col_offset ~win_rows ~minimap_rows
    ~scroll ~visible_lines ~ypc ~border_attr rows =
  let vp_first = scroll / ypc in
  let vp_last = (scroll + visible_lines - 1) / ypc in
  for r = 0 to win_rows - 1 do
    let mr = r in
    let in_viewport = mr >= vp_first && mr <= vp_last in
    (* Draw separator with viewport bracket *)
    let sep_char =
      if mr = vp_first && vp_first > 0 then char_round_top
      else if mr = vp_last && vp_last < minimap_rows - 1 then char_round_bot
      else char_vline
    in
    Grid.set_cell grid ~row:(base_row + r) ~col:(base_col + sep_col) sep_char border_attr;
    (* Draw minimap cells *)
    if mr < minimap_rows && mr < Array.length rows then begin
      let row = rows.(mr) in
      for c = 0 to Array.length row - 1 do
        let cell = row.(c) in
        let base_attr = grid_attr_of_status cell.status in
        let attr = if in_viewport then { base_attr with reverse = true }
                   else base_attr in
        Grid.set_cell grid ~row:(base_row + r) ~col:(base_col + col_offset + c) cell.braille attr
      done
    end else begin
      (* Empty row — clear *)
      let w = if Array.length rows > 0 then Array.length rows.(0)
              else win_rows in
      for c = 0 to w - 1 do
        Grid.set_cell grid ~row:(base_row + r) ~col:(base_col + col_offset + c)
          " " Grid.default_attr
      done
    end
  done
