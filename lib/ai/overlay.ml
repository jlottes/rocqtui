(* Render AI suggestions (FIM ghost + edit overlay) in the script
   pane. Called from [View.render_all] after the normal render
   completes, so we paint on top of the freshly-laid buffer text. *)

let ghost_attr () : Grid.attr =
  let a = Theme.attrs () in
  { a.ga_default with dim = true }

(* Highlight for "this span will be deleted by the predicted edit". *)
let edit_delete_attr () : Grid.attr =
  let a = Theme.attrs () in
  { a.ga_default with reverse = true; dim = true }

(* Inline copy of View.gutter_width to avoid an Ai → View module
   dependency. Keep in sync if the formula in view.ml changes. *)
let gutter_width buf =
  if not !Config.show_line_numbers then 0
  else
    let n = max 1 (Buffer.line_count buf) in
    let rec count k = if k = 0 then 0 else 1 + count (k / 10) in
    let digits = max 1 (count n) in
    1 + max 4 digits + 1

let draw_fim_ghost r tab (g : Per_tab.ghost) =
  if String.length g.text = 0 then ()
  else begin
    let buf = tab.Tab.buf in
    let line_text =
      if g.origin_line < Buffer.line_count buf then
        Buffer.get_line buf g.origin_line
      else ""
    in
    let gw = gutter_width buf in
    let (rows, cols) = Render.pane_dims r Render.PScript in
    let scroll = Buffer.scroll_top buf in
    let hscroll = Buffer.hscroll buf in
    let start_row = g.origin_line - scroll in
    let visual_col = Utf8.byte_to_col line_text g.origin_col in
    let start_col = visual_col - hscroll + gw in
    let attr = ghost_attr () in
    let lines = String.split_on_char '\n' g.text in
    List.iteri (fun i line ->
      let row = start_row + i in
      let col = if i = 0 then start_col else gw in
      if row >= 0 && row < rows && col < cols then
        ignore (Render.put_str r Render.PScript ~row ~col line attr)
    ) lines
  end

let draw_edits r tab (o : Per_tab.edits_overlay) =
  let buf = tab.Tab.buf in
  let gw = gutter_width buf in
  let (rows, cols) = Render.pane_dims r Render.PScript in
  let scroll = Buffer.scroll_top buf in
  let hscroll = Buffer.hscroll buf in
  let del_attr = edit_delete_attr () in
  let preview_attr = ghost_attr () in
  List.iter (fun (c : Per_tab.edit_change) ->
    let line_text =
      if c.start_line < Buffer.line_count buf then
        Buffer.get_line buf c.start_line
      else ""
    in
    let row = c.start_line - scroll in
    if row >= 0 && row < rows then begin
      let scol_visual = Utf8.byte_to_col line_text c.start_col in
      let ecol_visual =
        if c.end_line > c.start_line then
          (* multi-line deletion: just highlight to EOL of start_line *)
          Utf8.byte_to_col line_text (String.length line_text)
        else
          Utf8.byte_to_col line_text c.end_col
      in
      let s = scol_visual - hscroll + gw in
      let e = ecol_visual - hscroll + gw in
      let s_clamped = max gw s in
      let e_clamped = min cols e in
      if e_clamped > s_clamped then
        Render.chgat r Render.PScript ~row ~col:s_clamped
          ~width:(e_clamped - s_clamped) del_attr;
      (* Inline preview of the replacement (first line only) after
         the deletion span. Keeps the visual compact; multi-line
         replacements just show their first line. *)
      let preview_text =
        let first =
          match String.index_opt c.replacement '\n' with
          | Some i -> String.sub c.replacement 0 i
          | None -> c.replacement
        in
        " → " ^ first
      in
      let preview_col = e_clamped + 1 in
      if preview_col < cols then
        ignore (Render.put_str r Render.PScript
          ~row ~col:preview_col preview_text preview_attr)
    end
  ) o.changes

let draw_overlay ~(state : State.t option) (r : Render.t) (tab : Tab.t) =
  match state with
  | None -> ()
  | Some state when not state.State.enabled -> ()
  | Some state ->
    let pt = State.per_tab state tab.id in
    (match pt.edits with
     | Some o -> draw_edits r tab o
     | None -> ());
    (match pt.ghost with
     | Some g -> draw_fim_ghost r tab g
     | None -> ())
