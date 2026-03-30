(** File manager: owns file watching and handles change detection. *)

type file_event =
  | Reloaded of string          (** file was auto-reloaded *)
  | DiskChanged of string       (** file changed but buffer is dirty *)
  | VerifiedAffected of string  (** file changed within verified region *)

type t

val create : unit -> t
val watch_fd : t -> Unix.file_descr
val add_watch : t -> string -> unit
val close : t -> unit

(** Reload a tab's buffer from disk (rewinds session, re-watches). *)
val reload_tab : t -> Tab.t -> string -> unit

(** Poll for file changes. Returns events for each affected tab. *)
val poll : t -> Tab.t list -> file_event list
