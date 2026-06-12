(* Horizontal scrollbar geometry: thumb placement, click inversion,
   clamping. Pure [make]-based tests — no Buffer needed. *)

module H = Rocqtui_lib.Hscrollbar

let check msg b =
  if not b then begin
    Printf.printf "FAIL: %s\n" msg;
    exit 1
  end

let () =
  (* total = max max_w (hscroll + content_cols) *)
  let t = H.make ~hscroll:0 ~max_w:200 ~content_cols:50 in
  check "total from max_w" (t.H.total = 200);
  let t = H.make ~hscroll:180 ~max_w:200 ~content_cols:50 in
  check "total from hscroll+cols" (t.H.total = 230);

  (* Everything fits: thumb spans the whole track. *)
  let t = H.make ~hscroll:0 ~max_w:30 ~content_cols:50 in
  let (s8, e8) = H.thumb t in
  check "fits: full-track thumb" (s8 = 0 && e8 = 50 * 8);

  (* Proportional placement at the extremes. *)
  let t = H.make ~hscroll:0 ~max_w:200 ~content_cols:50 in
  let (s8, e8) = H.thumb t in
  check "left-pinned start" (s8 = 0);
  check "quarter visible -> quarter thumb" (e8 = 50 * 8 / 4);
  let t = H.make ~hscroll:150 ~max_w:200 ~content_cols:50 in
  let (s8, e8) = H.thumb t in
  check "right-pinned end" (e8 = 50 * 8);
  check "right-pinned start" (s8 = 300);

  (* Minimum thumb width is one cell, kept inside the track. *)
  let t = H.make ~hscroll:0 ~max_w:100_000 ~content_cols:50 in
  let (s8, e8) = H.thumb t in
  check "min width left" (s8 = 0 && e8 = 8);
  let t = H.make ~hscroll:99_950 ~max_w:100_000 ~content_cols:50 in
  let (s8, e8) = H.thumb t in
  check "min width right" (e8 = 50 * 8 && e8 - s8 = 8);

  (* Invariants across a parameter sweep, including monotonicity of
     the thumb position in hscroll. *)
  List.iter (fun (max_w, cells) ->
    let track8 = cells * 8 in
    let prev_s8 = ref (-1) in
    let max_hs = max 0 (max_w - cells) in
    for hs = 0 to max_hs do
      let t = H.make ~hscroll:hs ~max_w ~content_cols:cells in
      let (s8, e8) = H.thumb t in
      check "thumb in track" (0 <= s8 && s8 < e8 && e8 <= track8);
      check "thumb >= 1 cell" (e8 - s8 >= 8);
      check "monotonic in hscroll" (s8 >= !prev_s8);
      prev_s8 := s8;
      (* Click inversion: clicking the thumb's center cell must not
         move the view by more than ~one cell's worth of columns. *)
      let center_cell = (s8 + e8) / 2 / 8 in
      let center_cell = min (cells - 1) center_cell in
      let hs' = H.hscroll_of_click t ~track_x:center_cell in
      let cols_per_cell = (t.H.total + track8 - 1) / track8 * 8 in
      check "click inversion" (abs (hs' - hs) <= cols_per_cell);
      check "click clamped"
        (hs' >= 0 && hs' <= t.H.total - t.H.cells)
    done
  ) [ (200, 50); (75, 50); (1000, 33); (10_000, 80) ];

  (* Click at the extremes clamps. *)
  let t = H.make ~hscroll:75 ~max_w:200 ~content_cols:50 in
  check "click left edge" (H.hscroll_of_click t ~track_x:0 = 0);
  check "click right edge" (H.hscroll_of_click t ~track_x:49 = 150);

  (* Paging: half a screen, clamped. *)
  check "page right" (H.page t ~dir:1 = 100);
  check "page left" (H.page t ~dir:(-1) = 50);
  let t = H.make ~hscroll:140 ~max_w:200 ~content_cols:50 in
  check "page right clamp" (H.page t ~dir:1 = 150);
  let t = H.make ~hscroll:10 ~max_w:200 ~content_cols:50 in
  check "page left clamp" (H.page t ~dir:(-1) = 0);

  (* Draw: tinted row, full / eighth-block thumb cells, reverse-video
     left edge, centred end triangles. Geometry: total=200, cells=50,
     track8=400, hscroll=75 -> thumb eighths [150, 250). *)
  let module Grid = Rocqtui_lib.Grid in
  let g = Grid.create 3 60 in
  let track_attr =
    { Grid.default_attr with bg = Grid.Color256 237 } in
  let thumb_attr =
    { track_attr with fg = Grid.Color256 244 } in
  let t = H.make ~hscroll:75 ~max_w:200 ~content_cols:50 in
  H.draw g ~row:1 ~col:0 ~gw:10 ~width:60 ~track_attr ~thumb_attr t;
  let cell c = g.Grid.cells.(1).(c) in
  check "left triangle" ((cell 0).Grid.text = "\xe2\xaf\x87");
  check "right triangle" ((cell 59).Grid.text = "\xe2\xaf\x88");
  check "track tint"
    ((cell 5).Grid.text = " "
     && (cell 5).Grid.attr.Grid.bg = Grid.Color256 237);
  (* Cell 18 of the track (col 28) straddles the thumb start at
     eighth 150: 6 unfilled eighths drawn as U+258A in reverse. *)
  check "left edge glyph" ((cell 28).Grid.text = "\xe2\x96\x8a");
  check "left edge reverse" (cell 28).Grid.attr.Grid.reverse;
  check "thumb body"
    ((cell 35).Grid.text = "\xe2\x96\x88"
     && not (cell 35).Grid.attr.Grid.reverse);
  (* Cell 31 (col 41) holds the thumb end at eighth 250: 2 filled
     eighths, U+258E, normal video. *)
  check "right edge glyph" ((cell 41).Grid.text = "\xe2\x96\x8e");
  check "right edge normal" (not (cell 41).Grid.attr.Grid.reverse);
  check "track after thumb" ((cell 50).Grid.text = " ");
  (* Everything fits: full-track thumb, no triangles. *)
  let g = Grid.create 3 60 in
  let t = H.make ~hscroll:0 ~max_w:30 ~content_cols:50 in
  H.draw g ~row:1 ~col:0 ~gw:10 ~width:60 ~track_attr ~thumb_attr t;
  let cell c = g.Grid.cells.(1).(c) in
  check "no left triangle" ((cell 0).Grid.text = " ");
  check "no right triangle" ((cell 59).Grid.text = "\xe2\x96\x88");

  print_endline "test_hscrollbar: all tests passed"
