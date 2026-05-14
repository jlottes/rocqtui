let screen_to_buffer_pos r buf ~x ~y =
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let script_rect = Render.pane_rect r Render.PScript in
  let row = y - script_rect.row in
  let gw = View.gutter_width buf in
  let col = x - script_rect.col - gw in
  if row < 0 || row >= rows || col < 0 || col >= cols - gw then None
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

(* Pane-selection / cache / scroll for the active messages sub-tab.
   Rocq's are per-file (on tab.rocq_msg); Build/Errors live on the
   global Msg_pane tab. Terminal sub-tabs aren't text panes — callers
   should check {!active_msg_kind} first. *)
let active_msg_pane_state (tab : Tab.t) =
  match Msg_pane.active_kind () with
  | Msg_pane.Rocq ->
    `Text (tab.rocq_msg.rms_sel,
           tab.rocq_msg.rms_lines_cache,
           tab.rocq_msg.rms_scroll)
  | Msg_pane.Build | Msg_pane.Errors | Msg_pane.Search ->
    let t = Msg_pane.active_tab () in
    `Text (t.sel, t.lines_cache, t.scroll)
  | Msg_pane.Terminal _ -> `Terminal

let active_msg_pane_sel (tab : Tab.t) =
  match active_msg_pane_state tab with
  | `Text (sel, _, _) -> sel
  | `Terminal -> tab.rocq_msg.rms_sel  (* defensive; callers shouldn't ask *)

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
        (match active_msg_pane_state tab with
         | `Text (_, cache, scr) -> (scr, cache)
         | `Terminal -> (0, []))
    in
    let line_idx = scroll + row in
    let n = List.length lines_cache in
    if line_idx >= n then None
    else begin
      let line = (List.nth lines_cache line_idx : Styled.line).text in
      let byte_col = Utf8.col_to_byte line (max 0 col) in
      Some (line_idx, byte_col)
    end
  end
