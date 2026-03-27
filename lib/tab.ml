type t = {
  buf : Buffer.t;
  mutable session : Session.t option;
  session_args : string list;
  mutable goals_scroll : int;
  mutable messages_scroll : int;
  mutable focused_pane : [`Script | `Goals | `Messages];
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable suppress_ensure_visible : bool;
}

type manager = {
  mutable tabs : t list;
  mutable active : int;
  mutable tab_scroll : int;
}

let create_blank ?(args=[]) () =
  let buf = Buffer.create () in
  let session =
    try Some (Session.create ~args buf)
    with _ -> None
  in
  { buf; session; session_args = args;
    goals_scroll = 0;
    messages_scroll = 0;
    focused_pane = `Script;
    show_all_hyps = false;
    mouse_selecting = false;
    suppress_ensure_visible = false }

let create_from_file ?(args=[]) filename =
  let buf =
    if Sys.file_exists filename then Buffer.load_file filename
    else begin
      let b = Buffer.create () in
      Buffer.set_filename b filename;
      b
    end
  in
  let session =
    try Some (Session.create ~args buf)
    with _ -> None
  in
  { buf; session; session_args = args;
    goals_scroll = 0;
    messages_scroll = 0;
    focused_pane = `Script;
    show_all_hyps = false;
    mouse_selecting = false;
    suppress_ensure_visible = false }

let active_tab mgr =
  List.nth mgr.tabs mgr.active

let count mgr = List.length mgr.tabs

let add_tab mgr tab =
  (* Insert after active tab *)
  let rec insert i = function
    | [] -> [tab]
    | x :: rest ->
      if i = mgr.active then x :: tab :: rest
      else x :: insert (i + 1) rest
  in
  mgr.tabs <- insert 0 mgr.tabs;
  mgr.active <- mgr.active + 1

let close_active mgr =
  let n = List.length mgr.tabs in
  if n <= 1 then false
  else begin
    (* Quit the session if any *)
    let tab = active_tab mgr in
    (match tab.session with Some s -> Session.quit s | None -> ());
    mgr.tabs <- List.filteri (fun i _ -> i <> mgr.active) mgr.tabs;
    if mgr.active >= List.length mgr.tabs then
      mgr.active <- List.length mgr.tabs - 1;
    true
  end

let next_tab mgr =
  let n = List.length mgr.tabs in
  if n > 1 then
    mgr.active <- (mgr.active + 1) mod n

let prev_tab mgr =
  let n = List.length mgr.tabs in
  if n > 1 then
    mgr.active <- (mgr.active + n - 1) mod n

let create_manager tab =
  { tabs = [tab]; active = 0; tab_scroll = 0 }

let tab_at_x mgr x =
  let col = ref 1 in
  let found = ref None in
  List.iteri (fun i tab ->
    let name = match Buffer.filename tab.buf with
      | Some f -> Filename.basename f
      | None -> "[new]"
    in
    let modified = Buffer.modified tab.buf in
    let label = (if modified then "*" else "") ^ name in
    let width = String.length label + 2 in  (* " label " *)
    if x >= !col && x < !col + width && !found = None then
      found := Some i;
    col := !col + width + 1  (* +1 for separator *)
  ) mgr.tabs;
  !found

let poll_all mgr =
  let any_changed = ref false in
  List.iter (fun tab ->
    match tab.session with
    | Some s ->
      if Session.poll s then any_changed := true
    | None -> ()
  ) mgr.tabs;
  !any_changed
