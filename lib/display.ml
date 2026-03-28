type t = {
  mutable script : Curses.window;
  mutable goals : Curses.window;
  mutable messages : Curses.window;
  mutable status : Curses.window;
  mutable term_h : int;
  mutable term_w : int;
  mutable split_col : int;
  mutable split_row : int;
  mutable cursor_row : int;
  mutable cursor_col : int;
  mutable has_tab_bar : bool;  (* whether tab bar is shown *)
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

let create_windows h w split_col split_row ~tab_bar =
  let top = if tab_bar then 1 else 0 in
  let script = Curses.newwin (h - 1 - top) split_col top 0 in
  let goals = Curses.newwin (split_row - top) (w - split_col - 1) top (split_col + 1) in
  let messages = Curses.newwin (h - 1 - split_row - 1) (w - split_col - 1) (split_row + 1) (split_col + 1) in
  let status = Curses.newwin 1 w (h - 1) 0 in
  (script, goals, messages, status)

let init_colors () =
  let _ = Curses.start_color () in
  let _ = Curses.use_default_colors () in
  let _ = Curses.init_pair color_verified Curses.Color.black Curses.Color.green in
  let _ = Curses.init_pair color_processing Curses.Color.black Curses.Color.yellow in
  let _ = Curses.init_pair color_error Curses.Color.white Curses.Color.red in
  let _ = Curses.init_pair color_status Curses.Color.black Curses.Color.cyan in
  let _ = Curses.init_pair color_border Curses.Color.cyan (-1) in
  ()

let draw_chrome_on ?(goals_focused=false) ?(messages_focused=false) t =
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
  let messages_label = if messages_focused then "[ Messages ]" else " Messages " in
  Curses.wattron stdscr (Curses.A.color_pair color_border lor Curses.A.bold);
  let _ = Curses.mvwaddstr stdscr top (t.split_col + 2) goals_label in
  let _ = Curses.mvwaddstr stdscr t.split_row (t.split_col + 2) messages_label in
  Curses.wattroff stdscr (Curses.A.color_pair color_border lor Curses.A.bold);
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
  let (script, goals, messages, status) = create_windows h w split_col split_row ~tab_bar in
  let t = { script; goals; messages; status;
            term_h = h; term_w = w; split_col; split_row;
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
  let (script, goals, messages, status) = create_windows h w split_col split_row ~tab_bar:t.has_tab_bar in
  t.script <- script;
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

let draw_chrome ?goals_focused ?messages_focused t =
  draw_chrome_on ?goals_focused ?messages_focused t

type pane_id = PScript | PGoals | PMessages | PStatus | PNone
              | PBorderV | PBorderH | PTabBar

let pane_at t ~x ~y =
  if t.has_tab_bar && y = 0 then PTabBar
  else if y >= t.term_h - 1 then PStatus
  else if x < t.split_col then PScript
  else if x = t.split_col then PBorderV
  else if y < t.split_row then PGoals
  else if y = t.split_row then PBorderH
  else PMessages

let move_split_v t col =
  let col = max 10 (min col (t.term_w - 15)) in
  if col <> t.split_col then begin
    destroy_windows t;
    let _ = Curses.werase (Curses.stdscr ()) in
    let split_col = col in
    let split_row = t.split_row in
    let (script, goals, messages, status) =
      create_windows t.term_h t.term_w split_col split_row ~tab_bar:t.has_tab_bar in
    t.script <- script; t.goals <- goals;
    t.messages <- messages; t.status <- status;
    t.split_col <- split_col;
    Curses.scrollok script true;
    Curses.scrollok goals true;
    Curses.scrollok messages true;
    let _ = Curses.keypad script true in
    Curses.wbkgdset status (Curses.A.color_pair color_status);
    let _ = Curses.werase status in
    draw_chrome_on t
  end

let move_split_h t row =
  let row = max 3 (min row (t.term_h - 5)) in
  if row <> t.split_row then begin
    destroy_windows t;
    let _ = Curses.werase (Curses.stdscr ()) in
    let split_col = t.split_col in
    let split_row = row in
    let (script, goals, messages, status) =
      create_windows t.term_h t.term_w split_col split_row ~tab_bar:t.has_tab_bar in
    t.script <- script; t.goals <- goals;
    t.messages <- messages; t.status <- status;
    t.split_row <- split_row;
    Curses.scrollok script true;
    Curses.scrollok goals true;
    Curses.scrollok messages true;
    let _ = Curses.keypad script true in
    Curses.wbkgdset status (Curses.A.color_pair color_status);
    let _ = Curses.werase status in
    draw_chrome_on t
  end

let set_tab_bar t enabled =
  if t.has_tab_bar <> enabled then begin
    t.has_tab_bar <- enabled;
    resize t
  end

let color_tab_active = 32
let color_tab_inactive = 33

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
  let _ = Curses.wmove t.script t.cursor_row t.cursor_col in
  let _ = Curses.wnoutrefresh t.script in
  if not defer_update then
    ignore (Curses.doupdate ())
