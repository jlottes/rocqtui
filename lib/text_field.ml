(* Single-line text editing buffer shared by the search prompt, the
   rename prompt, and (eventually) other modal text inputs. Stores
   contents as a string and the cursor as a byte offset; the byte
   cursor is maintained on a UTF-8 codepoint boundary by [Utf8.prev]/
   [next] (motion, deletion) and [Utf8.encode] (insertion always
   produces a complete codepoint). Consumers do their own rendering
   and place the hardware cursor via [cursor_col]. Focus is managed by
   the consumer, not the field. *)

type t = {
  mutable contents : string;
  mutable cursor : int;   (* byte offset, 0..String.length contents *)
}

let clamp_cursor s i = max 0 (min i (String.length s))

let create ?(contents = "") ?cursor_byte () =
  let cursor = match cursor_byte with
    | Some c -> clamp_cursor contents c
    | None -> String.length contents in
  { contents; cursor }

let contents t = t.contents
let cursor_byte t = t.cursor
let cursor_col t = Utf8.byte_to_col t.contents t.cursor

let set_contents ?cursor_byte t s =
  t.contents <- s;
  t.cursor <- (match cursor_byte with
    | Some c -> clamp_cursor s c
    | None -> String.length s)

let set_cursor_byte t i = t.cursor <- clamp_cursor t.contents i

let insert t s =
  let len = String.length t.contents in
  let before = String.sub t.contents 0 t.cursor in
  let after = String.sub t.contents t.cursor (len - t.cursor) in
  t.contents <- before ^ s ^ after;
  t.cursor <- t.cursor + String.length s

let delete_back t =
  if t.cursor > 0 then begin
    let len = String.length t.contents in
    let prev = Utf8.prev t.contents t.cursor in
    let before = String.sub t.contents 0 prev in
    let after = String.sub t.contents t.cursor (len - t.cursor) in
    t.contents <- before ^ after;
    t.cursor <- prev
  end

let delete_forward t =
  let len = String.length t.contents in
  if t.cursor < len then begin
    let next = Utf8.next t.contents t.cursor in
    let before = String.sub t.contents 0 t.cursor in
    let after = String.sub t.contents next (len - next) in
    t.contents <- before ^ after
  end

let handle_key t (ev : Input.event) =
  match ev with
  | Input.Key (cp, mods)
    when not (mods.ctrl || mods.alt || mods.super)
         && cp >= 32 ->
    (* Any printable codepoint (ASCII or compose-resolved
       multi-byte). Control characters (cp < 32) and modifier-key
       combos fall through so the caller can interpret them. *)
    insert t (Utf8.encode cp);
    true
  | Input.Special (Input.Backspace, _) -> delete_back t; true
  | Input.Special (Input.Delete, _) -> delete_forward t; true
  | Input.Special (Input.Left, _) ->
    t.cursor <- Utf8.prev t.contents t.cursor;
    true
  | Input.Special (Input.Right, _) ->
    t.cursor <- Utf8.next t.contents t.cursor;
    true
  | Input.Special (Input.Home, _) -> t.cursor <- 0; true
  | Input.Special (Input.End, _) ->
    t.cursor <- String.length t.contents; true
  | _ -> false
