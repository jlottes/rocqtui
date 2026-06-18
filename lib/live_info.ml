(* Live "About / Print" info for the identifier under the cursor.
   See live_info.mli and docs/LIVE_INFO_PLAN.md. *)

type result = {
  subject : string;
  about_pp : Pp.t list;
  mutable print_pp : Pp.t list option;  (* None until fetched on expand *)
  mutable print_pending : bool;         (* a Print query is in flight *)
  mutable print_stale : bool;           (* displayed Print needs a refetch *)
}

(* A saved-list entry: a live, self-re-querying item below the main one.
   Each carries its own originating session and re-queries (like the main
   pin) when that session's tip or the print options change. [e_level]
   cycles the collapse depth: 0 = type only, 1 = + definition, 2 = +
   information. *)
type entry = {
  e_subject : string;
  e_session : Session.t;
  mutable e_about : Pp.t list;
  mutable e_print : Pp.t list option;
  mutable e_print_pending : bool;
  mutable e_print_stale : bool;
  mutable e_key : (Stateid.t * (string list * Interface.option_value) list) option;
  mutable e_stale : bool;
  mutable e_level : int;
}

let current : result option ref = ref None
let expanded = ref false
let src_session : Session.t option ref = ref None
let saved : entry list ref = ref []

(* Pin: freeze cursor-following on the current result. While pinned the
   subject is fixed and re-queries target the *originating* session, so
   the pinned item survives switching to another file tab. [stale] flags
   that the pinned subject is no longer in scope at its session's current
   tip (e.g. rewound before its definition) — we keep the last good
   result on screen and mark it faintly. *)
let pinned = ref false
let stale = ref false

(* Error for the reserved top row: set when a cursor-driven query (live
   navigation, or an explicit ^A re-pin) fails; cleared on the next
   success or when the cursor leaves the failing identifier. A pinned
   *auto* re-query failure uses [stale] instead, so navigation in the
   pinned state never raises the error row (only an explicit ^A does). *)
let error_msg : string option ref = ref None

