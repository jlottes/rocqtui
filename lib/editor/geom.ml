let screen_to_buffer_pos r buf ~x ~y =
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let script_rect = Render.pane_rect r Render.PScript in
  let row = y - script_rect.row in
  let col = x - script_rect.col in
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let line_idx = scroll + row in
    if line_idx >= Buffer.line_count buf then None
    else begin
      let line = Buffer.get_line buf line_idx in
      let vcol = hscroll + col in
      let byte_col = Utf8.col_to_byte line vcol in
      Some (line_idx, byte_col)
    end
  end

let screen_to_pane_pos (tab : Tab.t) r ~x ~y pane_id =
  let pane = match pane_id with
    | `Goals -> Render.PGoals
    | `Messages -> Render.PMessages
  in
  let rect = Render.pane_rect r pane in
  let (rows, cols) = Render.pane_dims r pane in
  let row = y - rect.row in
  let col = x - rect.col - 1 in (* -1 for margin *)
  if row < 0 || row >= rows || col < 0 || col >= cols then None
  else begin
    let scroll, lines_cache = match pane_id with
      | `Goals -> (tab.goals_scroll, tab.goals_lines_cache)
      | `Messages ->
        let mt = Tab.active_msg_tab tab.msg in
        (mt.mt_scroll, mt.mt_lines_cache)
    in
    let line_idx = scroll + row in
    let n = List.length lines_cache in
    if line_idx >= n then None
    else begin
      let line = List.nth lines_cache line_idx in
      let byte_col = Utf8.col_to_byte line (max 0 col) in
      Some (line_idx, byte_col)
    end
  end
