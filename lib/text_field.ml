(* Single-line text editing buffer shared by the search prompt, the
   rename prompt, and (eventually) other modal text inputs. Holds
   the contents and a byte-offset cursor; consumers do their own
   rendering and decide where to place the hardware cursor (using
   [cursor]). Focus is managed by the consumer, not the field. *)

type t = {
  mutable contents : string;
  mutable cursor : int;   (* byte offset, 0..String.length contents *)
}

let clamp_cursor s i = max 0 (min i (String.length s))

let create ?(contents = "") ?cursor () =
  let cursor = match cursor with
    | Some c -> clamp_cursor contents c
    | None -> String.length contents in
  { contents; cursor }

let contents t = t.contents
let cursor t = t.cursor

let set_contents ?cursor t s =
  t.contents <- s;
  t.cursor <- (match cursor with
    | Some c -> clamp_cursor s c
    | None -> String.length s)

let set_cursor t i = t.cursor <- clamp_cursor t.contents i

let insert t s =
  let len = String.length t.contents in
  let before = String.sub t.contents 0 t.cursor in
  let after = String.sub t.contents t.cursor (len - t.cursor) in
  t.contents <- before ^ s ^ after;
  t.cursor <- t.cursor + String.length s

(* Cursor motion and deletion respect UTF-8 codepoint boundaries via
   [Utf8.prev]/[Utf8.next] — important for users typing multi-byte
   characters through the compose layer. *)

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
