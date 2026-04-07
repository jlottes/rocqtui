(* Sentence-aligned context extraction for MCP responses.
   Extracts complete sentences before/after a boundary offset. *)

(* Proof-introducing keywords. *)
let proof_commands = [
  "Lemma"; "Theorem"; "Corollary"; "Proposition"; "Property";
  "Fact"; "Remark"; "Example"; "Instance"; "Definition";
  "Fixpoint"; "CoFixpoint"; "Program"; "Let";
]

(* Check if a sentence (given as a substring) starts with a proof command. *)
let is_proof_command text start =
  let len = String.length text in
  (* Skip whitespace *)
  let i = ref start in
  while !i < len && Sentence.is_space text.[!i] do incr i done;
  List.exists (fun cmd ->
    let clen = String.length cmd in
    !i + clen <= len
    && String.sub text !i clen = cmd
    && (!i + clen >= len
        || Sentence.is_space text.[!i + clen]
        || text.[!i + clen] = '(')
  ) proof_commands

(* Scan backward from [boundary] to find sentence boundaries.
   Returns a list of (start, end) pairs for complete sentences,
   ordered from earliest to latest. *)
let sentences_before text ~boundary =
  if boundary <= 0 then []
  else begin
    let chunk = String.sub text 0 boundary in
    Sentence.split chunk
  end

(* Scan forward from [boundary] to find sentence boundaries.
   Returns a list of (start, end) pairs for complete sentences. *)
let sentences_after text ~boundary =
  let len = String.length text in
  if boundary >= len then []
  else begin
    let chunk = String.sub text boundary (len - boundary) in
    List.map (fun (s, e) -> (s + boundary, e + boundary))
      (Sentence.split chunk)
  end

(* Find the start of the proof-introducing sentence.
   Scans backward through sentences from [boundary] looking for a
   Lemma/Theorem/etc. Returns the byte offset of the start of that
   sentence, or None. *)
let find_proof_start text ~boundary =
  let sents = sentences_before text ~boundary in
  (* Walk backward through sentences *)
  let rec find = function
    | [] -> None
    | (start, _end) :: rest ->
      if is_proof_command text start then Some start
      else find rest
  in
  find (List.rev sents)

(* Extract context before the boundary.
   At least [min_bytes] of complete sentences.
   If [has_goals] is true, extends back to include the proof-introducing
   sentence (Lemma, Theorem, etc.). *)
let before text ~boundary ?(min_bytes=500) ?(has_goals=false) () =
  let sents = sentences_before text ~boundary in
  if sents = [] then ""
  else begin
    (* Start from the end, accumulate sentences backward *)
    let rev_sents = List.rev sents in
    let acc = ref [] in
    let bytes = ref 0 in
    let reached_min = ref false in
    List.iter (fun (s, e) ->
      if not !reached_min then begin
        acc := (s, e) :: !acc;
        bytes := !bytes + (e - s);
        if !bytes >= min_bytes then reached_min := true
      end
    ) rev_sents;
    (* If we have goals, extend to proof-introducing sentence *)
    let start = match !acc with
      | (s, _) :: _ -> s
      | [] -> boundary
    in
    let start =
      if has_goals then
        match find_proof_start text ~boundary with
        | Some ps when ps < start ->
          (* Add all sentences from proof start to our current start *)
          acc := List.filter (fun (s, _) -> s >= ps) sents;
          ps
        | _ -> start
      else start
    in
    if start >= boundary then ""
    else String.sub text start (boundary - start)
  end

(* Extract context after the boundary.
   At most [max_bytes] of complete sentences. *)
let after text ~boundary ?(max_bytes=200) () =
  let sents = sentences_after text ~boundary in
  if sents = [] then begin
    (* Return remaining text if it's short *)
    let len = String.length text in
    let remaining = len - boundary in
    if remaining > 0 && remaining <= max_bytes then
      String.sub text boundary remaining
    else if remaining > 0 then
      String.sub text boundary max_bytes
    else ""
  end else begin
    let buf = Stdlib.Buffer.create max_bytes in
    List.iter (fun (s, e) ->
      if Stdlib.Buffer.length buf + (e - s) <= max_bytes || Stdlib.Buffer.length buf = 0 then begin
        (* Include whitespace before sentence *)
        let ws_start = if Stdlib.Buffer.length buf = 0 then boundary else s in
        if ws_start < s then
          Stdlib.Buffer.add_string buf (String.sub text ws_start (s - ws_start));
        Stdlib.Buffer.add_string buf (String.sub text s (e - s))
      end
    ) sents;
    Stdlib.Buffer.contents buf
  end

(* Get the text of the last sentence before [boundary]. *)
let last_sentence text ~boundary =
  let sents = sentences_before text ~boundary in
  match List.rev sents with
  | [] -> None
  | (s, e) :: _ ->
    Some (String.trim (String.sub text s (e - s)))
