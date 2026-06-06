(* tterm render driver. See view_terminal.mli. *)

let body_rect r =
  let st = Render.pane_rect r Render.PStatus in
  { Render.row = 0; col = 0;
    height = max 0 st.row;
    width = st.width }

(* Paint a leaf's tab strip into one row at [row], spanning [col..col
   + width - 1]. When [focused] the active tab is rendered with
   bracket-wrapped emphasis matching rocqtui's keyboard-focus indicator.
   Layout (truncation + scrolling) lives in [Render.tab_strip_layout];
   [bin/tterm.ml]'s hit-test reads the same layout so click targets and
   rendered ranges stay in sync. *)
let draw_leaf_strip r ~row ~col ~width ?(focused=false) (mp : Msg_pane.t) =
  let inactive_attr = (Theme.attrs ()).ga_tab_inactive in
  let active_attr = (Theme.attrs ()).ga_tab_active in
  let display_names = List.map Msg_pane.display_name mp.tabs in
  Render.draw_tab_strip r ~row ~col ~width ~focused
    ~display_names ~active:mp.active
    ~active_attr ~inactive_attr ()

let draw_vborder g (s : Layout.split) =
  let attr = (Theme.attrs ()).ga_border in
  let a_rect = Layout.rect_of s.a in
  let col = a_rect.col + a_rect.width in
  for row = s.rect.row to s.rect.row + s.rect.height - 1 do
    Grid.set_cell g ~row ~col "\xe2\x94\x82" attr  (* │ *)
  done

let draw_hborder g (s : Layout.split) =
  let attr = (Theme.attrs ()).ga_border in
  let a_rect = Layout.rect_of s.a in
  let row = a_rect.row + a_rect.height in
  for col = s.rect.col to s.rect.col + s.rect.width - 1 do
    Grid.set_cell g ~row ~col "\xe2\x94\x80" attr  (* ─ *)
  done

(* Render one leaf. Returns [Some (vt, cursor_row, cursor_col)] when
   the leaf's active terminal has the cursor visible; None otherwise.
   [focused] flags this leaf as the active one — its active tab gets
   bracket emphasis in the strip. *)
let render_leaf r ~focused (leaf : Layout.leaf) =
  let g = Render.curr r in
  let strip_row = leaf.rect.row in
  draw_leaf_strip r ~row:strip_row ~col:leaf.rect.col
    ~width:leaf.rect.width ~focused leaf.mp;
  let body = Layout.leaf_body_rect leaf in
  if body.height <= 0 || body.width <= 0 then None
  else match leaf.mp.tabs with
    | [] ->
      Grid.clear_rect g body ~attr:(Theme.attrs ()).ga_default;
      None
    | _ ->
      match Msg_pane.active_kind_in leaf.mp with
      | Msg_pane.Terminal term ->
        Terminal.render term g
          ~row:body.row ~col:body.col
          ~width:body.width ~height:body.height;
        let vt = Terminal.vterm term in
        let mode = Vterm_lib.Vterm_api.term_mode vt in
        if mode land 0x10 <> 0 then begin
          match Vterm_lib.Vterm_api.cursor_info vt with
          | Some ci -> Some (body.row + ci.y, body.col + ci.x)
          | None -> None
        end else None
      | _ ->
        Grid.clear_rect g body ~attr:(Theme.attrs ()).ga_default;
        None

let rec render_tree r ~active_leaf_id node =
  let g = Render.curr r in
  match (node : Layout.t) with
  | Leaf leaf ->
    let focused = leaf.id = active_leaf_id in
    let cursor = render_leaf r ~focused leaf in
    if focused then cursor else None
  | VSplit s ->
    let c_a = render_tree r ~active_leaf_id s.a in
    let c_b = render_tree r ~active_leaf_id s.b in
    draw_vborder g s;
    (match c_a with Some _ -> c_a | None -> c_b)
  | HSplit s ->
    let c_a = render_tree r ~active_leaf_id s.a in
    let c_b = render_tree r ~active_leaf_id s.b in
    draw_hborder g s;
    (match c_a with Some _ -> c_a | None -> c_b)

let update_status (ctx : Editor_context.t) r ~(active : Layout.leaf) =
  let compose_active = match ctx.compose with
    | Some cs -> Compose.active cs
    | None -> false
  in
  if compose_active then begin
    let cs = match ctx.compose with Some c -> c | None -> assert false in
    Render.set_status r (View.format_compose_status r cs)
  end
  else begin
    let mp = active.mp in
    let active_term = match mp.tabs with
      | [] -> None
      | _ ->
        (match Msg_pane.active_kind_in mp with
         | Msg_pane.Terminal t -> Some t
         | _ -> None)
    in
    match active_term with
    | None -> Render.set_status r ""
    | Some term ->
      let vt = Terminal.vterm term in
      let title = Terminal.title term in
      let scroll = match Vterm_lib.Vterm_api.scroll_info vt with
        | Some s -> " [" ^ s ^ "]"
        | None -> ""
      in
      let n = List.length mp.tabs in
      let pos =
        if n > 1 then Printf.sprintf " [%d/%d]" (mp.active + 1) n
        else ""
      in
      let (_, cols) = Render.pane_dims r Render.PStatus in
      let left = title ^ scroll in
      let avail = max 0 (cols - 2 - String.length pos) in
      let left =
        if String.length left > avail then String.sub left 0 avail
        else left ^ String.make (avail - String.length left) ' '
      in
      Render.set_status r (left ^ pos)
  end

let render_all (ctx : Editor_context.t) r layout ~active_leaf_id
    ~(overlay : (Grid.t -> unit) option) =
  let g = Render.curr r in
  (* Clear the layout area each frame so old terminal cells (e.g.
     from a closed leaf whose sibling has now expanded) don't bleed
     through. *)
  Grid.clear_rect g (body_rect r) ~attr:(Theme.attrs ()).ga_default;
  let cursor = render_tree r ~active_leaf_id layout in
  (* Status. Find the active leaf (or fall back to first). *)
  let active_leaf = match Layout.find_leaf_by_id layout active_leaf_id with
    | Some l -> l
    | None ->
      (match Layout.leaves layout with
       | l :: _ -> l
       | [] -> failwith "View_terminal.render_all: empty layout")
  in
  update_status ctx r ~active:active_leaf;
  (* Cursor placement (only when active leaf's active terminal has
     a visible cursor). *)
  (match cursor with
   | Some (row, col) ->
     Render.place_cursor r ~row ~col;
     Render.set_cursor_visible r true
   | None ->
     Render.set_cursor_visible r false);
  (* Optional overlay (drag-tab ghost) painted last. *)
  (match overlay with
   | Some f -> f g
   | None -> ())
