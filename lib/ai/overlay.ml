(* Render AI ghost text in the script pane.

   Called from [View.render_all] after the normal render completes.
   The first line of the ghost paints at the cursor; subsequent
   lines paint at column 0 (just past the gutter) of the following
   rows. Multi-line ghosts overwrite whatever buffer content was
   rendered there — a Phase-2 simplification; a future revision can
   push real lines down so they remain visible. *)

let ghost_attr () : Grid.attr =
  let a = Theme.attrs () in
  { a.ga_default with dim = true }

(* Inline copy of View.gutter_width to avoid an Ai → View module
   dependency (View itself depends on Editor_context, which holds an
   Ai.State.t, which would close the cycle). Keep in sync if the
   formula in view.ml changes. *)
let gutter_width buf =
  if not !Config.show_line_numbers then 0
  else
    let n = max 1 (Buffer.line_count buf) in
    let rec count k = if k = 0 then 0 else 1 + count (k / 10) in
    let digits = max 1 (count n) in
    1 + max 4 digits + 1

let draw_overlay ~(state : State.t option) (r : Render.t) (tab : Tab.t) =
  match state with
  | None -> ()
  | Some state when not state.State.enabled -> ()
  | Some state ->
    let pt = State.per_tab state tab.id in
    (match pt.ghost with
     | None -> ()
     | Some g ->
       if String.length g.text = 0 then ()
       else begin
         let buf = tab.buf in
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
       end)
