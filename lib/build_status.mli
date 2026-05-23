(** Per-file build status for the project's .v files, computed from
    file mtimes against the dep graph. Lives as global state alongside
    [Build_errors]; refresh explicitly when something that affects
    status changes (build finished, graph changed). *)

type status =
  | Built_fresh
  | Stale
  | Build_error
  | Never_built

(** Recompute status for every node in [graph]. Files listed in
    [error_files] (project-relative .v paths) override the mtime-based
    status with [Build_error]. *)
val refresh :
  project_dir:string ->
  graph:Dep_graph.t ->
  error_files:string list ->
  unit

(** Status of one file; rel_path is project-relative ".v". Returns
    [Never_built] for unknown paths. *)
val get : string -> status

(** Drop all cached state (e.g. when switching projects). *)
val clear : unit -> unit
