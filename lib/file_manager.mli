(** File manager: owns file watching and handles change detection. *)

type file_event =
  | Reloaded of string          (** file was auto-reloaded *)
  | DiskChanged of string       (** file changed but buffer is dirty *)
  | VerifiedAffected of string  (** file changed within verified region *)
  | ProjectChanged              (** project tree gained or lost entries *)
  | SourcesChanged
      (** Something that could change what [rocq dep] outputs happened:
          a .v file was added, removed, or its contents changed; or the
          project file was added, removed, or edited. Coalesced to at
          most one per [poll] call. *)
  | BuildArtifactChanged
      (** A .v or .vo inside a watched project subdirectory was written,
          created, or removed. Refresh per-file build status. Coalesced
          to at most one per [poll] call. *)

type t

val create : unit -> t
val watch_fd : t -> Unix.file_descr
val add_watch : t -> string -> unit
val close : t -> unit

(** Start watching a project directory tree recursively. Subsequent
    file/dir additions inside the tree are auto-watched. Calling again
    with a different [dir] tears down the old watches first. Skips
    [_build], [.git], and other dot-directories. *)
val set_project_dir : t -> string -> unit

(** Reload a tab's buffer from disk (rewinds session, re-watches).
    If [keep_verified] is true, skip the session rewind and let the
    region-buffer gateway decide whether the reload is safe. Returns
    the gateway's result so callers can distinguish a successful
    reload from a region-violating one. *)
val reload_tab :
  ?keep_verified:bool -> t -> Tab.t -> string -> Region_buffer.result

(** Poll for file changes. Returns events for each affected tab. *)
val poll : t -> Tab.t list -> file_event list
