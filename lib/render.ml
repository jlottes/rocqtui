(* Rendering layer: pane layout on top of Grid.
   Replaces Display.t and ncurses window management. *)

(* The rect type lives in Grid so the rect-aware drawing primitives
   can share it. Re-exported here so existing callers that reference
   [Render.rect] continue to compile. *)
type rect = Grid.rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

type pane_id =
  | PScript | PMinimap | PGoals | PMessages | PStatus | PTabBar
  | PFileTree
  | PBorderV | PBorderH | PBorderBoth | PBorderMinimap | PBorderFileTree
  | PNone

type overlay = {
  rect : rect;
  render : Grid.t -> rect -> unit;
}

type t = {
  curr : Grid.t;
  prev : Grid.t;
  mutable term_h : int;
  mutable term_w : int;
  mutable split_col : int;
  mutable split_row : int;
  mutable minimap_width : int;
  mutable has_tab_bar : bool;
  mutable panel_rows : int;
  mutable file_tree_visible : bool;
  mutable file_tree_width : int;
  mutable cursor_row : int;
  mutable cursor_col : int;
  mutable cursor_visible : bool;
  mutable overlay : overlay option;
  (* Pane rects — computed from layout *)
  mutable script : rect;
  mutable goals : rect;
  mutable messages : rect;
  mutable status : rect;
  mutable minimap_rect : rect;
  mutable file_tree_rect : rect;
}

let empty_rect = { row = 0; col = 0; height = 0; width = 0 }

let compute_layout t =
  let top = if t.has_tab_bar then 1 else 0 in
  let content_h = t.term_h - top - 1 in  (* minus status bar *)
  let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
  (* File-tree pane on the far left, separator column drawn by chrome. *)
  let ft_total = if t.file_tree_visible then t.file_tree_width + 1 else 0 in
  let script_right = t.split_col - mm_total in
  t.file_tree_rect <- (if t.file_tree_visible then
    { row = top; col = 0;
      height = content_h; width = t.file_tree_width }
  else empty_rect);
  t.script <- { row = top; col = ft_total;
                height = content_h;
                width = max 1 (script_right - ft_total) };
  t.minimap_rect <- (if t.minimap_width > 0 then
    { row = top; col = script_right; height = content_h;
      width = t.minimap_width + 1 }  (* +1 for separator *)
  else empty_rect);
  t.goals <- { row = top; col = t.split_col + 1;
               height = t.split_row - top;
               width = t.term_w - t.split_col - 1 };
  t.messages <- { row = t.split_row + 1; col = t.split_col + 1;
                  height = t.term_h - 1 - t.split_row - 1;
                  width = t.term_w - t.split_col - 1 };
  t.status <- { row = t.term_h - 1; col = 0;
                height = 1; width = t.term_w }

let create () =
  let (h, w) = Term.size () in
  let split_col = w * 60 / 100 in
  let split_row = h / 2 in
  let t = {
    curr = Grid.create h w;
    prev = Grid.create h w;
    term_h = h; term_w = w;
    split_col; split_row;
    minimap_width = 0;
    has_tab_bar = false;
    panel_rows = 0;
    file_tree_visible = false;
    file_tree_width = 28;
    cursor_row = 0; cursor_col = 0;
    cursor_visible = true;
    overlay = None;
    script = empty_rect; goals = empty_rect;
    messages = empty_rect; status = empty_rect;
    minimap_rect = empty_rect;
    file_tree_rect = empty_rect;
  } in
  compute_layout t;
  t

let resize t =
  let (h, w) = Term.size () in
  t.term_h <- h;
  t.term_w <- w;
  t.split_col <- min t.split_col (w - 15);
  t.split_row <- min t.split_row (h - 3);
  if t.file_tree_visible then
    t.file_tree_width <- max 10 (min t.file_tree_width (w - 25));
  Grid.resize t.curr h w;
  Grid.resize t.prev h w;
  Grid.clear t.prev;  (* force full redraw *)
  (* Clear any stale content past the new edge from a shrink. *)
  Term.clear_screen ();
  compute_layout t

(* --- Pane hit testing --- *)

let pane_at t ~x ~y =
  if t.has_tab_bar && y = 0 then PTabBar
  else if y >= t.term_h - 1 - t.panel_rows then PStatus
  else if t.file_tree_visible && x < t.file_tree_width then PFileTree
  else if t.file_tree_visible && x = t.file_tree_width then PBorderFileTree
  else begin
    let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
    let script_w = t.split_col - mm_total in
    if x < script_w then PScript
    else if t.minimap_width > 0 && x = script_w then PBorderMinimap
    else if x < t.split_col then PMinimap
    else if x = t.split_col && y = t.split_row then PBorderBoth
    else if x = t.split_col then PBorderV
    else if y < t.split_row then PGoals
    else if y = t.split_row then PBorderH
    else PMessages
  end

