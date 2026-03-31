(* Rendering layer: pane layout on top of Grid.
   Replaces Display.t and ncurses window management. *)

type rect = {
  row : int;
  col : int;
  height : int;
  width : int;
}

type pane_id =
  | PScript | PMinimap | PGoals | PMessages | PStatus | PTabBar
  | PBorderV | PBorderH | PBorderMinimap | PNone

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
}

let empty_rect = { row = 0; col = 0; height = 0; width = 0 }

let compute_layout t =
  let top = if t.has_tab_bar then 1 else 0 in
  let content_h = t.term_h - top - 1 in  (* minus status bar *)
  let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
  let script_w = t.split_col - mm_total in
  t.script <- { row = top; col = 0;
                height = content_h; width = max 1 script_w };
  t.minimap_rect <- (if t.minimap_width > 0 then
    { row = top; col = script_w; height = content_h;
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
    cursor_row = 0; cursor_col = 0;
    cursor_visible = true;
    overlay = None;
    script = empty_rect; goals = empty_rect;
    messages = empty_rect; status = empty_rect;
    minimap_rect = empty_rect;
  } in
  compute_layout t;
  t

let resize t =
  let (h, w) = Term.size () in
  t.term_h <- h;
  t.term_w <- w;
  t.split_col <- min t.split_col (w - 15);
  t.split_row <- min t.split_row (h - 3);
  Grid.resize t.curr h w;
  Grid.resize t.prev h w;
  Grid.clear t.prev;  (* force full redraw *)
  compute_layout t

(* --- Pane hit testing --- *)

let pane_at t ~x ~y =
  if t.has_tab_bar && y = 0 then PTabBar
  else if y >= t.term_h - 1 then PStatus
  else begin
    let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
    let script_w = t.split_col - mm_total in
    if x < script_w then PScript
    else if t.minimap_width > 0 && x = script_w then PBorderMinimap
    else if x < t.split_col then PMinimap
    else if x = t.split_col then PBorderV
    else if y < t.split_row then PGoals
    else if y = t.split_row then PBorderH
    else PMessages
  end

(* --- Drawing into panes --- *)

(* Write a string into a pane at pane-relative (row, col) *)
let put_str t pane ~row ~col s attr =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | PMinimap -> t.minimap_rect | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
    | _ -> empty_rect
  in
  if row >= 0 && row < r.height then
    Grid.put_str t.curr ~row:(r.row + row) ~col:(r.col + col) s attr
  else 0

(* Set a single cell in a pane *)
let set_cell t pane ~row ~col s attr =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | PMinimap -> t.minimap_rect | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
    | _ -> empty_rect
  in
  if row >= 0 && row < r.height && col >= 0 && col < r.width then
    Grid.set_cell t.curr ~row:(r.row + row) ~col:(r.col + col) s attr

(* Fill a region within a pane *)
let fill t pane ~row ~col ~width ch attr =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | PMinimap -> t.minimap_rect | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
    | _ -> empty_rect
  in
  if row >= 0 && row < r.height then
    Grid.fill t.curr ~row:(r.row + row) ~col:(r.col + col) ~width ch attr

(* Change attributes of a region (like mvwchgat) *)
let chgat t pane ~row ~col ~width attr =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | _ -> empty_rect
  in
  let abs_row = r.row + row in
  let abs_col = r.col + col in
  if abs_row >= 0 && abs_row < t.term_h then
    for c = abs_col to min (abs_col + width - 1) (t.term_w - 1) do
      if c >= 0 then
        t.curr.cells.(abs_row).(c).attr <- attr
    done

(* Clear a pane — content panes use theme default, UI panes use their own *)
let clear_pane t pane =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | PMinimap -> t.minimap_rect | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
    | _ -> empty_rect
  in
  let attr = match pane with
    | PScript | PGoals | PMessages -> (Theme.attrs ()).ga_default
    | PStatus -> (Theme.attrs ()).ga_status
    | _ -> Grid.default_attr
  in
  Grid.clear_region t.curr ~row:r.row ~col:r.col
    ~height:r.height ~width:r.width ~attr

(* Get pane dimensions *)
let pane_dims t pane =
  let r = match pane with
    | PScript -> t.script | PGoals -> t.goals
    | PMessages -> t.messages | PStatus -> t.status
    | PMinimap -> t.minimap_rect
    | _ -> empty_rect
  in
  (r.height, r.width)

(* Get pane rect *)
let pane_rect t pane =
  match pane with
  | PScript -> t.script | PGoals -> t.goals
  | PMessages -> t.messages | PStatus -> t.status
  | PMinimap -> t.minimap_rect
  | PTabBar -> { row = 0; col = 0; height = 1; width = t.term_w }
  | _ -> empty_rect

(* Raw grid access *)
let curr t = t.curr

(* --- Chrome (borders and labels) --- *)

let draw_chrome t ?(goals_focused=false) ?(messages_focused=false)
    ?(msg_tab_names=[]) ?(msg_tab_active=0) () =
  let border_attr = (Theme.attrs ()).ga_border in
  let top = if t.has_tab_bar then 1 else 0 in
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

(* --- Cursor --- *)

let place_cursor t ~row ~col =
  t.cursor_row <- row;
  t.cursor_col <- col

let set_cursor_visible t v = t.cursor_visible <- v

(* --- Tab bar --- *)

let draw_tab_bar t tabs active =
  if not t.has_tab_bar then ()
  else begin
    let inactive_attr = (Theme.attrs ()).ga_tab_inactive in
    let active_attr = (Theme.attrs ()).ga_tab_active in
    (* Fill background *)
    Grid.fill t.curr ~row:0 ~col:0 ~width:t.term_w ' ' inactive_attr;
    let col = ref 1 in
    List.iteri (fun i (name, _modified) ->
      let is_active = (i = active) in
      let attr = if is_active then active_attr else inactive_attr in
      let label = Printf.sprintf " %s " name in
      if !col + String.length label < t.term_w then begin
        ignore (Grid.put_str t.curr ~row:0 ~col:!col label attr);
        col := !col + String.length label;
        if i < List.length tabs - 1 then begin
          ignore (Grid.put_str t.curr ~row:0 ~col:!col
            "\xe2\x94\x82" inactive_attr);
          col := !col + 1
        end
      end
    ) tabs
  end

(* --- Status bar --- *)

let set_status t text =
  let attr = (Theme.attrs ()).ga_status in
  Grid.fill t.curr ~row:t.status.row ~col:0 ~width:t.term_w ' ' attr;
  ignore (Grid.put_str t.curr ~row:t.status.row ~col:1 text attr)

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
