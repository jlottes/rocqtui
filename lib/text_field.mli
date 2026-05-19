(** Single-line text editing buffer.

    A minimal mutable text field used by the search, rename, and other
    modal prompts. Owns its contents and a byte-offset cursor; does not
    render itself.

    Three positions exist conceptually:

    - byte offset — what we store; suitable for slicing the string;
    - codepoint index — never materialised, the byte cursor always sits
      on a codepoint boundary so codepoint-level operations (Left/Right,
      Backspace/Delete) work directly on bytes via [Utf8.prev]/[next];
    - column — what [Render.place_cursor_*] needs; computed on demand.

    Consumers read [contents] and place the hardware cursor using
    [cursor_col]. They should not generally need [cursor_byte] unless
    they're slicing [contents]. *)

type t

val create : ?contents:string -> ?cursor_byte:int -> unit -> t

val contents : t -> string

(** Byte offset of the cursor in [contents], 0..String.length contents.
    Always on a UTF-8 codepoint boundary. *)
val cursor_byte : t -> int

(** Display column of the cursor — sum of codepoint widths up to the
    byte cursor. Use this when placing the hardware cursor. *)
val cursor_col : t -> int

val set_contents : ?cursor_byte:int -> t -> string -> unit
val set_cursor_byte : t -> int -> unit

(** Insert a string at the current cursor; cursor advances past it. *)
val insert : t -> string -> unit

(** Delete the codepoint before the cursor (Backspace). No-op at offset 0. *)
val delete_back : t -> unit

(** Delete the codepoint at the cursor (Delete). No-op at the end. *)
val delete_forward : t -> unit

(** Apply a key event. Returns true if the field claimed it
    (printable codepoint, Backspace, Delete, Left, Right, Home, End).
    Returns false for any other event so the caller can interpret
    Enter / Esc / Tab / modifier combos. *)
val handle_key : t -> Input.event -> bool
