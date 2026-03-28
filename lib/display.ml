type t = {
  mutable script : Curses.window;
  mutable minimap : Curses.window option;
  mutable goals : Curses.window;
  mutable messages : Curses.window;
  mutable status : Curses.window;
  mutable term_h : int;
  mutable term_w : int;
  mutable split_col : int;      (* main vertical divider: script+minimap | goals *)
  mutable split_row : int;
  mutable minimap_width : int;  (* 0 = hidden, >0 = braille columns (excl separator) *)
  mutable cursor_row : int;
  mutable cursor_col : int;
  mutable has_tab_bar : bool;
}

(* Color pair IDs *)
let color_verified = 1
let color_processing = 2
let color_error = 3
let color_status = 4
let color_border = 5

let compute_layout h w ~tab_bar =
  let top = if tab_bar then 1 else 0 in
  let content_h = h - top - 1 in  (* minus status bar *)
  let split_col = w * 60 / 100 in
  let split_row = top + content_h / 2 in
  (split_col, split_row)

let create_windows h w split_col split_row ~tab_bar ~minimap_width =
  let top = if tab_bar then 1 else 0 in
  let content_h = h - 1 - top in
  let mm_total = if minimap_width > 0 then minimap_width + 1 else 0 in (* +1 for separator *)
  let script_w = split_col - mm_total in
  let script = Curses.newwin content_h (max 1 script_w) top 0 in
  let minimap = if minimap_width > 0 then
    Some (Curses.newwin content_h (minimap_width + 1) top script_w)  (* +1 for separator col *)
  else None in
  let goals = Curses.newwin (split_row - top) (w - split_col - 1) top (split_col + 1) in
  let messages = Curses.newwin (h - 1 - split_row - 1) (w - split_col - 1) (split_row + 1) (split_col + 1) in
  let status = Curses.newwin 1 w (h - 1) 0 in
  (script, minimap, goals, messages, status)

let init_colors () =
  let _ = Curses.start_color () in
  let _ = Curses.use_default_colors () in
  let _ = Curses.init_pair color_verified Curses.Color.black Curses.Color.green in
  let _ = Curses.init_pair color_processing Curses.Color.black Curses.Color.yellow in
  let _ = Curses.init_pair color_error Curses.Color.white Curses.Color.red in
  let _ = Curses.init_pair color_status Curses.Color.black Curses.Color.cyan in
  let _ = Curses.init_pair color_border Curses.Color.cyan (-1) in
  ()

let color_tab_active = 32
let color_tab_inactive = 33

let draw_chrome_on ?(goals_focused=false) ?(messages_focused=false)
    ?(msg_tab_names=[]) ?(msg_tab_active=0) t =
  let acs = Curses.get_acs_codes () in
  let stdscr = Curses.stdscr () in
  let top = if t.has_tab_bar then 1 else 0 in
  Curses.wattron stdscr (Curses.A.color_pair color_border);
  (* Vertical divider *)
  for row = top to t.term_h - 2 do
    let _ = Curses.mvwaddch stdscr row t.split_col acs.Curses.Acs.vline in
    ()
  done;
  (* Horizontal divider on right side *)
  for col = t.split_col to t.term_w - 1 do
    let ch =
      if col = t.split_col then acs.Curses.Acs.ltee
      else acs.Curses.Acs.hline
    in
    let _ = Curses.mvwaddch stdscr t.split_row col ch in
    ()
  done;
  Curses.wattroff stdscr (Curses.A.color_pair color_border);
  (* Pane labels *)
  let goals_label = if goals_focused then "[ Goals ]" else " Goals " in
  Curses.wattron stdscr (Curses.A.color_pair color_border lor Curses.A.bold);
  let _ = Curses.mvwaddstr stdscr top (t.split_col + 2) goals_label in
  Curses.wattroff stdscr (Curses.A.color_pair color_border lor Curses.A.bold);
  (* Messages tab bar *)
  let col = ref (t.split_col + 2) in
  List.iteri (fun i name ->
    let is_active = (i = msg_tab_active) in
    let focused = messages_focused && is_active in
    let label = if focused then Printf.sprintf "[ %s ]" name
                else Printf.sprintf " %s " name in
    let attr = if is_active then
      Curses.A.color_pair color_tab_active lor Curses.A.bold
    else
      Curses.A.color_pair color_border in
    Curses.wattron stdscr attr;
    let _ = Curses.mvwaddstr stdscr t.split_row !col label in
    Curses.wattroff stdscr attr;
    col := !col + String.length label;
    if i < List.length msg_tab_names - 1 then begin
      Curses.wattron stdscr (Curses.A.color_pair color_border);
      let _ = Curses.mvwaddstr stdscr t.split_row !col "│" in
      Curses.wattroff stdscr (Curses.A.color_pair color_border);
      col := !col + 1  (* │ is 3 bytes but 1 column *)
    end
  ) msg_tab_names;
  let _ = Curses.wnoutrefresh stdscr in
  ()

