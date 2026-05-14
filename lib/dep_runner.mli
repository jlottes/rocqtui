(** Async runner for [rocq dep -f _RocqProject]. Spawns the subprocess,
    drains its stdout non-blocking from the main loop's [select], and
    stores the latest successfully-parsed [Dep_graph.t]. Mirrors
    [Build]'s plumbing — one in-flight subprocess at a time;
    [refresh] kills the running one so the most-recent request wins. *)

type t

val create : unit -> t

(** Start (or restart) a computation for the project file at the given
    absolute path. The subprocess is spawned with the project's
    directory as CWD so emitted paths are project-relative. *)
val refresh : t -> project_file:string -> unit

(** fd to include in [select]. None when no subprocess is running. *)
val watch_fd : t -> Unix.file_descr option

(** Drain available bytes from the running subprocess. On EOF, reaps
    the child, parses the accumulated output, and replaces [graph].
    Returns [true] when a new graph was installed (the main loop
    should trigger a re-render). *)
val poll : t -> bool

(** Latest successfully-parsed graph, or [None] if no run has
    completed since [create]. *)
val graph : t -> Dep_graph.t option

(** True while a subprocess is in flight. The panel uses this to show
    "computing…" in its header. *)
val running : t -> bool

(** Kill any in-flight subprocess. Called at shutdown. *)
val close : t -> unit
