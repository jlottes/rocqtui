(* tterm render driver. See view_terminal.mli. *)

let body_rect r =
  let st = Render.pane_rect r Render.PStatus in
  { Render.row = 1; col = 0;
    height = max 0 (st.row - 1);
    width = st.width }

(* Paint a leaf's tab strip into one row at [row], spanning [col..col
   + width - 1]. The same algorithm [Render.draw_tab_bar] uses, but
   for an arbitrary rect rather than the full top row. *)
let draw_leaf_strip g ~row ~col ~width (mp : Msg_pane.t) =
  let inactive_attr = (Theme.attrs ()).ga_tab_inactive in
  let active_attr = (Theme.attrs ()).ga_tab_active in
  Grid.fill g ~row ~col ~width ' ' inactive_attr;
  let pen = ref (col + 1) in
  let right = col + width in
  List.iteri (fun i (tab : Msg_pane.tab) ->
    let name = Msg_pane.display_name tab in
    let label = " " ^ name ^ " " in
    let is_active = (i = mp.active) in
    let attr = if is_active then active_attr else inactive_attr in
    if !pen + String.length label < right then begin
      ignore (Grid.put_str g ~row ~col:!pen label attr);
      pen := !pen + String.length label;
      if i < List.length mp.tabs - 1 && !pen + 1 < right then begin
        ignore (Grid.put_str g ~row ~col:!pen
          "\xe2\x94\x82" inactive_attr);  (* │ *)
        pen := !pen + 1
      end
    end
  ) mp.tabs

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
   the leaf's active terminal has the cursor visible; None otherwise. *)
let render_leaf g (leaf : Layout.leaf) =
  let strip_row = leaf.rect.row in
  draw_leaf_strip g ~row:strip_row ~col:leaf.rect.col
    ~width:leaf.rect.width leaf.mp;
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

let rec render_tree g ~active_leaf_id node =
  match (node : Layout.t) with
  | Leaf leaf ->
    let cursor = render_leaf g leaf in
    if leaf.id = active_leaf_id then cursor else None
  | VSplit s ->
    let c_a = render_tree g ~active_leaf_id s.a in
    let c_b = render_tree g ~active_leaf_id s.b in
    draw_vborder g s;
    (match c_a with Some _ -> c_a | None -> c_b)
  | HSplit s ->
    let c_a = render_tree g ~active_leaf_id s.a in
    let c_b = render_tree g ~active_leaf_id s.b in
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
  let cursor = render_tree g ~active_leaf_id layout in
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
