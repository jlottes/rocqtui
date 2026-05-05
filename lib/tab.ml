let next_id = ref 0

type pane_selection = {
  mutable ps_anchor_line : int;
  mutable ps_anchor_col : int;
  mutable ps_cursor_line : int;
  mutable ps_cursor_col : int;
  mutable ps_active : bool;
}

let fresh_pane_sel () =
  { ps_anchor_line = 0; ps_anchor_col = 0;
    ps_cursor_line = 0; ps_cursor_col = 0; ps_active = false }

type msg_tab = {
  mt_name : string;
  mutable mt_lines : string list;
  mutable mt_scroll : int;
  mt_sel : pane_selection;
  mutable mt_lines_cache : string list;
  mt_terminal : Terminal.t option;
}

type msg_tabs = {
  mutable mt_tabs : msg_tab list;
  mutable mt_active : int;
}

let fresh_msg_tab name =
  { mt_name = name; mt_lines = []; mt_scroll = 0;
    mt_sel = fresh_pane_sel (); mt_lines_cache = [];
    mt_terminal = None }

let fresh_msg_tabs () =
  { mt_tabs = [fresh_msg_tab "Rocq"]; mt_active = 0 }

let active_msg_tab mt =
  if mt.mt_active >= 0 && mt.mt_active < List.length mt.mt_tabs then
    List.nth mt.mt_tabs mt.mt_active
  else
    List.hd mt.mt_tabs  (* fallback to first *)

let find_msg_tab mt name =
  let rec find i = function
    | [] -> None
    | t :: _ when t.mt_name = name -> Some (i, t)
    | _ :: rest -> find (i + 1) rest
  in
  find 0 mt.mt_tabs

let ensure_msg_tab mt name =
  match find_msg_tab mt name with
  | Some (_, t) -> t
  | None ->
    let t = fresh_msg_tab name in
    mt.mt_tabs <- mt.mt_tabs @ [t];
    t

let activate_msg_tab mt name =
  match find_msg_tab mt name with
  | Some (i, _) -> mt.mt_active <- i
  | None -> ()

(* Get the display name for a msg_tab. Terminal tabs use their
   dynamic title; text tabs use mt_name. *)
let msg_tab_display_name (tab : msg_tab) =
  match tab.mt_terminal with
  | Some term -> Terminal.title term
  | None -> tab.mt_name

(* Sticky terminal: when set, sync_terminals will activate this
   terminal across file tab switches. *)
let sticky_terminal : Terminal.t option ref = ref None

let set_sticky_terminal term = sticky_terminal := term
let get_sticky_terminal () = !sticky_terminal

(* Sync global terminals into msg_tabs. Adds/removes terminal sub-tabs
   to match Terminal.all(). Called before rendering. *)
let sync_terminals mt =
  let live = Terminal.all () in
  (* Remember the currently active terminal (if any) *)
  let cur_active = active_msg_tab mt in
  (match cur_active.mt_terminal with
   | Some _ as t -> sticky_terminal := t
   | None -> ());
  (* Remove stale terminal tabs *)
  mt.mt_tabs <- List.filter (fun tab ->
    match tab.mt_terminal with
    | None -> true
    | Some term -> List.exists (fun t -> t == term) live
  ) mt.mt_tabs;
  (* Add new terminals *)
  List.iter (fun term ->
    let exists = List.exists (fun tab ->
      match tab.mt_terminal with
      | Some t -> t == term
      | None -> false
    ) mt.mt_tabs in
    if not exists then begin
      let tab = { mt_name = "Terminal";
                  mt_lines = []; mt_scroll = 0;
                  mt_sel = fresh_pane_sel ();
                  mt_lines_cache = [];
                  mt_terminal = Some term } in
      mt.mt_tabs <- mt.mt_tabs @ [tab]
    end
  ) live;
  (* Clamp active index *)
  let n = List.length mt.mt_tabs in
  if mt.mt_active >= n then mt.mt_active <- max 0 (n - 1);
  (* Restore sticky terminal if set *)
  (match !sticky_terminal with
   | Some term ->
     let rec find i = function
       | [] -> ()
       | tab :: _ when tab.mt_terminal <> None &&
           (match tab.mt_terminal with Some t -> t == term | None -> false) ->
         mt.mt_active <- i
       | _ :: rest -> find (i + 1) rest
     in
     find 0 mt.mt_tabs
   | None -> ())

