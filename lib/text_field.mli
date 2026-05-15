(** Single-line text editing buffer.

    A minimal mutable text field used by the search, rename, and other
    modal prompts. Owns its contents and a byte-offset cursor; does not
    render itself. Consumers read [contents] and [cursor], render where
    they like, and place the hardware cursor based on [cursor]. *)

type t

val create : ?contents:string -> ?cursor:int -> unit -> t

val contents : t -> string
val cursor : t -> int

val set_contents : ?cursor:int -> t -> string -> unit
val set_cursor : t -> int -> unit

(** Insert a string at the current cursor; cursor advances past it. *)
val insert : t -> string -> unit

(** Delete the byte before the cursor (Backspace). No-op at offset 0. *)
val delete_back : t -> unit

(** Delete the byte at the cursor (Delete). No-op at the end. *)
val delete_forward : t -> unit

(** Apply a key event. Returns true if the field claimed it
    (printable ASCII, Backspace, Delete, Left, Right, Home, End).
    Returns false for any other event so the caller can interpret
    Enter / Esc / Tab / modifier combos. *)
val handle_key : t -> Input.event -> bool
