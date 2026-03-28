(** File modification watcher using Linux inotify. *)

type t

(** Create the inotify watcher. *)
val create : unit -> t

(** The fd to include in select. *)
val watch_fd : t -> Unix.file_descr

(** Start watching a file path. Idempotent. *)
val add_watch : t -> string -> unit

(** Stop watching a file path. *)
val remove_watch : t -> string -> unit

(** Read pending events. Returns true if any files changed. *)
val poll : t -> bool

(** Get and clear the list of changed file paths. *)
val take_changed : t -> string list

(** Close the watcher. *)
val close : t -> unit
