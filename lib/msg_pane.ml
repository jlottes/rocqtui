type kind =
  | Rocq
  | Build
  | Errors
  | Terminal of Terminal.t

let kind_eq a b = match a, b with
  | Rocq, Rocq | Build, Build | Errors, Errors -> true
  | Terminal t1, Terminal t2 -> t1 == t2
  | _ -> false

type tab = {
  kind : kind;
  mutable lines : Styled.line list;
  mutable scroll : int;
  sel : Tab.pane_selection;
  mutable lines_cache : Styled.line list;
}

type t = {
  mutable tabs : tab list;
  mutable active : int;
  mutable history : kind list;
}

let make_tab kind =
  { kind; lines = []; scroll = 0;
    sel = Tab.fresh_pane_sel ();
    lines_cache = [] }

let global = { tabs = [make_tab Rocq]; active = 0; history = [] }

let state () = global

let find kind =
  let rec aux i = function
    | [] -> None
    | t :: _ when kind_eq t.kind kind -> Some (i, t)
    | _ :: rest -> aux (i + 1) rest
  in
  aux 0 global.tabs

let active_tab () =
  let n = List.length global.tabs in
  if n = 0 then make_tab Rocq  (* defensive: should never happen *)
  else if global.active >= 0 && global.active < n then
    List.nth global.tabs global.active
  else
    List.hd global.tabs

let active_kind () = (active_tab ()).kind

let ensure kind =
  match find kind with
  | Some (_, t) -> t
  | None ->
    let t = make_tab kind in
    global.tabs <- global.tabs @ [t];
    t

let history_remove kind hist =
  List.filter (fun k -> not (kind_eq k kind)) hist

let pop_active_internal () =
  let exists k = match find k with Some _ -> true | None -> false in
  let rec find_existing = function
    | [] -> Rocq
    | k :: _ when exists k -> k
    | _ :: rest -> find_existing rest
  in
  let target = find_existing global.history in
  global.history <- history_remove target global.history;
  (match find target with
   | Some (i, _) -> global.active <- i
   | None ->
     ignore (ensure Rocq);
     (match find Rocq with
      | Some (i, _) -> global.active <- i
      | None -> assert false))

let pop_active () = pop_active_internal ()

let activate kind =
  match find kind with
  | None -> ()
  | Some (i, _) ->
    let cur = active_kind () in
    if not (kind_eq cur kind) then begin
      global.history <-
        cur :: history_remove cur (history_remove kind global.history);
      global.active <- i
    end

let activate_unless_terminal kind =
  match active_kind () with
  | Terminal _ -> ()
  | _ -> activate kind

let remove kind =
  match find kind with
  | None -> ()
  | Some (i, _) ->
    let was_active = global.active = i in
    global.tabs <- List.filteri (fun j _ -> j <> i) global.tabs;
    global.history <- history_remove kind global.history;
    if was_active then pop_active_internal ()
    else if global.active > i then global.active <- global.active - 1

let display_name tab =
  match tab.kind with
  | Rocq -> "Rocq"
  | Build -> "Build"
  | Errors -> "Errors"
  | Terminal term -> Terminal.title term

let sync_terminals () =
  let live = Terminal.all () in
  let term_alive t = List.exists (fun t' -> t' == t) live in
  let active_dead =
    global.active >= 0 && global.active < List.length global.tabs &&
    (match (List.nth global.tabs global.active).kind with
     | Terminal t -> not (term_alive t)
     | _ -> false)
  in
  let dead_kinds = List.filter_map (fun tab ->
    match tab.kind with
    | Terminal t when not (term_alive t) -> Some tab.kind
    | _ -> None
  ) global.tabs in
  global.tabs <- List.filter (fun tab ->
    match tab.kind with
    | Terminal t -> term_alive t
    | _ -> true
  ) global.tabs;
  global.history <- List.filter (fun k ->
    not (List.exists (fun dk -> kind_eq k dk) dead_kinds)
  ) global.history;
  List.iter (fun term ->
    let already = List.exists (fun tab ->
      match tab.kind with
      | Terminal t -> t == term
      | _ -> false
    ) global.tabs in
    if not already then
      global.tabs <- global.tabs @ [make_tab (Terminal term)]
  ) live;
  let n = List.length global.tabs in
  if global.active >= n then global.active <- max 0 (n - 1);
  if active_dead then pop_active_internal ()