external setlocale : int -> string -> string = "caml_curses_setlocale"
external all_mouse_events : unit -> int = "caml_all_mouse_events"
external getmouse : unit -> int * int * int * int = "caml_getmouse"

let init () =
  ignore (setlocale 0 "");  (* LC_ALL = 0, "" = use environment *)
  (* Reduce ncurses Escape delay — we handle Escape ourselves *)
  Unix.putenv "ESCDELAY" "25";
  let _stdscr = Curses.initscr () in
  let _ = Curses.raw () in
  let _ = Curses.noecho () in
  let _ = Curses.keypad (Curses.stdscr ()) true in
  (* Enable mouse events + button-motion tracking *)
  ignore (Curses.mousemask (all_mouse_events ()));
  ignore (Unix.write_substring Unix.stdout "\x1b[?1002h" 0 8);
  init_colors ();
  let (h, w) = Curses.getmaxyx (Curses.stdscr ()) in
  let tab_bar = false in  (* enabled later via set_tab_bar *)
  let (split_col, split_row) = compute_layout h w ~tab_bar in
  let minimap_width = 0 in
  let (script, minimap, goals, messages, status) =
    create_windows h w split_col split_row ~tab_bar ~minimap_width in
  let t = { script; minimap; goals; messages; status;
            term_h = h; term_w = w; split_col; split_row;
            minimap_width;
            cursor_row = 0; cursor_col = 0; has_tab_bar = tab_bar } in
  (* Enable scrolling on content panes *)
  Curses.scrollok script true;
  Curses.scrollok goals true;
  Curses.scrollok messages true;
  (* Style the status bar *)
  Curses.wbkgdset status (Curses.A.color_pair color_status);
  let _ = Curses.werase status in
  draw_chrome_on t;
  t

let teardown _t =
  ignore (Unix.write_substring Unix.stdout "\x1b[?1002l" 0 8);
  Curses.endwin ()

let destroy_windows t =
  let _ = Curses.delwin t.script in
  (match t.minimap with Some w -> ignore (Curses.delwin w) | None -> ());
  let _ = Curses.delwin t.goals in
  let _ = Curses.delwin t.messages in
  let _ = Curses.delwin t.status in
  ()

let resize t =
  destroy_windows t;
  let (h, w) = Curses.get_size () in
  let stdscr = Curses.stdscr () in
  let _ = Curses.wresize stdscr h w in
  let _ = Curses.werase stdscr in
  let _ = Curses.keypad stdscr true in
  let (split_col, split_row) = compute_layout h w ~tab_bar:t.has_tab_bar in
  let (script, minimap, goals, messages, status) =
    create_windows h w split_col split_row
      ~tab_bar:t.has_tab_bar ~minimap_width:t.minimap_width in
  t.script <- script;
  t.minimap <- minimap;
  t.goals <- goals;
  t.messages <- messages;
  t.status <- status;
  t.term_h <- h;
  t.term_w <- w;
  t.split_col <- split_col;
  t.split_row <- split_row;
  Curses.scrollok script true;
  Curses.scrollok goals true;
  Curses.scrollok messages true;
  let _ = Curses.keypad script true in
  Curses.wbkgdset status (Curses.A.color_pair color_status);
  let _ = Curses.werase status in
  draw_chrome_on t

let script_win t = t.script
let goals_win t = t.goals
let messages_win t = t.messages
let status_win t = t.status

let script_dims t =
  Curses.getmaxyx t.script

let draw_chrome ?goals_focused ?messages_focused ?msg_tab_names ?msg_tab_active t =
  draw_chrome_on ?goals_focused ?messages_focused ?msg_tab_names ?msg_tab_active t

type pane_id = PScript | PMinimap | PGoals | PMessages | PStatus | PNone
              | PBorderV | PBorderH | PBorderMinimap | PTabBar

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

let rebuild_layout t =
  destroy_windows t;
  let _ = Curses.werase (Curses.stdscr ()) in
  let (script, minimap, goals, messages, status) =
    create_windows t.term_h t.term_w t.split_col t.split_row
      ~tab_bar:t.has_tab_bar ~minimap_width:t.minimap_width in
  t.script <- script; t.minimap <- minimap;
  t.goals <- goals; t.messages <- messages; t.status <- status;
  Curses.scrollok script true;
  Curses.scrollok goals true;
  Curses.scrollok messages true;
  let _ = Curses.keypad script true in
  Curses.wbkgdset status (Curses.A.color_pair color_status);
  let _ = Curses.werase status in
  draw_chrome_on t

