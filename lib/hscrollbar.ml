type t = {
  hscroll : int;
  cells : int;
  total : int;
}

let make ~hscroll ~max_w ~content_cols =
  { hscroll; cells = max 1 content_cols;
    total = max max_w (hscroll + content_cols) }

(* Widest line (in screen columns) among the [rows] lines starting at
   the buffer's scroll position. *)
let visible_max_width buf ~rows =
  let scroll = Buffer.scroll_top buf in
  let last = min (scroll + rows - 1) (Buffer.line_count buf - 1) in
  let m = ref 0 in
  for i = scroll to last do
    let w = Utf8.string_width (Buffer.get_line buf i) in
    if w > !m then m := w
  done;
  !m

let of_buffer buf ~rows ~content_cols =
  make ~hscroll:(Buffer.hscroll buf)
    ~max_w:(visible_max_width buf ~rows) ~content_cols

let wanted buf ~rows ~content_cols =
  rows >= 3
  && (Buffer.hscroll buf > 0
      || visible_max_width buf ~rows > content_cols)

let thumb t =
  let track8 = t.cells * 8 in
  if t.total <= t.cells then (0, track8)
  else begin
    let s8 = t.hscroll * track8 / t.total in
    (* Ceiling so the thumb covers everything currently on screen. *)
    let e8 = ((t.hscroll + t.cells) * track8 + t.total - 1) / t.total in
    let e8 = min e8 track8 in
    if e8 - s8 >= 8 then (s8, e8)
    else if s8 + 8 <= track8 then (s8, s8 + 8)
    else (track8 - 8, track8)
  end

let clamp t v = max 0 (min (t.total - t.cells) v)

let hscroll_of_click t ~track_x =
  let track8 = t.cells * 8 in
  let pos8 = track_x * 8 + 4 in
  clamp t (pos8 * t.total / track8 - t.cells / 2)

let page t ~dir =
  clamp t (t.hscroll + dir * max 1 (t.cells / 2))

(* Left-fill block with [k] of 8 eighths of ink: U+2588 (full) down
   to U+258F (one eighth). *)
let block_of_eighths k =
  let b = Bytes.of_string "\xe2\x96\x88" in
  Bytes.set b 2 (Char.chr (0x90 - k));
  Bytes.to_string b

let draw g ~row ~col ~gw ~width ~track_attr ~thumb_attr t =
  for i = 0 to width - 1 do
    Grid.set_cell g ~row ~col:(col + i) " " track_attr
  done;
  let (s8, e8) = thumb t in
  let rev_thumb = { thumb_attr with Grid.reverse = true } in
  for i = 0 to t.cells - 1 do
    let lo = max (i * 8) s8 and hi = min ((i + 1) * 8) e8 in
    if hi > lo then begin
      let c = col + gw + i in
      if lo = i * 8 && hi = (i + 1) * 8 then
        Grid.set_cell g ~row ~col:c "\xe2\x96\x88" thumb_attr
      else if lo > i * 8 then
        (* Left edge: the *unfilled* prefix as a left-fill block in
           reverse video — ink turns into track bg, the rest of the
           cell into thumb color. *)
        Grid.set_cell g ~row ~col:c (block_of_eighths (lo - i * 8)) rev_thumb
      else
        Grid.set_cell g ~row ~col:c (block_of_eighths (hi - i * 8)) thumb_attr
    end
  done;
  (* U+2BC7/U+2BC8 centred triangles — sit on the line centerline,
     unlike the baseline-aligned U+25C0/25B6. *)
  if t.hscroll > 0 then
    Grid.set_cell g ~row ~col "\xe2\xaf\x87" track_attr;
  if t.hscroll + t.cells < t.total then
    Grid.set_cell g ~row ~col:(col + width - 1) "\xe2\xaf\x88" track_attr
