(** Linux inotify wrapper. Distinguishes file watches (track content
    changes) from directory watches (track entries created / deleted /
    moved). One [t] owns both kinds. *)

type t

type event =
  | FileChanged of string
  | DirEntryAdded of { dir : string; name : string; is_dir : bool }
  | DirEntryRemoved of { dir : string; name : string; is_dir : bool }

val create : unit -> t

(** The fd to include in [select]. *)
val watch_fd : t -> Unix.file_descr

(** Watch a file's content (mask: CLOSE_WRITE | MOVE_SELF | DELETE_SELF).
    Idempotent. If the same path was previously dir-watched, replaces
    that with a file watch. Silently no-ops when the file does not
    exist. *)
val add_watch : t -> string -> unit

(** Watch a directory's entries (mask: CREATE | DELETE | MOVED_FROM |
    MOVED_TO). Recursion is the caller's job — fire [add_dir_watch] on
    each subdirectory you care about, and on [DirEntryAdded] events
    where [is_dir] is true. *)
val add_dir_watch : t -> string -> unit

(** Stop watching a path. *)
val remove_watch : t -> string -> unit

(** Drain pending events from the kernel queue. Re-attaches file
    watches when a file is replaced by atomic rename. *)
val poll : t -> event list

val close : t -> unit

(** All currently watched paths (files and dirs together). *)
val watched_paths : t -> string list
