type case_mode =
  | Smart
  | Sensitive

type flags = {
  case : case_mode;
  regex : bool;
}

type pos = { line : int; col : int }

type match_ = { start_ : pos; end_ : pos }

type focus = Find | Replace

type state = {
  query : string;
  flags : flags;
  matches : match_ array;
  current : int;
  saved_cursor : pos;
  replacement : string;
  focus : focus;
}

(* --- New state model (in progress; see docs/SEARCH_STATE_REFACTOR.md) ---

   The old [state] above conflates a global "what we're searching for"
   with per-buffer "where the matches are". The model below splits
   that cleanly. Both will coexist during the phased migration; the
   old type is retired in Phase 2. *)

type query_state = {
  query : Text_field.t;
  flags : flags;
  replacement : Text_field.t;
  focus : focus;
}

type buffer_matches = {
  matches : match_ array;
  mutable current : int;
  saved_cursor : pos;
}

let empty_flags = { case = Smart; regex = false }

let empty_query () = {
  query = Text_field.create ();
  flags = empty_flags;
  replacement = Text_field.create ();
  focus = Find;
}

let has_uppercase s =
  let len = String.length s in
  let rec scan i =
    if i >= len then false
    else
      let c = s.[i] in
      if c >= 'A' && c <= 'Z' then true
      else scan (i + 1)
  in
  scan 0

let is_case_insensitive ~query ~flags =
  match flags.case with
  | Sensitive -> false
  | Smart -> not (has_uppercase query)

let line_starts text =
  let len = String.length text in
  let acc = ref [0] in
  for i = 0 to len - 1 do
    if text.[i] = '\n' then acc := (i + 1) :: !acc
  done;
  Array.of_list (List.rev !acc)

(* Largest index [i] such that [starts.(i) <= off]. *)
let line_of_offset starts off =
  let n = Array.length starts in
  let lo = ref 0 and hi = ref (n - 1) in
  while !lo < !hi do
    let mid = (!lo + !hi + 1) / 2 in
    if starts.(mid) <= off then lo := mid
    else hi := mid - 1
  done;
  !lo

let pos_of_offset starts off =
  let line = line_of_offset starts off in
  { line; col = off - starts.(line) }

let pos_compare a b =
  if a.line <> b.line then compare a.line b.line
  else compare a.col b.col

let compile_re query flags =
  if query = "" then None
  else
    try
      let pat =
        if flags.regex then Re.Pcre.re query
        else Re.str query
      in
      let pat =
        if is_case_insensitive ~query ~flags
        then Re.no_case pat
        else pat
      in
      Some (Re.compile pat)
    with _ -> None

(* Core matcher: operate on raw text. Used directly by the
   project-wide scanner so it doesn't have to wrap each scanned file
   in a Buffer.t. *)
let recompute_in_text (text : string) (query : string) (flags : flags)
  : match_ array =
  match compile_re query flags with
  | None -> [||]
  | Some re ->
    let starts = line_starts text in
    Re.all re text
    |> List.map (fun g ->
      let s = Re.Group.start g 0 in
      let e = Re.Group.stop g 0 in
      { start_ = pos_of_offset starts s; end_ = pos_of_offset starts e })
    |> Array.of_list

let recompute (buf : Buffer.t) (query : string) (flags : flags) : match_ array =
  recompute_in_text (Buffer.text buf) query flags

(* Build a [buffer_matches] from [buf] under the given [query_state].
   [anchor] picks the new [current] — typically the previous current's
   start or, when there was no previous current, the cursor at the
   moment ^F was pressed in this buffer. [saved_cursor] is forwarded
   verbatim onto the new record. *)
let recompute_buffer_matches (q : query_state) (buf : Buffer.t)
    ~(anchor : pos) ~(saved_cursor : pos) : buffer_matches =
  let matches = recompute buf (Text_field.contents q.query) q.flags in
  let n = Array.length matches in
  let current =
    if n = 0 then -1
    else
      let rec scan i =
        if i >= n then 0  (* wrap to first *)
        else if pos_compare matches.(i).start_ anchor >= 0 then i
        else scan (i + 1)
      in
      scan 0
  in
  { matches; current; saved_cursor }

