(* Render AI ghost text in the script pane.

   Called from [View.render_all] after the normal render completes.
   Phase 1 paints a single-line ghost continuation to the right of
   the cursor, in a dimmed style. Multi-line ghost is Phase 2. *)

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
       (* Single-line ghost for Phase 1. *)
       let text = match String.index_opt g.text '\n' with
         | Some i -> String.sub g.text 0 i
         | None -> g.text
       in
       if String.length text = 0 then ()
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
         let row = g.origin_line - scroll in
         let visual_col = Utf8.byte_to_col line_text g.origin_col in
         let col = visual_col - hscroll + gw in
         if row >= 0 && row < rows && col >= gw && col < cols then
           ignore (Render.put_str r Render.PScript ~row ~col text (ghost_attr ()))
       end)
