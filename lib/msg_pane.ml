type kind =
  | Rocq
  | Info
  | Build
  | Errors
  | Search
  | Terminal of Terminal.t

let kind_eq a b = match a, b with
  | Rocq, Rocq | Info, Info | Build, Build | Errors, Errors | Search, Search -> true
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

let create () =
  { tabs = []; active = 0; history = [] }

let global = create ()

let state () = global

(* --- Per-instance API. The singleton functions below are thin
   wrappers that pass [global]. --- *)

let find_in mp kind =
  let rec aux i = function
    | [] -> None
    | t :: _ when kind_eq t.kind kind -> Some (i, t)
    | _ :: rest -> aux (i + 1) rest
  in
  aux 0 mp.tabs

let active_tab_in mp =
  let n = List.length mp.tabs in
  if n = 0 then failwith "Msg_pane.active_tab_in: no tabs"
  else if mp.active >= 0 && mp.active < n then
    List.nth mp.tabs mp.active
  else
    List.hd mp.tabs

let active_kind_in mp = (active_tab_in mp).kind

let ensure_in mp kind =
  match find_in mp kind with
  | Some (_, t) -> t
  | None ->
    let t = make_tab kind in
    mp.tabs <- mp.tabs @ [t];
    t

(* Like [ensure_in], but when creating the tab insert it immediately
   after the first [after] tab instead of appending (falls back to
   append if [after] isn't present). Keeps [active] pointing at the same
   tab. Used to pin the Info tab right after Rocq. *)
let ensure_after_in mp ~after kind =
  match find_in mp kind with
  | Some (_, t) -> t
  | None ->
    let t = make_tab kind in
    let pos = ref (List.length mp.tabs) in
    let rec ins i = function
      | [] -> [t]
      | x :: rest when kind_eq x.kind after -> pos := i + 1; x :: t :: rest
      | x :: rest -> x :: ins (i + 1) rest
    in
    mp.tabs <- ins 0 mp.tabs;
    if !pos <= mp.active then mp.active <- mp.active + 1;
    t

let history_remove kind hist =
  List.filter (fun k -> not (kind_eq k kind)) hist

let pop_active_internal mp =
  let exists k = match find_in mp k with Some _ -> true | None -> false in
  let rec find_existing_in_history = function
    | [] -> None
    | k :: _ when exists k -> Some k
    | _ :: rest -> find_existing_in_history rest
  in
  match find_existing_in_history mp.history with
  | Some target ->
    mp.history <- history_remove target mp.history;
    (match find_in mp target with
     | Some (i, _) -> mp.active <- i
     | None -> assert false)
  | None ->
    if mp.tabs <> [] then mp.active <- 0

let pop_active_in mp = pop_active_internal mp

let activate_in mp kind =
  match find_in mp kind with
  | None -> ()
  | Some (i, _) ->
    let cur = active_kind_in mp in
    if not (kind_eq cur kind) then begin
      mp.history <-
        cur :: history_remove cur (history_remove kind mp.history);
      mp.active <- i
    end

let activate_unless_terminal_in mp kind =
  match active_kind_in mp with
  | Terminal _ -> ()
  | _ -> activate_in mp kind

let remove_in mp kind =
  match find_in mp kind with
  | None -> ()
  | Some (i, _) ->
    let was_active = mp.active = i in
    mp.tabs <- List.filteri (fun j _ -> j <> i) mp.tabs;
    mp.history <- history_remove kind mp.history;
    if was_active then pop_active_internal mp
    else if mp.active > i then mp.active <- mp.active - 1

let display_name tab =
  match tab.kind with
  | Rocq -> "Rocq"
  | Info -> "Info"
  | Build -> "Build"
  | Errors -> "Errors"
  | Search -> "Search"
  | Terminal term -> Terminal.title term

let cycle_in mp delta =
  let n = List.length mp.tabs in
  if n > 1 then begin
    let next_idx = ((mp.active + delta) mod n + n) mod n in
    let next = List.nth mp.tabs next_idx in
    activate_in mp next.kind
  end

let activate_prev_in mp = cycle_in mp (-1)
let activate_next_in mp = cycle_in mp 1

(* Sync [mp]'s tab list against [live]: drop Terminal tabs whose
   terminal is not in [live]; append any [live] terminal that isn't
   already in [mp.tabs]. Non-terminal tabs are untouched. *)
let sync_terminals_in mp live =
  let term_alive t = List.exists (fun t' -> t' == t) live in
  let active_dead =
    mp.active >= 0 && mp.active < List.length mp.tabs &&
    (match (List.nth mp.tabs mp.active).kind with
     | Terminal t -> not (term_alive t)
     | _ -> false)
  in
  let dead_kinds = List.filter_map (fun tab ->
    match tab.kind with
    | Terminal t when not (term_alive t) -> Some tab.kind
    | _ -> None
  ) mp.tabs in
  mp.tabs <- List.filter (fun tab ->
    match tab.kind with
    | Terminal t -> term_alive t
    | _ -> true
  ) mp.tabs;
  mp.history <- List.filter (fun k ->
    not (List.exists (fun dk -> kind_eq k dk) dead_kinds)
  ) mp.history;
  List.iter (fun term ->
    let already = List.exists (fun tab ->
      match tab.kind with
      | Terminal t -> t == term
      | _ -> false
    ) mp.tabs in
    if not already then
      mp.tabs <- mp.tabs @ [make_tab (Terminal term)]
  ) live;
  let n = List.length mp.tabs in
  if mp.active >= n then mp.active <- max 0 (n - 1);
  if active_dead then pop_active_internal mp

(* Reorder / transplant primitives used by tterm's drag-tab
   handling. They don't fit the singleton API and aren't wrapped. *)

(* Remove [tab] from [mp] without dropping its data. Returns true if
   it was present. Used by the drag-tab move: the [tab] record is
   then handed to [insert_in target tab]. *)
let take_tab_in mp tab =
  let before = mp.tabs in
  mp.tabs <- List.filter (fun t -> not (t == tab)) mp.tabs;
  let removed = List.length before <> List.length mp.tabs in
  if removed then begin
    mp.history <- history_remove tab.kind mp.history;
    let n = List.length mp.tabs in
    if mp.active >= n then mp.active <- max 0 (n - 1)
  end;
  removed

(* Append [tab] to [mp] at the end; activate it. The tab's terminal
   (if any) must already be alive in the global list. *)
let insert_in mp tab =
  mp.tabs <- mp.tabs @ [tab];
  mp.active <- List.length mp.tabs - 1

(* --- Singleton API: thin wrappers. --- *)

let find kind = find_in global kind
let active_tab () = active_tab_in global
let active_kind () = active_kind_in global
let ensure kind = ensure_in global kind
let ensure_after ~after kind = ensure_after_in global ~after kind
let pop_active () = pop_active_in global
let activate kind = activate_in global kind
let activate_unless_terminal kind = activate_unless_terminal_in global kind
let remove kind = remove_in global kind
let activate_prev () = activate_prev_in global
let activate_next () = activate_next_in global
let sync_terminals () = sync_terminals_in global (Terminal.all ())
