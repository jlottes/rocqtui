(* Live "About / Print" info for the identifier under the cursor.
   See live_info.mli and docs/LIVE_INFO_PLAN.md. *)

type result = {
  subject : string;
  about_pp : Pp.t list;
  mutable print_pp : Pp.t list option;  (* None until fetched on expand *)
  mutable print_pending : bool;         (* a Print query is in flight *)
}

let current : result option ref = ref None
let expanded = ref false
let src_session : Session.t option ref = ref None

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

(* Render cache, rebuilt when the width changes or [dirty] is set. *)
let dirty = ref true
let cache_width = ref (-1)
let cache_lines : Styled.line list ref = ref []

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

let deliver_about s subj msgs =
  if looks_like_error (pp_text msgs) then ()  (* keep last good result *)
  else begin
    (* Preserve the collapse state across re-queries of the same subject
       (tip / option changes); only a genuinely new subject re-collapses. *)
    let same_subject =
      match !current with Some r -> r.subject = subj | None -> false in
    current := Some { subject = subj; about_pp = msgs;
                      print_pp = None; print_pending = false };
    if not same_subject then expanded := false;
    src_session := Some s;
    invalidate ()
  end

let deliver_print subj msgs =
  match !current with
  | Some r when r.subject = subj ->
    r.print_pending <- false;
    (* On a Print error (e.g. an axiom with no body) fall back to the
       About output so expanding always shows something sensible. *)
    if looks_like_error (pp_text msgs) then r.print_pp <- Some r.about_pp
    else r.print_pp <- Some msgs;
    invalidate ()
  | _ -> ()

(* --- per-frame driver --- *)

let subject_at_cursor buf =
  match Highlight.qualid_at_cursor buf with
  | Some _ as x -> x
  | None -> Buffer.word_at_cursor buf

let tick session buf =
  match session with
  | None -> ()
  | Some s ->
    let opts = Printopts.to_set_options () in
    let tip = Session.tip s in
    (* Follow the cursor: (re-)issue About when the subject, tip, or
       options change and the session is idle. Keep the last result when
       on a non-identifier (subject = None). *)
    (match subject_at_cursor buf with
     | Some w when key_changed (w, tip, opts) && not (Session.is_busy s) ->
       last_about_key := Some (w, tip, opts);
       Session.query s ~extra_opts:opts
         ~on_done:(fun msgs -> deliver_about s w msgs)
         ("About " ^ w ^ ".")
     | _ -> ());
    (* Lazily fetch Print for the current subject once expanded, at the
       current tip/options. About produces a fresh result (print_pp =
       None) whenever the key changes, so this re-fetches automatically. *)
    (match !current with
     | Some r
       when !expanded && r.print_pp = None && not r.print_pending
            && not (Session.is_busy s) ->
       r.print_pending <- true;
       let subj = r.subject in
       Session.query s ~extra_opts:opts
         ~on_done:(fun msgs -> deliver_print subj msgs)
         ("Print " ^ subj ^ ".")
     | _ -> ())

(* --- accessors --- *)

let has_content () = !current <> None
let current_subject () = match !current with Some r -> Some r.subject | None -> None
let is_expanded () = !expanded

let toggle_expand () =
  expanded := not !expanded;
  invalidate ()
  (* the Print fetch (if needed) happens on the next idle tick *)

(* --- rendering --- *)

let glyph_collapsed = "\xe2\x96\xb8 "  (* ▸  (same as file-tree) *)
let glyph_expanded  = "\xe2\x96\xbe "  (* ▾ *)

(* Format a Pp list to [width], then highlight the whole snippet once so
   the lexer keeps cross-line context, and dim the info/prose lines. *)
let format_body ~width pps =
  let a = Theme.attrs () in
  let texts =
    List.concat_map
      (fun pp -> String.split_on_char '\n' (Session.string_of_pp ~width pp))
      pps
  in
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

let render ~width =
  if (not !dirty) && !cache_width = width then !cache_lines
  else begin
    let a = Theme.attrs () in
    let lines =
      match !current with
      | None ->
        [ Styled.style "  (move the cursor onto an identifier)"
            { a.ga_default with dim = true } ]
      | Some r ->
        let g = if !expanded then glyph_expanded else glyph_collapsed in
        let header = Styled.style (g ^ r.subject) { a.ga_default with bold = true } in
        let body_pp =
          if !expanded then
            (match r.print_pp with Some p -> p | None -> r.about_pp)
          else r.about_pp
        in
        header :: format_body ~width body_pp
    in
    cache_lines := lines;
    cache_width := width;
    dirty := false;
    lines
  end
