(** System clipboard integration via OSC 52 and bracketed paste. *)

(** Enable bracketed paste mode. Call after curses init. *)
val enable_bracketed_paste : unit -> unit

(** Disable bracketed paste mode. Call before curses teardown. *)
val disable_bracketed_paste : unit -> unit

(** Copy text to the system clipboard via OSC 52. *)
val copy_to_system : string -> unit