let move_split_v t col =
  let mm_total = if t.minimap_width > 0 then t.minimap_width + 1 else 0 in
  let col = max (10 + mm_total) (min col (t.term_w - 15)) in
  if col <> t.split_col then begin
    t.split_col <- col;
    rebuild_layout t
  end

let move_split_h t row =
  let row = max 3 (min row (t.term_h - 5)) in
  if row <> t.split_row then begin
    t.split_row <- row;
    rebuild_layout t
  end

let set_minimap_width t w =
  let w = max 0 (min w (t.split_col - 12)) in
  if w <> t.minimap_width then begin
    t.minimap_width <- w;
    rebuild_layout t
  end

let minimap_width t = t.minimap_width

let minimap_win t = t.minimap

(* Determine which messages sub-tab was clicked on the horizontal divider.
   Returns the tab index or None. *)
let msg_tab_at_x t ~x ~tab_names =
  if x <= t.split_col + 1 then None
  else begin
    let col = ref (t.split_col + 2) in
    let found = ref None in
    List.iteri (fun i name ->
      let label_len = String.length name + 2 in  (* " name " *)
      if x >= !col && x < !col + label_len && !found = None then
        found := Some i;
      col := !col + label_len;
      if i < List.length tab_names - 1 then
        col := !col + 1  (* separator │ *)
    ) tab_names;
    !found
  end

let move_minimap_border t col =
  (* col is the screen x of the minimap's left border.
     minimap_width = split_col - col - 1 *)
  let new_w = t.split_col - col - 1 in
  let new_w = max 2 (min new_w (t.split_col - 12)) in
  if new_w <> t.minimap_width then begin
    t.minimap_width <- new_w;
    rebuild_layout t
  end

let set_tab_bar t enabled =
  if t.has_tab_bar <> enabled then begin
    t.has_tab_bar <- enabled;
    resize t
  end

let draw_tab_bar t tabs active =
  if not t.has_tab_bar then ()
  else begin
    let stdscr = Curses.stdscr () in
    (* Clear tab bar row *)
    let _ = Curses.move 0 0 in
    Curses.wattron stdscr (Curses.A.color_pair color_tab_inactive);
    for _ = 0 to t.term_w - 1 do
      ignore (Curses.waddch stdscr (Char.code ' '))
    done;
    Curses.wattroff stdscr (Curses.A.color_pair color_tab_inactive);
    (* Draw tabs *)
    let col = ref 1 in
    List.iteri (fun i (name, modified) ->
      let label = (if modified then "*" else "") ^ name in
      let is_active = (i = active) in
      let pair = if is_active then color_tab_active else color_tab_inactive in
      let attr = if is_active then Curses.A.bold else Curses.A.normal in
      if !col + String.length label + 3 < t.term_w then begin
        Curses.wattron stdscr (Curses.A.color_pair pair lor attr);
        let _ = Curses.mvwaddstr stdscr 0 !col (Printf.sprintf " %s " label) in
        Curses.wattroff stdscr (Curses.A.color_pair pair lor attr);
        col := !col + String.length label + 2;
        if i < List.length tabs - 1 then begin
          Curses.wattron stdscr (Curses.A.color_pair color_tab_inactive);
          let _ = Curses.mvwaddstr stdscr 0 !col "│" in
          Curses.wattroff stdscr (Curses.A.color_pair color_tab_inactive);
          col := !col + 1
        end
      end
    ) tabs;
    let _ = Curses.wnoutrefresh stdscr in
    ()
  end

let get_mouse () = getmouse ()

let set_status t text =
  let _ = Curses.werase t.status in
  let _ = Curses.mvwaddstr t.status 0 0 (" " ^ text) in
  let _ = Curses.wnoutrefresh t.status in
  ()

let place_cursor t ~row ~col =
  t.cursor_row <- row;
  t.cursor_col <- col

let refresh_all ?(defer_update=false) t =
  let _ = Curses.wnoutrefresh t.goals in
  let _ = Curses.wnoutrefresh t.messages in
  let _ = Curses.wnoutrefresh t.status in
  (match t.minimap with
   | Some w -> ignore (Curses.wnoutrefresh w)
   | None -> ());
  let _ = Curses.wmove t.script t.cursor_row t.cursor_col in
  let _ = Curses.wnoutrefresh t.script in
  if not defer_update then
    ignore (Curses.doupdate ())
