(* Paren / bracket / brace matching.

   Single forward pass over [text], skipping Rocq strings and (nested)
   comments via [Sentence.skip_string] / [Sentence.skip_comment]. Builds
   a position-to-position table of matched bracket pairs. *)

let is_open c = c = '(' || c = '[' || c = '{'
let is_close c = c = ')' || c = ']' || c = '}'

let matches o c = match o, c with
  | '(', ')' | '[', ']' | '{', '}' -> true
  | _ -> false

let build_pairs text =
  let len = String.length text in
  let pairs : (int, int) Hashtbl.t = Hashtbl.create 64 in
  let stack = Stack.create () in
  let i = ref 0 in
  while !i < len do
    let c = text.[!i] in
    if c = '(' && !i + 1 < len && text.[!i + 1] = '*' then
      i := Sentence.skip_comment text (!i + 2)
    else if c = '"' then
      i := Sentence.skip_string text (!i + 1)
    else if is_open c then begin
      Stack.push (c, !i) stack;
      incr i
    end
    else if is_close c then begin
      (match Stack.top_opt stack with
       | Some (o, op) when matches o c ->
         ignore (Stack.pop stack);
         Hashtbl.add pairs op !i;
         Hashtbl.add pairs !i op
       | _ -> ());
      incr i
    end
    else incr i
  done;
  pairs

let find_match text pos =
  if pos < 0 || pos >= String.length text then None
  else
    let c = text.[pos] in
    if not (is_open c || is_close c) then None
    else Hashtbl.find_opt (build_pairs text) pos

let pair_at_cursor text ~cursor =
  let len = String.length text in
  let on_bracket pos =
    pos >= 0 && pos < len
    && (let c = text.[pos] in is_open c || is_close c)
  in
  let pairs = lazy (build_pairs text) in
  let try_pos pos =
    if not (on_bracket pos) then None
    else
      match Hashtbl.find_opt (Lazy.force pairs) pos with
      | Some other -> Some (pos, other)
      | None -> None
  in
  match try_pos cursor with
  | Some _ as r -> r
  | None -> try_pos (cursor - 1)
