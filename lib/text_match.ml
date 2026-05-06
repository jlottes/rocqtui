(* Whitespace-normalized text matching for MCP tools.
   Used by both rocqtui (mcp_server) and the OCaml bridge. *)

(* Collapse runs of whitespace to single space, trim ends. *)
let normalize s =
  let len = String.length s in
  let buf = Stdlib.Buffer.create len in
  let in_space = ref true in (* start true to trim leading *)
  for i = 0 to len - 1 do
    let c = s.[i] in
    if c = ' ' || c = '\t' || c = '\n' || c = '\r' then begin
      if not !in_space then Stdlib.Buffer.add_char buf ' ';
      in_space := true
    end else begin
      Stdlib.Buffer.add_char buf c;
      in_space := false
    end
  done;
  (* Trim trailing space *)
  let result = Stdlib.Buffer.contents buf in
  let rlen = String.length result in
  if rlen > 0 && result.[rlen - 1] = ' ' then
    String.sub result 0 (rlen - 1)
  else result

(* Build a mapping from normalized offset to original offset.
   Returns an array where map.(i) = original byte offset corresponding
   to normalized byte i. *)
let build_offset_map s =
  let len = String.length s in
  let map = Stdlib.Buffer.create len in
  let in_space = ref true in
  for i = 0 to len - 1 do
    let c = s.[i] in
    if c = ' ' || c = '\t' || c = '\n' || c = '\r' then begin
      if not !in_space then begin
        (* This space char in normalized corresponds to position i *)
        Stdlib.Buffer.add_char map (Char.chr (i land 0xff));
        Stdlib.Buffer.add_char map (Char.chr ((i lsr 8) land 0xff));
        Stdlib.Buffer.add_char map (Char.chr ((i lsr 16) land 0xff))
      end;
      in_space := true
    end else begin
      Stdlib.Buffer.add_char map (Char.chr (i land 0xff));
      Stdlib.Buffer.add_char map (Char.chr ((i lsr 8) land 0xff));
      Stdlib.Buffer.add_char map (Char.chr ((i lsr 16) land 0xff));
      in_space := false
    end
  done;
  let bytes = Stdlib.Buffer.contents map in
  let nlen = String.length bytes / 3 in
  Array.init nlen (fun i ->
    Char.code bytes.[i * 3]
    lor (Char.code bytes.[i * 3 + 1] lsl 8)
    lor (Char.code bytes.[i * 3 + 2] lsl 16))

(* Find all positions where normalized needle matches in normalized haystack.
   Returns original byte offsets (end of match in original text). *)
let find_all ~haystack ~needle =
  let norm_h = normalize haystack in
  let norm_n = normalize needle in
  let nlen = String.length norm_n in
  let hlen = String.length norm_h in
  if nlen = 0 then []
  else begin
    let offset_map = build_offset_map haystack in
    let results = ref [] in
    let i = ref 0 in
    while !i <= hlen - nlen do
      if String.sub norm_h !i nlen = norm_n then begin
        (* Map back: the match in normalized text spans [i, i+nlen).
           We want the original byte offset at the end of the match. *)
        let norm_end = !i + nlen - 1 in
        if norm_end < Array.length offset_map then begin
          (* Original offset is just past the last matched char *)
          let orig_end = offset_map.(norm_end) + 1 in
          (* Skip any trailing whitespace in original to get to sentence boundary *)
          results := orig_end :: !results
        end;
        incr i
      end else
        incr i
    done;
    List.rev !results
  end

(* Find a unique match. Returns the original byte offset at end of match,
   or an error with line numbers of all matches. *)
type match_result =
  | Unique of int  (* byte offset at end of match *)
  | No_match
  | Ambiguous of int list  (* 1-based line numbers of all matches *)

let line_of_offset text off =
  let line = ref 1 in
  let i = ref 0 in
  while !i < off && !i < String.length text do
    if text.[!i] = '\n' then incr line;
    incr i
  done;
  !line

let find_unique ~haystack ~needle ?after_text ?line () =
  let matches = find_all ~haystack ~needle in
  (* Filter by after_text if provided *)
  let matches = match after_text with
    | None -> matches
    | Some after ->
      let norm_after = normalize after in
      let alen = String.length norm_after in
      if alen = 0 then matches
      else
        List.filter (fun end_off ->
          (* Skip whitespace after the match in original text *)
          let i = ref end_off in
          let len = String.length haystack in
          while !i < len && Sentence.is_space haystack.[!i] do incr i done;
          (* Check if after_text matches here *)
          let remaining = if !i < len then
            String.sub haystack !i (min (len - !i) (alen * 3))
          else "" in
          let norm_rem = normalize remaining in
          String.length norm_rem >= alen
          && String.sub norm_rem 0 alen = norm_after
        ) matches
  in
  (* Filter by line number if provided *)
  let matches = match line with
    | None -> matches
    | Some target_line ->
      (* Keep only matches on or near the target line *)
      let on_line = List.filter (fun off ->
        line_of_offset haystack off = target_line
      ) matches in
      if on_line <> [] then on_line else matches
  in
  match matches with
  | [off] -> Unique off
  | [] -> No_match
  | _ ->
    let lines = List.map (line_of_offset haystack) matches in
    Ambiguous lines

(* Check if pattern matches the head of text starting at head_start
   (whitespace-normalized). Leading whitespace at head_start is allowed
   and not consumed. Returns (match_start, match_end) — the original
   offsets of the first and just-past-last matched non-space char — or
   None. Trailing whitespace within the matched span is included. *)
let head_matches ~text ~head_start ~pattern =
  let len = String.length text in
  if head_start >= len then None
  else begin
    let norm_pat = normalize pattern in
    let plen = String.length norm_pat in
    if plen = 0 then None
    else begin
      let chunk_end = min len (head_start + (plen * 3) + 16) in
      let chunk = String.sub text head_start (chunk_end - head_start) in
      let norm_chunk = normalize chunk in
      let clen = String.length norm_chunk in
      if clen >= plen
         && String.sub norm_chunk 0 plen = norm_pat then begin
        let offset_map = build_offset_map chunk in
        if Array.length offset_map < plen then None
        else
          let orig_start = offset_map.(0) in
          let orig_last = offset_map.(plen - 1) in
          Some (head_start + orig_start, head_start + orig_last + 1)
      end else
        None
    end
  end

(* Check if pattern matches the tail of text ending at tail_end.
   Returns the start offset of the match in the original text, or None. *)
let tail_matches ~text ~tail_end ~pattern =
  if tail_end <= 0 then None
  else begin
    let norm_pat = normalize pattern in
    let plen = String.length norm_pat in
    if plen = 0 then None
    else begin
      (* Extract a generous chunk of the tail for matching *)
      let chunk_start = max 0 (tail_end - plen * 3) in
      let chunk = String.sub text chunk_start (tail_end - chunk_start) in
      let norm_chunk = normalize chunk in
      let clen = String.length norm_chunk in
      if clen >= plen
         && String.sub norm_chunk (clen - plen) plen = norm_pat then begin
        (* Find the original start offset *)
        let offset_map = build_offset_map chunk in
        let norm_start = clen - plen in
        if norm_start < Array.length offset_map then
          Some (chunk_start + offset_map.(norm_start))
        else
          Some chunk_start
      end else
        None
    end
  end
