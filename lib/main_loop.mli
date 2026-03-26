(** Main loop model for Spawn.Async, using Unix.select.

    This replaces GLib's main loop in RocqIDE. Watched file descriptors
    are checked on each iteration of the curses event loop. *)

type async_chan = Unix.file_descr
type condition = [ `IN | `ERR | `HUP | `NVAL | `PRI ]
type watch_id = int

val add_watch : callback:(condition list -> bool) -> async_chan -> watch_id
val remove_watch : watch_id -> unit
val read_all : async_chan -> string
val async_chan_of_file_or_socket : Unix.file_descr -> async_chan

(** Select on watched fds + extra fds (like stdin), with timeout in seconds.
    Dispatches watch callbacks for ready watched fds.
    Returns the subset of [extra_fds] that are ready. *)
val select_with_watches : Unix.file_descr list -> float -> Unix.file_descr list
