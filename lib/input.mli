(** Terminal input parser.
    Reads raw bytes from stdin, parses escape sequences into events. *)

type modifier = {
  shift : bool;
  alt : bool;
  ctrl : bool;
  super : bool;
}

val no_mod : modifier

type special_key =
  | Up | Down | Left | Right
  | Home | End | PageUp | PageDown
  | Insert | Delete
  | F of int
  | Backspace | Tab | Enter | Escape

type mouse_button = Left | Middle | Right | ScrollUp | ScrollDown | Release

type mouse_event = {
  button : mouse_button;
  x : int;
  y : int;
  mods : modifier;
}

type event =
  | Key of int * modifier
  | Special of special_key * modifier
  | Mouse of mouse_event
  | Paste of string
  | Resize
  | Unknown

(** Read one complete input event. Returns None on timeout.
    [timeout] in seconds; negative = block forever. *)
val read_event : ?timeout:float -> Unix.file_descr -> event option

(** Pretty-print an event for debugging. *)
val show_event : event -> string

(** Set a debug logging function. *)
val set_debug_log : (string -> unit) -> unit
