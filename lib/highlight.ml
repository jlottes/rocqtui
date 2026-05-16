type span = {
  start_col : int;
  length : int;
  attr : int;       (* ncurses attribute — kept for now *)
  color : int;      (* ncurses color pair — kept for now *)
  grid_attr : Grid.attr;  (* Grid attr for new renderer *)
}

(* Color pair IDs — starting after Display's pairs (1-5) *)
let color_keyword = 6
let color_tactic = 7
let color_comment = 8
let color_string = 9
let color_bullet = 10
let color_number = 11

(* Verified-region variants: same foreground, verified background *)
let color_keyword_v = 16
let color_tactic_v = 17
let color_comment_v = 18
let color_string_v = 19
let color_bullet_v = 20
let color_number_v = 21
let color_default_v = 22

(* Processing-region variants *)
let color_keyword_p = 24
let color_tactic_p = 25
let color_comment_p = 26
let color_string_p = 27
let color_bullet_p = 28
let color_number_p = 29
let color_default_p = 30

let verified_pair color =
  if color = color_keyword then color_keyword_v
  else if color = color_tactic then color_tactic_v
  else if color = color_comment then color_comment_v
  else if color = color_string then color_string_v
  else if color = color_bullet then color_bullet_v
  else if color = color_number then color_number_v
  else color_default_v

let processing_pair color =
  if color = color_keyword then color_keyword_p
  else if color = color_tactic then color_tactic_p
  else if color = color_comment then color_comment_p
  else if color = color_string then color_string_p
  else if color = color_bullet then color_bullet_p
  else if color = color_number then color_number_p
  else color_default_p

(* Colors are now initialized by Theme.apply *)

module SS = Set.Make(String)

(* --- Context tracking --- *)

type context = Vernac | Ltac | Constr

type stack_entry = {
  ctx : context;
  paren_depth : int;
}

type state = {
  mutable stack : stack_entry list;
  mutable depth : int;
  mutable prev_toks : string list;  (* recent tokens, most recent first *)
}

let make_state () = {
  stack = [{ ctx = Vernac; paren_depth = 0 }];
  depth = 0;
  prev_toks = [];
}

(* Look back n tokens (0 = most recent) *)
let prev_tok st n =
  let rec nth l i = match l with
    | [] -> ""
    | x :: _ when i = 0 -> x
    | _ :: rest -> nth rest (i - 1)
  in
  nth st.prev_toks n

let push_tok st s =
  st.prev_toks <- s :: (if List.length st.prev_toks >= 6
                         then List.filteri (fun i _ -> i < 5) st.prev_toks
                         else st.prev_toks)

let current_ctx st =
  match st.stack with
  | { ctx; _ } :: _ -> ctx
  | [] -> Vernac

let push_ctx st ctx =
  st.stack <- { ctx; paren_depth = st.depth } :: st.stack

let pop_ctx st =
  match st.stack with
  | _ :: (_ :: _ as rest) -> st.stack <- rest
  | _ -> ()

(* Well-known tactic names *)
let tactics = List.fold_left (fun s x -> SS.add x s) SS.empty [
  "intros"; "intro"; "apply"; "exact"; "rewrite"; "simpl"; "unfold";
  "destruct"; "induction"; "inversion"; "split"; "left"; "right"; "exists";
  "reflexivity"; "symmetry"; "transitivity"; "assumption"; "contradiction";
  "discriminate"; "injection"; "auto"; "eauto"; "omega"; "lia"; "ring";
  "field"; "tauto"; "firstorder"; "trivial"; "congruence"; "subst"; "clear";
  "rename"; "assert"; "pose"; "set"; "remember"; "generalize"; "specialize";
  "revert"; "case"; "elim"; "constructor"; "econstructor"; "eapply";
  "replace"; "change"; "pattern"; "cbv"; "lazy"; "compute"; "vm_compute";
  "native_compute"; "cbn"; "hnf"; "red"; "fold"; "cut"; "enough";
  "exfalso"; "f_equal"; "decide"; "now"; "easy"; "solve"; "try"; "repeat";
  "progress"; "do"; "only"; "idtac"; "fail"; "abstract"; "shelve";
  "unshelve"; "move"; "have"; "suff"; "wlog"; "congr";
  "lazymatch"; "multimatch";
  "first"; "tryif"; "once"; "exactly_once"; "timeout";
]

(* Vernacular keywords *)
let vernac_keywords = List.fold_left (fun s x -> SS.add x s) SS.empty [
  "Theorem"; "Lemma"; "Definition"; "Fixpoint"; "CoFixpoint";
  "Inductive"; "CoInductive"; "Record"; "Structure"; "Module"; "Section";
  "End"; "Require"; "Import"; "Export"; "Open"; "Scope";
  "Notation"; "Infix"; "Set"; "Unset"; "Check"; "Print"; "Compute";
  "Eval"; "Search"; "About"; "Proof"; "Qed"; "Defined"; "Admitted";
  "Abort"; "Let"; "Example"; "Fact"; "Corollary"; "Proposition";
  "Variable"; "Variables"; "Hypothesis"; "Hypotheses"; "Context";
  "Existing"; "Instance"; "Class"; "Ltac"; "Ltac2";
  "Canonical"; "Coercion"; "Universe"; "Universes"; "Sort"; "Sorts";
  "Program"; "Next"; "Obligation";
  "Goal"; "Local"; "Global"; "Cumulative"; "NonCumulative";
  "Monomorphic"; "Polymorphic"; "Fail"; "Succeed"; "Time"; "Redirect";
  "Arguments"; "Implicit"; "Declare";
  "Typeclasses"; "Opaque"; "Transparent"; "Scheme";
  "Combined"; "Extract"; "Extraction"; "Add"; "Load"; "Comments";
  "Bind"; "Delimit"; "Hint"; "Resolve"; "Immediate"; "Constructors";
  "Unfold"; "Extern"; "Rewrite"; "Save"; "Remark"; "Property";
  "Axiom"; "Axioms"; "Parameter"; "Parameters"; "SubClass";
  "Variant"; "Chapter"; "Include"; "Reserved"; "Tactic"; "Abbreviation";
]

(* Gallina / term keywords *)
let constr_keywords = List.fold_left (fun s x -> SS.add x s) SS.empty [
  "forall"; "exists"; "fun"; "match"; "fix"; "cofix"; "with"; "for";
  "end"; "as"; "let"; "in"; "if"; "then"; "else"; "return";
  "Prop"; "Set"; "Type"; "SProp";
]

let is_constr_embed s =
  s = "constr" || s = "open_constr" || s = "uconstr"

let is_ltac_embed s =
  s = "ltac" || s = "ltac2"

(* Update context state based on a token. Returns the context that
   applies to THIS token (before any transitions it causes). *)
let process_token st (tok_text : string) =
  let ctx_before = current_ctx st in
  if tok_text = "(" then begin
    st.depth <- st.depth + 1;
    (* Check if previous was ":" and before that was ltac/constr
       LexerDiff splits "ltac:(" into IDENT("ltac"), IDENT(":"), IDENT("(") *)
    if prev_tok st 0 = ":" then begin
      if is_ltac_embed (prev_tok st 1) then
        push_ctx st Ltac
      else if is_constr_embed (prev_tok st 1) then
        push_ctx st Constr
    end
  end
  else if tok_text = ")" then begin
    (* Pop context if this closes the paren that opened a context switch *)
    (match st.stack with
     | { paren_depth; _ } :: _ :: _ when st.depth <= paren_depth ->
       pop_ctx st
     | _ -> ());
    st.depth <- max 0 (st.depth - 1)
  end
  else if tok_text = "." then begin
    (* "Proof." transitions to Ltac *)
    if prev_tok st 0 = "Proof" && ctx_before = Vernac then
      push_ctx st Ltac;
    (* "Qed." / "Defined." / "Admitted." / "Abort." pop Ltac *)
    let p = prev_tok st 0 in
    if (p = "Qed" || p = "Defined" || p = "Admitted" || p = "Abort")
       && ctx_before = Ltac then
      pop_ctx st
  end
  (* "Ltac <name> :=" — LexerDiff splits ":=" into ":" then "="
     So at "=" we see prev=":"  prev2=<name>  prev3="Ltac" *)
  else if tok_text = "=" && prev_tok st 0 = ":" && ctx_before = Vernac then begin
    (* Look for "Ltac" a few tokens back (Ltac <name> : =) *)
    if prev_tok st 2 = "Ltac" || prev_tok st 2 = "Ltac2" then
      push_ctx st Ltac
  end;
  push_tok st tok_text;
  ctx_before

(* --- Styling --- *)

let style_of_ident ctx tok_text =
  (* In Ltac context, check for tactics *)
  if ctx = Ltac && SS.mem tok_text tactics then
    Some (0, color_tactic)
  (* Vernacular keywords *)
  else if SS.mem tok_text vernac_keywords then
    Some (1, color_keyword)
  (* Constr/Gallina keywords *)
  else if SS.mem tok_text constr_keywords then
    Some (1, color_keyword)
  else
    None

(* --- Offset utilities --- *)

let offset_to_line_col (line_offsets : int array) bp =
  let n = Array.length line_offsets in
  let lo = ref 0 in
  let hi = ref (n - 1) in
  while !lo < !hi do
    let mid = (!lo + !hi + 1) / 2 in
    if line_offsets.(mid) <= bp then lo := mid
    else hi := mid - 1
  done;
  let line = !lo in
  let col = bp - line_offsets.(line) in
  (line, col)

(* Map ncurses color pair to Grid.attr using current theme *)
let grid_attr_of_color color =
  let a = Theme.attrs () in
  if color = color_keyword then a.ga_keyword
  else if color = color_tactic then a.ga_tactic
  else if color = color_comment then a.ga_comment
  else if color = color_string then a.ga_string
  else if color = color_bullet then a.ga_bullet
  else if color = color_number then a.ga_number
  else if color = color_keyword_v then a.ga_keyword_v
  else if color = color_tactic_v then a.ga_tactic_v
  else if color = color_comment_v then a.ga_comment_v
  else if color = color_string_v then a.ga_string_v
  else if color = color_bullet_v then a.ga_bullet_v
  else if color = color_number_v then a.ga_number_v
  else if color = color_default_v then a.ga_default_v
  else if color = color_keyword_p then a.ga_keyword_p
  else if color = color_tactic_p then a.ga_tactic_p
  else if color = color_comment_p then a.ga_comment_p
  else if color = color_string_p then a.ga_string_p
  else if color = color_bullet_p then a.ga_bullet_p
  else if color = color_number_p then a.ga_number_p
  else if color = color_default_p then a.ga_default_p
  else a.ga_default

let add_span result line_offsets num_lines bp ep attr color =
  if bp < ep then begin
    let (line, col) = offset_to_line_col line_offsets bp in
    let length = ep - bp in
    if line < num_lines && length > 0 then
      result.(line) <- { start_col = col; length; attr; color;
                         grid_attr = grid_attr_of_color color } :: result.(line)
  end

let add_multiline_span result line_offsets buf num_lines bp total_len attr color =
  let rec go pos remaining =
    if remaining <= 0 then ()
    else begin
      let (line, col) = offset_to_line_col line_offsets pos in
      if line < num_lines then begin
        let line_len = String.length (Buffer.get_line buf line) in
        let avail = line_len - col in
        let span_len = min remaining avail in
        if span_len > 0 then
          result.(line) <- { start_col = col; length = span_len;
                             attr; color;
                             grid_attr = grid_attr_of_color color } :: result.(line);
        go (pos + span_len + 1) (remaining - span_len - 1)
      end
    end
  in
  go bp total_len

(* --- Main highlighting function --- *)

let highlight_buffer buf =
  let num_lines = Buffer.line_count buf in
  let result = Array.make num_lines [] in
  let text = Buffer.text buf in
  if String.length text = 0 then result
  else begin
    let line_offsets = Array.make num_lines 0 in
    let offset = ref 0 in
    for i = 0 to num_lines - 1 do
      line_offsets.(i) <- !offset;
      offset := !offset + String.length (Buffer.get_line buf i) + 1
    done;
    let st = make_state () in
    let comment_state = CLexer.LexerDiff.State.init () in
    CLexer.LexerDiff.State.set comment_state;
    let char_stream = Gramlib.Stream.of_string text in
    let kw_state = CLexer.empty_keyword_state in
    let tok_stream = CLexer.LexerDiff.tok_func char_stream in
    let in_comment = ref 0 in
    let comment_start = ref 0 in
    let prev_comment_tok = ref "" in
    (try
       while true do
         match Rocq_compat.lstream_next kw_state tok_stream with
         | None -> raise Exit
         | Some tok ->
         let loc = Gramlib.LStream.current_loc tok_stream in
         let bp = loc.Loc.bp in
         let ep = loc.Loc.ep in
         let tok_text = Tok.extract_string true tok in
         if !in_comment > 0 then begin
           (* LexerDiff splits "(* " into "(*" or "(" then "*"
              and "* )" into "*" then ")" *)
           if tok_text = "(*" then
             incr in_comment
           else if tok_text = "(" && !prev_comment_tok = "" then
             () (* might be start of comment open *)
           else if tok_text = "*" && !prev_comment_tok = "(" then
             incr in_comment
           else if tok_text = "*)" then begin
             decr in_comment;
             if !in_comment = 0 then
               add_multiline_span result line_offsets buf num_lines
                 !comment_start (ep - !comment_start)
                 0 color_comment
           end else if tok_text = ")" && !prev_comment_tok = "*" then begin
             decr in_comment;
             if !in_comment = 0 then
               add_multiline_span result line_offsets buf num_lines
                 !comment_start (ep - !comment_start)
                 0 color_comment
           end;
           prev_comment_tok := tok_text
         end else if tok_text = "(*" then begin
           in_comment := 1;
           comment_start := bp;
           prev_comment_tok := "(*"
         end else begin
           let ctx = process_token st tok_text in
           let style = match tok with
             | Tok.STRING _ -> Some (0, color_string)
             | Tok.NUMBER _ -> Some (0, color_number)
             | Tok.BULLET _ -> Some (1, color_bullet)
             | Tok.IDENT s -> style_of_ident ctx s
             | _ -> None
           in
           (match style with
            | Some (attr, color) ->
              add_span result line_offsets num_lines bp ep attr color
            | None -> ())
         end;
         if tok = Tok.EOI then raise Exit
       done
     with
     | Exit -> ()
     | CLexer.Error.E _ -> ()
    );
    CLexer.LexerDiff.State.drop ();
    Array.iteri (fun i spans -> result.(i) <- List.rev spans) result;
    result
  end

(* --- Identifier lookup at cursor (used by ^L, About, Print) --- *)

(* Cursor's byte offset in [Buffer.text buf]. *)
let cursor_byte_offset buf =
  let (line, col) = Buffer.cursor buf in
  let off = ref 0 in
  for i = 0 to line - 1 do
    off := !off + String.length (Buffer.get_line buf i) + 1
  done;
  !off + col

(* With [empty_keyword_state] the Coq lexer labels every otherwise-untokenized
   chunk as IDENT — including punctuation like ".", ":", "(", "+". Filter
   to tokens whose content starts like a real identifier (letter, '_', or
   any non-ASCII codepoint, which we treat as a Unicode letter). *)
let is_real_ident_text s =
  String.length s > 0 &&
  let c = Char.code s.[0] in
  (c >= Char.code 'a' && c <= Char.code 'z') ||
  (c >= Char.code 'A' && c <= Char.code 'Z') ||
  c = Char.code '_' || c >= 0x80

(* Tokenize [text] and return all real IDENT/FIELD spans as (bp, ep) in source
   order. Returns [] if the lexer fails before producing any. *)
let collect_ident_spans text =
  let acc = ref [] in
  if String.length text = 0 then []
  else begin
    let comment_state = CLexer.LexerDiff.State.init () in
    CLexer.LexerDiff.State.set comment_state;
    let char_stream = Gramlib.Stream.of_string text in
    let kw_state = CLexer.empty_keyword_state in
    let tok_stream = CLexer.LexerDiff.tok_func char_stream in
    (try
       while true do
         match Rocq_compat.lstream_next kw_state tok_stream with
         | None -> raise Exit
         | Some tok ->
         let loc = Gramlib.LStream.current_loc tok_stream in
         (match tok with
          | Tok.IDENT s | Tok.FIELD s when is_real_ident_text s ->
            acc := (loc.Loc.bp, loc.Loc.ep) :: !acc
          | _ -> ());
         if tok = Tok.EOI then raise Exit
       done
     with
     | Exit -> ()
     | CLexer.Error.E _ -> ());
    CLexer.LexerDiff.State.drop ();
    List.rev !acc
  end

let qualid_at_cursor buf =
  let text = Buffer.text buf in
  let off = cursor_byte_offset buf in
  let toks = Array.of_list (collect_ident_spans text) in
  let n = Array.length toks in
  (* Find the first IDENT/FIELD whose [bp, ep] contains [off]. Inclusive on
     both ends so the cursor sitting at a boundary picks the left token. *)
  let rec find i =
    if i >= n then None
    else
      let (bp, ep) = toks.(i) in
      if bp > off then None
      else if off <= ep then Some i
      else find (i + 1)
  in
  match find 0 with
  | None -> None
  | Some i ->
    (* Extend left through adjacent IDENT/FIELD tokens (no gap = qualified
       name like Foo.Bar.baz where FIELD ".Bar" starts at the dot, which
       is exactly where IDENT "Foo" ended). *)
    let l = ref i in
    while !l > 0 && snd toks.(!l - 1) = fst toks.(!l) do decr l done;
    let r = ref i in
    while !r + 1 < n && snd toks.(!r) = fst toks.(!r + 1) do incr r done;
    let bp = fst toks.(!l) in
    let ep = snd toks.(!r) in
    if ep <= bp then None
    else
      let s = String.sub text bp (ep - bp) in
      (* Trim a trailing sentence-terminator '.' that the lexer sometimes
         folds into the final FIELD token (e.g. "Foo.Bar.baz." emits
         FIELD "baz." rather than FIELD "baz" + KEYWORD "."). *)
      let n = String.length s in
      let s = if n > 0 && s.[n - 1] = '.' then String.sub s 0 (n - 1) else s in
      if s = "" then None else Some s
