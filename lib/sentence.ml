(* Sentence boundary detection for Rocq source text.
   Based on the logic in rocq_lex.mll from RocqIDE. *)

let is_space c = c = ' ' || c = '\n' || c = '\r' || c = '\t' || c = '\012'
let is_bullet c = c = '-' || c = '+' || c = '*'

exception Found of int

(* Skip a Rocq string starting after the opening '"'.
   Returns the position after the closing '"', or len if unterminated. *)
let skip_string text pos =
  let len = String.length text in
  let i = ref pos in
  (try
     while !i < len do
       if text.[!i] = '"' then begin
         i := !i + 1;
         if !i < len && text.[!i] = '"' then
           i := !i + 1  (* escaped quote "" *)
         else
           raise (Found !i)
       end else
         i := !i + 1
     done;
     len
   with Found pos -> pos)

(* Skip a comment starting after "(*". Handles nesting.
   Returns the position after "*)". *)
let rec skip_comment text pos =
  let len = String.length text in
  let i = ref pos in
  (try
     while !i < len do
       if !i + 1 < len && text.[!i] = '(' && text.[!i + 1] = '*' then
         i := skip_comment text (!i + 2)
       else if !i + 1 < len && text.[!i] = '*' && text.[!i + 1] = ')' then
         raise (Found (!i + 2))
       else if text.[!i] = '"' then
         i := skip_string text (!i + 1)
       else
         i := !i + 1
     done;
     len
   with Found pos -> pos)

let at_space_or_eof text i =
  i >= String.length text || is_space text.[i]

(* If there's a bullet/brace at [pos], return the position just past it. *)
let bullet_end text pos =
  let len = String.length text in
  if pos >= len then None
  else
    let c = text.[pos] in
    if is_bullet c then begin
      let j = ref (pos + 1) in
      while !j < len && text.[!j] = c do incr j done;
      if at_space_or_eof text !j then Some !j
      else None
    end else if c = '{' || c = '}' then begin
      if at_space_or_eof text (pos + 1) then Some (pos + 1)
      else None
    end else
      None

(* Find the end of the next sentence starting at [start].
   Sentences end at:
   - '.' followed by whitespace or EOF
   - '...' (third dot) followed by whitespace or EOF
   - a bullet/brace is its own sentence

   Returns the byte offset just past the end of the sentence. *)
let find_end text ~start =
  let len = String.length text in
  let i = ref start in
  (* Skip leading whitespace *)
  while !i < len && is_space text.[!i] do incr i done;
  if !i >= len then None
  else begin
    (* Check if we start with a bullet — if so, it IS the sentence *)
    match bullet_end text !i with
    | Some end_pos -> Some end_pos
    | None ->
      (try
         while !i < len do
           let c = text.[!i] in
           if c = '(' && !i + 1 < len && text.[!i + 1] = '*' then
             i := skip_comment text (!i + 2)
           else if c = '"' then
             i := skip_string text (!i + 1)
           else if c = '.' then begin
             if !i + 1 < len && text.[!i + 1] = '.' then begin
               i := !i + 2;
               (* "..." — third dot ends sentence *)
               if !i < len && text.[!i] = '.' && at_space_or_eof text (!i + 1) then
                 raise (Found (!i + 1))
             end else if at_space_or_eof text (!i + 1) then
               raise (Found (!i + 1))
             else
               i := !i + 1
           end else
             i := !i + 1
         done;
         None
       with Found pos -> Some pos)
  end

let split text =
  let len = String.length text in
  let result = ref [] in
  let pos = ref 0 in
  while !pos < len && is_space text.[!pos] do incr pos done;
  let sent_start = ref !pos in
  while !pos < len do
    match find_end text ~start:!pos with
    | Some end_pos ->
      if end_pos > !sent_start then
        result := (!sent_start, end_pos) :: !result;
      pos := end_pos;
      while !pos < len && is_space text.[!pos] do incr pos done;
      sent_start := !pos
    | None ->
      pos := len
  done;
  List.rev !result
