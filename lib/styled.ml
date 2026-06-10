type span = {
  start : int;
  len : int;
  attr : Grid.attr;
}

type line = {
  text : string;
  spans : span list;
}

let plain text = { text; spans = [] }

let style text attr =
  let len = String.length text in
  if len = 0 then plain text
  else { text; spans = [{ start = 0; len; attr }] }

let length l = String.length l.text

let width l = Utf8.string_width l.text

let to_string l = l.text

let concat pieces =
  let buf = Stdlib.Buffer.create 64 in
  let spans = ref [] in
  List.iter (fun p ->
    let off = Stdlib.Buffer.length buf in
    Stdlib.Buffer.add_string buf p.text;
    List.iter (fun s ->
      spans := { s with start = s.start + off } :: !spans
    ) p.spans
  ) pieces;
  { text = Stdlib.Buffer.contents buf; spans = List.rev !spans }

let of_strings ss = List.map plain ss

(* Slice spans to a byte sub-range [b_lo, b_hi) of the source text and
   shift their starts by [-b_lo + offset]. Used both for wrap segments
   (offset = pad length on continuations, 0 otherwise). *)
let slice_spans spans ~b_lo ~b_hi ~offset =
  List.filter_map (fun s ->
    let s_start = max s.start b_lo in
    let s_end = min (s.start + s.len) b_hi in
    if s_end > s_start then
      Some { s with start = s_start - b_lo + offset;
                    len = s_end - s_start }
    else None
  ) spans

let wrap ?(hanging=0) width lines_list =
  let avail = max 1 (width - 2) in
  let pad = String.make (max 0 hanging) ' ' in
  let pad_len = String.length pad in
  let result = ref [] in
  List.iter (fun l ->
    let line = l.text in
    let line_w = Utf8.string_width line in
    if line_w <= avail then
      result := l :: !result
    else begin
      let len = String.length line in
      (* Break at display-cell boundaries (cluster-aware) so a wrap
         can't split a flag pair or separate a combining mark from
         its base. Followers and skipped bytes between cells travel
         with the preceding cell. *)
      let cells = Array.of_list (snd (Utf8.display_cells line)) in
      let ncells = Array.length cells in
      let ci = ref 0 in
      let pos = ref 0 in
      let segment_idx = ref 0 in
      while !pos < len do
        let start = !pos in
        let on_continuation = !segment_idx > 0 in
        let prefix_w = if on_continuation then pad_len else 0 in
        let cap = max 1 (avail - prefix_w) in
        let col = ref 0 in
        let stop = ref false in
        while !ci < ncells && not !stop do
          let w = cells.(!ci).Utf8.cell_width in
          if !col + w > cap then stop := true
          else begin col := !col + w; incr ci end
        done;
        if not !stop then pos := len  (* all cells consumed *)
        else begin
          (* force progress when a single cell exceeds the cap *)
          if cells.(!ci).Utf8.cell_off = start then incr ci;
          pos :=
            if !ci < ncells then cells.(!ci).Utf8.cell_off else len
        end;
        let segment_text = String.sub line start (!pos - start) in
        let segment_spans =
          slice_spans l.spans ~b_lo:start ~b_hi:(!pos)
            ~offset:(if on_continuation then pad_len else 0)
        in
        let text =
          if on_continuation then pad ^ segment_text else segment_text
        in
        result := { text; spans = segment_spans } :: !result;
        incr segment_idx
      done
    end
  ) lines_list;
  List.rev !result