(* --- Drawing into panes --- *)

(* Single source of truth for pane -> rect lookup. All drawing primitives
   and external [pane_rect] / [pane_dims] route through this. Add a new
   pane: one variant in [pane_id], one case here, one line in
   [compute_layout]. *)
let rect_of_pane t = function
  | PScript -> t.script
  | PGoals -> t.goals
  | PMessages -> t.messages
  | PStatus -> t.status
  | PMinimap -> t.minimap_rect
  | PFileTree -> t.file_tree_rect
  | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
  | PBorderV | PBorderH | PBorderBoth
  | PBorderMinimap | PBorderFileTree | PNone -> empty_rect

(* All per-pane drawing routes through Grid's rect-aware primitives so
   writes are clipped to the pane's rect. A long line no longer spills
   into the next pane. *)

let put_str t pane ~row ~col s attr =
  Grid.put_str_in_rect t.curr (rect_of_pane t pane) ~row ~col s attr

let set_cell t pane ~row ~col s attr =
  Grid.set_cell_in_rect t.curr (rect_of_pane t pane) ~row ~col s attr

let fill t pane ~row ~col ~width ch attr =
  Grid.fill_in_rect t.curr (rect_of_pane t pane) ~row ~col ~width ch attr

let chgat t pane ~row ~col ~width attr =
  Grid.chgat_in_rect t.curr (rect_of_pane t pane) ~row ~col ~width attr

let set_underline t pane ~row ~col ~width ~style ~color =
  Grid.set_underline_in_rect t.curr (rect_of_pane t pane)
    ~row ~col ~width ~style ~color

(* Clear a pane — content panes use theme default, UI panes use their own *)
let clear_pane t pane =
  let attr = match pane with
    | PStatus -> (Theme.attrs ()).ga_status
    | _ -> (Theme.attrs ()).ga_default
  in
  Grid.clear_rect t.curr (rect_of_pane t pane) ~attr

(* Get pane dimensions *)
let pane_dims t pane =
  let r = rect_of_pane t pane in
  (r.height, r.width)

(* Get pane rect *)
let pane_rect t pane = rect_of_pane t pane

(* Raw grid access *)
let curr t = t.curr

(* --- Chrome (borders and labels) --- *)

let draw_chrome t ?(goals_focused=false) ?(messages_focused=false)
    ?(msg_tab_names=[]) ?(msg_tab_active=0) () =
  let border_attr = (Theme.attrs ()).ga_border in
  let top = if t.has_tab_bar then 1 else 0 in
  (* File-tree separator (right edge of the panel, when visible) *)
  if t.file_tree_visible then
    for row = top to t.term_h - 2 do
      Grid.set_cell t.curr ~row ~col:t.file_tree_width
        "\xe2\x94\x82" border_attr  (* │ *)
    done;
  (* Vertical divider *)
  for row = top to t.term_h - 2 do
    Grid.set_cell t.curr ~row ~col:t.split_col "\xe2\x94\x82" border_attr  (* │ *)
  done;
  (* Horizontal divider *)
  for col = t.split_col to t.term_w - 1 do
    let ch = if col = t.split_col then "\xe2\x94\x9c"  (* ├ *)
             else "\xe2\x94\x80"  (* ─ *) in
    Grid.set_cell t.curr ~row:t.split_row ~col ch border_attr
  done;
  (* Goals label *)
  let goals_label = if goals_focused then "[ Goals ]" else " Goals " in
  let label_attr = { border_attr with bold = true } in
  ignore (Grid.put_str t.curr ~row:top ~col:(t.split_col + 2) goals_label label_attr);
  (* Messages tab bar *)
  let tab_active_attr = (Theme.attrs ()).ga_tab_active in
  let col = ref (t.split_col + 2) in
  List.iteri (fun i name ->
    let is_active = (i = msg_tab_active) in
    let focused = messages_focused && is_active in
    let label = if focused then Printf.sprintf "[ %s ]" name
                else Printf.sprintf " %s " name in
    let attr = if is_active then tab_active_attr else border_attr in
    ignore (Grid.put_str t.curr ~row:t.split_row ~col:!col label attr);
    col := !col + String.length label;
    if i < List.length msg_tab_names - 1 then begin
      ignore (Grid.put_str t.curr ~row:t.split_row ~col:!col
        "\xe2\x94\x82" border_attr);  (* │ *)
      col := !col + 1
    end
  ) msg_tab_names