type t = {
  id : int;
  buf : Buffer.t;
  rb : Region_buffer.t;
  mutable session : Session.t option;
  session_args : string list;
  mutable focused_pane : [`Script | `Goals | `Messages];
  mutable goals_scroll : int;
  mutable show_all_hyps : bool;
  mutable mouse_selecting : bool;
  mutable last_ensured_cur : (int * int) option;
  goals_sel : pane_selection;
  mutable goals_lines_cache : string list;
  msg : msg_tabs;
  mutable search : Search.state option;
  (* [Buffer.revision buf] when [search] was last refreshed; only
     meaningful when [search <> None]. *)
  mutable search_revision : int;
}

type manager = {
  mutable tabs : t list;
  mutable active : int;
  mutable tab_scroll : int;
}

let fresh_id () =
  let id = !next_id in
  incr next_id;
  id

let make_tab ?(args=[]) buf session =
  { id = fresh_id (); buf;
    rb = Region_buffer.create buf ~session;
    session; session_args = args;
    focused_pane = `Script;
    goals_scroll = 0;
    show_all_hyps = false;
    mouse_selecting = false;
    last_ensured_cur = None;
    goals_sel = fresh_pane_sel ();
    goals_lines_cache = [];
    msg = fresh_msg_tabs ();
    search = None;
    search_revision = 0 }

let create_blank ?(args=[]) () =
  let buf = Buffer.create () in
  let session =
    try Some (Session.create ~args buf)
    with _ -> None
  in
  make_tab ~args buf session

let create_from_file ?(args=[]) filename =
  let buf = Buffer.create () in
  Buffer.set_filename buf filename;
  let session =
    try Some (Session.create ~args buf)
    with _ -> None
  in
  let tab = make_tab ~args buf session in
  (* Initial load: routed through the gateway. The session has no
     verified content yet, so the check passes trivially. *)
  ignore (Region_buffer.try_reload_from_disk tab.rb);
  tab

(* Search state with on-demand refresh: if the buffer has changed since
   the search was last computed, re-run the matcher. Returns the
   (possibly updated) state stored on the tab. *)
let search_state tab =
  match tab.search with
  | None -> None
  | Some s ->
    let rev = Buffer.revision tab.buf in
    if rev = tab.search_revision then Some s
    else begin
      let s' = Search.update_after_edit s tab.buf in
      tab.search <- Some s';
      tab.search_revision <- rev;
      Some s'
    end

let set_search tab st =
  tab.search <- st;
  tab.search_revision <- Buffer.revision tab.buf

let active_tab mgr =
  List.nth mgr.tabs mgr.active

let find_by_id mgr id =
  List.find_opt (fun t -> t.id = id) mgr.tabs

let index_of_id mgr id =
  let rec find i = function
    | [] -> None
    | t :: _ when t.id = id -> Some i
    | _ :: rest -> find (i + 1) rest
  in
  find 0 mgr.tabs

let count mgr = List.length mgr.tabs

let add_tab mgr tab =
  let rec insert i = function
    | [] -> [tab]
    | x :: rest ->
      if i = mgr.active then x :: tab :: rest
      else x :: insert (i + 1) rest
  in
  mgr.tabs <- insert 0 mgr.tabs;
  mgr.active <- mgr.active + 1

(* Switch to a tab by ID. Returns true if found. *)
let switch_to_id mgr id =
  match index_of_id mgr id with
  | Some idx -> mgr.active <- idx; true
  | None -> false

(* Open a file in a new tab, or switch to it if already open.
   Returns (tab, created) where created=true if a new tab was made. *)
let open_or_switch mgr ?(extra_args=[]) path =
  let existing = List.find_opt (fun t ->
    Buffer.filename t.buf = Some path
  ) mgr.tabs in
  match existing with
  | Some t ->
    ignore (switch_to_id mgr t.id);
    (t, false)
  | None ->
    let (_pd, pargs) = Project.find_args (Some path) in
    let new_tab = create_from_file ~args:(pargs @ extra_args) path in
    add_tab mgr new_tab;
    (new_tab, true)

let close_active mgr =
  let n = List.length mgr.tabs in
  if n <= 1 then false
  else begin
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

(* Compute disambiguated display names for tabs.
   When multiple tabs share the same basename, progressively prepend
   parent directory components until all names are unique. *)
let display_names mgr =
  let tab_paths = List.map (fun (t : t) ->
    match Buffer.filename t.buf with
    | Some f -> (t.id, f)
    | None -> (t.id, "")
  ) mgr.tabs in
  (* Split path into components, root first: "/a/b/c.v" -> ["/";"a";"b";"c.v"] *)
  let split_path f =
    let rec aux acc f =
      let base = Filename.basename f in
      let dir = Filename.dirname f in
      if dir = f || base = "" then base :: acc
      else aux (base :: acc) dir
    in
    aux [] f
  in
  let components = List.map (fun (id, f) ->
    if f = "" then (id, ["[new]"])
    else (id, split_path f)
  ) tab_paths in
  let name_of_parts parts n =
    let len = List.length parts in
    let start = max 0 (len - n) in
    let selected = List.filteri (fun i _ -> i >= start) parts in
    String.concat "/" selected
  in
  (* Per-entry depth: only increase depth for entries that have duplicates *)
  let entries = ref (List.map (fun (id, parts) ->
    (id, 1, parts)
  ) components) in
  let has_dups () =
    let ns = List.map (fun (_, d, parts) -> name_of_parts parts d) !entries in
    let unique = List.sort_uniq String.compare ns in
    List.length unique < List.length ns
  in
  let max_iter = ref 0 in
  while has_dups () && !max_iter < 20 do
    incr max_iter;
    (* Find which names are duplicated *)
    let ns = List.map (fun (id, d, parts) ->
      (id, name_of_parts parts d, d, parts)
    ) !entries in
    let counts = Hashtbl.create 16 in
    List.iter (fun (_, n, _, _) ->
      let c = try Hashtbl.find counts n with Not_found -> 0 in
      Hashtbl.replace counts n (c + 1)
    ) ns;
    (* Increase depth only for entries whose current name is duplicated *)
    entries := List.map (fun (id, n, d, parts) ->
      if Hashtbl.find counts n > 1 then (id, d + 1, parts)
      else (id, d, parts)
    ) ns
  done;
  List.map (fun (id, d, parts) -> (id, name_of_parts parts d)) !entries

(* Project-relative path for a file, or basename if no project *)
let project_relative_path filename =
  match filename with
  | None -> "[new]"
  | Some f ->
    let dir = Filename.dirname f in
    match Project.find_project_file dir with
    | Some (project_dir, _) ->
      let prefix = project_dir ^ "/" in
      let prefix_len = String.length prefix in
      if String.length f > prefix_len
         && String.sub f 0 prefix_len = prefix then
        String.sub f prefix_len (String.length f - prefix_len)
      else
        Filename.basename f
    | None -> Filename.basename f

let tab_at_x mgr x =
  let dnames = display_names mgr in
  let col = ref 1 in
  let found = ref None in
  List.iteri (fun i tab ->
    let name = match List.assoc_opt tab.id dnames with
      | Some n -> n | None -> "[?]"
    in
    let modified = Buffer.modified tab.buf in
    let label = (if modified then "*" else "") ^ name in
    let width = String.length label + 2 in
    if x >= !col && x < !col + width && !found = None then
      found := Some i;
    col := !col + width + 1
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