(* Anchor for "preserve position across a recompute": the previous
   current's start_ when valid, else the saved_cursor. *)
let anchor_of (m : buffer_matches) : pos =
  if m.current >= 0 && m.current < Array.length m.matches
  then m.matches.(m.current).start_
  else m.saved_cursor

(* In-place navigation on a buffer_matches record. Mutates [current]. *)
let bm_next (m : buffer_matches) =
  let n = Array.length m.matches in
  if n > 0 then
    m.current <- (max 0 m.current + 1) mod n

let bm_prev (m : buffer_matches) =
  let n = Array.length m.matches in
  if n > 0 then
    m.current <- ((max 0 m.current) - 1 + n) mod n

let bm_set_current (m : buffer_matches) idx =
  let n = Array.length m.matches in
  if n = 0 then m.current <- -1
  else m.current <- max 0 (min (n - 1) idx)

let bm_current_match (m : buffer_matches) : match_ option =
  if m.current >= 0 && m.current < Array.length m.matches
  then Some m.matches.(m.current)
  else None

let first_match_at_or_after matches anchor =
  let n = Array.length matches in
  if n = 0 then -1
  else
    let rec scan i =
      if i >= n then 0  (* wrap to first *)
      else if pos_compare matches.(i).start_ anchor >= 0 then i
      else scan (i + 1)
    in
    scan 0

let create (buf : Buffer.t) : state =
  let (line, col) = Buffer.cursor buf in
  { query = "";
    flags = empty_flags;
    matches = [||];
    current = -1;
    saved_cursor = { line; col };
    replacement = "";
    focus = Find;
  }

let resave_cursor (s : state) (buf : Buffer.t) : state =
  let (line, col) = Buffer.cursor buf in
  { s with saved_cursor = { line; col } }

let update_query (s : state) buf new_query : state =
  let matches = recompute buf new_query s.flags in
  let current = first_match_at_or_after matches s.saved_cursor in
  { s with query = new_query; matches; current }

(* Anchor for "preserve current through change": the previous current's
   start, or the saved cursor if there was no current. *)
let edit_anchor (s : state) =
  if s.current >= 0 && s.current < Array.length s.matches
  then s.matches.(s.current).start_
  else s.saved_cursor

let update_after_edit (s : state) buf : state =
  let anchor = edit_anchor s in
  let matches = recompute buf s.query s.flags in
  let current = first_match_at_or_after matches anchor in
  { s with matches; current }

let set_flags (s : state) buf new_flags : state =
  let anchor = edit_anchor s in
  let matches = recompute buf s.query new_flags in
  let current = first_match_at_or_after matches anchor in
  { s with flags = new_flags; matches; current }

let toggle_case (s : state) buf : state =
  let case = match s.flags.case with Smart -> Sensitive | Sensitive -> Smart in
  set_flags s buf { s.flags with case }

let toggle_regex (s : state) buf : state =
  set_flags s buf { s.flags with regex = not s.flags.regex }

let next (s : state) : state =
  let n = Array.length s.matches in
  if n = 0 then s
  else { s with current = (s.current + 1) mod n }

let prev (s : state) : state =
  let n = Array.length s.matches in
  if n = 0 then s
  else { s with current = (s.current - 1 + n) mod n }

let set_current (s : state) idx : state =
  let n = Array.length s.matches in
  if n = 0 then { s with current = -1 }
  else { s with current = max 0 (min (n - 1) idx) }

let current_match (s : state) =
  if s.current >= 0 && s.current < Array.length s.matches
  then Some s.matches.(s.current)
  else None

let set_replacement (s : state) replacement : state = { s with replacement }
let set_focus (s : state) focus : state = { s with focus }

(* Expand $1..$9, $&, $$ in [template] against [groups] (groups.(0) is the
   whole match). Unknown $X sequences are kept verbatim. *)
let expand_template template groups =
  let n = String.length template in
  let buf = Stdlib.Buffer.create (n + 16) in
  let group_text i =
    if i < Array.length groups then groups.(i) else ""
  in
  let i = ref 0 in
  while !i < n do
    let c = template.[!i] in
    if c = '$' && !i + 1 < n then begin
      let next = template.[!i + 1] in
      if next = '$' then (Stdlib.Buffer.add_char buf '$'; i := !i + 2)
      else if next = '&' then
        (Stdlib.Buffer.add_string buf (group_text 0); i := !i + 2)
      else if next >= '0' && next <= '9' then
        (Stdlib.Buffer.add_string buf (group_text (Char.code next - Char.code '0'));
         i := !i + 2)
      else (Stdlib.Buffer.add_char buf c; incr i)
    end
    else (Stdlib.Buffer.add_char buf c; incr i)
  done;
  Stdlib.Buffer.contents buf

let substitute ~query ~flags ~replacement ~matched =
  if not flags.regex then replacement
  else
    match compile_re query flags with
    | None -> replacement
    | Some re ->
      (match Re.exec_opt re matched with
       | None -> replacement
       | Some g ->
         let groups =
           Array.init (Re.Group.nb_groups g) (fun i ->
             try Re.Group.get g i with Not_found -> "")
         in
         expand_template replacement groups)