(* --- Layout manipulation --- *)

let set_tab_bar t enabled =
  if t.has_tab_bar <> enabled then begin
    t.has_tab_bar <- enabled;
    compute_layout t
  end

let minimap_width t = t.minimap_width

let set_minimap_width t w =
  let w = max 0 (min w (t.split_col - 12)) in
  if w <> t.minimap_width then begin
    t.minimap_width <- w;
    compute_layout t
  end

let move_split_v t col =
  let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
  let col = max (10 + mm_total) (min col (t.term_w - 15)) in
  if col <> t.split_col then begin
    t.split_col <- col;
    compute_layout t
  end

let move_split_h t row =
  let row = max 3 (min row (t.term_h - 5)) in
  if row <> t.split_row then begin
    t.split_row <- row;
    compute_layout t
  end

let move_minimap_border t col =
  let new_w = t.split_col - col - 1 in
  let new_w = max 2 (min new_w (t.split_col - 12)) in
  if new_w <> t.minimap_width then begin
    t.minimap_width <- new_w;
    compute_layout t
  end

let file_tree_visible t = t.file_tree_visible
let file_tree_width t = t.file_tree_width

let set_file_tree_visible t v =
  if v <> t.file_tree_visible then begin
    t.file_tree_visible <- v;
    compute_layout t
  end

(* Drag the file-tree border: new width = clicked column. Clamps so the
   script pane keeps at least 15 cols after accounting for minimap. *)
let move_file_tree_border t col =
  let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
  let max_w = t.split_col - mm_total - 16 in
  let new_w = max 10 (min col max_w) in
  if new_w <> t.file_tree_width then begin
    t.file_tree_width <- new_w;
    compute_layout t
  end

(* --- Cursor --- *)

let place_cursor t ~row ~col =
  t.cursor_row <- row;
  t.cursor_col <- col

let set_cursor_visible t v = t.cursor_visible <- v

let place_cursor_status t ~row_from_bottom ~col =
  let row = t.term_h - 1 - row_from_bottom in
  place_cursor t ~row ~col

(* --- Tab bar --- *)

(* Tab strip layout — shared by the top-level file-tab bar here and
   by [View_terminal.draw_leaf_strip]. A [visible_tab] is a contiguous
   run of cells; both renderer and click hit-test consume the same
   list so geometry stays in sync. *)
type visible_tab = {
  orig_index : int;
  col_offset : int;
  cell_width : int;
  label : string;
}

let tab_ellipsis = "\xe2\x80\xa6"   (* … U+2026, 1 cell *)
let tab_separator = "\xe2\x94\x82"  (* │ U+2502, 1 cell *)
let tab_separator_cells = 1

let tab_strip_layout ?(focused=false) ~display_names ~active ~width () =
  let names = Array.of_list display_names in
  let n = Array.length names in
  if n = 0 || width <= 1 then [] else begin
    let active = max 0 (min active (n - 1)) in
    let labels = Array.mapi (fun i s ->
      if focused && i = active then "[ " ^ s ^ " ]"
      else " " ^ s ^ " "
    ) names in
    let wids = Array.map Utf8.string_width labels in
    let avail = width - 1 in
    let cum_from first =
      let sum = ref 0 in
      for i = first to active do
        sum := !sum + wids.(i);
        if i > first then sum := !sum + tab_separator_cells
      done;
      !sum
    in
    let total_natural =
      let sum = ref 0 in
      for i = 0 to n - 1 do
        sum := !sum + wids.(i);
        if i > 0 then sum := !sum + tab_separator_cells
      done;
      !sum
    in
    let first_visible =
      if total_natural <= avail then 0
      else
        let rec find first =
          if first >= active then active
          else if cum_from first <= avail then first
          else find (first + 1)
        in
        find 0
    in
    let out = ref [] in
    let pen = ref 1 in
    let i = ref first_visible in
    let stop = ref false in
    while not !stop && !i < n do
      let remaining = max 0 (1 + avail - !pen) in
      if remaining < 3 then stop := true
      else begin
        let w = wids.(!i) in
        let label, cell_w =
          if w <= remaining then labels.(!i), w
          else begin
            let take_cells = remaining - 1 in
            let take_bytes = Utf8.col_to_byte labels.(!i) take_cells in
            String.sub labels.(!i) 0 take_bytes ^ tab_ellipsis, remaining
          end
        in
        out := { orig_index = !i; col_offset = !pen;
                 cell_width = cell_w; label } :: !out;
        pen := !pen + cell_w;
        if !i < n - 1 then begin
          if 1 + avail - !pen >= tab_separator_cells + 1 then
            pen := !pen + tab_separator_cells
          else stop := true
        end;
        incr i
      end
    done;
    List.rev !out
  end

