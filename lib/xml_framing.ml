(* Incremental top-level-element boundary detector for the coqidetop XML
   stream.

   The stream coqidetop sends is a sequence of sibling top-level elements
   — one per protocol message (<value>…</value>, <feedback>…</feedback>,
   …), not wrapped in a single root. [Rocq_protocol.handle_input] drains
   the pipe in ~64 KB chunks and, before this, re-lexed the whole
   accumulated fragment from byte 0 on every drain; an in-progress giant
   message was therefore re-lexed O(N/chunk) times → O(N²) CPU. This
   tracks element-nesting depth byte by byte across drains so the caller
   can skip parsing until a complete message is actually buffered.

   This is purely a performance gate: [Xml_parser] remains the authority
   on real boundaries. A false positive (claiming a boundary too early)
   only costs a wasted parse attempt that the parser rejects as
   incomplete; the dangerous case is a false negative (missing a real
   boundary → hang), so depth accounting mirrors coqide's xml_lexer.mll
   exactly:
     - content excludes raw '<' '>' '&' (those are entities);
     - tags: <ident …>, </ident>, self-closing <…/>;
     - comments and headers are depth-neutral;
     - attribute values are double- or single-quoted, use backslash
       escaping, and may themselves contain a literal close-angle;
     - no CDATA / DOCTYPE (xml-light doesn't support them). *)

(* Per-tag scan state: which quote we're inside (if any), whether the
   last byte was an unconsumed backslash escape, and whether the last
   significant byte was '/' (for self-close detection at '>'). *)
type q = { quote : char option; esc : bool; slash : bool }

type mode =
  | Content
  | Lt                  (* just saw '<', classifying *)
  | Bang1               (* saw "<!" *)
  | Bang2               (* saw "<!-" *)
  | Comment of int      (* in <!-- … -->, matched length of "-->" (0..2) *)
  | Header of bool      (* in <? … ?>, true once a '?' awaits '>' *)
  | Start of q          (* in a start tag <ident … *)
  | End of q            (* in an end tag </ident … *)

type t = { depth : int; mode : mode; closed : bool }

let initial = { depth = 0; mode = Content; closed = false }
let at_boundary t = t.closed
let depth t = t.depth

let no_q = { quote = None; esc = false; slash = false }

let step_tag st q c ~is_end =
  let remode q = if is_end then End q else Start q in
  match q.quote with
  | Some qc ->
    if q.esc then { st with mode = remode { q with esc = false } }
    else if c = '\\' then { st with mode = remode { q with esc = true } }
    else if c = qc then { st with mode = remode { q with quote = None } }
    else st
  | None ->
    (match c with
     | '"' | '\'' -> { st with mode = remode { q with quote = Some c; slash = false } }
     | '>' ->
       if is_end then
         let d = max 0 (st.depth - 1) in
         { depth = d; mode = Content; closed = st.closed || d = 0 }
       else if q.slash then
         (* self-closing start tag: depth unchanged; a top-level element
            completes iff we were at depth 0 *)
         { depth = st.depth; mode = Content; closed = st.closed || st.depth = 0 }
       else
         { depth = st.depth + 1; mode = Content; closed = st.closed }
     | '/' when not is_end -> { st with mode = remode { q with slash = true } }
     | _ -> { st with mode = remode { q with slash = false } })

let step st c =
  match st.mode with
  | Content -> if c = '<' then { st with mode = Lt } else st
  | Lt ->
    (match c with
     | '!' -> { st with mode = Bang1 }
     | '?' -> { st with mode = Header false }
     | '/' -> { st with mode = End no_q }
     | ' ' | '\t' | '\r' | '\n' -> st          (* '<' space* … *)
     | _ -> { st with mode = Start no_q })
  | Bang1 -> { st with mode = (if c = '-' then Bang2 else Start no_q) }
  | Bang2 -> { st with mode = (if c = '-' then Comment 0 else Start no_q) }
  | Comment n ->
    (match c, n with
     | '-', 0 -> { st with mode = Comment 1 }
     | '-', (1 | 2) -> { st with mode = Comment 2 }
     | '>', 2 -> { st with mode = Content }
     | _ -> { st with mode = Comment 0 })
  | Header seen ->
    (match c with
     | '?' -> { st with mode = Header true }
     | '>' when seen -> { st with mode = Content }
     | _ -> { st with mode = Header false })
  | Start q -> step_tag st q c ~is_end:false
  | End q -> step_tag st q c ~is_end:true

let feed st s =
  let n = String.length s in
  let rec go st i = if i >= n then st else go (step st (String.unsafe_get s i)) (i + 1) in
  go st 0