(* Dedup key for the live [About] query: the (subject, tip, options)
   triple it was last issued for. We re-fire when any component changes —
   a symbol can go from undefined to defined as the verified region
   advances, and option changes (implicit args, universes, …) alter the
   rendering. The key is set when we *issue* (success OR error), so a
   not-yet-defined symbol isn't retried until the tip moves. *)
let last_about_key = ref None

let key_changed (subject, tip, opts) =
  match !last_about_key with
  | None -> true
  | Some (s', t', o') ->
    not (subject = s' && Stateid.equal tip t' && opts = o')

(* Clickable regions, one per rendered (wrapped) row. The leading column
   ranges are fixed by the header layout; the trailing int is the display
   column of the 🔍 goto-definition glyph (which sits after the subject,
   so its column varies). See [render]. *)
type row_target = RT_main of int | RT_entry of int * int

(* Render cache, rebuilt when the width changes or [dirty] is set.
   [cache_targets] is aligned 1:1 with [cache_lines] (post-wrap). *)
let dirty = ref true
let cache_width = ref (-1)
let cache_lines : Styled.line list ref = ref []
let cache_targets : row_target option array ref = ref [||]

let invalidate () = dirty := true

(* --- small string helpers (lib uses [re], not [str]; keep it local) --- *)

let contains_sub hay needle =
  let hl = String.length hay and nl = String.length needle in
  if nl = 0 then true
  else
    let rec scan i =
      if i + nl > hl then false
      else if String.sub hay i nl = needle then true
      else scan (i + 1)
    in
    scan 0

(* About on an unknown name returns [Good] with the error delivered as a
   feedback *message* (verified empirically — see the plan), so the only
   way to tell an error apart is to sniff the text. Keep the list tight
   to avoid false positives; we keep the last good result on a hit. *)
let error_markers = [
  "not a defined object";
  "was not found";
  "No such";
  "Syntax error";
  "Unbound";
  "Error:";
]

let looks_like_error text =
  let t = String.trim text in
  t = "" || List.exists (contains_sub t) error_markers

(* Prose / informational lines that should be de-emphasised rather than
   syntax-highlighted. The type signature, [Arguments …], and the
   [Print] body are NOT info lines and get highlighted. *)
let is_info_line text =
  let t = String.trim text in
  contains_sub t "universe polymorphic"
  || contains_sub t "is transparent"
  || contains_sub t "is opaque"
  || String.starts_with ~prefix:"Expands to:" t
  || String.starts_with ~prefix:"Declared in" t

(* --- query delivery --- *)

let pp_text msgs =
  String.concat "\n" (List.map (fun pp -> Session.string_of_pp pp) msgs)

let first_line s =
  let s = String.trim s in
  match String.index_opt s '\n' with
  | Some i -> String.sub s 0 i
  | None -> s

let deliver_success s subj msgs =
  (* Preserve the collapse state across re-queries of the same subject
     (tip / option changes); only a genuinely new subject re-collapses. *)
  let same_subject, old_print =
    match !current with
    | Some r when r.subject = subj -> true, r.print_pp
    | _ -> false, None
  in
  current := Some {
    subject = subj; about_pp = msgs;
    (* On a same-subject re-query keep showing the previous definition
       and refetch in the background, so stepping while pinned+expanded
       doesn't flash the About body before Print returns. *)
    print_pp = (if same_subject then old_print else None);
    print_pending = false;
    print_stale = same_subject;
  };
  if not same_subject then expanded := false;
  src_session := Some s;
  stale := false;
  error_msg := None;
  invalidate ()

(* [mode] selects how a failed query is surfaced (the last good result is
   kept on screen either way): [`Cursor] — live navigation or an explicit
   ^A re-pin — puts the message in the reserved error row; [`Auto] — a
   pinned re-query forced by a tip/option change — marks the pinned entry
   stale instead, so navigating while pinned never raises the error row. *)
let deliver_about ~mode s subj msgs =
  if looks_like_error (pp_text msgs) then
    (match mode with
     | `Cursor -> error_msg := Some (first_line (pp_text msgs)); invalidate ()
     | `Auto -> stale := true; invalidate ())
  else deliver_success s subj msgs

let deliver_print subj msgs =
  match !current with
  | Some r when r.subject = subj ->
    r.print_pending <- false;
    r.print_stale <- false;
    (* On a Print error (e.g. an axiom with no body) fall back to the
       About output so expanding always shows something sensible. *)
    if looks_like_error (pp_text msgs) then r.print_pp <- Some r.about_pp
    else r.print_pp <- Some msgs;
    invalidate ()
  | _ -> ()

(* --- saved-list entry delivery --- *)

let deliver_entry_about e msgs =
  if looks_like_error (pp_text msgs) then begin
    e.e_stale <- true; invalidate ()
  end else begin
    e.e_about <- msgs;
    (* Keep the old definition shown; refetch it in the background. *)
    e.e_print_stale <- true;
    e.e_print_pending <- false;
    e.e_stale <- false;
    invalidate ()
  end

let deliver_entry_print e msgs =
  e.e_print_pending <- false;
  e.e_print_stale <- false;
  if looks_like_error (pp_text msgs) then e.e_print <- Some e.e_about
  else e.e_print <- Some msgs;
  invalidate ()

(* Re-query each saved entry against its own session when that session's
   tip or the print options change; fetch its definition lazily once it's
   expanded past the type-only level. One query per (idle) session per
   tick — queries serialise within a session, so this converges. *)
let tick_entries opts =
  List.iter (fun e ->
    if not (Session.is_busy e.e_session) then begin
      let k = Some (Session.tip e.e_session, opts) in
      if e.e_key <> k then begin
        e.e_key <- k;
        Session.query e.e_session ~extra_opts:opts
          ~on_done:(fun msgs -> deliver_entry_about e msgs)
          ("About " ^ e.e_subject ^ ".")
      end
      else if e.e_level >= 1 && (e.e_print = None || e.e_print_stale)
              && not e.e_print_pending then begin
        e.e_print_pending <- true;
        Session.query e.e_session ~extra_opts:opts
          ~on_done:(fun msgs -> deliver_entry_print e msgs)
          ("Print " ^ e.e_subject ^ ".")
      end
    end
  ) !saved

(* --- per-frame driver --- *)

let subject_at_cursor buf =
  match Highlight.qualid_at_cursor buf with
  | Some _ as x -> x
  | None -> Buffer.word_at_cursor buf

(* Explicit ^A re-pin to [w] against session [s]: query now (forcing the
   key) and route the result through the [`Cursor] path, so a failure
   shows in the error row and leaves the current pinned entry intact. *)
let repin s w =
  let opts = Printopts.to_set_options () in
  last_about_key := Some (w, Session.tip s, opts);
  Session.query s ~extra_opts:opts
    ~on_done:(fun msgs -> deliver_about ~mode:`Cursor s w msgs)
    ("About " ^ w ^ ".")

let tick session buf =
  let opts = Printopts.to_set_options () in
  (* While pinned, target the originating session (so the pin survives
     switching file tabs) and keep the subject frozen; otherwise follow
     the active tab's session and cursor. *)
  let active_session = if !pinned then !src_session else session in
  (match active_session with
  | None -> ()
  | Some s ->
    let tip = Session.tip s in
    let mode = if !pinned then `Auto else `Cursor in
    let subject =
      if !pinned then (match !current with Some r -> Some r.subject | None -> None)
      else subject_at_cursor buf
    in
    (* Unpinned: clear the error row once the cursor leaves a failing
       identifier (onto whitespace / a keyword). *)
    if (not !pinned) && subject = None && !error_msg <> None then begin
      error_msg := None; invalidate ()
    end;
    (* (Re-)issue About when the subject, tip, or options change and the
       session is idle. Keep the last result when on a non-identifier
       (subject = None). *)
    (match subject with
     | Some w when key_changed (w, tip, opts) && not (Session.is_busy s) ->
       last_about_key := Some (w, tip, opts);
       Session.query s ~extra_opts:opts
         ~on_done:(fun msgs -> deliver_about ~mode s w msgs)
         ("About " ^ w ^ ".")
     | _ -> ());
    (* Lazily fetch Print for the current subject once expanded, at the
       current tip/options. About produces a fresh result (print_pp =
       None) whenever the key changes, so this re-fetches automatically. *)
    (match !current with
     | Some r
       when !expanded && (r.print_pp = None || r.print_stale)
            && not r.print_pending && not (Session.is_busy s) ->
       r.print_pending <- true;
       let subj = r.subject in
       Session.query s ~extra_opts:opts
         ~on_done:(fun msgs -> deliver_print subj msgs)
         ("Print " ^ subj ^ ".")
     | _ -> ()));
  (* Saved-list entries re-query independently against their own sessions
     (which [Tab.poll_all] keeps polling), regardless of the main item. *)
  tick_entries opts

(* --- accessors --- *)

let has_content () = !current <> None
let current_subject () = match !current with Some r -> Some r.subject | None -> None
let is_expanded () = !expanded

(* (session, subject) to resolve a go-to-definition for the main item /
   the i-th saved entry — each via the session its result came from. *)
let main_locate () =
  match !current, !src_session with
  | Some r, Some s -> Some (s, r.subject)
  | _ -> None

let entry_locate i =
  match List.nth_opt !saved i with
  | Some e -> Some (e.e_session, e.e_subject)
  | None -> None

let toggle_expand () =
  expanded := not !expanded;
  invalidate ()
  (* the Print fetch (if needed) happens on the next idle tick *)

let is_pinned () = !pinned

(* Pin the current result (no-op when there's nothing to pin), or unpin.
   Pinning freezes cursor-following; unpinning resumes it on the next
   tick. *)
let toggle_pin () =
  if !pinned then begin
    pinned := false;
    stale := false;
    invalidate ()
  end else if !current <> None then begin
    pinned := true;
    stale := false;
    invalidate ()
  end

(* Append the current (main) item to the saved list as a live entry,
   capturing its session and current context. Deduped by subject+session.
   Defaults to the type-only collapse level. *)
let append_current () =
  match !current, !src_session with
  | Some r, Some s ->
    let dup = List.exists
      (fun e -> e.e_subject = r.subject && e.e_session == s) !saved in
    if not dup then begin
      let e = {
        e_subject = r.subject;
        e_session = s;
        e_about = r.about_pp;
        e_print = r.print_pp;
        e_print_pending = false;
        e_print_stale = false;
        e_key = Some (Session.tip s, Printopts.to_set_options ());
        e_stale = false;
        e_level = 0;
      } in
      saved := !saved @ [e];
      invalidate ()
    end
  | _ -> ()

let remove_entry i =
  saved := List.filteri (fun j _ -> j <> i) !saved;
  invalidate ()

let cycle_entry i =
  match List.nth_opt !saved i with
  | Some e -> e.e_level <- (e.e_level + 1) mod 3; invalidate ()
  | None -> ()

(* --- rendering --- *)

let glyph_collapsed = "\xe2\x96\xb8 "  (* ▸  (same as file-tree) *)
let glyph_expanded  = "\xe2\x96\xbe "  (* ▾ *)

(* Pin affordance, fixed at 3 display columns so the subject stays put
   when toggling: ◌ (1 col) padded with two spaces; 📌 (2 cols) plus one.
   See docs/LIVE_INFO_PLAN.md for the chosen glyph pair. *)
let pin_off = "\xe2\x97\x8c  "    (* ◌ + two spaces  → click to pin *)
let pin_on  = "\xf0\x9f\x93\x8c " (* 📌 + one space  → pinned (frozen) *)

(* Main header "+" (append to list) at cols 5-6; entry "✕" (remove) at
   cols 2-4. The collapse/cycle glyph stays at cols 0-1 on every header. *)
let append_glyph = "+ "
let remove_glyph = "\xe2\x9c\x95  "  (* ✕ + two spaces *)

(* Go-to-definition affordance, placed after the subject (two-space gap).
   🔍 is a 2-wide emoji. *)
let goto_glyph = "\xf0\x9f\x94\x8d"  (* 🔍 *)

let pp_to_texts ~width pps =
  List.concat_map
    (fun pp -> String.split_on_char '\n' (Session.string_of_pp ~width pp))
    pps

(* Highlight a list of text lines (Rocq snippet) once so the lexer keeps
   cross-line context; info/prose lines are dimmed instead. An optional
   [indent] prefixes each line (used to nest saved-list entries). *)
let highlight_texts ?(indent="") texts =
  let a = Theme.attrs () in
  let texts = List.map (fun t -> indent ^ t) texts in
  let spans = Highlight.highlight_text (String.concat "\n" texts) in
  List.mapi (fun i text ->
    if is_info_line text then
      Styled.style text { a.ga_default with dim = true }
    else begin
      let hl = if i < Array.length spans then spans.(i) else [] in
      let ss = List.map (fun (sp : Highlight.span) ->
        { Styled.start = sp.start_col; len = sp.length; attr = sp.grid_attr })
        hl
      in
      { Styled.text; spans = ss }
    end
  ) texts

let format_body ~width pps = highlight_texts (pp_to_texts ~width pps)

(* Split an About rendering into its leading type signature (lines up to
   the first blank) and the rest (info / Arguments / etc.). *)
let split_type_rest texts =
  let rec go acc = function
    | [] -> (List.rev acc, [])
    | "" :: tl -> (List.rev acc, tl)
    | x :: tl -> go (x :: acc) tl
  in
  go [] texts

(* Body lines for a saved entry at its collapse level, indented to nest
   under its header: 0 = type only, 1 = + definition, 2 = + information. *)
let entry_lines ~width e =
  let w = max 1 (width - 2) in
  let about_texts = pp_to_texts ~width:w e.e_about in
  let (type_texts, rest_texts) = split_type_rest about_texts in
  let def_texts () =
    match e.e_print with
    | Some p -> pp_to_texts ~width:w p
    | None -> type_texts  (* not fetched yet, or no body *)
  in
  let body_texts =
    match e.e_level with
    | 0 -> type_texts
    | 1 -> def_texts ()
    | _ -> def_texts () @ rest_texts
  in
  highlight_texts ~indent:"  " body_texts

let render ~width =
  if (not !dirty) && !cache_width = width then !cache_lines
  else begin
    let a = Theme.attrs () in
    let dim = { a.ga_default with dim = true } in
    let bold = { a.ga_default with bold = true } in
    let err_line msg = Styled.style ("  " ^ msg) dim in
    let stale_suffix t = Styled.concat [ t; Styled.style "  (stale)" dim ] in
    (* A header line "<lead><subject>" + the 🔍 goto glyph; returns the
       styled line and the display column the glyph lands on. *)
    let header_with_goto lead subject stale =
      let lead_w = Utf8.string_width lead and subj_w = Utf8.string_width subject in
      let goto_col = lead_w + subj_w + 2 in  (* two-space gap before 🔍 *)
      let title =
        Styled.concat [ Styled.style (lead ^ subject) bold;
                        Styled.style ("  " ^ goto_glyph) dim ] in
      ((if stale then stale_suffix title else title), goto_col)
    in
    (* Build semantic rows paired with an optional click target; wrap
       each one below so targets stay aligned to displayed rows. *)
    let rows = ref [] in
    let push ?target line = rows := (line, target) :: !rows in
    (match !current with
     | None ->
       (match !error_msg with
        | Some msg -> push (err_line msg)
        | None ->
          push (Styled.style "  (move the cursor onto an identifier)" dim))
     | Some r ->
       (* Reserved top row: dimmed error, or blank when clear. *)
       push (match !error_msg with Some msg -> err_line msg | None -> Styled.plain "");
       let g = if !expanded then glyph_expanded else glyph_collapsed in
       let pin = if !pinned then pin_on else pin_off in
       let (header, goto_col) =
         header_with_goto (g ^ pin ^ append_glyph) r.subject (!pinned && !stale) in
       push ~target:(RT_main goto_col) header;
       let body_pp =
         if !expanded then (match r.print_pp with Some p -> p | None -> r.about_pp)
         else r.about_pp
       in
       List.iter (fun l -> push l) (format_body ~width body_pp);
       (* Saved list below, separated by a blank row. *)
       if !saved <> [] then push (Styled.plain "");
       List.iteri (fun i e ->
         let cyc = if e.e_level = 0 then glyph_collapsed else glyph_expanded in
         let (eheader, goto_col) =
           header_with_goto (cyc ^ remove_glyph) e.e_subject e.e_stale in
         push ~target:(RT_entry (i, goto_col)) eheader;
         List.iter (fun l -> push l) (entry_lines ~width e)
       ) !saved);
    let semantic = List.rev !rows in
    (* Wrap each semantic line; only its first wrapped row keeps the
       target (the glyphs live there). *)
    let wlines = ref [] and wtargets = ref [] in
    List.iter (fun (line, tgt) ->
      let ws = match Styled.wrap width [line] with [] -> [line] | ws -> ws in
      List.iteri (fun j wl ->
        wlines := wl :: !wlines;
        wtargets := (if j = 0 then tgt else None) :: !wtargets
      ) ws
    ) semantic;
    cache_lines := List.rev !wlines;
    cache_targets := Array.of_list (List.rev !wtargets);
    cache_width := width;
    dirty := false;
    !cache_lines
  end

(* Map a click in the (already-wrapped) pane to an action, using the
   fixed header-glyph columns. [row] is the wrapped-line index, [col] the
   content display column. *)
let target_at ~row ~col =
  let on_goto goto_col = col >= goto_col && col <= goto_col + 1 in
  if row < 0 || row >= Array.length !cache_targets then `None
  else match (!cache_targets).(row) with
  | None -> `None
  | Some (RT_main goto_col) ->
    if col <= 1 then `Expand
    else if col <= 4 then `Pin
    else if col <= 6 then `Append
    else if on_goto goto_col then `Goto
    else `None
  | Some (RT_entry (i, goto_col)) ->
    if col <= 1 then `Cycle i
    else if col <= 4 then `Remove i
    else if on_goto goto_col then `EntryGoto i
    else `None
