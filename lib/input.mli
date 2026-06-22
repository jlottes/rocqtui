(** Terminal input parser.
    A push-based state machine: feed raw bytes in via [feed], drain parsed
    events via [next_event]. State persists across [feed] calls, so a
    sequence split across read boundaries (paste markers, CSI escapes,
    multi-byte UTF-8) is parsed correctly. *)

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

(** Parser state. Create one and keep it for the lifetime of the input
    source; it carries partial-sequence state between [feed] calls. *)
type t

val create : unit -> t

(** Push [len] bytes from [bytes] (starting at [off]) through the parser,
    enqueuing any complete events. *)
val feed : t -> bytes -> off:int -> len:int -> unit

(** Dequeue the next parsed event, or [None] if none are ready. *)
val next_event : t -> event option

(** True iff the parser is holding a lone ESC awaiting disambiguation.
    When true, the event loop should shorten its select timeout and call
    [flush] once the cycle goes idle. No other parser state is "pending":
    machine-emitted sequences just wait for their remaining bytes. *)
val pending : t -> bool

(** Resolve a held lone ESC as an [Escape] event. No-op unless [pending]. *)
val flush : t -> unit

(** True iff any currently-queued event satisfies [pred]. Non-destructive
    — leaves the queue intact (used by the interrupt hook to detect ^C
    without consuming other events). *)
val any_queued : t -> (event -> bool) -> bool

(** Read whatever bytes are immediately available on [fd] (non-blocking)
    and feed them. Returns the number of bytes fed (0 on EOF / nothing
    available). *)
val read_available : t -> Unix.file_descr -> int

(** Blocking convenience for standalone tools: return the next event,
    blocking on [fd] up to [timeout] seconds (negative = forever).
    Returns [None] on timeout. Not for the main event loop — use
    [feed]/[next_event]/[flush] there. *)
val read_event : ?timeout:float -> t -> Unix.file_descr -> event option

(** Pretty-print an event for debugging. *)
val show_event : event -> string

(** Set a debug logging function. *)
val set_debug_log : (string -> unit) -> unit