let draw_tab_strip t ~row ~col ~width ?(focused=false)
    ~display_names ~active ~active_attr ~inactive_attr () =
  Grid.fill t.curr ~row ~col ~width ' ' inactive_attr;
  let visibles = tab_strip_layout ~focused ~display_names ~active ~width () in
  let arr = Array.of_list visibles in
  Array.iteri (fun k v ->
    let attr = if v.orig_index = active then active_attr else inactive_attr in
    ignore (Grid.put_str t.curr ~row ~col:(col + v.col_offset) v.label attr);
    if k + 1 < Array.length arr then begin
      let sep_col = col + v.col_offset + v.cell_width in
      ignore (Grid.put_str t.curr ~row ~col:sep_col
        tab_separator inactive_attr)
    end
  ) arr

let draw_tab_bar t tabs active =
  if not t.has_tab_bar then ()
  else begin
    let inactive_attr = (Theme.attrs ()).ga_tab_inactive in
    let active_attr = (Theme.attrs ()).ga_tab_active in
    let display_names = List.map fst tabs in
    draw_tab_strip t ~row:0 ~col:0 ~width:t.term_w
      ~display_names ~active ~active_attr ~inactive_attr ()
  end

(* --- Status bar --- *)

let set_status t text =
  let attr = (Theme.attrs ()).ga_status in
  Grid.fill t.curr ~row:t.status.row ~col:0 ~width:t.term_w ' ' attr;
  ignore (Grid.put_str t.curr ~row:t.status.row ~col:1 text attr)

let set_panel_rows t n =
  let n = max 0 n in
  if n <> t.panel_rows then t.panel_rows <- n

let panel_rows t = t.panel_rows

let set_status_line t ~row_from_bottom text =
  let attr = (Theme.attrs ()).ga_status in
  let row = t.term_h - 1 - row_from_bottom in
  if row >= 0 && row < t.term_h then begin
    Grid.fill t.curr ~row ~col:0 ~width:t.term_w ' ' attr;
    ignore (Grid.put_str t.curr ~row ~col:1 text attr)
  end

let set_status_line_styled t ~row_from_bottom segments =
  let base_attr = (Theme.attrs ()).ga_status in
  let row = t.term_h - 1 - row_from_bottom in
  if row >= 0 && row < t.term_h then begin
    Grid.fill t.curr ~row ~col:0 ~width:t.term_w ' ' base_attr;
    let col = ref 1 in
    List.iter (fun (text, attr) ->
      col := !col + Grid.put_str t.curr ~row ~col:!col text attr
    ) segments
  end

let set_overlay t rect render_fn =
  t.overlay <- Some { rect; render = render_fn }

let clear_overlay t =
  t.overlay <- None

(* --- Flush --- *)

(* Diff current vs previous, write ANSI to stdout, swap buffers.
   [force]: skip diff, emit every cell. *)
let present ?(force=false) t =
  (* Apply overlay if any *)
  (match t.overlay with
   | Some ov -> ov.render t.curr ov.rect
   | None -> ());
  let buf = Stdlib.Buffer.create 4096 in
  if force then
    Grid.emit_all t.curr buf
  else
    Grid.diff ~prev:t.prev ~curr:t.curr buf;
  (* Position cursor *)
  if t.cursor_visible then begin
    Stdlib.Buffer.add_string buf
      (Printf.sprintf "\x1b[?25h\x1b[%d;%dH"
         (t.cursor_row + 1) (t.cursor_col + 1))
  end else
    Stdlib.Buffer.add_string buf "\x1b[?25l";
  Stdlib.Buffer.add_string buf "\x1b[0m";
  Term.write_stdout (Stdlib.Buffer.contents buf);
  Grid.copy ~src:t.curr ~dst:t.prev

(* --- Msg tab hit testing --- *)

let msg_tab_at_x t ~x ~tab_names =
  if x <= t.split_col + 1 then None
  else begin
    let col = ref (t.split_col + 2) in
    let found = ref None in
    List.iteri (fun i name ->
      let label_len = String.length name + 2 in
      if x >= !col && x < !col + label_len && !found = None then
        found := Some i;
      col := !col + label_len;
      if i < List.length tab_names - 1 then
        col := !col + 1
    ) tab_names;
    !found
  end
